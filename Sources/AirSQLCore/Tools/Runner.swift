// Ported from AirSCP 1.4.0 Sources/AirSCPCore/Runner.swift: CommandResult, Cancellation and Runner's spawning, reaping
// and draining (posix_spawn into a process group of its own, socket pairs for pipes), without what only OpenSSH needs
// there (the debug log, sentinels, the pseudo-terminal, the master connection). `output` and `input`, the client
// tools' pipelines, are AirSQL's own.
import Darwin
import Foundation

/// What a finished command produced.
public struct CommandResult: Sendable {
    /// The exit status; 128 + the signal number when a signal ended it, 127 when it couldn't start.
    public var status: Int32
    public var stdout: Data
    public var stderr: String

    public init(status: Int32, stdout: Data = Data(), stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var output: String { String(decoding: stdout, as: UTF8.self) }
}

/// Stops running commands (SIGTERM to each one's process group), or keeps a queued one from starting.
public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: Set<pid_t> = []
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.locked { cancelled } }

    public func cancel() {
        lock.locked {
            cancelled = true
            for pid in pids { kill(-pid, SIGTERM) }
        }
    }

    /// Records a started process; kills it at once if the cancellation came first.
    fileprivate func attach(_ pid: pid_t) {
        lock.locked {
            pids.insert(pid)
            if cancelled { kill(-pid, SIGTERM) }
        }
    }

    /// The process has exited (not yet reaped): its process group id may not be signalled any more.
    fileprivate func detach(_ pid: pid_t) {
        lock.locked { _ = pids.remove(pid) }
    }
}

/// Runs the client tools (mysql, mysqldump, gzip). posix_spawn, not Foundation's Process: Process turns arguments into
/// decomposed Unicode (NFD), which would change database and file names written in precomposed form (NFC).
public enum Runner {
    /// How a pipeline went: the tool (mysqldump, mysql), the filter between it and the file (gzip), if any, the bytes
    /// this process copied, and the errno of a copy that failed (the disk is full; the tool stopped reading).
    public struct Piped: Sendable {
        public var tool: CommandResult
        public var filter: CommandResult?
        public var bytes: Int64 = 0
        public var ioError: Int32?
    }

    /// Runs `argv` to its end with its output and error output collected, cancelled after `timeout` seconds.
    public static func run(_ argv: [String], environment: [String: String] = [:], timeout: TimeInterval = 10) async -> CommandResult {
        let cancellation = Cancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { cancellation.cancel() }
        return await detached {
            guard let out = makePipe() else { return CommandResult(status: 127, stderr: "Can't start \(argv[0]): no pipe") }
            let started = Started(argv, stdin: -1, stdout: out.1, environment: environment, cancellation: cancellation)
            close(out.1)
            var data = Data()
            drain(out.0) { data.append($0); return true }
            var result = started.finish(cancellation)
            result.stdout = data
            return result
        }
    }

    /// Runs `tool` with its standard output written into `sink` by this process, so it can be counted and looked at:
    /// `chunk` gets each part on a background thread, and `begun` once, at the first part (the tool has connected).
    public static func output(of tool: [String], into sink: Writer, environment: [String: String] = [:],
                              cancellation: Cancellation, begun: @escaping () -> Void = {},
                              chunk: @escaping (Data) -> Void = { _ in }) async -> Piped {
        await detached {
            var piped = Piped(tool: CommandResult(status: 0), filter: nil)
            if let out = makePipe() {
                let started = Started(tool, stdin: -1, stdout: out.1, environment: environment, cancellation: cancellation)
                close(out.1)
                drain(out.0) { data in
                    if piped.bytes == 0 { begun() }
                    guard !cancellation.isCancelled else { return false }
                    guard sink.write(data) else {
                        piped.ioError = errno
                        return false
                    }
                    piped.bytes += Int64(data.count)
                    chunk(data)
                    return true
                }
                piped.tool = started.finish(cancellation)
            } else {
                piped.tool = CommandResult(status: 127, stderr: "Can't start \(tool[0]): no pipe")
            }
            piped.filter = sink.finish()
            return piped
        }
    }

    /// Runs `tool` with what `source` reads written into its standard input by this process, so it can be counted:
    /// `progress` gets the bytes of the file taken so far, on a background thread. `begun` runs once the tool has taken
    /// in 64 KB (so it is connected and reading), or when it ends. The tool's output is dropped; its error output is in
    /// the result, and `errorOutput` gets it as it comes.
    public static func input(of tool: [String], from source: Inflow, environment: [String: String] = [:],
                             cancellation: Cancellation, begun: @escaping () -> Void = {},
                             errorOutput: @escaping (String) -> Void = { _ in }, progress: @escaping (Int64) -> Void) async -> Piped {
        await detached {
            var piped = Piped(tool: CommandResult(status: 127, stderr: "Can't start \(tool[0]): no pipe"), filter: nil)
            var told = false
            if let input = makePipe() {
                _ = fcntl(input.1, F_SETNOSIGPIPE, 1)  // a tool that ends early must not take the app down
                let started = Started(tool, stdin: input.0, stdout: -1, environment: environment, cancellation: cancellation,
                                      errorOutput: errorOutput)
                close(input.0)
                var fed: Int64 = 0
                while !cancellation.isCancelled, let data = source.next(65536) {
                    guard data.withUnsafeBytes({ writeAll(input.1, $0) }) else { break }  // the tool stopped reading
                    fed += Int64(data.count)
                    if fed >= 65536 && !told {
                        told = true
                        begun()
                    }
                    progress(source.fed)
                }
                close(input.1)
                piped.tool = started.finish(cancellation)
            }
            piped.filter = source.finish()
            piped.bytes = source.fed
            piped.ioError = source.readError
            if !told { begun() }
            return piped
        }
    }

    // MARK: Streams this process reads or writes

    /// What this process writes (AirSQL's own export) going into `file`, through `filter` (gzip -c) when given: the
    /// filter writes the file. `finish` closes the stream and waits for the filter. The caller closes `file`.
    public final class Writer {
        private let target: Int32
        private let filtering: Started?
        private let cancellation: Cancellation
        public private(set) var bytes: Int64 = 0

        public init(file: Int32, through filter: [String]?, cancellation: Cancellation) throws {
            self.cancellation = cancellation
            guard let filter else {
                target = file
                filtering = nil
                return
            }
            guard let pipe = makePipe() else { throw AirSQLError(.other, "Can't start \(filter[0]): no pipe") }
            _ = fcntl(pipe.1, F_SETNOSIGPIPE, 1)
            filtering = Started(filter, stdin: pipe.0, stdout: file, environment: [:], cancellation: cancellation)
            close(pipe.0)
            target = pipe.1
        }

        public func write(_ text: String) throws {
            guard write(Data(text.utf8)) else { throw AirSQLError(.other, "Can't write the file: \(String(cString: strerror(errno)))") }
        }

        /// False when the bytes can't be written (errno says why: the disk is full, the filter ended).
        public func write(_ data: Data) -> Bool {
            guard data.withUnsafeBytes({ writeAll(target, $0) }) else { return false }
            bytes += Int64(data.count)
            return true
        }

        /// Ends the stream: the filter's status (nil without one).
        public func finish() -> CommandResult? {
            guard let filtering else { return nil }
            close(target)
            return filtering.finish(cancellation)
        }
    }

    /// What this process reads from `file`, through `filter` (gzip -dc) when given: `next` gives the text in pieces,
    /// `fed` how much of the file has been taken so far (so progress is real for a compressed file too). The caller
    /// closes `file` after `finish`.
    public final class Inflow: @unchecked Sendable {
        private let file: Int32
        private let source: Int32
        private let filtering: Started?
        private let cancellation: Cancellation
        private let lock = NSLock()
        private var taken: Int64 = 0
        private var failed: Int32?
        private let copied = DispatchGroup()

        public init(file: Int32, through filter: [String]?, cancellation: Cancellation) throws {
            self.file = file
            self.cancellation = cancellation
            guard let filter else {
                source = file
                filtering = nil
                return
            }
            guard let into = makePipe(), let out = makePipe() else { throw AirSQLError(.other, "Can't start \(filter[0]): no pipe") }
            _ = fcntl(into.1, F_SETNOSIGPIPE, 1)
            filtering = Started(filter, stdin: into.0, stdout: out.1, environment: [:], cancellation: cancellation)
            close(into.0)
            close(out.1)
            source = out.0
            copied.enter()
            Thread.detachNewThread { [self] in
                var buffer = [UInt8](repeating: 0, count: 65536)
                while !cancellation.isCancelled {
                    let count = read(file, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    if count < 0 { lock.locked { failed = errno } }
                    guard count > 0, buffer.withUnsafeBytes({ writeAll(into.1, UnsafeRawBufferPointer(rebasing: $0[0..<count])) })
                    else { break }
                    lock.locked { taken += Int64(count) }
                }
                close(into.1)
                copied.leave()
            }
        }

        /// Bytes of the file taken so far.
        public var fed: Int64 { lock.locked { taken } }
        /// The errno of a read of the file that failed: what was read is not all of it.
        public var readError: Int32? { lock.locked { failed } }

        /// The next piece (up to `size` bytes), nil at the end. Blocks: call it off the main thread.
        public func next(_ size: Int = 4 << 20) -> Data? {
            var data = Data(count: size), filled = 0
            while filled < size && !cancellation.isCancelled {
                let count = data.withUnsafeMutableBytes { read(source, $0.baseAddress! + filled, size - filled) }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && filtering == nil { lock.locked { failed = errno } }
                guard count > 0 else { break }
                filled += count
                if filtering == nil { lock.locked { taken += Int64(count) } }
            }
            return filled == 0 ? nil : data.prefix(filled)
        }

        /// Ends the reading: the filter's status (nil without one).
        public func finish() -> CommandResult? {
            guard let filtering else { return nil }
            close(source)
            copied.wait()
            return filtering.finish(cancellation)
        }
    }

    // MARK: Internals

    /// Runs `work` on a thread of its own: it blocks (reading pipes, waiting for processes), so not on Dispatch's
    /// shared threads, which can run out.
    private static func detached<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: work()) }
        }
    }

    /// A started command, its error output collected (the end kept: a tool's last words say how it ended).
    private final class Started {
        private let pid: pid_t?
        private let failed: String?
        private let lock = NSLock()
        private var errors = Data()
        private let drained = DispatchGroup()
        private static let errorLimit = 65536

        /// `stdin` and `stdout`: descriptors for the command (-1: /dev/null); the caller closes its own copies.
        init(_ argv: [String], stdin: Int32, stdout: Int32, environment: [String: String], cancellation: Cancellation,
             errorOutput: ((String) -> Void)? = nil) {
            let devNull = open("/dev/null", O_RDWR | O_CLOEXEC)
            defer { close(devNull) }
            guard let err = makePipe() else {
                pid = nil
                failed = "Can't start \(argv[0]): \(String(cString: strerror(errno)))"
                return
            }
            do {
                let pid = try spawn(argv, environment: environment, stdin: stdin >= 0 ? stdin : devNull,
                                    stdout: stdout >= 0 ? stdout : devNull, stderr: err.1)
                self.pid = pid
                failed = nil
                cancellation.attach(pid)
            } catch {
                pid = nil
                failed = error.localizedDescription
            }
            close(err.1)
            drained.enter()
            Thread.detachNewThread { [self] in
                drain(err.0) { data in
                    errorOutput?(String(decoding: data, as: UTF8.self))
                    lock.locked {
                        errors.append(data)
                        if errors.count > 2 * Self.errorLimit { errors = errors.suffix(Self.errorLimit) }
                    }
                    return true
                }
                drained.leave()
            }
        }

        /// Waits for the command to end; its status and error output.
        func finish(_ cancellation: Cancellation) -> CommandResult {
            guard let pid else {
                drained.wait()
                return CommandResult(status: 127, stderr: failed ?? "Can't start")
            }
            let status = reap(pid, cancellation: cancellation)
            // Error output still buffered arrives right after the exit; a child it started may hold the pipe: not long.
            _ = drained.wait(timeout: .now() + (cancellation.isCancelled ? 0.2 : 2))
            return lock.locked {
                var kept = errors
                if kept.count > Self.errorLimit {  // from the start of a line
                    kept = kept.suffix(Self.errorLimit)
                    if let newline = kept.firstIndex(of: 0x0A) { kept = kept[(newline + 1)...] }
                }
                return CommandResult(status: status, stderr: String(decoding: kept, as: UTF8.self))
            }
        }
    }

    /// A connected pair of sockets, used like a pipe (.0 reads, .1 writes), whose ends children don't inherit unless
    /// given them. Not a pipe: when the system's pipe buffers run short, each pipe read returns 512 bytes.
    private static func makePipe() -> (Int32, Int32)? {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return nil }
        fds.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        return (fds[0], fds[1])
    }

    private static func spawn(_ argv: [String], environment: [String: String], stdin: Int32, stdout: Int32,
                              stderr: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors above are inherited (the app's other pipes and sockets are not), the child
        // gets default signal handling, and it leads a process group of its own so cancelling reaches its children.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
                                                     | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        let env = childEnvironment(ProcessInfo.processInfo.environment, environment)
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, &attributes, cArgs, cEnv)
        guard rc == 0 else { throw AirSQLError(.other, "Can't start \(argv[0]): \(String(cString: strerror(rc)))") }
        return pid
    }

    /// A tool's environment: this app's with `extra`, without the MYSQL_ and MARIADB_ variables the tools read
    /// (MYSQL_PWD is a password, MYSQL_HOST and the like would change where they connect, MYSQL_TEST_LOGIN_FILE which
    /// login file they read). An app started from the Finder has no locale variables: UTF-8 is asked for then.
    static func childEnvironment(_ base: [String: String], _ extra: [String: String]) -> [String: String] {
        var env = base.filter { !$0.key.hasPrefix("MYSQL_") && !$0.key.hasPrefix("MARIADB_") }
        env.merge(extra) { $1 }
        if env["LC_ALL"] == nil && env["LC_CTYPE"] == nil && env["LANG"] == nil { env["LC_CTYPE"] = "C.UTF-8" }
        return env
    }

    /// Waits for the process to exit, tells `cancellation` before the pid can be reused, then reaps it.
    private static func reap(_ pid: pid_t, cancellation: Cancellation?) -> Int32 {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
        cancellation?.detach(pid)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// Reads `fd` to its end (or until `chunk` returns false) on this thread, then closes it.
    private static func drain(_ fd: Int32, chunk: (Data) -> Bool) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                if !chunk(Data(buffer[0..<count])) { break }
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        close(fd)
    }

    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }
}
