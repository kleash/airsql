import Foundation
import Testing
@testable import AirSQLCore

/// The tree lane's statements on the lab's servers (AIRSQL_LAB=1).
@Suite(.serialized, .enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
struct TreeLabTests {
    static let database = "lane_tree"

    @Test(arguments: NavigatorLabTests.servers)
    func treeStatementsDoWhatTheySay(_ server: Lab.Server) async throws {
        let session = DBConnection(options: DBLab.options(server), role: .tools, log: DBLab.log)
        try await session.connect()
        let db = Self.database, flag = session.noBackslashEscapes
        _ = try await session.query("DROP DATABASE IF EXISTS " + SQLQuote.identifier(db))
        _ = try await session.query("CREATE DATABASE " + SQLQuote.identifier(db))
        defer { Task { _ = try? await session.query("DROP DATABASE IF EXISTS " + SQLQuote.identifier(db)) } }
        let parent = DatabaseObject(.table, db, "parent"), child = DatabaseObject(.table, db, "child_rows")
        let routine = DatabaseObject(.procedure, db, "tidy")
        _ = try await session.query("CREATE TABLE \(parent.quoted) (id INT PRIMARY KEY, note VARCHAR(40))")
        _ = try await session.query("""
            CREATE TABLE \(child.quoted) (id INT PRIMARY KEY, parent_id INT, n INT, INDEX by_n (n),
            CONSTRAINT to_parent FOREIGN KEY (parent_id) REFERENCES \(parent.quoted) (id), CONSTRAINT positive CHECK (n > 0))
            """)
        _ = try await session.query("CREATE VIEW \(SQLQuote.identifier(db, "parent_view")) AS SELECT id FROM \(parent.quoted)")
        _ = try await session.query("CREATE VIEW \(SQLQuote.identifier(db, "other_view")) AS SELECT id FROM \(child.quoted)")
        _ = try await session.query("CREATE PROCEDURE \(routine.quoted)() DELETE FROM \(parent.quoted)")
        _ = try await session.query("INSERT INTO \(parent.quoted) VALUES (1, 'alpha'), (2, 'beta'), (3, 'alphabet')")

        // Where it's used: whole words only, in this database.
        let rows = try await session.rows(NavigatorSQL.usages(of: "parent", noBackslashEscapes: flag))
        let names = Set(rows.filter { $0[1] == db && NavigatorSQL.names("parent", in: $0[3] ?? "") }.compactMap { $0[2] })
        #expect(names == ["parent_view", "tidy"], "\(rows)")
        #expect(rows.allSatisfy { $0.count == 4 && DatabaseObject.Kind(rawValue: $0[0] ?? "") != nil })

        // Find modes and limits.
        func count(_ kind: NavigatorSQL.TextMatch.Kind, _ text: String, limit: Int? = nil) async throws -> String? {
            try await session.rows(NavigatorSQL.countContaining(text, in: parent, columns: ["note"], noBackslashEscapes: flag, match: .init(kind: kind), limit: limit)).first?.first ?? nil
        }
        #expect(try await count(.contains, "alpha") == "2")
        #expect(try await count(.exact, "alpha") == "1")
        #expect(try await count(.regex, "^(alpha|beta)$") == "2")
        #expect(try await count(.contains, "a", limit: 2) == "2")

        // Quick Documentation's rows.
        let columns = [("id", "int"), ("note", "varchar")].map {
            SchemaColumn(name: $0.0, dataType: $0.1, columnType: $0.1, nullable: true, defaultValue: .none, autoIncrement: false, onUpdate: nil, generated: nil,
                         invisible: false, isJSON: false, charset: nil, collation: nil, comment: "")
        }
        let first = try #require(NavigatorSQL.firstRows(parent, columns, limit: 2))
        #expect(try await session.rows(first.sql).count == 2)

        // Comments, then dropping parts: the table and its rows stay.
        _ = try await session.query(NavigatorSQL.setComment("it's a parent", of: parent, noBackslashEscapes: flag))
        #expect(try await session.rows("SELECT TABLE_COMMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA = '\(db)' AND TABLE_NAME = 'parent'").first?.first == "it's a parent")
        _ = try await session.query(NavigatorSQL.setComment("sweeps", of: routine, noBackslashEscapes: flag))
        #expect(try await session.rows("SELECT ROUTINE_COMMENT FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = '\(db)'").first?.first == "sweeps")
        for (part, name) in [(TablePart.foreignKeys, "to_parent"), (.checks, "positive"), (.indexes, "by_n"), (.indexes, "PRIMARY")] {
            _ = try await session.query(try #require(NavigatorSQL.dropPart(part, name, of: child)))
        }
        // The index a foreign key made for itself stays when the key goes, as the server has it.
        let left = try #require(try await session.rows("SHOW CREATE TABLE \(child.quoted)").first?[1])
        for gone in ["FOREIGN KEY", "PRIMARY KEY", "by_n", "CONSTRAINT"] { #expect(!left.contains(gone), "\(left)") }
    }
}
