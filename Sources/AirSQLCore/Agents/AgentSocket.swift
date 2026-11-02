// Ported from AirSCP 1.4.0: the app's agent socket (Sources/AirSCP/AgentServer.swift's init, acceptLoop and serve) and
// the helper's side of it (Sources/AirSCPCore/Askpass.swift's exchange and unixAddress). Here a reply may come after
// progress lines, one JSON object per line.
import Darwin
import Foundation
import os

/// The running app's agent socket: `<support dir>/agent/sock` (0600) in a folder only this user can open (0700), next
/// to `token` (0600, new at each start). It takes one JSON request per connection, `{tool, arguments, client, token}`,
/// from processes of this user carrying the token, and answers with zero or more progress lines,
/// `{"progress": {progress, total?, message?}}`, then the reply, one JSON object per line. Anything else gets no answer.
/// The token is readable by every process of this user, as in AirSCP (plan R18).
public final class AgentListener: @unchecked Sendable {
    /// What the app does with a request: the tool's name, its arguments, the MCP client's name, and a way to report
    /// progress. The reply is MCP's tool result (or, for `resources/…`, that method's result).
    public typealias Handler = (_ tool: String, _ arguments: [String: Any], _ client: String,
                                _ progress: @escaping (_ done: Double, _ total: Double?, _ message: String?) -> Void)
        async -> [String: Any]

    public let socketPath: String
    private let tokenPath: String
    private let token: String
    private let listener: Int32
    private let handler: Handler
    private let lock = NSLock()
    private var closed = false
    private static let log = Logger(subsystem: "com.kleash.airsql", category: "agents")

    public init(directory: URL = AgentSocket.directory, handler: @escaping Handler) throws {
        self.handler = handler
        let dir = directory.path
        socketPath = dir + "/sock"
        tokenPath = dir + "/token"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(dir, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), chmod(dir, 0o700) == 0 else {
            throw AirSQLError(.other, "The agent folder isn't a folder of yours.")
        }
        guard var address = AgentSocket.unixAddress(socketPath) else {
            throw AirSQLError(.other, AgentSocket.socketPathProblem(socketPath) ?? "")
        }
        if AgentSocket.answers(socketPath) {
            throw AirSQLError(.other, "Another AirSQL with this settings folder already lets agents in: quit it first.")
        }
        unlink(socketPath)
        var random = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&random, random.count)
        token = random.map { String(format: "%02x", $0) }.joined()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AirSQLError(.other, "Can't create the agent socket.") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(fd, SOMAXCONN) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            throw AirSQLError(.other, "Can't listen on the agent socket: \(reason)")
        }
        listener = fd
        let file = open(tokenPath, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0, fchmod(file, 0o600) == 0, write(file, token, token.utf8.count) == token.utf8.count else {
            let reason = String(cString: strerror(errno))
            if file >= 0 { Darwin.close(file) }
            Darwin.close(fd)
            unlink(socketPath)
            throw AirSQLError(.other, "Can't write the agent token: \(reason)")
        }
        Darwin.close(file)
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
        Self.log.log("agents on")
    }

    deinit { close() }

    /// Stops listening and removes the socket and the token (agents turned off, Quit).
    public func close() {
        guard lock.locked({ () -> Bool in
            defer { closed = true }
            return !closed
        }) else { return }
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(socketPath)
        unlink(tokenPath)
        rmdir((socketPath as NSString).deletingLastPathComponent)
        Self.log.log("agents off")
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
            // A request comes at once: a connection that sends nothing doesn't hold its thread for long.
            var limit = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            Thread.detachNewThread { [weak self] in
                guard let self else {
                    Darwin.close(connection)
                    return
                }
                self.serve(connection)
            }
        }
    }

    /// One request: only from this user, at most 1 MB of JSON, with the token.
    private func serve(_ connection: Int32) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(connection, &uid, &gid) == 0, uid == getuid() else {
            Darwin.close(connection)
            return
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = recv(connection, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if data.count > 1 << 20 {
                Darwin.close(connection)
                return
            }
        }
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sent = request["token"] as? String, AgentSocket.same(sent, token), let tool = request["tool"] as? String
        else {
            Darwin.close(connection)
            return
        }
        let arguments = request["arguments"] as? [String: Any] ?? [:]
        let client = String((request["client"] as? String ?? "an agent").prefix(80))
        let writer = LineWriter(connection)
        let handler = self.handler
        Task {
            let reply = await handler(tool, arguments, client) { done, total, message in
                var progress: [String: Any] = ["progress": done]
                if let total { progress["total"] = total }
                if let message { progress["message"] = message }
                writer.write(["progress": progress])
            }
            writer.write(reply)
            writer.close()
        }
    }

    /// Writes JSON lines to a connection, in order, off the caller's thread.
    private final class LineWriter: @unchecked Sendable {
        private let connection: Int32
        private let queue = DispatchQueue(label: "com.kleash.airsql.agent-reply")

        init(_ connection: Int32) { self.connection = connection }

        func write(_ object: [String: Any]) {
            var body = AgentJSON.data(object)
            body.append(0x0A)
            queue.async { [connection] in
                body.withUnsafeBytes { raw in
                    var sent = 0
                    while sent < raw.count {
                        let count = send(connection, raw.baseAddress! + sent, raw.count - sent, 0)
                        if count < 0 && errno == EINTR { continue }
                        if count <= 0 { break }
                        sent += count
                    }
                }
            }
        }

        func close() { queue.async { [connection] in Darwin.close(connection) } }
    }
}
