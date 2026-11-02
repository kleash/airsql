// Ported from AirSCP 1.4.0 Tests/AirSCPTests/Support.swift: the tests' isolation, polling and throwaway sshd. The
// parts built on AirSCP's sessions, hosts and Runner come with the lanes that port those types.
import Darwin
import Foundation
@testable import AirSQLCore

/// Test-wide isolation, set up once: a short folder for everything the tests create, an ssh_config that every ssh the
/// tests run gets with -F (never ~/.ssh/config), and an environment for the commands they run: a scratch HOME and no
/// agent. Every ssh also names its key file and known_hosts explicitly, so nothing under the real ~/.ssh is used.
enum TestEnvironment {
    /// Everything the tests create (short, because unix socket paths are limited to 104 bytes).
    static let root: String = {
        // Folders of earlier runs whose test process has gone (the name carries its pid).
        for name in (try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? [] where name.hasPrefix("airsql-test.") {
            let pid = name.split(separator: ".").dropFirst().first.flatMap { Int32($0) } ?? 0
            if pid <= 0 || (kill(pid, 0) == -1 && errno == ESRCH) { try? FileManager.default.removeItem(atPath: "/tmp/" + name) }
        }
        var template = Array("/tmp/airsql-test.\(getpid()).XXXXXX".utf8CString)
        // The real path (/private/tmp/…), as ssh and sshd report it.
        return String(cString: realpath(mkdtemp(&template)!, nil))
    }()

    /// The ssh_config every test command gets with -F: no hosts at all, so only the command line counts.
    static var sshConfig: String { root + "/ssh_config" }

    /// The environment of the commands the tests run (`run`, the sshd, Lab's ssh): what the test process has, with
    /// HOME in the scratch folder (ssh-copy-id and friends write in $HOME/.ssh) and no agent.
    static var environment: [String: String] {
        ProcessInfo.processInfo.environment.merging(["HOME": root + "/local-home", "SSH_AUTH_SOCK": ""]) { $1 }
    }

    static let isolated: Void = {
        try? "# The tests' ssh_config: no hosts, so nothing from ~/.ssh/config.\n"
            .write(toFile: sshConfig, atomically: true, encoding: .utf8)
        try? FileManager.default.createDirectory(atPath: root + "/local-home/.ssh", withIntermediateDirectories: true)
        // Never the real settings folder, and so never the login Keychain: a throwaway instance's passwords stay in memory.
        setenv("AIRSQL_SUPPORT_DIR", root + "/support", 1)
        Keychain.memoryOnly = true
        Keychain.readItem = { (errSecItemNotFound, nil) }
        Keychain.writeItem = { _ in errSecSuccess }
        // No window animations (a window freed while one runs crashed AirSCP's test process), and nothing an earlier run
        // saved in the defaults.
        UserDefaults.standard.register(defaults: ["NSAutomaticWindowAnimationsEnabled": false, "NSWindowResizeTime": 0.001])
        UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
        // After a menu, window-server events stop the main run loop: rerun it, as NSApp.run does.
        if #available(macOS 27, *) {
            RunLoop.main.add(Timer(timeInterval: 0, repeats: false) { _ in RunLoop.main.run() }, forMode: .common)
        }
    }()
}

/// A failure in the tests' own machinery (a server that didn't start, a command that failed).
struct SupportError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A thread-safe list.
final class Recorder<Item> {
    private let lock = NSLock()
    private var items: [Item] = []

    func append(_ item: Item) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
    }

    var all: [Item] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Polls until `condition` holds or `timeout` passes. 120 s: what holds at once on an idle Mac took tens of seconds on
/// CI's three-core runners under the whole suite (whose main queue stalls there for a minute at times), and over a
/// minute on a Mac with twice as many busy threads as cores. Only a failing test waits that long.
func eventually(timeout: TimeInterval = 120, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return await condition()
}

/// A throwaway sshd on 127.0.0.1, run as this user with its own config, host key, authorized_keys and HOME (all in a
/// temporary folder). A watchdog shell kills it, and every ssh started for the tests, if the test process dies.
final class TestServer {
    struct Options {
        /// Password logins allowed. sshd, run as this user, can't check a password: each one is refused, and ssh asks
        /// again (the prompts are what such a test is after).
        var passwords = false
    }

    static let passphrase = "airsql test passphrase"

    let root: String
    /// The remote HOME.
    let home: String
    let port: Int
    let plainKey: String
    /// Protected with `passphrase`.
    let encryptedKey: String
    let knownHosts: String
    private let watchdog: Process

    private init(root: String, home: String, port: Int, plainKey: String, encryptedKey: String, knownHosts: String,
                 watchdog: Process) {
        self.root = root
        self.home = home
        self.port = port
        self.plainKey = plainKey
        self.encryptedKey = encryptedKey
        self.knownHosts = knownHosts
        self.watchdog = watchdog
    }

    deinit { stopServer() }

    static func start(_ options: Options = Options()) async throws -> TestServer {
        _ = TestEnvironment.isolated
        var template = Array((TestEnvironment.root + "/server.XXXXXX").utf8CString)
        let root = String(cString: mkdtemp(&template)!)
        // A space in the keys' folder, as in real paths: what quotes an IdentityFile gets it here.
        let home = root + "/home", keys = root + "/keys dir"
        for dir in [home, keys] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let plainKey = keys + "/id_plain", encryptedKey = keys + "/id_enc"
        try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "host", "-f", root + "/host_key"])
        try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "plain", "-f", plainKey])
        try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", passphrase, "-C", "encrypted", "-f", encryptedKey])
        let authorized = try String(contentsOfFile: plainKey + ".pub") + String(contentsOfFile: encryptedKey + ".pub")
        try authorized.write(toFile: root + "/authorized_keys", atomically: true, encoding: .utf8)

        for _ in 0..<5 {
            let port = freePort()
            let config = """
                Port \(port)
                ListenAddress 127.0.0.1
                HostKey \(root)/host_key
                AuthorizedKeysFile \(root)/authorized_keys \(home)/.ssh/authorized_keys
                PidFile \(root)/sshd.pid
                UsePAM no
                StrictModes no
                PasswordAuthentication \(options.passwords ? "yes" : "no")
                KbdInteractiveAuthentication no
                PermitUserRC no
                PermitUserEnvironment no
                SetEnv HOME=\(home)
                """
            try config.write(toFile: root + "/sshd_config", atomically: true, encoding: .utf8)
            let logFile = root + "/sshd.log"
            try? FileManager.default.removeItem(atPath: logFile)
            let script = """
                /usr/sbin/sshd -D -f "$1" -E "$2" &
                sshd=$!
                trap 'kill $sshd 2>/dev/null; exit 0' TERM
                while kill -0 "$3" 2>/dev/null && kill -0 $sshd 2>/dev/null; do sleep 1; done
                kill $sshd 2>/dev/null
                kill -0 "$3" 2>/dev/null || pkill -f "$4"
                """
            let watchdog = Process()
            watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
            watchdog.arguments = ["-c", script, "sh", root + "/sshd_config", logFile, String(getpid()), TestEnvironment.root]
            watchdog.environment = TestEnvironment.environment
            watchdog.standardInput = FileHandle.nullDevice
            watchdog.standardOutput = FileHandle.nullDevice
            watchdog.standardError = FileHandle.nullDevice
            try watchdog.run()
            let server = TestServer(root: root, home: home, port: port, plainKey: plainKey, encryptedKey: encryptedKey,
                                    knownHosts: root + "/known_hosts", watchdog: watchdog)
            let ready = await eventually {
                let text = (try? String(contentsOfFile: logFile)) ?? ""
                return text.contains("Server listening") || text.contains("Bind to port") || text.contains("fatal")
            }
            if ready, ((try? String(contentsOfFile: logFile)) ?? "").contains("Server listening") { return server }
            server.stopServer()
        }
        throw SupportError("The test sshd didn't start; see \(root)/sshd.log")
    }

    /// The options of an ssh to this server (the destination, 127.0.0.1 or another name for it such as localhost,
    /// comes after them): the tests' ssh_config, the plain key (or `key`), this server's own known_hosts with new host
    /// keys trusted, no agent and no questions.
    func sshOptions(key: String? = nil) -> [String] {
        ["-F", TestEnvironment.sshConfig, "-p", String(port), "-i", key ?? plainKey, "-o", "IdentitiesOnly=yes",
         "-o", "IdentityAgent=none", "-o", "UserKnownHostsFile=\(knownHosts)", "-o", "StrictHostKeyChecking=accept-new",
         "-o", "BatchMode=yes"]
    }

    /// Stops sshd and deletes the server's folder.
    func shutdown() async {
        stopServer()
        _ = await eventually(timeout: 5) { !FileManager.default.fileExists(atPath: self.root + "/sshd.pid") }  // sshd removes it
        try? FileManager.default.removeItem(atPath: root)
    }

    private func stopServer() {
        if let text = try? String(contentsOfFile: root + "/sshd.pid"),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            // Its connections first (sshd's children): they outlive sshd, and so would the master ssh of a session the
            // test didn't disconnect itself.
            let connections = Process()
            connections.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            connections.arguments = ["-TERM", "-P", String(pid)]
            if (try? connections.run()) != nil { connections.waitUntilExit() }
            kill(pid, SIGTERM)
        }
        if watchdog.isRunning { watchdog.terminate() }
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                bind(fd, pointer, length)
                return getsockname(fd, pointer, &length)
            }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// Runs a tool with the tests' environment (`TestEnvironment.environment` plus `environment`) and throws if it fails.
@discardableResult
func run(_ argv: [String], environment: [String: String] = [:]) async throws -> (output: String, stderr: String) {
    _ = TestEnvironment.isolated
    // Files, not pipes: a tool that fills one pipe while nobody reads it would wait for ever.
    let base = TestEnvironment.root + "/run-" + UUID().uuidString.prefix(8)
    defer { for suffix in [".out", ".err"] { try? FileManager.default.removeItem(atPath: base + suffix) } }
    for suffix in [".out", ".err"] { FileManager.default.createFile(atPath: base + suffix, contents: nil) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: argv[0])
    process.arguments = Array(argv.dropFirst())
    process.environment = TestEnvironment.environment.merging(environment) { $1 }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: base + ".out"))
    process.standardError = try FileHandle(forWritingTo: URL(fileURLWithPath: base + ".err"))
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
    }
    let output = (try? String(contentsOfFile: base + ".out", encoding: .utf8)) ?? ""
    let stderr = (try? String(contentsOfFile: base + ".err", encoding: .utf8)) ?? ""
    guard status == 0 else { throw SupportError("\(argv.joined(separator: " ")) failed (\(status)): \(stderr)") }
    return (output, stderr)
}

/// Starts a test server, runs `body` and always shuts the server down.
func withServer(_ options: TestServer.Options = TestServer.Options(), _ body: (TestServer) async throws -> Void) async throws {
    let server = try await TestServer.start(options)
    do {
        try await body(server)
    } catch {
        await server.shutdown()
        throw error
    }
    await server.shutdown()
}

/// A fresh local scratch folder for one test, under `TestEnvironment.root` (short enough for unix sockets in it).
func scratch() throws -> String {
    _ = TestEnvironment.isolated
    let path = TestEnvironment.root + "/local-" + UUID().uuidString.prefix(8)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}
