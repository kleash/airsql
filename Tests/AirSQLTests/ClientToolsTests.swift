import CMariaDB
import Darwin
import Foundation
import Testing
@testable import AirSQLCore

// The client tools (plan §2.9): finding them and reading their versions, which suits which server, their command lines
// (the login in a private option file, never on the command line), and the runner's pipelines.
struct ClientToolsTests {
    static func server(_ flavor: ServerInfo.Flavor, _ number: Int) -> ServerInfo {
        ServerInfo(flavor: flavor, version: "\(number)", versionNumber: number, threadID: 1, tls: nil, certificate: nil)
    }

    static func tool(_ name: String, _ family: ToolVersion.Family, _ numbers: [Int]) -> ClientTool {
        ClientTool(path: "/opt/homebrew/bin/" + name, version: ToolVersion(family: family, numbers: numbers))
    }

    @Test func versionsAreReadFromEveryKindOfVersionLine() {
        let lines: [(String, ToolVersion?)] = [
            ("mysql  Ver 8.4.3 for macos14.7 on arm64 (Homebrew)", ToolVersion(family: .mysql, numbers: [8, 4, 3])),
            ("mysqldump  Ver 9.6.0 for macos26.2 on arm64 (Homebrew)", ToolVersion(family: .mysql, numbers: [9, 6, 0])),
            ("mysql  Ver 14.14 Distrib 5.7.44, for osx10.19 (x86_64) using  EditLine wrapper",
             ToolVersion(family: .mysql, numbers: [5, 7, 44])),
            ("mysqldump  Ver 10.19 Distrib 10.5.23-MariaDB, for osx10.19 (arm64)", ToolVersion(family: .mariadb, numbers: [10, 5, 23])),
            ("mariadb from 11.8.3-MariaDB, client 15.2 for osx10.20 (arm64) using  EditLine wrapper",
             ToolVersion(family: .mariadb, numbers: [11, 8, 3])),
            ("mariadb-dump from 11.4.2-MariaDB, client 10.19 for osx10.19 (arm64)\nsecond line",
             ToolVersion(family: .mariadb, numbers: [11, 4, 2])),
            ("mysql  Ver 8.0.35-27 for Linux on x86_64 (Percona Server (GPL), Release 27)", ToolVersion(family: .mysql, numbers: [8, 0, 35])),
            ("zsh: command not found: mysql", nil),
            ("", nil),
        ]
        for (line, version) in lines { #expect(ToolVersion.parse(line) == version, "\(line)") }
    }

    @Test func toolsAreFoundInHomebrewMAMPAndPathEachOnce() async throws {
        let root = try scratch()
        func make(_ path: String, _ version: String) throws {
            try FileManager.default.createDirectory(atPath: root + (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try "#!/bin/sh\necho '\(version)'\n".write(toFile: root + path, atomically: true, encoding: .utf8)
            chmod(root + path, 0o755)
        }
        try make("/opt/homebrew/opt/mysql-client/bin/mysqldump", "mysqldump  Ver 9.6.0 for macos26.2 on arm64 (Homebrew)")
        try make("/opt/homebrew/opt/mariadb@10.11/bin/mariadb-dump", "mariadb-dump from 10.11.9-MariaDB, client 10.19 for osx10.19")
        try make("/opt/homebrew/opt/openssl@3/bin/mysqldump", "not a dump tool")
        try make("/Applications/MAMP/Library/bin/mysql80/bin/mysqldump", "mysqldump  Ver 8.0.35 for osx10.12 on x86_64 (MySQL)")
        try make("/elsewhere/mysqldump", "mysqldump  Ver 14.14 Distrib 5.6.51, for osx10.13 (x86_64)")
        // Homebrew's bin links to the formula's: one program.
        try FileManager.default.createDirectory(atPath: root + "/opt/homebrew/bin", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/opt/homebrew/bin/mysqldump",
                                                   withDestinationPath: root + "/opt/homebrew/opt/mysql-client/bin/mysqldump")
        let folders = ClientTools.searchFolders(environment: ["PATH": "/elsewhere:/usr/bin"], root: root)
        #expect(!folders.contains(root + "/opt/homebrew/opt/openssl@3/bin"))
        let tools = await ClientTools.find(.dump, folders: folders)
        #expect(tools.map(\.title) == ["mariadb-dump 10.11.9", "mysqldump 9.6.0", "mysqldump 8.0.35", "mysqldump 5.6.51"])
        // The chosen one comes first; a chosen one that isn't there says so.
        let chosen = await ClientTools.find(.dump, chosen: root + "/elsewhere/mysqldump", folders: folders)
        #expect(chosen.first?.path == root + "/elsewhere/mysqldump" && chosen.count == 4)
        let missing = try #require(await ClientTools.find(.dump, chosen: root + "/nowhere/mysqldump", folders: []).first)
        #expect(!missing.found && ClientTools.fit(missing, server: nil).message.contains("isn't there"))
        // The best for each server: its family's, closest at or above its release.
        #expect(ClientTools.best(tools, for: Self.server(.mysql, 80036))?.title == "mysqldump 8.0.35")
        #expect(ClientTools.best(tools, for: Self.server(.mysql, 90100))?.title == "mysqldump 9.6.0")
        #expect(ClientTools.best(tools, for: Self.server(.mariadb, 101106))?.title == "mariadb-dump 10.11.9")
        #expect(ClientTools.best(tools, for: Self.server(.mariadb, 110809))?.title == "mariadb-dump 10.11.9")
    }

    @Test func eachToolSaysHowWellItSuitsTheServer() {
        let mysql84 = Self.server(.mysql, 80413), maria118 = Self.server(.mariadb, 110809)
        #expect(ClientTools.fit(Self.tool("mysqldump", .mysql, [8, 4, 3]), server: mysql84) == .good("✓ suits the server (MySQL 8.4)"))
        #expect(ClientTools.fit(Self.tool("mysqldump", .mysql, [9, 6, 0]), server: mysql84).isUsable)
        guard case .warning(let older) = ClientTools.fit(Self.tool("mysqldump", .mysql, [8, 0, 36]), server: mysql84) else {
            Issue.record("an older tool should warn")
            return
        }
        #expect(older.contains("older than the server"))
        guard case .warning(let family) = ClientTools.fit(Self.tool("mysqldump", .mysql, [9, 6, 0]), server: maria118) else {
            Issue.record("another family's tool should warn")
            return
        }
        #expect(family.contains("MariaDB"))
        #expect(!ClientTools.fit(Self.tool("mysqldump", .mysql, [5, 6, 51]), server: mysql84).isUsable)
        #expect(!ClientTools.fit(Self.tool("mysqldump", .mariadb, [10, 1, 48]), server: maria118).isUsable)
        #expect(!ClientTools.fit(ClientTool(path: "/bin/sh", version: nil), server: nil).isUsable)
    }

    @Test func theLoginGoesInAPrivateOptionFileTheToolsReadBackExactly() throws {
        let folder = URL(fileURLWithPath: try scratch() + "/ClientTools")
        let password = #"p#ss "w\o'rd ; x"# + "\ttab "
        let url = try OptionFile.write(user: "app user", password: password, in: folder)
        let file = try FileManager.default.attributesOfItem(atPath: url.path)
        let dir = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect(file[.posixPermissions] as? Int == 0o600 && dir[.posixPermissions] as? Int == 0o700)
        // MySQL's own reader, when this Mac has it, reads the same user and password back.
        let reader = "/opt/homebrew/opt/mysql-client/bin/my_print_defaults"
        if FileManager.default.isExecutableFile(atPath: reader) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: reader)
            process.arguments = ["--defaults-file=" + url.path, "-s", "client"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let lines = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").map(String.init)
            #expect(lines == ["--user=app user", "--password=" + password])
        }
        // At launch, what other runs left goes; this run's files stay.
        let other = folder.appendingPathComponent("1-left.cnf")
        FileManager.default.createFile(atPath: other.path, contents: Data("x".utf8))
        OptionFile.removeLeftovers(in: folder)
        #expect(!FileManager.default.fileExists(atPath: other.path) && FileManager.default.fileExists(atPath: url.path))
    }

    @Test func commandLinesConnectAsTheConnectionDoesAndNeverHoldTheSecret() throws {
        var options = ConnectOptions(name: "Shop", host: "db.example.com", port: 3307, user: "app", password: "s3cret",
                                     tls: TLSOptions(mode: .verifyIdentity, caFile: "/certs/ca.pem"))
        let mysql = ToolCommand(tool: Self.tool("mysqldump", .mysql, [8, 4, 3]), options: options, server: Self.server(.mysql, 80413))
        var request = DumpRequest(databases: ["shop"], tables: ["customers", "orders"])
        request.extra = try ToolCommand.words(#"--skip-comments --where="id > 5""#)
        let dump = mysql.dump(request, optionFile: "/private/f.cnf")
        #expect(dump == ["/opt/homebrew/bin/mysqldump", "--defaults-file=/private/f.cnf", "--protocol=TCP", "--host=db.example.com",
                         "--port=3307", "--ssl-mode=VERIFY_IDENTITY", "--ssl-ca=/certs/ca.pem", "--default-character-set=utf8mb4",
                         "--single-transaction", "--hex-blob", "--routines", "--events", "--triggers", "--skip-add-drop-table",
                         "--skip-comments", "--where=id > 5", "shop", "customers", "orders"])
        #expect(!dump.joined().contains("s3cret") && !dump.contains("app"))
        #expect(ToolCommand.display(dump, optionFile: "/private/f.cnf")
            .hasPrefix("/opt/homebrew/bin/mysqldump --defaults-file=‹private temporary file› --protocol=TCP"))
        #expect(ToolCommand.display(dump, optionFile: "/private/f.cnf").hasSuffix("'--where=id > 5' shop customers orders"))
        #expect(mysql.tlsProblem == nil)

        // MariaDB's tools, several databases, through a route; MySQL 8's tool for MariaDB skips column statistics.
        options.endpoint = .route("/private/tunnels/1.sock")
        let maria = ToolCommand(tool: Self.tool("mariadb-dump", .mariadb, [11, 8, 3]), options: options,
                                server: Self.server(.mariadb, 110809))
        var both = DumpRequest(databases: ["shop", "crm"])
        both.content = .data
        let routed = maria.dump(both, optionFile: "/f")
        #expect(routed.contains("--protocol=SOCKET") && routed.contains("--socket=/private/tunnels/1.sock") && !routed.contains("--host=db.example.com"))
        #expect(routed.contains("--ssl") && routed.contains("--ssl-verify-server-cert") && routed.contains("--no-create-info"))
        #expect(routed.contains("--skip-triggers") && Array(routed.suffix(3)) == ["--databases", "shop", "crm"])
        let crossed = ToolCommand(tool: Self.tool("mysqldump", .mysql, [9, 6, 0]), options: options, server: Self.server(.mariadb, 110809))
        #expect(crossed.dump(both, optionFile: "/f").contains("--loose-column-statistics=0"))
        #expect(crossed.dump(both, optionFile: "/f").contains("--ssl-mode=VERIFY_CA"))  // no name check through a socket

        // Restore and Terminal; the server's own socket needs no TLS.
        options.endpoint = .socket("/tmp/mysql.sock")
        let client = ToolCommand(tool: Self.tool("mysql", .mysql, [8, 4, 3]), options: options, server: nil)
        #expect(client.restore(into: "shop", continueOnError: true, optionFile: "/f")
            == ["/opt/homebrew/bin/mysql", "--defaults-file=/f", "--protocol=SOCKET", "--socket=/tmp/mysql.sock",
                "--default-character-set=utf8mb4", "--batch", "--force", "shop"])
        #expect(client.terminal(database: "", optionFile: "/f").last == "--default-character-set=utf8mb4")

        // A read-only connection's tools run READ ONLY sessions: Terminal's mysql, and the dumps where they know how.
        options.readOnly = true
        let readOnly = "--loose-init-command=SET SESSION TRANSACTION READ ONLY"
        let locked = ToolCommand(tool: Self.tool("mysql", .mysql, [8, 4, 3]), options: options, server: nil)
        #expect(locked.terminal(database: "shop", optionFile: "/f").suffix(2) == [readOnly, "shop"])
        #expect(ToolCommand(tool: Self.tool("mariadb-dump", .mariadb, [11, 8, 3]), options: options, server: nil)
            .dump(DumpRequest(databases: ["shop"]), optionFile: "/f").contains(readOnly))
    }

    @Test func toolsThatCantCheckTheCertificateAsAirSQLDoesSaySo() {
        var options = ConnectOptions(host: "db.example.com", user: "app", tls: TLSOptions(mode: .verifyIdentity))
        let mysql = Self.tool("mysqldump", .mysql, [8, 4, 3]), maria = Self.tool("mariadb-dump", .mariadb, [11, 4, 2])
        #expect(ToolCommand(tool: mysql, options: options, server: nil).tlsProblem?.contains("CA file") == true)
        #expect(ToolCommand(tool: maria, options: options, server: nil).tlsProblem == nil)
        options.tls.pinnedFingerprint = "AB:CD"
        #expect(ToolCommand(tool: maria, options: options, server: nil).tlsProblem?.contains("--ssl-fp") == true)
        #expect(ToolCommand(tool: mysql, options: options, server: nil).tlsProblem?.contains("--ssl-fp") == true)
        options.tls.mode = .off
        #expect(ToolCommand(tool: mysql, options: options, server: nil).tlsProblem == nil)
    }

    /// A pinned certificate: a tool with --ssl-fp gets the pin whatever the mode; one without runs only against the
    /// connection's CA file, verifying; else it is refused, and not offered as runnable. Never a run without a check.
    @Test func aPinIsCheckedByTheToolOrItsCAFileOrTheToolDoesntRun() {
        var options = ConnectOptions(host: "db.example.com", user: "app", tls: TLSOptions(mode: .required, pinnedFingerprint: "AB:CD"))
        var pinning = Self.tool("mariadb-dump", .mariadb, [11, 8, 3])
        pinning.takesFingerprint = true
        let old = Self.tool("mariadb-dump", .mariadb, [10, 11, 6]), mysql = Self.tool("mysqldump", .mysql, [8, 4, 3])
        func command(_ tool: ClientTool) -> ToolCommand { ToolCommand(tool: tool, options: options, server: nil) }
        func argv(_ tool: ClientTool) -> [String] { command(tool).dump(DumpRequest(databases: ["shop"]), optionFile: "/private") }

        for mode in [TLSOptions.Mode.required, .verifyCA, .verifyIdentity] {
            options.tls.mode = mode
            #expect(command(pinning).tlsProblem == nil)
            #expect(argv(pinning).contains("--ssl-fp=AB:CD") && argv(pinning).contains("--ssl"))
            #expect(command(old).tlsProblem != nil && command(mysql).tlsProblem != nil, "\(mode)")
        }
        #expect(ToolCommand.runnable([old, mysql, pinning], options: options, server: nil) == [pinning])

        options.tls.caFile = "/etc/ca.pem"
        #expect(command(old).tlsProblem == nil && command(mysql).tlsProblem == nil)
        #expect(argv(old).contains("--ssl-verify-server-cert") && argv(old).contains("--ssl-ca=/etc/ca.pem"))
        #expect(argv(mysql).contains("--ssl-mode=VERIFY_IDENTITY") && argv(mysql).contains("--ssl-ca=/etc/ca.pem"))
        options.tls.mode = .required  // a CA file nothing checks against is no check
        #expect(command(old).tlsProblem != nil && command(mysql).tlsProblem != nil)
    }

    /// The tick box: off by default, only for a MySQL tool with a pin and no CA file, and TLS stays required.
    @Test func runningWithoutTheCheckStillRequiresTLSAndIsOnlyForMySQLsTools() {
        var options = ConnectOptions(host: "db.example.com", user: "app", tls: TLSOptions(mode: .verifyIdentity, pinnedFingerprint: "AB:CD"))
        var mysql = ToolCommand(tool: Self.tool("mysqldump", .mysql, [8, 4, 3]), options: options, server: nil)
        var maria = ToolCommand(tool: Self.tool("mariadb-dump", .mariadb, [10, 11, 6]), options: options, server: nil)
        #expect(!mysql.uncheckedCertificate && mysql.mayRunUnchecked && mysql.tlsProblem != nil && mysql.uncheckedNote == nil)
        mysql.uncheckedCertificate = true
        let argv = mysql.dump(DumpRequest(databases: ["shop"]), optionFile: "/private")
        #expect(mysql.tlsProblem == nil && argv.contains("--ssl-mode=REQUIRED") && !argv.contains("--ssl-mode=DISABLED"))
        #expect(mysql.uncheckedNote?.contains("without checking") == true)

        let terminal = mysql.terminal(database: "shop", optionFile: "/private")
        #expect(terminal.contains("--ssl-mode=REQUIRED"), "Terminal's line too")

        // MariaDB's --ssl without a check connects in plain text to a server without TLS: its tools stay blocked.
        maria.uncheckedCertificate = true
        #expect(!maria.mayRunUnchecked && maria.tlsProblem != nil && maria.uncheckedNote == nil)

        // No pin, or a CA file to check against: no box, and a tick changes nothing.
        options.tls.caFile = "/etc/ca.pem"
        var withCA = ToolCommand(tool: Self.tool("mysqldump", .mysql, [8, 4, 3]), options: options, server: nil)
        withCA.uncheckedCertificate = true
        #expect(!withCA.mayRunUnchecked)
        #expect(withCA.dump(DumpRequest(databases: ["shop"]), optionFile: "/private").contains("--ssl-mode=VERIFY_IDENTITY"))
        options.tls = TLSOptions(mode: .verifyIdentity)
        var noPin = ToolCommand(tool: Self.tool("mysqldump", .mysql, [8, 4, 3]), options: options, server: nil)
        noPin.uncheckedCertificate = true
        #expect(!noPin.mayRunUnchecked && noPin.tlsProblem != nil)
    }

    /// Whether a tool takes --ssl-fp comes from its own --help, not its version.
    @Test func aToolsHelpSaysWhetherItTakesAFingerprint() async throws {
        let folder = try scratch()
        func script(_ name: String, version: String, help: String) throws -> String {
            let path = folder + "/" + name
            try "#!/bin/sh\ncase \"$1\" in --version) echo '\(version)';; *) echo '\(help)';; esac\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return path
        }
        let new = try script("new-dump", version: "mariadb-dump from 11.8.3-MariaDB, client 10.20 for osx (arm64)", help: "  --ssl-fp=name  Server certificate fingerprint")
        let old = try script("old-dump", version: "mariadb-dump  Ver 10.19 Distrib 10.11.6-MariaDB, for osx (arm64)", help: "  --ssl-verify-server-cert")
        #expect(await ClientTools.find(.dump, chosen: new, folders: []).first?.takesFingerprint == true)
        #expect(await ClientTools.find(.dump, chosen: old, folders: []).first?.takesFingerprint == false)
    }

    @Test func extraOptionsSplitLikeAShellAndKeepSecretsOff() throws {
        #expect(try ToolCommand.words(#"  --a 'b c' "d \"e\"" f\ g "#) == ["--a", "b c", #"d "e""#, "f g"])
        for refused in ["--password=x", "-px", "--defaults-extra-file=/x", "--no-defaults", "-r out.sql", "--result-file=x", "'open"] {
            #expect(throws: AirSQLError.self, "\(refused)") { try ToolCommand.words(refused) }
        }
        #expect(ToolCommand.shellWord("plain-word_1.sql") == "plain-word_1.sql")
        #expect(ToolCommand.shellWord("it's") == #"'it'\''s'"#)
    }

    @Test func pipelinesCountWhatTheyCopyAndCancelStopsThem() async throws {
        let dir = try scratch()
        // A tool's output through gzip into a file, counted on its way.
        let out = open(dir + "/out.gz", O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        var seen = 0
        let gzip = try Runner.Writer(file: out, through: ["/usr/bin/gzip", "-c"], cancellation: Cancellation())
        let piped = await Runner.output(of: ["/bin/sh", "-c", "yes 'INSERT INTO t VALUES (1);' | head -n 20000"], into: gzip,
                                        cancellation: Cancellation(), chunk: { seen += $0.count })
        close(out)
        #expect(piped.tool.status == 0 && piped.filter?.status == 0 && piped.bytes == 20000 * 26 && seen == 20000 * 26)
        // The file back into a tool through gzip -dc, counted by what was read from the file.
        let size = try FileManager.default.attributesOfItem(atPath: dir + "/out.gz")[.size] as? Int64 ?? 0
        let input = open(dir + "/out.gz", O_RDONLY)
        var begun = false
        let source = try Runner.Inflow(file: input, through: ["/usr/bin/gzip", "-dc"], cancellation: Cancellation())
        let fed = await Runner.input(of: ["/bin/sh", "-c", "wc -l > '\(dir)/lines'"], from: source, cancellation: Cancellation(),
                                     begun: { begun = true }) { _ in }
        close(input)
        #expect(fed.tool.status == 0 && fed.bytes == size && begun)
        #expect((try String(contentsOfFile: dir + "/lines")).trimmingCharacters(in: .whitespacesAndNewlines) == "20000")
        // Cancel ends the tool (SIGTERM to its process group).
        let cancellation = Cancellation()
        let devNull = open("/dev/null", O_WRONLY)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancellation.cancel() }
        let stopped = await Runner.output(of: ["/bin/sleep", "30"], into: try Runner.Writer(file: devNull, through: nil,
                                                                                            cancellation: cancellation),
                                          cancellation: cancellation)
        close(devNull)
        #expect(stopped.tool.status == 128 + SIGTERM)
        // A tool that isn't there.
        #expect(await Runner.run(["/nowhere/mysqldump", "--version"]).status == 127)
        #expect(Runner.childEnvironment(["MYSQL_PWD": "x", "MYSQL_HOST": "h", "PATH": "/bin"], [:]).keys.sorted() == ["LC_CTYPE", "PATH"])
    }

    @Test func aFailureIsTheToolsOwnErrorWithoutItsWarnings() {
        let readOnly = "unknown variable 'loose-init-command=SET SESSION TRANSACTION READ ONLY'"
        let denied = "Got error: 1045: \"Access denied for user 'app'@'localhost' (using password: YES)\" when trying to connect"
        for (name, warning) in [("mariadb-dump", "Warning: mariadb-dump: " + readOnly), ("mysqldump", "mysqldump: [Warning] " + readOnly)] {
            let error = ToolRun.failure(name, CommandResult(status: 2, stderr: "\(warning)\n\(name): \(denied)\n"))
            #expect(error.message == "\(name) stopped: \(name): \(denied)")
            #expect(error.details == "\(name): \(denied)")
        }
        // A tool that only warned before it stopped.
        let quiet = ToolRun.failure("mariadb", CommandResult(status: 1, stderr: "Warning: mariadb: \(readOnly)\n"))
        #expect(quiet.message == "mariadb stopped: it ended with status 1." && quiet.details.isEmpty)
    }

    @Test func aDumpThatWritesElsewhereIsFlagged() {
        var scan = DumpScan()
        // mysqldump --databases: CREATE DATABASE /*!32312 IF NOT EXISTS*/ `crm` …; USE `crm`; and the like.
        scan.add(words: ["/*!40000", "DROP", "DATABASE", "IF", "EXISTS", "crm"].filter { !$0.hasPrefix("/*") }, line: 18)
        scan.add(words: ["CREATE", "DATABASE", "IF", "NOT", "EXISTS", "crm", "DEFAULT", "CHARACTER", "SET", "utf8mb4"], line: 20)
        scan.add(words: ["USE", "crm"], line: 22)
        scan.add(words: ["DROP", "TABLE", "IF", "EXISTS", "a", ",", "b"], line: 30)
        scan.add(words: ["DROP", "TABLE", "IF", "EXISTS", "c"], line: 40)
        scan.add(words: ["SET", "@@GLOBAL.GTID_PURGED", "=", "'+'", "'3E11FA47-71CA-11E1-9E33-C80AA9429562:1-5'"], line: 50)
        scan.add(words: ["USE", "crm"], line: 60)
        scan.add(words: ["INSERT", "INTO", "t", "VALUES", "(", "1", ")"], line: 70)
        #expect(scan.target(picked: "shop") == "crm")
        let warnings = scan.warnings(picked: "shop")
        #expect(warnings.count == 4, "\(warnings)")
        #expect(warnings[0].contains("drops the database “crm” (line 18)") && warnings[2].contains("switches to the database “crm”"))
        #expect(warnings[3].contains("GTID_PURGED (line 50)"))
        // The picked database itself: only dropping it is worth a word.
        #expect(scan.warnings(picked: "crm").count == 2)
        var plain = DumpScan()
        plain.add(words: ["CREATE", "TABLE", "t", "(", "id", "INT", ")"], line: 1)
        plain.add(words: ["CREATE", "OR", "REPLACE", "SCHEMA", "x"], line: 2)
        #expect(plain.findings == [DumpScan.Finding(kind: .createDatabase, database: "x", line: 2)] && plain.target(picked: "p") == "p")
    }

    @Test func theBuiltInExportWritesEachValueByItsType() {
        let store = ResultStore(columns: [
            ResultStore.Column(name: "id", type: MYSQL_TYPE_LONG), ResultStore.Column(name: "price", type: MYSQL_TYPE_NEWDECIMAL),
            ResultStore.Column(name: "flags", type: MYSQL_TYPE_BIT, charset: 63), ResultStore.Column(name: "raw", type: MYSQL_TYPE_BLOB, charset: 63),
            ResultStore.Column(name: "note", type: MYSQL_TYPE_VAR_STRING), ResultStore.Column(name: "doc", type: MYSQL_TYPE_JSON),
        ])
        _ = store.append([Array("7".utf8), Array("12.50".utf8), [0x01, 0x05], [0x00, 0xFF, 0x27], Array("it's \\ ok\n".utf8),
                          Array(#"{"a": "b"}"#.utf8)])
        _ = store.append([nil, nil, nil, nil, nil, nil])
        #expect((0..<6).map { SQLExport.literal(store, 0, $0) }
            == ["7", "12.50", "b'100000101'", "X'00FF27'", #"'it\'s \\ ok\n'"#, #"'{\"a\": \"b\"}'"#])
        #expect((0..<6).allSatisfy { SQLExport.literal(store, 1, $0) == "NULL" })
        // Generated columns stay out of the INSERTs; expression defaults don't make a column generated.
        #expect(SQLExport.isGenerated("VIRTUAL GENERATED") && SQLExport.isGenerated("STORED GENERATED") && SQLExport.isGenerated("PERSISTENT"))
        #expect(!SQLExport.isGenerated("DEFAULT_GENERATED") && !SQLExport.isGenerated("auto_increment") && !SQLExport.isGenerated("INVISIBLE"))
        // Views come after the views they use; routines go between DELIMITER lines in a file.
        let views = SQLExport.ordered([("totals", "CREATE VIEW `totals` AS SELECT * FROM `paid`"), ("paid", "CREATE VIEW `paid` AS SELECT 1")])
        #expect(views.map(\.name) == ["paid", "totals"])
        #expect(SQLPiece.routine("CREATE PROCEDURE p() BEGIN SELECT 1; END").fileText
            == "DELIMITER ;;\nCREATE PROCEDURE p() BEGIN SELECT 1; END ;;\nDELIMITER ;\n")
        #expect(SQLPiece.statement("SET NAMES utf8mb4").fileText == "SET NAMES utf8mb4;\n")
    }

    @Test func theDumpToolIsToldTheExportsChoicesItKnows() {
        let command = ToolCommand(tool: Self.tool("mysqldump", .mysql, [8, 4, 3]), options: ConnectOptions(name: "Shop", host: "db.example.com", user: "app"), server: nil)
        var request = DumpRequest(databases: ["shop"])
        request.dataMode = .replace
        request.createDatabase = true
        request.dropDatabase = true
        request.insertSize = 64 << 10
        let argv = command.dump(request, optionFile: "/f")
        #expect(argv.contains("--replace") && argv.contains("--add-drop-database") && argv.contains("--net-buffer-length=65536"))
        #expect(argv.suffix(2) == ["--databases", "shop"])
        #expect(request.builtInOnly == nil)
        // Some tables stay a table list: no DROP DATABASE, which would take the rest with it.
        var some = DumpRequest(databases: ["shop"], tables: ["orders"])
        some.dropDatabase = true
        let few = command.dump(some, optionFile: "/f")
        #expect(!few.contains("--add-drop-database") && few.suffix(2) == ["shop", "orders"])
        some.createDatabase = true
        #expect(some.builtInOnly != nil)
        some = DumpRequest(databases: ["shop"])
        some.removeDefiner = true
        #expect(some.builtInOnly?.contains("DEFINER") == true)
    }

    @Test func csvTakesAnyQuoteAndSeparatorAndJoinsLines() {
        let columns = [GridColumn(name: "a"), GridColumn(name: "b")]
        var options = CopyOptions()
        options.separator = "||"
        options.quote = "'"
        #expect(CopyWriter.text(.csv, columns: columns, rows: [["it's", "x||y"], [#"say "hi""#, nil]], table: "t", options: options)
            == "'it''s'||'x||y'\n" + #"say "hi""# + "||NULL\n")
        options.quote = ""
        #expect(CopyWriter.text(.csv, columns: columns, rows: [["a'b", "x||y"]], table: "t", options: options) == "a'b||x||y\n")
        options = CopyOptions()
        options.joinLines = true
        #expect(CopyWriter.text(.csv, columns: columns, rows: [["a\nb\r\nc", nil]], table: "t", options: options) == "a b c,NULL\n")
    }

    @Test func theExportRemovesDefinersAndTheNextAutoIncrementOnly() {
        #expect(SQLExport.withoutDefiner("CREATE ALGORITHM=UNDEFINED DEFINER=`a`@`%` SQL SECURITY DEFINER VIEW `v` AS select 1")
            == "CREATE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `v` AS select 1")
        #expect(SQLExport.withoutDefiner("CREATE DEFINER=`a``b`@`h` PROCEDURE `p`() SELECT 'DEFINER=`x`'") == "CREATE PROCEDURE `p`() SELECT 'DEFINER=`x`'")
        #expect(SQLExport.withoutDefiner("CREATE TABLE t (a INT)") == "CREATE TABLE t (a INT)")
        let create = "CREATE TABLE `t` (\n  `id` int NOT NULL AUTO_INCREMENT COMMENT 'AUTO_INCREMENT=9'\n) ENGINE=InnoDB AUTO_INCREMENT=42 DEFAULT CHARSET=utf8mb4"
        #expect(SQLExport.withoutAutoIncrement(create)
            == "CREATE TABLE `t` (\n  `id` int NOT NULL AUTO_INCREMENT COMMENT 'AUTO_INCREMENT=9'\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4")
    }

    @Test func csvIsReadAsSpreadsheetsWriteItInAnyPieces() throws {
        let text = "\u{FEFF}id,name,note\r\n1,Ada,\"says \"\"hi\"\", then, leaves\"\r\n2,,\"two\nlines\"\n3,Émile,\n4,\"\",last"
        let expected = [["id", "name", "note"], ["1", "Ada", #"says "hi", then, leaves"#], ["2", "", "two\nlines"], ["3", "Émile", ""],
                        ["4", "", "last"]]
        // Whole, and a byte at a time (records and quotes cut anywhere).
        var whole = CSVReader()
        #expect(try whole.read(Data(text.utf8)) + whole.finish() == expected)
        var bytes = CSVReader(), records: [[String]] = []
        for byte in Data(text.utf8) { records += bytes.read(Data([byte])) }
        #expect(try records + bytes.finish() == expected)
        var open = CSVReader()
        _ = open.read(Data("1,\"never closed".utf8))
        #expect(throws: AirSQLError.self) { try open.finish() }
        #expect(CSVReader.guessSeparator(Data("a;b;\"c,d\";e\n1,2,3,4,5,6".utf8)) == UInt8(ascii: ";"))
        #expect(CSVReader.guessSeparator(Data("a\tb\tc\n".utf8)) == 0x09)
        #expect(CSVReader.guessSeparator(Data("single".utf8)) == UInt8(ascii: ","))
    }

    static let dump = """
        -- MySQL dump 10.13  Distrib 9.6.0
        /*!40101 SET NAMES utf8mb4 */;
        /*!40000 DROP DATABASE IF EXISTS `crm`*/;
        CREATE DATABASE /*!32312 IF NOT EXISTS*/ `crm` /*!40100 DEFAULT CHARACTER SET utf8mb4 */;
        USE `crm`;
        /* a comment; with a semicolon */
        INSERT INTO `notes` VALUES (1,'é😀; USE elsewhere;\nnext line'),(2,'x');
        DELIMITER ;;
        CREATE PROCEDURE `p`() BEGIN SELECT 1; SELECT 'é'; END ;;
        DELIMITER ;
        SET @@GLOBAL.GTID_PURGED=/*!80000 '+'*/ 'abc:1-5';
        SELECT 'last' -- no delimiter
        """

    static let dumpStatements: [(String, Int)] = [
        ("/*!40101 SET NAMES utf8mb4 */", 2), ("/*!40000 DROP DATABASE IF EXISTS `crm`*/", 3),
        ("CREATE DATABASE /*!32312 IF NOT EXISTS*/ `crm` /*!40100 DEFAULT CHARACTER SET utf8mb4 */", 4), ("USE `crm`", 5),
        ("INSERT INTO `notes` VALUES (1,'é😀; USE elsewhere;\nnext line'),(2,'x')", 7),
        ("CREATE PROCEDURE `p`() BEGIN SELECT 1; SELECT 'é'; END", 10),
        ("SET @@GLOBAL.GTID_PURGED=/*!80000 '+'*/ 'abc:1-5'", 12), ("SELECT 'last'", 13),
    ]

    @Test func aScriptIsSplitTheSameWhereverItsPiecesEnd() async throws {
        let file = URL(fileURLWithPath: try scratch() + "/dump.sql")
        try Self.dump.write(to: file, atomically: true, encoding: .utf8)
        for size in [1, 2, 3, 5, 7, 13, 64, 1 << 20] {
            let (inflow, fd, _) = try SQLScript.open(file, cancellation: Cancellation())
            var got: [(String, Int)] = []
            try await SQLScript.statements(from: inflow, pieceSize: size) { got.append(($0, $1)) }
            _ = inflow.finish()
            close(fd)
            #expect(got.map(\.0) == Self.dumpStatements.map(\.0) && got.map(\.1) == Self.dumpStatements.map(\.1), "\(size): \(got)")
        }
    }

    @Test func theRestoreCheckFindsWhereADumpWritesEvenCompressed() async throws {
        let dir = try scratch()
        let file = URL(fileURLWithPath: dir + "/dump.sql")
        try Self.dump.write(to: file, atomically: true, encoding: .utf8)
        _ = try await run(["/bin/sh", "-c", "/usr/bin/gzip -c '\(file.path)' > '\(dir)/dump.sql.gz'"])
        for url in [file, URL(fileURLWithPath: dir + "/dump.sql.gz")] {
            var seen: Int64 = 0
            let scan = try await DumpScan.scan(url, cancellation: Cancellation()) { read, _ in seen = read }
            #expect(scan.findings.map(\.kind) == [.dropDatabase, .createDatabase, .use, .gtidPurged], "\(url.lastPathComponent)")
            #expect(scan.findings.map(\.line) == [3, 4, 5, 12] && scan.target(picked: "shop") == "crm")
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
            #expect(seen == size)
        }
    }

    @Test func terminalsScriptRemovesItselfAndTheLoginThenBecomesTheClient() async throws {
        let dir = try scratch()
        let optionFile = dir + "/Application Support/1-login.cnf"
        let script = ToolRun.terminalScript(["/opt/homebrew/bin/mysql", "--defaults-file=" + optionFile, "--protocol=TCP", "shop"],
                                            optionFile: optionFile)
        #expect(script == "#!/bin/sh\nrm -f -- \"$0\"\n(trap '' HUP; sleep 10; rm -f -- '\(optionFile)') &\nexec "
            + "/opt/homebrew/bin/mysql '--defaults-file=\(optionFile)' --protocol=TCP shop\n")
        // Run with a stand-in for mysql: the script is gone at once, and the stand-in got its words unchanged.
        let fake = ToolRun.terminalScript(["/bin/echo", "--defaults-file=" + optionFile, "it's"], optionFile: optionFile)
        try fake.write(toFile: dir + "/t.command", atomically: true, encoding: .utf8)
        let (output, _) = try await run(["/bin/sh", dir + "/t.command"])
        #expect(output == "--defaults-file=\(optionFile) it's\n" && !FileManager.default.fileExists(atPath: dir + "/t.command"))
    }
}
