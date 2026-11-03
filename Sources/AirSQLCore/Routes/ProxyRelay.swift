import Darwin
import Foundation

/// A proxy route's end on this Mac (plan §2.3): a private Unix socket whose every connection is relayed, through the
/// connection's HTTP CONNECT or SOCKS5 proxy, to one host and port: the database (Proxy only), or the first SSH host
/// (SSH + proxy, where ssh's ProxyCommand is `nc -U` to this socket). Each connection runs `ProxyConnect`'s blocking
/// handshake and then copies bytes both ways, on threads of its own (R19).
public final class ProxyRelay: @unchecked Sendable {
    public let socket: String
    private let proxy: ProxySettings
    private let password: String
    private let host: String
    private let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var open: Set<Int32> = []
    private var closed = false
    private var _lastError: AirSQLError?

    /// Why the last relayed connection failed (the proxy refused, its login was wrong), for the connect's message: the
    /// driver or ssh only see the connection close.
    public var lastError: AirSQLError? { lock.locked { _lastError } }

    /// Listens on `socket` (made anew, mode 0600, in the routes' private folder) for connections to host:port.
    public init(socket: String, proxy: ProxySettings, password: String, host: String, port: Int) throws {
        self.socket = socket
        self.proxy = proxy
        self.password = password
        self.host = host
        self.port = port
        try RouteFolder.prepare()
        unlink(socket)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = Askpass.unixAddress(socket) else {
            if fd >= 0 { Darwin.close(fd) }
            throw AirSQLError(.other, "Can't create the proxy route's socket \(socket).")
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socket, 0o600) == 0, listen(fd, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            unlink(socket)
            throw AirSQLError(.other, "Can't listen on the proxy route's socket: \(reason)")
        }
        listener = fd
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit { close() }

    /// Stops listening and ends every relayed connection.
    public func close() {
        let fds: Set<Int32>? = lock.locked {
            guard !closed else { return nil }
            closed = true
            return open
        }
        guard let fds else { return }
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(socket)
        for fd in fds { shutdown(fd, SHUT_RDWR) }
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return  // closed
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            guard track(client) else {
                Darwin.close(client)
                return
            }
            Thread.detachNewThread { [self] in relay(client) }
        }
    }

    /// Remembers an open descriptor so `close` can end it; false once closed.
    private func track(_ fd: Int32) -> Bool {
        lock.locked {
            guard !closed else { return false }
            open.insert(fd)
            return true
        }
    }

    private func forget(_ fd: Int32) {
        lock.locked { _ = open.remove(fd) }
        Darwin.close(fd)
    }

    private func relay(_ client: Int32) {
        let server: Int32, early: [UInt8]
        do {
            (server, early) = try ProxyConnect.open(proxy, password: password, host: host, port: port)
        } catch {
            lock.locked { _lastError = error as? AirSQLError ?? AirSQLError(.other, error.localizedDescription) }
            forget(client)
            return
        }
        guard track(server) else {
            Darwin.close(server)
            forget(client)
            return
        }
        lock.locked { _lastError = nil }
        let done = DispatchGroup()
        done.enter()
        Thread.detachNewThread {
            Self.pump(from: client, to: server)
            shutdown(server, SHUT_WR)
            done.leave()
        }
        if early.isEmpty || early.withUnsafeBytes({ ProxyConnect.writeAll(client, $0) }) {
            Self.pump(from: server, to: client)
        }
        shutdown(client, SHUT_RDWR)
        done.wait()
        forget(server)
        forget(client)
    }

    /// Copies `source` to `destination` until the end of `source` or an error on either.
    private static func pump(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(source, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0, buffer.withUnsafeBytes({
                ProxyConnect.writeAll(destination, UnsafeRawBufferPointer(rebasing: $0.prefix(count)))
            }) else { return }
        }
    }
}
