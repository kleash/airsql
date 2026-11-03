import Foundation
import Testing
@testable import AirSQLCore

/// The navigator's statements on the lab's servers (AIRSQL_LAB=1): what they change is what they say, with hostile
/// names and texts, and Kill stops only the statement the process list showed.
@Suite(.serialized, .enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
struct NavigatorLabTests {
    static let servers = [Lab.mysql84, Lab.mariadb114, Lab.mariadb105]
    static let database = "lane_l5a_nav"
    static let other = "lane_l5a_nav other`s"

    private func session(_ server: Lab.Server) async throws -> DBConnection {
        let session = DBConnection(options: DBLab.options(server), role: .tools, log: DBLab.log)
        try await session.connect()
        return session
    }

    private func value(_ session: DBConnection, _ sql: String) async throws -> String? {
        try await session.rows(sql).first?.first ?? nil
    }

    @Test(arguments: servers)
    func tableStatementsDoWhatTheySay(_ server: Lab.Server) async throws {
        let session = try await session(server)
        let (db, other) = (Self.database, Self.other)
        for name in [db, other] { _ = try await session.query("DROP DATABASE IF EXISTS " + SQLQuote.identifier(name)) }
        _ = try await session.query(NavigatorSQL.createDatabase(db, charset: "utf8mb4", collation: "utf8mb4_bin"))
        _ = try await session.query(NavigatorSQL.createDatabase(other, charset: nil, collation: nil))
        #expect(try await value(session, "SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = "
                                + SQLQuote.string(db)) == "utf8mb4_bin")

        let name = "it's `odd` ✓"  // MariaDB's names hold no emoji
        let table = DatabaseObject(.table, db, name)
        _ = try await session.query("CREATE TABLE \(table.quoted) (id INT PRIMARY KEY, note VARCHAR(40), twice INT AS (id * 2))")
        _ = try await session.query("INSERT INTO \(table.quoted) (id, note) VALUES (1, '50%_off!'), (2, 'plain'), (3, NULL)")
        func count(_ object: DatabaseObject) async throws -> String? { try await value(session, "SELECT COUNT(*) FROM \(object.quoted)") }

        // Copy Table: the definition, then the rows where the condition holds, without the generated column.
        for sql in NavigatorSQL.copyTable(table, to: other, name: "copy", columns: ["id", "note"], where: "id < 3") {
            _ = try await session.query(sql)
        }
        let copy = DatabaseObject(.table, other, "copy")
        #expect(try await count(copy) == "2")
        #expect(try await value(session, "SELECT twice FROM \(copy.quoted) WHERE id = 2") == "4")

        // Find text: %, _ and ! match only themselves.
        func found(_ text: String) async throws -> String? {
            try await value(session, NavigatorSQL.countContaining(text, in: table, columns: ["note"],
                                                                   noBackslashEscapes: session.noBackslashEscapes))
        }
        #expect(try await found("%_o") == "1")
        #expect(try await found("%") == "1")
        #expect(try await found("!") == "1")
        #expect(try await found("PLAIN") == "0")  // the column's collation decides: utf8mb4_bin tells case apart
        for text in Hostile.values where !text.isEmpty && !"50%_off!plain".contains(text) {
            #expect(try await found(text) == "0", "\(text.debugDescription)")
        }

        // Rename, truncate, engine, collation, maintenance, move.
        _ = try await session.query(NavigatorSQL.rename(table, to: "renamed"))
        let renamed = DatabaseObject(.table, db, "renamed")
        for sql in NavigatorSQL.truncate([renamed]) { _ = try await session.query(sql) }
        #expect(try await count(renamed) == "0")
        let where_ = "FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(SQLQuote.string(db)) AND TABLE_NAME = 'renamed'"
        _ = try await session.query(NavigatorSQL.changeEngine(renamed, to: "MyISAM"))
        #expect(try await value(session, "SELECT ENGINE " + where_) == "MyISAM")
        _ = try await session.query(NavigatorSQL.changeEngine(renamed, to: "InnoDB"))
        _ = try await session.query(NavigatorSQL.convert(renamed, charset: "utf8mb4", collation: "utf8mb4_unicode_ci"))
        #expect(try await value(session, "SELECT TABLE_COLLATION " + where_) == "utf8mb4_unicode_ci")
        for operation in Maintenance.allCases {
            let results = try await session.query(NavigatorSQL.maintenance(operation, [renamed, copy]))
            #expect((results.first?.rows?.rowCount ?? 0) >= 2, "\(operation)")
        }
        _ = try await session.query(NavigatorSQL.move([renamed], to: other))
        #expect(try await count(DatabaseObject(.table, other, "renamed")) == "0")

        // Drop every kind at once: triggers go before their tables.
        _ = try await session.query("CREATE VIEW \(SQLQuote.identifier(other, "v")) AS SELECT id FROM \(copy.quoted)")
        _ = try await session.query("CREATE TRIGGER \(SQLQuote.identifier(other, "t")) BEFORE INSERT ON \(copy.quoted) FOR EACH ROW SET NEW.id = NEW.id")
        _ = try await session.query("CREATE PROCEDURE \(SQLQuote.identifier(other, "p"))() SELECT 1")
        _ = try await session.query("CREATE FUNCTION \(SQLQuote.identifier(other, "f"))() RETURNS INT DETERMINISTIC RETURN 1")
        _ = try await session.query("CREATE EVENT \(SQLQuote.identifier(other, "e")) ON SCHEDULE EVERY 1 DAY DO SELECT 1")
        let objects = [copy, DatabaseObject(.view, other, "v"), DatabaseObject(.trigger, other, "t"),
                       DatabaseObject(.procedure, other, "p"), DatabaseObject(.function, other, "f"),
                       DatabaseObject(.event, other, "e"), DatabaseObject(.table, other, "renamed")]
        for sql in NavigatorSQL.drop(objects) { _ = try await session.query(sql) }
        #expect(try await value(session, "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = " + SQLQuote.string(other)) == "0")
        #expect(try await value(session, "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = "
                                + SQLQuote.string(other)) == "0")
        for name in [db, other] { _ = try await session.query(NavigatorSQL.dropDatabase(name)) }
        #expect(try await value(session, "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME LIKE 'lane!_l5a!_nav%' ESCAPE '!'") == "0")
        await session.close()
    }

    @Test(arguments: servers)
    func killStopsOnlyTheStatementTheListShowed(_ server: Lab.Server) async throws {
        let victim = try await session(server)
        let watcher = try await session(server)
        let thread = try #require(victim.server?.threadID)
        let mariaDB = watcher.server?.flavor == .mariadb
        let sleeping = Task { try await victim.query("SELECT SLEEP(60) AS slept") }
        var shown: ServerProcess?
        #expect(try await eventually(timeout: 20) {
            shown = NavigatorSQL.processes(try await watcher.rows(NavigatorSQL.processList(mariaDB: mariaDB)))
                .first { $0.id == thread && $0.info?.contains("SLEEP(60)") == true }
            return shown != nil
        })
        let process = try #require(shown)
        #expect((process.queryID != nil) == mariaDB)
        let check = NavigatorSQL.stillRunning(process, noBackslashEscapes: watcher.noBackslashEscapes)
        #expect(try await value(watcher, check) == "1")
        _ = try await watcher.query(NavigatorSQL.killQuery(process))
        // MySQL's SLEEP says it was interrupted; MariaDB reports the statement interrupted. The connection stays.
        switch await sleeping.result {
        case .success(let results): #expect(results.first?.rows?.string(0, 0) == "1")
        case .failure(let error): #expect((error as? AirSQLError)?.kind == .cancelled)
        }
        #expect(try await value(victim, "SELECT 2") == "2")
        #expect(try await value(watcher, check) == "0")  // it ended: Kill Query would refuse now

        let connected = NavigatorSQL.stillConnected(process, noBackslashEscapes: watcher.noBackslashEscapes)
        #expect(try await value(watcher, connected) == "1")
        _ = try await watcher.query(NavigatorSQL.killConnection(process))
        await #expect(throws: AirSQLError.self) { _ = try await victim.query("SELECT 3") }
        #expect(try await value(watcher, connected) == "0")
        await victim.close()
        await watcher.close()
    }
}
