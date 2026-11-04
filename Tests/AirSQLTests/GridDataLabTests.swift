import AppKit
import Foundation
import Testing
@testable import AirSQL
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

    /// As the table tab applies them, on the data session (UPDATE counts the rows it matched: CLIENT_FOUND_ROWS).
    func apply(_ source: TableDataSource, on session: DBConnection) async throws {
        try await PendingChanges.apply(try source.changes.statements(database: Self.database, table: source.table.name,
                                                                  columns: source.columns,
                                                                  noBackslashEscapes: session.noBackslashEscapes)) { sql in
            try await session.query(sql, rowCap: 1).last?.affectedRows ?? 0
        }
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

    /// You load price 1.50, a colleague sets 20, you set 15: their 20 stays. A column you didn't edit doesn't matter.
    @Test(arguments: servers)
    func anEditedCellChangedBySomeoneElseRollsEverythingBack(_ server: Lab.Server) async throws {
        try await withTables(server) { session, snapshot in
            let other = try await connected(server)
            let source = try await loaded("items", snapshot, on: session)
            source.set(.text("15"), row: 0, column: 2)
            source.set(.text("Bo"), row: 1, column: 1)
            source.set(.text("0xAB"), row: 0, column: 3)
            source.set(.text("110"), row: 0, column: 4)
            _ = try await other.query("UPDATE \(Self.database).items SET price = 20 WHERE id = 1")
            let failure = await #expect(throws: ApplyFailure.self) { try await apply(source, on: session) }
            #expect(failure?.statement.target == .update(["1"]) && failure?.changed == 0)
            #expect(failure?.errorDescription?.contains("nothing was applied") == true)
            let after = try await rows("SELECT id, \(SQLQuote.identifier(Self.odd)), price FROM \(Self.database).items WHERE id < 3 ORDER BY id",
                                       on: session)
            #expect(after == [["1", "Ann", "20.00"], ["2", "Bob", "2.00"]])

            // Changes restored after a restart are checked too.
            let restored = try await loaded("items", snapshot, on: session)
            restored.changes = PendingChanges(keyColumns: ["id"], state: source.changes.state)
            await #expect(throws: ApplyFailure.self) { try await apply(restored, on: session) }

            // Someone else's change to another column, and values that compare exactly, let the edit through.
            source.changes.revertAll()
            let fresh = try await loaded("items", snapshot, on: session)
            fresh.set(.text("15"), row: 0, column: 2)
            fresh.set(.text("0xAB"), row: 0, column: 3)
            fresh.set(.text("110"), row: 0, column: 4)
            fresh.set(.text("x"), row: 1, column: 3)  // NULL before
            _ = try await other.query("UPDATE \(Self.database).items SET \(SQLQuote.identifier(Self.odd)) = 'Anna' WHERE id = 1")
            await other.close()
            try await apply(fresh, on: session)
            #expect(try await rows("SELECT \(SQLQuote.identifier(Self.odd)), price, HEX(photo), BIN(flags) FROM \(Self.database).items "
                                   + "WHERE id = 1", on: session) == [["Anna", "15.00", "AB", "110"]])
        }
    }

    /// Every type's loaded value finds itself in the WHERE, or the edit goes by the key: no false conflict, and no
    /// refusal from a strict server, which MySQL gives a zero date as a literal.
    @Test(arguments: servers)
    func everyTypeAppliesWithoutAFalseConflict(_ server: Lab.Server) async throws {
        try await withTables(server) { session, _ in
            let table = "\(Self.database).types"
            let mode = try await rows("SELECT @@SESSION.sql_mode", on: session)[0][0] ?? ""
            for statement in [
                "SET SESSION sql_mode = ''",
                "CREATE TABLE \(table) (id INT PRIMARY KEY, a DATE, b DATETIME(3), c TIMESTAMP(3) NULL, d TIME(2), e YEAR, f FLOAT, "
                    + "g DOUBLE, h DECIMAL(30,10), i BIT(5), j ENUM('x','y'), k SET('x','y'), l JSON, m POINT, n BINARY(4), "
                    + "o VARCHAR(20), p TEXT, q BIGINT UNSIGNED, r CHAR(3), s TINYINT(1)) ENGINE=InnoDB",
                "INSERT INTO \(table) VALUES (1, '0000-00-00', '2024-01-00 10:00:00.123', '2024-03-31 01:30:00.125', '-838:59:59.00', "
                    + "2024, 0.1, 0.1, 123456789012345678.1234567891, b'00101', 'y', 'x,y', '{\"a\": 1.50}', POINT(1, 2), X'0102', "
                    + "'it''s \\\\ %', 'é😀', 18446744073709551615, 'ab', 1), "
                    + "(2, '2024-02-29', '2024-02-29 23:59:59.999', NULL, '00:00:00.50', 1901, 16777217, 1.7976931348623157e308, "
                    + "-0.0000000001, b'0', 'x', '', '[]', NULL, X'00000000', '', '', 0, '', 0)",
                "SET SESSION sql_mode = '\(mode)'",
            ] { _ = try await session.query(statement) }
            let cache = SchemaCache(source: session, includes: { $0 == Self.database })
            try await cache.load()
            for column in 1...19 {
                let source = try await loaded("types", cache.snapshot, on: session)
                let bit = source.columns[column].name == "i", set = ["j", "k"].contains(source.columns[column].name)
                let value: PendingChanges.Value = source.columns[column].name == "o" ? .text("edited") : .null
                for row in 0..<2 { source.set(bit || set ? .text(bit ? "1" : "x") : value, row: row, column: column) }
                try await apply(source, on: session)
            }
        }
    }

    /// Pages of a sort with many equal values follow one another: the key breaks the ties (MySQL 8.4 repeated and
    /// missed rows without it).
    @Test(arguments: servers)
    func sortedPagesNeitherRepeatNorMissARow(_ server: Lab.Server) async throws {
        let session = try await connected(server)
        let cache = SchemaCache(source: session, includes: { $0 == Lab.fixture })
        try await cache.load()
        let source = TableDataSource(database: Lab.fixture, table: try #require(cache.snapshot.table(Lab.fixture, "big")))
        for ascending in [true, false] {
            source.sort = [.init(column: "flag", ascending: ascending)]
            var seen = Set<String?>()
            for page in 0..<3 {
                for row in try await rows(source.pageSQL(offset: page * 1_000, limit: 1_000), on: session) { seen.insert(row[0]) }
            }
            #expect(seen.count == 3_000)
        }
        await session.close()
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

// The table tab in the app on MySQL 8.4 and MariaDB 11.4 (AIRSQL_LAB=1): rows paged from the real data session, edits
// applied through the preview on a Production-like connection, a row deleted by someone else rolling the Apply back.
extension AppTests {
    @MainActor @Suite(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh")) struct GridDataAppLabTests {
        static let database = "lane_l3a_griddata_app"

        @Test(arguments: GridDataLabTests.servers)
        func editsAndAppliesThroughTheTableTab(_ lab: Lab.Server) async throws {
            let connection = Connection(options: DBLab.options(lab), log: DBLab.log)
            defer { Task { await connection.disconnect() } }
            let schemaSession = try await connection.session(.schema)
            let database = SQLQuote.identifier(Self.database)
            for sql in ["DROP DATABASE IF EXISTS \(database)", "CREATE DATABASE \(database)",
                        "CREATE TABLE \(database).items (id INT PRIMARY KEY, name VARCHAR(20), price DECIMAL(8,2) NOT NULL DEFAULT 0)",
                        "INSERT INTO \(database).items VALUES (1, 'Ann', 1.50), (2, 'Bob', 2.00), (3, 'Cy', 3.00)"] {
                _ = try await schemaSession.query(sql)
            }
            let name = Self.database
            let schema = SchemaCache(source: schemaSession, includes: { $0 == name })
            try await schema.load()
            var saved = SavedConnection(name: "Lab \(lab)", host: "127.0.0.1", user: "airsql")
            saved.safety = .production  // the preview comes first
            let model = testModel([saved])
            let (main, harness) = appWindow(model)
            let context = EditorContext(connection: saved, sessions: connection, schema: schema)
            let tab = TableDataController(model: model, context: context, database: Self.database, table: "items")
            main.select(main.open(tab, title: "items", connection: saved.id))
            await ready { tab.loading != nil || tab.source == nil }
            #expect(tab.grid.rowCount == 3 && tab.viewer.status.rows.stringValue == "3 rows", "\(lab)")

            tab.source?.set(.text("Anna"), row: 0, column: 1)
            tab.source?.changes.delete([["3"]])
            tab.changesDidChange()
            tab.applyChanges(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await call(harness, "press", ["title": "Apply"])
            _ = await eventually(timeout: 30) {
                try? await Task.sleep(nanoseconds: 50_000_000)
                return tab.source?.changes.isEmpty == true && tab.loading == nil
            }
            let after = try await schemaSession.rows("SELECT id, name FROM \(database).items ORDER BY id")
            #expect(after == [["1", "Anna"], ["2", "Bob"]], "\(lab)")
            #expect(tab.grid.rowCount == 2, "\(lab): the rows are read back")

            // Someone else deletes row 2 after it was loaded: nothing is applied and the grid selects the row.
            tab.source?.set(.text("first"), row: 0, column: 1)
            tab.source?.set(.text("Bobby"), row: 1, column: 1)
            tab.changesDidChange()
            _ = try await schemaSession.query("DELETE FROM \(database).items WHERE id = 2")
            tab.applyChanges(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await call(harness, "press", ["title": "Apply"])
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 30])  // the error
            #expect(tab.grid.selection.containsRow(1) && tab.source?.changes.rowCount == 2, "\(lab)")
            _ = await call(harness, "press", ["title": "OK"])
            #expect(try await schemaSession.rows("SELECT name FROM \(database).items") == [["Anna"]], "\(lab)")
            tab.revertAllChanges(nil)
            _ = try await schemaSession.query("DROP DATABASE \(database)")
        }

        /// Data ▸ Quick Filter's conditions, Type a Value… and Sort by Columns… run on the server.
        @Test(arguments: GridDataLabTests.servers)
        func filtersAndSortsFromTheDataMenu(_ lab: Lab.Server) async throws {
            let connection = Connection(options: DBLab.options(lab), log: DBLab.log)
            defer { Task { await connection.disconnect() } }
            let schemaSession = try await connection.session(.schema)
            let name = "lane_r2_find_app", database = SQLQuote.identifier(name)
            for sql in ["DROP DATABASE IF EXISTS \(database)", "CREATE DATABASE \(database)",
                        "CREATE TABLE \(database).items (id INT PRIMARY KEY, name VARCHAR(20), price DECIMAL(8,2) NOT NULL)",
                        "INSERT INTO \(database).items VALUES (1, 'Ann', 1.50), (2, 'Bob', 2.00), (3, 'Cy', 3.00), (4, 'Anna', 4.00), "
                            + "(5, 'Dee', 2.00)"] {
                _ = try await schemaSession.query(sql)
            }
            let schema = SchemaCache(source: schemaSession, includes: { $0 == name })
            try await schema.load()
            let saved = SavedConnection(name: "Lab \(lab)", host: "127.0.0.1", user: "airsql")
            let model = testModel([saved])
            let (main, harness) = appWindow(model)
            let tab = TableDataController(model: model, context: EditorContext(connection: saved, sessions: connection, schema: schema),
                                          database: name, table: "items")
            main.select(main.open(tab, title: "items", connection: saved.id))
            await ready { tab.loading != nil || tab.source == nil }
            func ids() async -> [String] {
                await ready { tab.loading != nil }
                return (0..<tab.grid.rowCount).compactMap { tab.source?.value($0, 0) }
            }
            main.window?.makeFirstResponder(tab.grid)
            tab.grid.selection.select(GridPosition(row: 0, column: 1))
            #expect(await call(harness, "menu", ["path": "Data > Quick Filter > Starts with Selection"]).error == nil)
            #expect(await ids() == ["1", "4"], "\(lab)")
            tab.grid.selection.select(GridPosition(row: 1, column: 2))
            #expect(await call(harness, "menu", ["path": "Data > Quick Filter > Type a Value…"]).error == nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await call(harness, "set", ["id": "quickFilter.operator", "value": "Less than (<)"])
            _ = await call(harness, "set", ["id": "quickFilter.add", "value": true])
            _ = await call(harness, "press", ["title": "Filter", "in": "sheet"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            #expect(await ids() == ["1"] && tab.bar.filterText == "(`name` LIKE 'Ann%') AND `price` < 4.00", "\(lab)")
            tab.clearFilter(nil)
            _ = await ids()
            #expect(await call(harness, "menu", ["path": "Data > Sort by Columns…"]).error == nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await call(harness, "set", ["id": "sort.column.0", "value": "price"])
            _ = await call(harness, "set", ["id": "sort.direction.0", "value": "Descending"])
            _ = await call(harness, "press", ["id": "sort.add"])
            _ = await call(harness, "set", ["id": "sort.column.1", "value": "name"])
            _ = await call(harness, "press", ["id": "sort.ok"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            #expect(await ids() == ["4", "3", "2", "5", "1"], "\(lab)")
            tab.clearSort(nil)
            _ = await ids()
            _ = try await schemaSession.query("DROP DATABASE \(database)")
        }
    }
}
