// Replaces AirSCP 1.4.0's Session for AirSQL (plan §2.3, R13): one ssh per connection, started as AirSCP's Runner.start
// starts its master (posix_spawn into a process group of its own, error output drained, reaped on a thread).
import Darwin
import Foundation

/// An SSH route's end on this Mac: one ssh that forwards a private Unix socket to the database through the connection's
/// SSH hosts, `ssh -F <its ssh_config> -N -L <socket>:<database>:<port> <SSH host>` (`SSHConfig`). Prompts (passwords,
/// host keys, codes) come through askpass; the progress, hop by hop, from ssh's "Authenticated to" notes. Closing it
/// ends ssh and the jump hosts' ssh with it; ssh ending by itself (the network went away) is reported to `onExit`.
public final class Tunnel: @unchecked Sendable {
    public let socket: String
    let configPath: String
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var status: Int32?
    private var errors = ""
    private var ready = false
    private var closing = false
    private var _onExit: ((AirSQLError) -> Void)?

    /// Called once, on a background thread, when ssh ends by itself after the tunnel was up: the route dropped.
    public var onExit: ((AirSQLError) -> Void)? {
        get { lock.locked { _onExit } }
        set { lock.locked { _onExit = newValue } }
    }

    /// Variables for the ssh it runs, over this app's environment (tests: a scratch HOME, no agent).
    public static var environmentOverrides: [String: String] = [:]

    private init(socket: String, configPath: String) {
        self.socket = socket
        self.configPath = configPath
    }

    deinit { close() }

    /// Starts ssh for `connection` and waits until its socket is there (every hop logged in), or ssh has ended (the error
    /// says why). `proxySocket`: the relay to the first hop (SSH + proxy). `progress` gets "SSH to <hop> (1 of 2)" as
    /// each hop is reached, on a background thread. Cancelling the task ends ssh.
    public static func open(_ connection: SavedConnection, askpass: AskpassServer, proxySocket: String? = nil,
                            progress: @escaping (String) -> Void) async throws -> Tunnel {
        if let problem = SSHConfig.problem(with: connection) { throw AirSQLError(.other, problem) }
        try RouteFolder.prepare()
        let base = RouteFolder.base(for: connection.id)
        let tunnel = Tunnel(socket: base + ".sock", configPath: base + ".ssh_config")
        try SSHConfig.text(for: connection, proxySocket: proxySocket).write(toFile: tunnel.configPath, atomically: true,
                                                                            encoding: .utf8)
        chmod(tunnel.configPath, 0o600)
        unlink(tunnel.socket)
        let hops = connection.sshHops
        let database = connection.host.contains(":") ? "[\(connection.host)]" : connection.host
        let argv = ["/usr/bin/ssh", "-F", tunnel.configPath, "-N", "-L", "\(tunnel.socket):\(database):\(connection.port ?? 3306)",
                    "--", hops[hops.count - 1].host]
        var environment = ProcessInfo.processInfo.environment.merging(askpass.environment(for: connection.id.uuidString)) { $1 }
        environment.merge(environmentOverrides) { $1 }
        if environment["LC_ALL"] == nil && environment["LC_CTYPE"] == nil && environment["LANG"] == nil {
            environment["LC_CTYPE"] = "C.UTF-8"
        }
        func step(_ index: Int) -> String {
            index < hops.count ? "SSH to \(hops[index].displayName) (\(index + 1) of \(hops.count))"
                : "Opening the tunnel to \(connection.host)"
        }
        progress(step(0))
        var authenticated = 0
        try tunnel.start(argv, environment: environment) { line in
            guard line.hasPrefix("Authenticated to ") else { return }
            authenticated += 1
            progress(step(authenticated))
        }
        while true {
            if Task.isCancelled {
                tunnel.close()
                throw AirSQLError(.cancelled, "Connecting was cancelled.")
            }
            let (status, errors) = tunnel.lock.locked { (tunnel.status, tunnel.errors) }
            if let status {
                tunnel.close()
                throw ErrorMapping.ssh(errors, status: status)
            }
            var info = stat()
            if lstat(tunnel.socket, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK {
                tunnel.lock.locked { tunnel.ready = true }
                return tunnel
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Ends ssh (with its jump hosts' ssh and helpers: its process group) and removes the socket and the config.
    public func close() {
        let pid = lock.locked { () -> pid_t in
            closing = true
            return self.pid
        }
        if pid > 0 { kill(-pid, SIGTERM) }
        unlink(socket)
        unlink(configPath)
    }

    /// ssh's last words, for a message when the tunnel drops.
    var errorOutput: String { lock.locked { errors } }

    private func start(_ argv: [String], environment: [String: String], line: @escaping (String) -> Void) throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw AirSQLError(.other, "Can't start ssh: \(String(cString: strerror(errno)))")
        }
        fds.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        let devNull = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
        defer {
            Darwin.close(devNull)
            Darwin.close(fds[1])
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, devNull, 0)
        posix_spawn_file_actions_adddup2(&actions, devNull, 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors above are inherited, signals are as by default, and ssh leads a process group of
        // its own, so closing reaches the jump hosts' ssh it starts.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
                                                     | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, &attributes, cArgs, cEnv)
        guard rc == 0 else {
            Darwin.close(fds[0])
            throw AirSQLError(.other, "Can't start ssh: \(String(cString: strerror(rc)))")
        }
        lock.locked { self.pid = pid }
        let reader = fds[0], drained = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 16384), pending = ""
            while true {
                let count = read(reader, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                let text = String(decoding: buffer[0..<count], as: UTF8.self)
                lock.locked { errors = String((errors + text).suffix(32768)) }
                pending += text
                while let end = pending.firstIndex(where: \.isNewline) {
                    line(String(pending[..<end]))
                    pending = String(pending[pending.index(after: end)...])
                }
            }
            Darwin.close(reader)
            drained.signal()
        }
        Thread.detachNewThread { [self] in
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
            // Gone: its process group id may not be signalled any more.
            lock.locked { self.pid = 0 }
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
            _ = drained.wait(timeout: .now() + 2)  // its last words first
            let signal = raw & 0x7f, ended = signal == 0 ? (raw >> 8) & 0xff : 128 + signal
            let (report, errors): (((AirSQLError) -> Void)?, String) = lock.locked {
                status = ended
                return (ready && !closing ? _onExit : nil, self.errors)
            }
            report?(AirSQLError(.disconnected, "The SSH tunnel closed: " + ErrorMapping.ssh(errors, status: ended).message,
                                details: errors))
        }
    }
}
