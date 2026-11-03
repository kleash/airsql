import Foundation
import Testing
@testable import AirSQLCore

/// Pending changes applied on MySQL 8.4 and MariaDB 11.4 (AIRSQL_LAB=1): edits, new rows and deletes by key (hostile
/// names and values, binary and composite keys, BIT), read back exactly; a row someone else deleted rolls the whole
/// Apply back; the table's pages with a filter and a sort.
@Suite(.serialized, .enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
struct GridDataLabTests {
    static let database = "lane_l3a_griddata"
    static let servers = [Lab.mysql84, Lab.mariadb114]
    static let odd = "it's `odd`"

    func connected(_ server: Lab.Server) async throws -> DBConnection {
        let session = DBConnection(options: DBLab.options(server), role: .data, log: DBLab.log)
        try await session.connect()
        return session
    }

    /// A fresh database with `items` (an AUTO_INCREMENT key, a hostile column name, DECIMAL, BLOB, BIT) and `pairs` (a
    /// composite key, one part BINARY(16)).
    func setUp(_ session: DBConnection) async throws -> SchemaSnapshot {
        let database = SQLQuote.identifier(Self.database)
        for statement in [
            "DROP DATABASE IF EXISTS \(database)", "CREATE DATABASE \(database)",
            "CREATE TABLE \(database).items (id INT AUTO_INCREMENT PRIMARY KEY, \(SQLQuote.identifier(Self.odd)) VARCHAR(100) NULL, "
                + "price DECIMAL(10,2) NOT NULL DEFAULT 0, photo BLOB NULL, flags BIT(3) NULL) ENGINE=InnoDB",
            "INSERT INTO \(database).items VALUES (1, 'Ann', 1.50, X'00FF', b'101'), (2, 'Bob', 2.00, NULL, NULL), "
                + "(3, 'Cy', 3.25, NULL, b'0')",
            "CREATE TABLE \(database).pairs (shop INT NOT NULL, tag BINARY(16) NOT NULL, note VARCHAR(20) NULL, "
                + "PRIMARY KEY (shop, tag)) ENGINE=InnoDB",
            "INSERT INTO \(database).pairs VALUES (1, UNHEX('00112233445566778899AABBCCDDEEFF'), 'a'), "
                + "(1, UNHEX('FFEEDDCCBBAA99887766554433221100'), 'b'), (2, UNHEX(REPEAT('00', 16)), 'c')",
        ] { _ = try await session.query(statement) }
        let cache = SchemaCache(source: session, includes: { $0 == Self.database })
        try await cache.load()
        return cache.snapshot
    }

    /// Runs `body` on a data session of `server` with the tables set up, then drops the database.
    func withTables(_ server: Lab.Server, _ body: (DBConnection, SchemaSnapshot) async throws -> Void) async throws {
        let session = try await connected(server)
        do {
            try await body(session, try await setUp(session))
        } catch {
            await tearDown(session)
            throw error
        }
        await tearDown(session)
    }

    func tearDown(_ session: DBConnection) async {
        _ = try? await session.query("DROP DATABASE IF EXISTS \(SQLQuote.identifier(Self.database))")
        await session.close()
    }

    /// The table's first page in a source, as the tab loads it.
    func loaded(_ table: String, _ snapshot: SchemaSnapshot, on session: DBConnection, filter: String = "",
                sort: [TableViewSettings.SortKey] = []) async throws -> TableDataSource {
        let source = TableDataSource(database: Self.database, table: try #require(snapshot.table(Self.database, table)))
        source.filter = filter
        source.sort = sort
        let page = try #require(try await session.query(source.pageSQL(offset: 0, limit: 100)).first?.rows)
        source.append(page, requested: 100)
        return source
    }

    func apply(_ source: TableDataSource, on session: DBConnection) async throws {
        try await PendingChanges.apply(source.changes.statements(database: Self.database, table: source.table.name,
                                                                  columns: source.columns,
                                                                  noBackslashEscapes: session.noBackslashEscapes), on: session)
    }

    func rows(_ sql: String, on session: DBConnection) async throws -> [[String?]] {
        try await session.rows(sql)
    }

    @Test(arguments: servers)
    func appliesEditsNewRowsAndDeletesExactly(_ server: Lab.Server) async throws {
        try await withTables(server) { session, snapshot in
            let source = try await loaded("items", snapshot, on: session)
            #expect(source.key == [0] && source.rowCount == 3)
            let hostile = "x'; DROP TABLE items; -- \\ \u{0} 😀"
            source.set(.text(hostile), row: 0, column: 1)
            source.set(.text("0x0102"), row: 0, column: 3)
            source.set(.text("011"), row: 0, column: 4)
            source.set(.null, row: 1, column: 1)
            source.changes.delete([["3"]])
            source.changes.addRow([Self.odd: .text("Dee"), "price": .text("9.99")])
            source.changes.addRow()
            try await apply(source, on: session)
            let after = try await rows("SELECT id, \(SQLQuote.identifier(Self.odd)), price, HEX(photo), BIN(flags) FROM "
                                       + "\(Self.database).items ORDER BY id", on: session)
            #expect(after == [["1", hostile, "1.50", "0102", "11"], ["2", nil, "2.00", nil, nil], ["4", "Dee", "9.99", nil, nil],
                              ["5", nil, "0.00", nil, nil]])
        }
    }

    @Test(arguments: servers)
    func aRowChangedBySomeoneElseRollsEverythingBack(_ server: Lab.Server) async throws {
        try await withTables(server) { session, snapshot in
            let source = try await loaded("items", snapshot, on: session)
            source.changes.addRow([Self.odd: .text("new")])
            source.set(.text("first"), row: 0, column: 1)
            source.set(.text("gone"), row: 2, column: 1)
            // Someone else deletes row 3 after it was loaded.
            let other = try await connected(server)
            _ = try await other.query("DELETE FROM \(Self.database).items WHERE id = 3")
            await other.close()
            let failure = await #expect(throws: ApplyFailure.self) { try await apply(source, on: session) }
            #expect(failure?.statement.target == .update(["3"]) && failure?.changed == 0)
            let after = try await rows("SELECT id, \(SQLQuote.identifier(Self.odd)) FROM \(Self.database).items ORDER BY id", on: session)
            #expect(after == [["1", "Ann"], ["2", "Bob"]])  // the first edit and the new row were rolled back
            #expect(!session.inTransaction)
            // A refused statement (a duplicate key) rolls back too.
            source.changes.revertAll()
            source.set(.text("first"), row: 0, column: 1)
            source.set(.text("1"), row: 1, column: 0)
            let refused = await #expect(throws: ApplyFailure.self) { try await apply(source, on: session) }
            #expect(refused?.changed == nil && refused?.statement.target == .update(["2"]))
            #expect(try await rows("SELECT \(SQLQuote.identifier(Self.odd)) FROM \(Self.database).items WHERE id = 1", on: session)
                    == [["Ann"]])
        }
    }

    @Test(arguments: servers)
    func binaryAndCompositeKeysAddressTheirRows(_ server: Lab.Server) async throws {
        try await withTables(server) { session, snapshot in
            let source = try await loaded("pairs", snapshot, on: session)
            #expect(source.key == [0, 1] && source.rowKey(0) == ["1", "0x00112233445566778899AABBCCDDEEFF"])
            source.set(.text("edited"), row: 0, column: 2)
            source.changes.delete([try #require(source.rowKey(1)), try #require(source.rowKey(2))])
            try await apply(source, on: session)
            #expect(try await rows("SELECT shop, HEX(tag), note FROM \(Self.database).pairs", on: session)
                    == [["1", "00112233445566778899AABBCCDDEEFF", "edited"]])
        }
    }

    @Test(arguments: servers)
    func pagesFilterSortAndCount(_ server: Lab.Server) async throws {
        try await withTables(server) { session, snapshot in
            let source = try await loaded("items", snapshot, on: session, filter: "WHERE price > 1.6",
                                          sort: [.init(column: "price", ascending: false)])
            #expect((0..<source.rowCount).map { source.value($0, 0) } == ["3", "2"])
            #expect(try await rows(source.countSQL, on: session) == [["2"]])
            let search = try #require(GridFilter.search("b", in: source.columns))
            source.filter = search
            let page = try #require(try await session.query(source.pageSQL(offset: 0, limit: 10)).first?.rows)
            source.reset()
            source.append(page, requested: 10)
            #expect((0..<source.rowCount).map { source.value($0, 1) } == ["Bob"])
            #expect(!source.hasMore)
        }
    }
}
