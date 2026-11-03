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
}
