import Darwin
import Foundation

/// What to dump (Export with mysqldump or mariadb-dump).
public struct DumpRequest: Equatable, Sendable {
    public enum Content: String, CaseIterable, Sendable {
        case structureAndData, structure, data

        public var title: String {
            switch self {
            case .structureAndData: return "Structure and data"
            case .structure: return "Structure only"
            case .data: return "Data only"
            }
        }
    }

    /// How rows are written.
    public enum DataMode: Int, CaseIterable, Sendable {
        case insert, insertIgnore, replace, deleteInsert

        public var title: String {
            switch self {
            case .insert: return "INSERT"
            case .insertIgnore: return "INSERT IGNORE"
            case .replace: return "REPLACE"
            case .deleteInsert: return "DELETE, then INSERT"
            }
        }

        var verb: String {
            switch self {
            case .insert, .deleteInsert: return "INSERT INTO"
            case .insertIgnore: return "INSERT IGNORE INTO"
            case .replace: return "REPLACE INTO"
            }
        }
    }

    /// One database: its tables (`tables`, empty for all) and no CREATE DATABASE, so it restores into any database.
    /// Several: each whole, with CREATE DATABASE and USE.
    public var databases: [String]
    public var tables: [String] = []
    public var content = Content.structureAndData
    /// Views, routines, triggers and events.
    public var objects = true
    /// One consistent snapshot (--single-transaction).
    public var singleTransaction = true
    /// Binary as hex (--hex-blob).
    public var hexBlob = true
    public var addDropTable = false
    public var gzip = false
    public var dataMode = DataMode.insert
    /// One database: CREATE DATABASE and USE all the same, so it restores under its own name.
    public var createDatabase = false
    /// DROP DATABASE first, for whole databases only: a file of some tables mustn't drop the others.
    public var dropDatabase = false
    public var removeDefiner = false
    public var removeAutoIncrement = false
    /// Each table's rows between START TRANSACTION and COMMIT.
    public var wrapInTransactions = false
    /// The largest INSERT, in bytes of SQL.
    public var insertSize = SQLExport.statementSize
    /// The person's own options, already split into words (`ToolCommand.words`).
    public var extra: [String] = []

    public init(databases: [String], tables: [String] = []) {
        self.databases = databases
        self.tables = tables
    }

    /// What only AirSQL's own export can do, in words, nil when a dump tool can write this.
    public var builtInOnly: String? {
        if removeDefiner { return "Removing DEFINER" }
        if removeAutoIncrement { return "Removing AUTO_INCREMENT values" }
        if dataMode == .deleteInsert { return "DELETE before the rows" }
        if wrapInTransactions { return "A transaction per table" }
        if createDatabase && !tables.isEmpty { return "CREATE DATABASE with only some tables" }
        return nil
    }
}

/// The client tools' command lines for a connection (plan §2.9). The login goes in an option file only this user can
/// read, passed first as --defaults-file so ~/.my.cnf and /etc/my.cnf aren't read at all; where to connect and how
/// to check TLS follow on the command line, which never holds a secret.
public struct ToolCommand: Sendable {
    /// This run goes without the certificate check, as the person ticked (`mayRunUnchecked`); never saved.
    public var uncheckedCertificate = false
    public var tool: ClientTool
    public var options: ConnectOptions
    public var server: ServerInfo?

    public init(tool: ClientTool, options: ConnectOptions, server: ServerInfo?) {
        self.tool = tool
        self.options = options
        self.server = server
    }

    private var family: ToolVersion.Family { tool.version?.family ?? .mysql }

    /// The option file, where to connect (TCP to the host, or a Unix socket: the server's own or a route's), TLS as the
    /// connection asks for it and utf8mb4. A read-only connection's tools get a READ ONLY session, as AirSQL's own
    /// sessions do: Terminal's mysql above all. Written loose-, as mysqldump knows it only from MySQL 8.4 and
    /// mariadb-dump not at all; the dumps only read anyway.
    public func connection(optionFile: String) -> [String] {
        var args = ["--defaults-file=" + optionFile]
        switch options.endpoint {
        case .tcp: args += ["--protocol=TCP", "--host=" + options.host, "--port=\(options.port)"]
        case .socket(let path), .route(let path): args += ["--protocol=SOCKET", "--socket=" + path]
        }
        if case .socket = options.endpoint {} else { args += tls }
        args.append("--default-character-set=utf8mb4")
        if options.readOnly { args.append("--loose-init-command=SET SESSION TRANSACTION READ ONLY") }
        return args
    }

    /// The connection's TLS check in the tool family's own words (no loose- prefix: a tool that doesn't know one of these
    /// must stop rather than connect without TLS). Through a route the tools see a local socket, so MySQL's tools check
    /// the certificate's authority there but not its name; MariaDB's have no such middle ground.
    private var tls: [String] {
        var args: [String]
        let mode = options.tls.mode
        if family == .mysql {
            let routed: Bool
            if case .route = options.endpoint { routed = true } else { routed = false }
            switch mode {
            case .off: args = ["--ssl-mode=DISABLED"]
            case .required: args = ["--ssl-mode=REQUIRED"]
            case .verifyCA: args = ["--ssl-mode=VERIFY_CA"]
            case .verifyIdentity: args = [routed ? "--ssl-mode=VERIFY_CA" : "--ssl-mode=VERIFY_IDENTITY"]
            }
        } else {
            switch mode {
            case .off: args = ["--skip-ssl"]
            case .required: args = ["--ssl", "--skip-ssl-verify-server-cert"]
            case .verifyCA, .verifyIdentity: args = ["--ssl", "--ssl-verify-server-cert"]
            }
            // The pin is the check, as in AirSQL's own sessions: a wrong certificate is refused whatever the mode.
            if mode != .off, tool.takesFingerprint, let pin = pin {
                args = ["--ssl", "--skip-ssl-verify-server-cert", "--ssl-fp=" + pin]
            }
        }
        if uncheckedCertificate && mayRunUnchecked { args = ["--ssl-mode=REQUIRED"] }
        guard mode != .off else { return args }
        if let file = options.tls.caFile, !file.isEmpty { args.append("--ssl-ca=" + file) }
        if let file = options.tls.certFile, !file.isEmpty { args.append("--ssl-cert=" + file) }
        if let file = options.tls.keyFile, !file.isEmpty { args.append("--ssl-key=" + file) }
        return args
    }

    private var pin: String? { options.tls.pinnedFingerprint.flatMap { $0.isEmpty ? nil : $0 } }

    /// Whether the person may run this tool once without its certificate check (Export and Restore's tick box): it can't
    /// check the pin and there is no CA file. Only MySQL's tools: `--ssl-mode=REQUIRED` refuses a server without TLS,
    /// where MariaDB's `--ssl` without a check quietly connects in plain text.
    public var mayRunUnchecked: Bool {
        if case .socket = options.endpoint { return false }
        return family == .mysql && pin != nil && options.tls.mode != .off && (options.tls.caFile ?? "").isEmpty
    }

    /// The SQL log's line for a run without the check; nil for any other run.
    public var uncheckedNote: String? {
        uncheckedCertificate && mayRunUnchecked ? "\(tool.name) run without checking the server's certificate (TLS required)" : nil
    }

    /// Those of `tools` that can run on this connection now: usable, and able to check its certificate.
    public static func runnable(_ tools: [ClientTool], options: ConnectOptions, server: ServerInfo?) -> [ClientTool] {
        tools.filter { ClientTools.fit($0, server: server).isUsable && ToolCommand(tool: $0, options: options, server: server).tlsProblem == nil }
    }

    /// Why the tool can't check the server as this connection asks, if it can't, and what to do: a pinned certificate needs
    /// a tool that takes --ssl-fp, or the connection's CA file to check against; MySQL's tools asked to check a
    /// certificate need a CA file (they don't read macOS's trusted certificates). No tool runs without its check.
    public var tlsProblem: String? {
        if case .socket = options.endpoint { return nil }
        let tls = options.tls
        guard tls.mode != .off, !(uncheckedCertificate && mayRunUnchecked) else { return nil }
        let hasCA = !(tls.caFile ?? "").isEmpty, verifies = tls.mode == .verifyCA || tls.mode == .verifyIdentity
        if pin != nil, !tool.takesFingerprint, !(hasCA && verifies) {
            return "\(tool.name) can't check the certificate you trusted for this server. Use AirSQL's built-in, choose a "
                + "newer MariaDB tool (one that takes --ssl-fp), or add the server's CA file in the connection's TLS settings."
        }
        if family == .mysql && verifies && !hasCA {
            return "MySQL's tools check certificates only against a CA file, and this connection has none. Use AirSQL's "
                + "built-in, or add one in the connection's TLS settings."
        }
        return nil
    }

    /// mysqldump or mariadb-dump for `request`, writing the dump to its standard output.
    public func dump(_ request: DumpRequest, optionFile: String) -> [String] {
        var args = [tool.path] + connection(optionFile: optionFile)
        if request.singleTransaction { args.append("--single-transaction") }
        if request.hexBlob { args.append("--hex-blob") }
        switch request.content {
        case .structureAndData: break
        case .structure: args.append("--no-data")
        case .data: args.append("--no-create-info")
        }
        args += request.objects && request.content != .data ? ["--routines", "--events", "--triggers"] : ["--skip-triggers"]
        args.append(request.addDropTable ? "--add-drop-table" : "--skip-add-drop-table")
        if request.dataMode == .insertIgnore { args.append("--insert-ignore") }
        if request.dataMode == .replace { args.append("--replace") }
        if request.insertSize != SQLExport.statementSize { args.append("--net-buffer-length=\(request.insertSize)") }
        if request.dropDatabase && request.tables.isEmpty { args.append("--add-drop-database") }
        // MySQL 8's tools read column statistics only MySQL 8 has (written loose-: only MySQL's tools know it).
        if family == .mysql, (tool.version?.majorMinor ?? 0) >= 800,
           let server, server.flavor == .mariadb || !server.atLeast(8) {
            args.append("--loose-column-statistics=0")
        }
        args += request.extra
        if request.databases.count == 1, !(request.tables.isEmpty && (request.createDatabase || request.dropDatabase)) {
            args += request.databases + request.tables
        } else {
            args += ["--databases"] + request.databases
        }
        return args
    }

    /// mysql or mariadb running the SQL on its standard input in `database`: stopping at the first error, or going on
    /// past errors (--force).
    public func restore(into database: String, continueOnError: Bool, optionFile: String) -> [String] {
        var args = [tool.path] + connection(optionFile: optionFile) + ["--batch"]
        if continueOnError { args.append("--force") }
        return database.isEmpty ? args : args + [database]
    }

    /// mysql or mariadb for Terminal, in `database` when given.
    public func terminal(database: String, optionFile: String) -> [String] {
        let args = [tool.path] + connection(optionFile: optionFile)
        return database.isEmpty ? args : args + [database]
    }

    /// The command line to show and copy: each word quoted for a shell, the option file's path left out.
    public static func display(_ argv: [String], optionFile: String) -> String {
        argv.map { word in
            word == "--defaults-file=" + optionFile ? "--defaults-file=‹private temporary file›" : shellWord(word)
        }.joined(separator: " ")
    }

    /// `word` as a shell reads it back: as is when it is plain, else in single quotes.
    public static func shellWord(_ word: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,@%+")
        if !word.isEmpty && word.unicodeScalars.allSatisfy(plain.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The person's extra options split into words as a shell would (quotes and backslashes), or why they can't be
    /// used: a password on the command line, other option files, or another output file.
    public static func words(_ text: String) throws -> [String] {
        var words: [String] = [], word = "", inWord = false, quote: Character?
        var escaped = false
        for character in text {
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\" && quote != "'" {
                escaped = true
                inWord = true
            } else if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                inWord = true
            } else if character.isWhitespace {
                if inWord { words.append(word) }
                word = ""
                inWord = false
            } else {
                word.append(character)
                inWord = true
            }
        }
        if quote != nil { throw AirSQLError(.other, "A quote in the extra options isn't closed.") }
        if inWord { words.append(word) }
        for word in words {
            let name = word.split(separator: "=", maxSplits: 1).first.map(String.init) ?? word
            if name.hasPrefix("--password") || (word.hasPrefix("-p") && !word.hasPrefix("--")) {
                throw AirSQLError(.other, "Leave the password out of the extra options: AirSQL passes it in a private file, "
                    + "never on the command line.")
            }
            if name.hasPrefix("--defaults") || name == "--no-defaults" || name.hasPrefix("--login-path") {
                throw AirSQLError(.other, "\(name) can't be used here: AirSQL gives the tool its own option file.")
            }
            if name == "--result-file" || word.hasPrefix("-r") && !word.hasPrefix("--") {
                throw AirSQLError(.other, "\(name) can't be used here: AirSQL writes the file you chose in Save to.")
            }
        }
        return words
    }
}
