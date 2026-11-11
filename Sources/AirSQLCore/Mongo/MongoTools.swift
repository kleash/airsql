import Darwin
import Foundation

/// mongodump and mongorestore (mongo-plan, Phase 4): the person's own, found where mongosh is, on the route's one server
/// through its socket with `directConnection` (as mongosh), or the saved servers for Direct. The connection string has no
/// database (the tools refuse one that differs from `--db`) and an explicit `authSource`. The password goes in a private
/// YAML `--config` file (0600) holding `password:` only, removed when the run ends; the user is on the command line.
/// One `.archive.gz` streams through this process, so progress is by bytes and Cancel stops the tool.
public struct MongoToolCommand {
    public enum Tool: String, Sendable { case dump = "mongodump", restore = "mongorestore" }

    public var program: String
    public var saved: SavedConnection
    /// The route's socket for the server; nil for Direct.
    public var socket: String?
    /// This run goes with `--tlsInsecure`, as the person ticked when `tlsProblem` says the tool can't check; never saved.
    public var unchecked = false
    /// What to dump or restore (`dumpScope`, `restoreScope`).
    public var scope: [String]

    public init(program: String, saved: SavedConnection, socket: String?, scope: [String]) {
        self.program = program
        self.saved = saved
        self.socket = socket
        self.scope = scope
    }

    /// The tool in the client tools' folders (as `MongoShell.find`); nil when it isn't installed. File work.
    public static func find(_ tool: Tool, folders: [String] = ClientTools.searchFolders()) -> String? {
        folders.map { $0 + "/" + tool.rawValue }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Why the tool can't check the server's certificate as the connection does, if it can't. The tools know only
    /// `--tlsInsecure`, which skips the whole check: so a route's socket (no server name to check), Verify CA (the name
    /// alone can't be skipped) and a certificate trusted in AirSQL (they take no pin) need the person's tick box.
    /// Required without a pin checks nothing in AirSQL either, so it runs with `--tlsInsecure` as is.
    public var tlsProblem: String? {
        let tls = saved.tls, name = program.split(separator: "/").last.map(String.init) ?? program
        guard tls.mode != .off else { return nil }
        let pinned = !(tls.pinnedFingerprint ?? "").isEmpty
        if tls.mode == .required && !pinned { return nil }
        if socket != nil {
            return "Over this connection's route \(name) reaches the server through a socket on this Mac, so it can't check the "
                + "server's name in its certificate, and it can't skip only that check."
        }
        if pinned && ((tls.caFile ?? "").isEmpty || tls.mode != .verifyIdentity) {
            return "\(name) can't check the certificate you trusted in AirSQL. Choose the authority's file in the connection's TLS tab."
        }
        if tls.mode == .verifyCA { return "\(name) can't check a certificate without checking its name too, as Verify CA asks." }
        return nil
    }

    /// The command line: `config` is the password file's path (nil: no password).
    public func argv(config: String?) throws -> [String] {
        var uri = saved.mongoURI
        uri.database = ""  // the tools refuse a database in the string that differs from --db
        uri.setOption("connectTimeoutMS", nil)
        if let socket {
            // One server through its socket: the tool can't reach the others by their names.
            uri.srv = false
            uri.hosts = [MongoURI.encode(socket)]
            uri.setOption("replicaSet", nil)
            uri.setOption("directConnection", "true")
        }
        // mongodb+srv's DNS TXT record names it otherwise.
        if !saved.mongoX509, !uri.srv, uri.option("authSource") == nil { uri.setOption("authSource", "admin") }
        var argv = [program, "--uri=" + uri.string]
        if !saved.user.isEmpty { argv.append("--username=" + saved.user) }
        if let config { argv.append("--config=" + config) }
        if saved.tls.mode != .off {
            if let problem = tlsProblem {
                guard unchecked else { throw AirSQLError(.tls, problem) }
                argv.append("--tlsInsecure")
            } else if saved.tls.mode == .required {
                argv.append("--tlsInsecure")
            } else if let ca = saved.tls.caFile, !ca.isEmpty {
                argv.append("--tlsCAFile=" + ca)
            }
            if let file = saved.tls.certFile, !file.isEmpty { argv.append("--tlsCertificateKeyFile=" + file) }
        }
        return argv + scope
    }

    /// The command line to show and copy: each word quoted for a shell, the password file's path left out.
    public func display(password: Bool) -> String {
        let hidden = "‹private temporary file›"
        let argv = (try? argv(config: password ? hidden : nil)) ?? []
        return argv.map { $0 == "--config=" + hidden ? $0 : ToolCommand.shellWord($0) }.joined(separator: " ")
    }

    /// mongodump's: a database, or one of its collections, as one gzip-compressed archive on standard output.
    public static func dumpScope(database: String, collection: String?) -> [String] {
        ["--db=" + database] + (collection.map { ["--collection=" + $0] } ?? []) + ["--archive", "--gzip"]
    }

    /// mongorestore's: the archive on standard input; `rename` restores only that database of the file, under the new
    /// name; `drop` drops each collection before restoring it.
    public static func restoreScope(rename: (from: String, to: String)?, drop: Bool, gzip: Bool) -> [String] {
        var scope = ["--archive"] + (gzip ? ["--gzip"] : [])
        if let rename {
            let (from, to) = (pattern(rename.from), pattern(rename.to))
            scope += ["--nsInclude=\(from).*", "--nsFrom=\(from).*", "--nsTo=\(to).*"]
        }
        return scope + (drop ? ["--drop"] : [])
    }

    /// A database name in a namespace pattern: its \, * and $ taken literally.
    static func pattern(_ name: String) -> String {
        name.reduce(into: "") { out, character in
            if "\\*$".contains(character) { out.append("\\") }
            out.append(character)
        }
    }

    /// The database a dump's file is named after ("shop-2026-11-11-1407.archive.gz", "shop.orders.archive.gz": shop).
    public static func database(inFileName name: String) -> String {
        var base = name
        for suffix in [".gz", ".archive"] where base.hasSuffix(suffix) { base.removeLast(suffix.count) }
        if let date = base.range(of: #"-\d{4}-\d{2}-\d{2}-\d{4}$"#, options: .regularExpression) { base.removeSubrange(date) }
        return String(base.prefix { $0 != "." })
    }

    // MARK: Running

    /// The private password file: `password:` only, as YAML reads back exactly. File work.
    static func configFile(_ password: String) throws -> URL {
        try OptionFile.create(Data("password: \(OptionFile.value(password))\n".utf8), named: UUID().uuidString + ".yaml", mode: 0o600)
    }

    /// Dumps into `url` through a part file that takes its place once the tool ended well, so a stopped or failed dump
    /// leaves no file. `progress` gets the bytes written so far, on a background thread.
    public func dump(password: String?, to url: URL, cancellation: Cancellation,
                     progress: @escaping (Int64) -> Void) async throws -> Int64 {
        let config = try password.map(Self.configFile)
        defer { config.map { _ = unlink($0.path) } }
        let argv = try argv(config: config?.path)
        let part = try ToolRun.PartFile(url)
        let sink: Runner.Writer
        do {
            sink = try Runner.Writer(file: part.fd, through: nil, cancellation: cancellation)
        } catch {
            part.discard()
            throw error
        }
        var bytes: Int64 = 0
        let piped = await Runner.output(of: argv, into: sink, cancellation: cancellation, chunk: { data in
            bytes += Int64(data.count)
            progress(bytes)
        })
        guard !cancellation.isCancelled, piped.tool.status == 0, piped.ioError == nil else {
            part.discard()
            if cancellation.isCancelled { throw AirSQLError.cancelled }
            if let error = piped.ioError { throw AirSQLError(.other, "Can't write the dump: \(String(cString: strerror(error)))") }
            throw Self.failure(.dump, piped.tool)
        }
        try part.keep()
        return piped.bytes
    }

    /// Restores the archive in `url`; `progress` gets the bytes of the file read so far, on a background thread. What
    /// was restored before a stop or a failure stays. Returns mongorestore's count line ("… document(s) restored
    /// successfully. … document(s) failed to restore.").
    public func restore(password: String?, from url: URL, cancellation: Cancellation,
                        progress: @escaping (Int64) -> Void) async throws -> String? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw AirSQLError(.other, "Can't read \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let config = try password.map(Self.configFile)
        defer { config.map { _ = unlink($0.path) } }
        let argv = try argv(config: config?.path)
        let source = try Runner.Inflow(file: fd, through: nil, cancellation: cancellation)
        let piped = await Runner.input(of: argv, from: source, cancellation: cancellation, progress: progress)
        if cancellation.isCancelled { throw AirSQLError.cancelled }
        if let error = piped.ioError { throw AirSQLError(.other, "Can't read \(url.lastPathComponent): \(String(cString: strerror(error)))") }
        guard piped.tool.status == 0 else { throw Self.failure(.restore, piped.tool) }
        return Self.untimed(piped.tool.stderr).split(separator: "\n").last { $0.contains("restored successfully") }.map(String.init)
    }

    /// The tools' error output without the time each line starts with ("2026-11-11T14:07:31.460+0800\t").
    static func untimed(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { line in
            line.first?.isNumber == true ? String(line.split(separator: "\t", maxSplits: 1).last ?? line) : String(line)
        }.joined(separator: "\n")
    }

    static func failure(_ tool: Tool, _ result: CommandResult) -> AirSQLError {
        var result = result
        result.stderr = untimed(result.stderr)
        return ToolRun.failure(tool.rawValue, result)
    }
}
