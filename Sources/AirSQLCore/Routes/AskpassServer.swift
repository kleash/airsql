// Ported from AirSCP 1.4.0 Sources/AirSCPCore/Askpass.swift (AskpassServer): its socket now lives in the routes'
// private folder, and a stale one is that of an AirSQL whose process has gone.
import Darwin
import Foundation

/// The app side of askpass: listens on a socket in the routes' private folder and hands each prompt to the handler
/// registered for the asking ssh's id (a connection's), on the main queue. Prompts with no handler are cancelled. A
/// request must carry the server's token, which only the commands AirSQL starts get (in their environment). Another
/// program of the same user could still read the token from a helper's environment, so a request also says whether it
/// comes from a process AirSQL started or one of their descendants (`fromAirSQL`): saved passwords go only to those.
public final class AskpassServer: @unchecked Sendable {
    /// Called with the prompt and a reply function: pass the answer, or nil to cancel.
    public typealias Handler = (AskpassRequest, @escaping (String?) -> Void) -> Void

    /// The program ssh runs to ask (the AirSQL binary).
    public let helperPath: String
    public let socketPath: String
    /// The token: a random secret for this launch.
    private let secret: String
    private let listener: Int32
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    /// Connections waiting for an answer, with the id that asked, by a token that is never reused (unlike the
    /// descriptor: a late reply to a cancelled prompt must not answer a newer one).
    private var waiting: [UInt64: (connection: Int32, id: String)] = [:]
    private var nextToken: UInt64 = 0
    private var closed = false

    public init(helperPath: String) throws {
        self.helperPath = helperPath
        var random = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&random, random.count)
        secret = random.map { String(format: "%02x", $0) }.joined()
        try RouteFolder.prepare()
        Self.removeStaleSockets()
        socketPath = RouteFolder.path + "/askpass-\(getpid())-" + secret.prefix(8)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = Askpass.unixAddress(socketPath) else {
            if fd >= 0 { Darwin.close(fd) }
            throw AirSQLError(.other, "Can't create the askpass socket.")
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw AirSQLError(.other, "Can't listen on the askpass socket: \(String(cString: strerror(errno)))")
        }
        listener = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    deinit { close() }

    /// Sockets of AirSQLs that stopped without quitting (killed, a test run cut off): their process has gone.
    static func removeStaleSockets() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: RouteFolder.path)) ?? [] where name.hasPrefix("askpass-") {
            guard let pid = name.dropFirst("askpass-".count).split(separator: "-").first.flatMap({ Int32($0) }),
                  pid != getpid(), kill(pid, 0) == -1, errno == ESRCH
            else { continue }
            unlink(RouteFolder.path + "/" + name)
        }
    }

    /// SSH_ASKPASS and friends for an ssh whose prompts should go to the handler for `id`.
    public func environment(for id: String) -> [String: String] {
        Askpass.environment(helper: helperPath, socket: socketPath, token: secret, id: id)
    }

    /// Registers (or with nil removes) the handler for prompts from commands tagged `id`.
    public func setHandler(_ handler: Handler?, for id: String) {
        lock.locked { handlers[id] = handler }
    }

    /// Cancels every prompt from `id` that is still waiting for an answer.
    public func cancelPending(for id: String) {
        let tokens = lock.locked { waiting.filter { $0.value.id == id }.map(\.key) }
        tokens.forEach { reply($0, [:]) }
    }

    public func close() {
        let (alreadyClosed, tokens): (Bool, [UInt64]) = lock.locked {
            defer { closed = true }
            return (closed, Array(waiting.keys))
        }
        guard !alreadyClosed else { return }
        tokens.forEach { reply($0, [:]) }
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(socketPath)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let connection = accept(fd, nil, nil)
            if connection < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return  // closed
            }
            _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [weak self] in
                guard let self else {
                    Darwin.close(connection)
                    return
                }
                self.serve(connection)
            }
        }
    }

    private func serve(_ connection: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 1 << 20 {
            let count = recv(connection, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, object["token"] as? String == secret else {
            Darwin.close(connection)
            return
        }
        let fromAirSQL = Askpass.startedByThisApp(peerOf: connection)
        let (token, handler): (UInt64, Handler?) = lock.locked {
            nextToken += 1
            waiting[nextToken] = (connection, id)
            return (nextToken, handlers[id])
        }
        guard let prompt = object["prompt"] as? String, let handler else { return reply(token, [:]) }
        let request = AskpassRequest(id: id, prompt: prompt, pid: Int32(object["pid"] as? Int ?? 0), fromAirSQL: fromAirSQL)
        DispatchQueue.main.async { [self] in
            handler(request) { [weak self] answer in self?.reply(token, answer.map { ["answer": $0] } ?? [:]) }
        }
    }

    /// Sends the reply (empty: cancelled) once and closes the connection.
    private func reply(_ token: UInt64, _ object: [String: Any]) {
        guard let connection = lock.locked({ waiting.removeValue(forKey: token) })?.connection else { return }
        if let body = try? JSONSerialization.data(withJSONObject: object) {
            _ = body.withUnsafeBytes { send(connection, $0.baseAddress, $0.count, 0) }
        }
        Darwin.close(connection)
    }
}
