import Darwin
import Foundation
import Testing
@testable import AirSQLCore

/// The client tools against the lab (AIRSQL_LAB=1), with the mysqldump/mariadb-dump and mysql/mariadb this Mac has (a
/// test without them returns at once): dump then restore gives the same rows, errors stop a restore or are counted, and
/// no option file is left behind. Writes go to lane_l6_* databases only.
@Suite(.serialized, .enabled(if: Lab.enabled, "AIRSQL_LAB=1 runs the lab tests"))
struct ClientToolsLabTests {
    static let log = SQLLog(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("airsql-l6-\(getpid())/SQL.log"))
    static let tables = ["customers", "orders", "order_items", "texts", "all_types", "no_pk_log"]

    static func options(_ server: Lab.Server, password: String = Lab.airsql.password) -> ConnectOptions {
        ConnectOptions(name: "Lab " + server.name, host: "127.0.0.1", port: server.port ?? 3306, user: Lab.airsql.user,
                       password: password, tls: TLSOptions(mode: .required))
    }

    /// A session on `server`, the tools of both kinds suited to it, or nil when this Mac has none.
    static func setUp(_ server: Lab.Server) async throws -> (DBConnection, ServerInfo, dump: ClientTool, client: ClientTool)? {
        let dumps = await ClientTools.find(.dump), clients = await ClientTools.find(.client)
        let session = DBConnection(options: options(server), role: .tools, log: log)
        let info = try await session.connect()
        guard let dump = ClientTools.best(dumps, for: info), let client = ClientTools.best(clients, for: info) else {
            await session.close()
            return nil
        }
        return (session, info, dump, client)
    }

    static func checksums(_ session: DBConnection, _ database: String) async throws -> [String] {
        let list = tables.map { SQLQuote.identifier(database, $0) }.joined(separator: ", ")
        let rows = try await session.query("CHECKSUM TABLE " + list).first?.rows
        return (0..<(rows?.rowCount ?? 0)).map { "\(tables[$0]): " + (rows?.string($0, 1) ?? "NULL") }
    }

    @Test(arguments: [Lab.mysql84, Lab.mariadb114])
    func dumpThenRestoreGivesTheSameRows(_ server: Lab.Server) async throws {
        guard let (session, info, dump, client) = try await Self.setUp(server) else { return }
        let target = "lane_l6_roundtrip"
        _ = try await session.query("DROP DATABASE IF EXISTS " + SQLQuote.identifier(target))
        _ = try await session.query("CREATE DATABASE " + SQLQuote.identifier(target))
        var request = DumpRequest(databases: [Lab.fixture], tables: Self.tables)
        request.gzip = true
        let file = URL(fileURLWithPath: try scratch() + "/fixture.sql.gz")
        var seen = ToolProgress()
        let dumped = try await ToolRun.dump(ToolCommand(tool: dump, options: Self.options(server), server: info), request, to: file,
                                            estimate: nil, cancellation: Cancellation()) { seen = $0 }
        #expect(dumped.bytes > 10_000 && seen.bytes == dumped.bytes && seen.table == "no_pk_log", "\(server): \(seen)")
        #expect(FileManager.default.fileExists(atPath: file.path))
        var fed = ToolProgress()
        let restored = try await ToolRun.restore(ToolCommand(tool: client, options: Self.options(server), server: info), file: file,
                                                 into: target, continueOnError: false, cancellation: Cancellation()) { fed = $0 }
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64
        #expect(restored.bytes == size && fed.bytes == size && fed.total == size && restored.errors == 0)
        let expected = try await Self.checksums(session, Lab.fixture), got = try await Self.checksums(session, target)
        #expect(got == expected.map { $0 }, "\(server): \(got) vs \(expected)")
        // No option file left: each was removed once its tool had connected.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: OptionFile.folder.path)) ?? []).isEmpty)
        _ = try await session.query("DROP DATABASE " + SQLQuote.identifier(target))
        await session.close()
    }

    @Test func aRestoreStopsAtTheFirstErrorOrCountsThemAll() async throws {
        let server = Lab.mariadb114
        guard let (session, info, _, client) = try await Self.setUp(server) else { return }
        let target = "lane_l6_errors"
        _ = try await session.query("DROP DATABASE IF EXISTS " + SQLQuote.identifier(target))
        _ = try await session.query("CREATE DATABASE " + SQLQuote.identifier(target))
        let file = URL(fileURLWithPath: try scratch() + "/errors.sql")
        try """
            CREATE TABLE t (id INT PRIMARY KEY);
            INSERT INTO t VALUES (1);
            INSERT INTO t VALUES (1);
            INSERT INTO t VALUES (2);
            SELEKT 3;
            INSERT INTO t VALUES (3);

            """.write(to: file, atomically: true, encoding: .utf8)
        let command = ToolCommand(tool: client, options: Self.options(server), server: info)
        await #expect(throws: AirSQLError.self) {
            _ = try await ToolRun.restore(command, file: file, into: target, continueOnError: false, cancellation: Cancellation()) { _ in }
        }
        let count = { try await session.query("SELECT COUNT(*) FROM \(SQLQuote.identifier(target, "t"))").first?.rows?.string(0, 0) }
        #expect(try await count() == "1")
        _ = try await session.query("DROP TABLE " + SQLQuote.identifier(target, "t"))
        let outcome = try await ToolRun.restore(command, file: file, into: target, continueOnError: true, cancellation: Cancellation()) { _ in }
        #expect(outcome.errors == 2 && outcome.lastError?.contains("at line 5") == true, "\(outcome)")
        #expect(try await count() == "3")
        _ = try await session.query("DROP DATABASE " + SQLQuote.identifier(target))
        await session.close()
    }

    @Test func aWrongPasswordSaysSoAndLeavesNoFile() async throws {
        let server = Lab.mysql84
        guard let (session, info, dump, _) = try await Self.setUp(server) else { return }
        await session.close()
        let file = URL(fileURLWithPath: try scratch() + "/never.sql")
        let command = ToolCommand(tool: dump, options: Self.options(server, password: "wrong"), server: info)
        do {
            _ = try await ToolRun.dump(command, DumpRequest(databases: [Lab.fixture], tables: ["customers"]), to: file, estimate: nil,
                                       cancellation: Cancellation()) { _ in }
            Issue.record("the dump should fail")
        } catch let error as AirSQLError {
            #expect(error.message.contains("Access denied"), "\(error.message)")
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)) ?? []).isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: OptionFile.folder.path)) ?? []).isEmpty)
    }

    /// A read-only connection's mysql, as Open in Terminal starts it, can't write: its session is READ ONLY. A dump
    /// still works.
    @Test(arguments: [Lab.mysql84, Lab.mariadb114])
    func aReadOnlyConnectionsToolsOnlyRead(_ server: Lab.Server) async throws {
        guard let (session, info, dump, client) = try await Self.setUp(server) else { return }
        var options = Self.options(server)
        options.readOnly = true
        let optionFile = try OptionFile.write(user: options.user, password: options.password)
        let terminal = ToolCommand(tool: client, options: options, server: info).terminal(database: "", optionFile: optionFile.path)
        let refused = await Runner.run(terminal + ["--batch", "-e", "CREATE DATABASE lane_ro_terminal"])
        unlink(optionFile.path)
        #expect(refused.status != 0 && refused.stderr.contains("READ ONLY"), "\(server): \(refused.stderr)")
        let made = try await session.query("SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'lane_ro_terminal'")
        #expect(made.first?.rows?.string(0, 0) == "0")
        let file = URL(fileURLWithPath: try scratch() + "/read-only.sql")
        let dumped = try await ToolRun.dump(ToolCommand(tool: dump, options: options, server: info),
                                            DumpRequest(databases: [Lab.fixture], tables: ["customers"]), to: file, estimate: nil,
                                            cancellation: Cancellation()) { _ in }
        #expect(dumped.bytes > 1_000, "\(server)")
        await session.close()
    }

    /// AirSQL's own export, restored by the client, gives the same rows: every column type, both flavours.
    @Test(arguments: [Lab.mysql84, Lab.mariadb114])
    func theBuiltInExportRestoresToTheSameRows(_ server: Lab.Server) async throws {
        guard let (session, info, _, client) = try await Self.setUp(server) else { return }
        let target = "lane_l6_builtin"
        _ = try await session.query("DROP DATABASE IF EXISTS " + SQLQuote.identifier(target))
        _ = try await session.query("CREATE DATABASE " + SQLQuote.identifier(target))
        let file = URL(fileURLWithPath: try scratch() + "/builtin.sql.gz")
        let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        let writer = try Runner.Writer(file: fd, through: ["/usr/bin/gzip", "-c"], cancellation: Cancellation())
        let reader = DBConnection(options: Self.options(server), role: .tools, log: Self.log)
        _ = try await reader.connect()
        var last: SQLExport.Progress?
        try await SQLExport.run(DumpRequest(databases: [Lab.fixture], tables: Self.tables + ["customer_order_totals"]), from: reader,
                                into: SQLFileSink(writer), cancellation: Cancellation()) { last = $0 }
        #expect(writer.finish()?.status == 0)
        close(fd)
        await reader.close()
        #expect(last?.rows ?? 0 > 0 && writer.bytes > 10_000)
        _ = try await ToolRun.restore(ToolCommand(tool: client, options: Self.options(server), server: info), file: file, into: target,
                                      continueOnError: false, cancellation: Cancellation()) { _ in }
        let expected = try await Self.checksums(session, Lab.fixture), got = try await Self.checksums(session, target)
        #expect(got == expected, "\(server): \(got) vs \(expected)")
        _ = try await session.query("DROP DATABASE " + SQLQuote.identifier(target))
        await session.close()
    }

    /// Copy to Another Server: under another name on the same server (views follow the new name), and from MySQL to
    /// MariaDB, with the same rows.
    @Test func copiesGiveTheSameRows() async throws {
        let mysql = DBConnection(options: Self.options(Lab.mysql84), role: .tools, log: Self.log)
        let maria = DBConnection(options: Self.options(Lab.mariadb114), role: .tools, log: Self.log)
        _ = try await mysql.connect()
        _ = try await maria.connect()
        let target = "lane_l6_copy"
        for session in [mysql, maria] { _ = try await session.query("DROP DATABASE IF EXISTS " + SQLQuote.identifier(target)) }
        var request = DumpRequest(databases: [Lab.fixture], tables: Self.tables + ["customer_order_totals"])
        request.singleTransaction = true
        // The same server, another name.
        let reader = DBConnection(options: Self.options(Lab.mysql84), role: .tools, log: Self.log)
        _ = try await reader.connect()
        try await SQLExport.run(request, from: reader, into: SQLServerSink(mysql), names: [Lab.fixture: target],
                                cancellation: Cancellation()) { _ in }
        #expect(try await Self.checksums(mysql, target) == Self.checksums(mysql, Lab.fixture))
        let view = { (database: String) in
            try await mysql.query("SELECT COUNT(*) FROM \(SQLQuote.identifier(database, "customer_order_totals"))").first?.rows?.string(0, 0)
        }
        #expect(try await view(target) == view(Lab.fixture))
        // MySQL to MariaDB.
        request.tables = ["customers", "orders", "order_items", "texts"]
        request.objects = false
        try await SQLExport.run(request, from: reader, into: SQLServerSink(maria), names: [Lab.fixture: target],
                                cancellation: Cancellation()) { _ in }
        await reader.close()
        for table in request.tables {
            let count = "SELECT COUNT(*) FROM "
            let a = try await mysql.query(count + SQLQuote.identifier(Lab.fixture, table)).first?.rows?.string(0, 0)
            let b = try await maria.query(count + SQLQuote.identifier(target, table)).first?.rows?.string(0, 0)
            #expect(a != nil && a == b, "\(table)")
        }
        for session in [mysql, maria] { _ = try await session.query("SET SESSION group_concat_max_len = 1000000") }
        let body = "SELECT GROUP_CONCAT(body ORDER BY id SEPARATOR '|') FROM "
        let a = try await mysql.query(body + SQLQuote.identifier(Lab.fixture, "texts")).first?.rows?.string(0, 0)
        let b = try await maria.query(body + SQLQuote.identifier(target, "texts")).first?.rows?.string(0, 0)
        #expect(a != nil && a == b)
        for session in [mysql, maria] {
            _ = try await session.query("DROP DATABASE " + SQLQuote.identifier(target))
            await session.close()
        }
    }

    /// Import CSV: mapped fields into their columns, empty fields as NULL, a column left out takes its default, and a
    /// record that fails leaves the table as it was.
    @Test(arguments: [Lab.mysql84, Lab.mariadb114])
    func csvImportsIntoMappedColumnsOrNotAtAll(_ server: Lab.Server) async throws {
        let session = DBConnection(options: Self.options(server), role: .tools, log: Self.log)
        _ = try await session.connect()
        let target = "lane_l6_csv"
        _ = try await session.query("DROP DATABASE IF EXISTS " + SQLQuote.identifier(target))
        _ = try await session.query("CREATE DATABASE " + SQLQuote.identifier(target))
        _ = try await session.query("CREATE TABLE \(SQLQuote.identifier(target, "people")) (id INT PRIMARY KEY, name VARCHAR(50) "
                                    + "NOT NULL, note TEXT NULL, country CHAR(2) NOT NULL DEFAULT 'NL')")
        let file = URL(fileURLWithPath: try scratch() + "/people.csv")
        try "note;name;number\n\"says \"\"hi\"\"; twice\";Ada;1\n;Émile 👋;2\n\"two\nlines\";O'Brien \\ x;3\n"
            .write(to: file, atomically: true, encoding: .utf8)
        var options = CSVImport.Options()
        options.separator = UInt8(ascii: ";")
        let columns = ["id", "name", "note", "country"]
        let rows = try await CSVImport.run(.file(file), options: options, into: session, database: target, table: "people", columns: columns,
                                           mapping: [2, 1, 0, nil], cancellation: Cancellation()) { _ in }
        #expect(rows.rows == 3)
        let result = try await session.query("SELECT id, name, note, country FROM \(SQLQuote.identifier(target, "people")) ORDER BY id")
            .first?.rows
        let got = (0..<(result?.rowCount ?? 0)).map { row in (0..<4).map { result?.string(row, $0) ?? "NULL" } }
        #expect(got == [["1", "Ada", #"says "hi"; twice"#, "NL"], ["2", "Émile 👋", "NULL", "NL"], ["3", "O'Brien \\ x", "two\nlines", "NL"]],
                "\(server): \(got)")
        // A duplicate key in the last record: nothing of this file stays.
        try "name,id\nGrace,4\nAlan,1\n".write(to: file, atomically: true, encoding: .utf8)
        await #expect(throws: AirSQLError.self) {
            _ = try await CSVImport.run(.file(file), options: CSVImport.Options(), into: session, database: target, table: "people",
                                        columns: columns, mapping: [1, 0, nil, nil], cancellation: Cancellation()) { _ in }
        }
        let count = try await session.query("SELECT COUNT(*) FROM \(SQLQuote.identifier(target, "people"))").first?.rows?.string(0, 0)
        #expect(count == "3")
        _ = try await session.query("DROP DATABASE " + SQLQuote.identifier(target))
        await session.close()
    }

    /// A new table from a file, as the sheet makes it; then duplicates skipped or replaced, the table emptied in the same
    /// transaction, refused rows written to a file while the rest stay, and a result's NULLs and bytes kept apart.
    @Test(arguments: [Lab.mysql84, Lab.mariadb114])
    func importMakesTheTableAndHandlesWhatItIsAskedTo(_ server: Lab.Server) async throws {
        let session = DBConnection(options: Self.options(server), role: .tools, log: Self.log)
        _ = try await session.connect()
        let target = "lane_transfer_import"
        _ = try await session.query("DROP DATABASE IF EXISTS " + SQLQuote.identifier(target))
        _ = try await session.query("CREATE DATABASE " + SQLQuote.identifier(target))
        let table = SQLQuote.identifier(target, "people")
        func rows(_ sql: String) async throws -> [[String?]] { try await session.rows(sql) }
        func run(_ source: ImportSource, _ options: CSVImport.Options, mapping: [Int?] = [0, 1, 2],
                 columns: [String] = ["id", "name", "joined"], table: String = "people") async throws -> CSVImport.Progress {
            try await CSVImport.run(source, options: options, into: session, database: target, table: table, columns: columns,
                                    mapping: mapping, cancellation: Cancellation()) { _ in }
        }
        let text = "id,name,joined\n1,Ada,2026-01-02\n2,Émile 👋,\n"
        let columns = try ImportDetect.columns(.text(text), options: CSVImport.Options(), cancellation: Cancellation())
        _ = try await session.query(ImportDetect.createTable(database: target, table: "people", columns: columns))
        #expect(try await run(.text(text), CSVImport.Options()).rows == 2)
        #expect(try await rows("SELECT id, name, joined FROM \(table) ORDER BY id") == [["1", "Ada", "2026-01-02"], ["2", "Émile 👋", nil]])
        #expect(try await rows("SELECT DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = '\(target)' ORDER BY ORDINAL_POSITION")
            .map { $0[0] } == ["int", "varchar", "date"])

        _ = try await session.query("ALTER TABLE \(table) ADD PRIMARY KEY (id)")
        var options = CSVImport.Options()
        options.duplicates = .skip
        #expect(try await run(.text("id,name,joined\n1,Other,\n3,Grace,\n"), options).warnings > 0)
        #expect(try await rows("SELECT name FROM \(table) WHERE id = 1") == [["Ada"]])
        options.duplicates = .replace
        _ = try await run(.text("id,name,joined\n1,Other,\n"), options)
        #expect(try await rows("SELECT name FROM \(table) WHERE id = 1") == [["Other"]])

        // A failed import brings the deleted rows back.
        var empty = CSVImport.Options()
        empty.emptyFirst = true
        await #expect(throws: AirSQLError.self) { _ = try await run(.text("id,name,joined\n7,A,\n7,B,\n"), empty) }
        #expect(try await rows("SELECT COUNT(*) FROM \(table)") == [["3"]])
        _ = try await run(.text("id,name,joined\n7,A,\n"), empty)
        #expect(try await rows("SELECT id FROM \(table)") == [["7"]])

        // Refused rows go to the file with the reason; the good ones around them stay, on InnoDB and on a table without transactions.
        for engine in ["InnoDB", "MyISAM"] {
            let name = "keep_" + engine
            _ = try await session.query("CREATE TABLE \(SQLQuote.identifier(target, name)) (id INT PRIMARY KEY, name VARCHAR(3) NOT NULL) ENGINE=\(engine)")
            var keep = CSVImport.Options()
            keep.rejects = URL(fileURLWithPath: try scratch() + "/skipped.csv")
            let done = try await run(.text("id,name\n1,a\n1,dup\n2,toolong\n3,c\n"), keep, mapping: [0, 1], columns: ["id", "name"], table: name)
            #expect(done.rows == 2 && done.rejected == 2 && done.note.contains("2 rows were refused"), "\(engine)")
            #expect(try await rows("SELECT id FROM \(SQLQuote.identifier(target, name)) ORDER BY id") == [["1"], ["3"]], "\(engine)")
            let file = try String(contentsOf: try #require(keep.rejects), encoding: .utf8)
            #expect(file.hasPrefix("\"1\",\"dup\",") && file.contains("\"2\",\"toolong\","), "\(file)")
        }
        // No refused row, no file.
        var clean = CSVImport.Options()
        clean.rejects = URL(fileURLWithPath: try scratch() + "/none.csv")
        _ = try await run(.text("id,name\n9,a\n"), clean, mapping: [0, 1], columns: ["id", "name"], table: "keep_InnoDB")
        #expect(!FileManager.default.fileExists(atPath: try #require(clean.rejects).path))

        // A result: NULL against empty text and the text NULL, bytes as bytes.
        var result = CSVImport.Options()
        result.hexIsBinary = true
        let source = ImportSource.rows([["a", "b", "c"], [nil, "", "0x00FF"], ["NULL", nil, nil]])
        let made = try ImportDetect.columns(source, options: result, cancellation: Cancellation())
        #expect(made.map(\.type) == ["VARCHAR(32)", "VARCHAR(255)", "LONGBLOB"])
        _ = try await session.query(ImportDetect.createTable(database: target, table: "copied", columns: made))
        result.binaryColumns = ["c"]
        result.emptyIsNull = false
        _ = try await run(source, result, columns: ["a", "b", "c"], table: "copied")
        #expect(try await rows("SELECT a, b, HEX(c) FROM \(SQLQuote.identifier(target, "copied")) ORDER BY a IS NULL DESC") == [[nil, "", "00FF"], ["NULL", nil, nil]])
        _ = try await session.query("DROP DATABASE " + SQLQuote.identifier(target))
        await session.close()
    }

    /// Run SQL File without client tools takes mysqldump's own output (executable comments, LOCK TABLES, DELIMITER around
    /// routines) to the same rows; and a dump of whole databases, which writes into its own, is flagged before it runs.
    @Test(arguments: [Lab.mysql84, Lab.mariadb114])
    func theBuiltInRunnerRunsDumpsAndAHostileOneIsFlagged(_ server: Lab.Server) async throws {
        guard let (session, info, dump, _) = try await Self.setUp(server) else { return }
        let target = "lane_l6_run"
        _ = try await session.query("DROP DATABASE IF EXISTS " + SQLQuote.identifier(target))
        _ = try await session.query("CREATE DATABASE " + SQLQuote.identifier(target))
        let command = ToolCommand(tool: dump, options: Self.options(server), server: info)
        var request = DumpRequest(databases: [Lab.fixture], tables: Self.tables)
        request.gzip = true
        let file = URL(fileURLWithPath: try scratch() + "/fixture.sql.gz")
        _ = try await ToolRun.dump(command, request, to: file, estimate: nil, cancellation: Cancellation()) { _ in }
        let clean = try await DumpScan.scan(file, cancellation: Cancellation()) { _, _ in }
        #expect(clean.warnings(picked: target).isEmpty && clean.target(picked: target) == target, "\(clean)")
        let runner = DBConnection(options: Self.options(server), role: .tools, log: Self.log)
        _ = try await runner.connect()
        let outcome = try await SQLScript.run(file, in: target, on: runner, continueOnError: false, cancellation: Cancellation()) { _ in }
        await runner.close()
        #expect(outcome.errors == 0 && outcome.bytes > 0)
        #expect(try await Self.checksums(session, target) == Self.checksums(session, Lab.fixture))
        let routines = try await session.query("SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = '\(target)'")
            .first?.rows?.string(0, 0)
        #expect(routines == "5", "\(server): \(routines ?? "")")  // mysqldump --routines: DELIMITER ;; … ;; ran as one
        // A dump of the whole database (--databases) creates and uses fixture: restoring it into lane_l6_run is flagged.
        var whole = DumpRequest(databases: [Lab.fixture])
        whole.extra = ["--databases", "--no-data"]
        let hostile = URL(fileURLWithPath: try scratch() + "/whole.sql")
        _ = try await ToolRun.dump(command, whole, to: hostile, estimate: nil, cancellation: Cancellation()) { _ in }
        let flagged = try await DumpScan.scan(hostile, cancellation: Cancellation()) { _, _ in }
        #expect(flagged.target(picked: target) == Lab.fixture)
        #expect(flagged.warnings(picked: target).contains { $0.contains("switches to the database “fixture”") }, "\(flagged)")
        _ = try await session.query("DROP DATABASE " + SQLQuote.identifier(target))
        await session.close()
    }
}
