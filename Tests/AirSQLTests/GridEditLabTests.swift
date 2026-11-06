import Foundation
import Testing
@testable import AirSQLCore

/// The editing core against MariaDB 11.4 and MySQL 8.4 (AIRSQL_LAB=1): a typed value's literal is kept by the server as
/// typed, a value the core refuses is one the server refuses too, Insert Value expressions run, and the foreign-key,
/// read-back and join rules hold on real schemas and result metadata. Writes only in lane_l3b_edit_<server>.
@Suite(.serialized, .enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
struct GridEditLabTests {
    static let servers = Lab.direct

    static func connected(_ server: Lab.Server, role: DBConnection.Role) async throws -> DBConnection {
        let session = DBConnection(options: DBLab.options(server), role: role, log: DBLab.log)
        try await session.connect()
        return session
    }

    /// The session facts, read as the grid's data session reads them.
    static func context(_ session: DBConnection) async throws -> EditContext {
        let row = try #require(try await session.query("SELECT @@SESSION.sql_mode, @@SESSION.time_zone, VERSION()").first?.rows)
        return EditContext(server: SchemaServer(version: row.string(0, 2) ?? ""), sqlMode: row.string(0, 0) ?? "",
                           timeZone: row.string(0, 1) ?? "SYSTEM")
    }

    @Test(arguments: servers)
    func typedValuesRoundTripThroughTheServer(_ server: Lab.Server) async throws {
        let session = try await Self.connected(server, role: .data), schemaSession = try await Self.connected(server, role: .schema)
        var context = try await Self.context(session)
        let database = "lane_l3b_edit_\(server.name)", table = SQLQuote.identifier(database, "t")
        _ = try await session.query("DROP DATABASE IF EXISTS " + SQLQuote.identifier(database))
        _ = try await session.query("CREATE DATABASE " + SQLQuote.identifier(database))
        _ = try await session.query("""
            CREATE TABLE \(table) (id INT AUTO_INCREMENT PRIMARY KEY, i INT, u BIGINT UNSIGNED, d DECIMAL(38,10),
            b3 BIT(3), b64 BIT(64), dt DATE, tm TIME(6), dtm DATETIME(3), ts TIMESTAMP(6) NULL, y YEAR,
            v VARCHAR(40) CHARACTER SET utf8mb4, l VARCHAR(20) CHARACTER SET latin1, vb VARBINARY(16), bl BLOB, j JSON,
            e ENUM('a','it''s','x\\\\y'), s SET('a','b','c'))
            """)
        let cache = SchemaCache(source: schemaSession, includes: { [Lab.fixture, database].contains($0) })
        try await cache.load()
        let schema = try #require(cache.snapshot.table(database, "t"))
        func type(_ column: String) throws -> ColumnType { ColumnType(try #require(schema.column(column))) }
        #expect(try type("e").kind == .enumeration(["a", "it's", "x\\y"]) && type("j").kind == .json)

        /// Inserts the typed value through its literal and reads back what the server kept, as an editor shows it.
        func roundTrip(_ column: String, _ text: String) async throws -> String {
            let literal = try type(column).literal(text, context)
            let insert = try #require(try await session.query("INSERT INTO \(table) (\(SQLQuote.identifier(column))) VALUES (\(literal))").first)
            let rows = try await session.query("SELECT \(SQLQuote.identifier(column)) FROM \(table) WHERE id = \(insert.insertID)")
            return try type(column).editorText(stored: rows.first?.rows?.bytes(0, 0))
        }
        let ones = String(repeating: "1", count: 64), high = "1" + String(repeating: "0", count: 63)
        var cases: [(String, String, String)] = [
            ("i", " -2147483648 ", "-2147483648"), ("u", "18446744073709551615", "18446744073709551615"),
            ("d", "-1234567890123456789012345678.0123456789", "-1234567890123456789012345678.0123456789"),
            ("d", "00012.5", "12.5000000000"), ("b3", "101", "101"), ("b3", "b'1'", "001"), ("b64", ones, ones), ("b64", high, high),
            ("dt", "2026-1-3", "2026-01-03"), ("tm", "-838:59:59", "-838:59:59.000000"), ("tm", "1 02:03:04.5", "26:03:04.500000"),
            ("dtm", "2026-11-03T14:05:06.123", "2026-11-03 14:05:06.123"),
            ("ts", "2026-11-03 14:05:06.000001", "2026-11-03 14:05:06.000001"), ("y", "0000", "0000"), ("y", "2155", "2155"),
            ("l", "café €", "café €"), ("vb", "0x00FF27", "0x00FF27"), ("bl", "00 01 02", "0x000102"), ("e", "IT'S", "it's"),
            ("e", "x\\y", "x\\y"), ("s", "c, A", "a,c"), ("v", "", ""), ("j", #"{"a": [1, "x"]}"#, #"{"a": [1, "x"]}"#),
        ]
        cases += Hostile.values.filter { $0.unicodeScalars.count <= 40 }.map { ("v", $0, $0) }
        // Values the core refuses are values the server refuses as typed (strict mode); MySQL's sql_mode refuses zero
        // dates, MariaDB's keeps them.
        var refused = [("dt", "2026-02-29"), ("tm", "839:00:00"), ("i", "2147483648"), ("y", "1900"), ("e", "zzz"),
                       ("vb", "0x" + String(repeating: "00", count: 17)), ("l", "中")]
        let deep = { (levels: Int) in String(repeating: "[", count: levels) + String(repeating: "]", count: levels) }
        if server.flavor == .mariadb {
            cases += [("dt", "0000-00-00", "0000-00-00"), ("j", deep(31), deep(31))]
            refused.append(("j", deep(32)))
        } else {
            cases.append(("j", deep(100), deep(100)))
            refused += [("dt", "0000-00-00"), ("j", deep(101))]
        }
        for (column, text, kept) in cases {
            #expect(try await roundTrip(column, text) == kept, "\(column) ← \(text)")
        }
        for (column, text) in refused {
            #expect(throws: EditError.self, "\(column) ← \(text)") { try type(column).literal(text, context) }
            await #expect(throws: (any Error).self, "\(column) ← \(text)") {
                try await session.query("INSERT INTO \(table) (\(SQLQuote.identifier(column))) VALUES ("
                    + SQLQuote.string(text, noBackslashEscapes: context.noBackslashEscapes) + ")")
            }
        }
        // The same hostile text without backslash escapes.
        _ = try await session.query("SET SESSION sql_mode = CONCAT(@@SESSION.sql_mode, ',NO_BACKSLASH_ESCAPES')")
        context = try await Self.context(session)
        #expect(context.noBackslashEscapes && session.noBackslashEscapes)
        for value in Hostile.values where value.unicodeScalars.count <= 40 {
            #expect(try await roundTrip("v", value) == value)
        }
        #expect(try await roundTrip("e", "x\\y") == "x\\y")

        // Every Insert Value item each column offers runs on the server.
        let id = try #require(try await session.query("INSERT INTO \(table) (i) VALUES (1)").first?.insertID)
        for column in schema.columns where column.name != "id" {
            for item in column.insertValues {
                let sql = item.sql(for: ColumnType(column), context)
                let done = try await session.query("UPDATE \(table) SET \(SQLQuote.identifier(column.name)) = \(sql) WHERE id = \(id)")
                #expect(done.first?.warnings == 0, "\(column.name) = \(sql)")
            }
        }
        // A new row is read back by the insert ID.
        let readBack = try schema.readBackQuery(database: database, values: [:], insertID: id)
        #expect(try await session.query(readBack).first?.rows?.rowCount == 1)
        _ = try await session.query("DROP DATABASE " + SQLQuote.identifier(database))
        try await relatedRowsAndJoinsOnTheFixture(session, cache.snapshot, context)
        await session.close()
        await schemaSession.close()
    }

    /// The fixture's shop (testenv/seed/10-fixture.sql), read only.
    func relatedRowsAndJoinsOnTheFixture(_ session: DBConnection, _ snapshot: SchemaSnapshot, _ context: EditContext) async throws {
        let orders = try #require(snapshot.table(Lab.fixture, "orders")), customers = try #require(snapshot.table(Lab.fixture, "customers"))
        let key = try #require(ForeignKeyQueries.foreignKey(of: "customer_id", in: orders))
        let label = ForeignKeyQueries.defaultLabel(customers, key: key.referencedColumns)
        #expect(label == "name")
        let lookup = try #require(try await session.query(ForeignKeyQueries.lookup(key, referenced: customers, label: label,
                                                                                 search: "a", limit: 5, context: context)).first?.rows)
        #expect(lookup.columns.map(\.name) == ["id", "name"] && (1...5).contains(lookup.rowCount))
        // The labels the grid shows after customer_id's values: one row per key found, none for a key that isn't there.
        let ids = (0..<lookup.rowCount).compactMap { lookup.string($0, 0) } + ["999999999"]
        let labelsSQL = try #require(ForeignKeyQueries.labels(key, referenced: customers, label: "name", values: ids, context: context))
        let labels = try #require(try await session.query(labelsSQL).first?.rows)
        #expect(labels.columns.count == 2 && labels.rowCount == ids.count - 1)

        func row(_ sql: String) async throws -> [String: [UInt8]?] {
            let store = try #require(try await session.query(sql).first?.rows)
            return Dictionary(uniqueKeysWithValues: store.columns.indices.map { (store.columns[$0].name, store.bytes(0, $0)) })
        }
        let order = try await row("SELECT * FROM `fixture`.`orders` ORDER BY id LIMIT 1")
        let parent = try ForeignKeyQueries.referenced(by: key, from: orders, row: order, context: context)
        #expect(try await session.query(parent.sql).first?.rows?.rowCount == 1)
        let customer = try await row(parent.sql)
        let children = ForeignKeyQueries.referencing(database: Lab.fixture, table: customers, row: customer, snapshot: snapshot,
                                                     context: context)
        #expect(children.map(\.table).contains("orders"))
        for child in children {
            #expect(try await session.query(child.sql).first?.rows?.rowCount ?? 0 >= (child.table == "orders" ? 1 : 0))
        }

        // The server names each column's table and alias as the join rules expect.
        let sql = "SELECT o.id, o.total, c.id AS customer, c.name, o.total * 2 AS twice FROM fixture.orders o "
            + "JOIN fixture.customers c ON c.id = o.customer_id"
        let store = try #require(try await session.query(sql).first?.rows)
        let editing = ResultEditing(sql: sql, store: store, snapshot: snapshot)
        #expect(editing.sources.map(\.table) == ["orders", "customers"] && editing.sources[1].keyColumns == [2])
        #expect(editing.columns[0] == .editable(source: 0, column: "id") && editing.columns[1] == .editable(source: 0, column: "total"))
        #expect(editing.columns[4] == .readOnly("Worked out by the query, not a column of a table"))
        let outer = ResultEditing(sql: sql.replacingOccurrences(of: " JOIN ", with: " LEFT JOIN "), store: store, snapshot: snapshot)
        #expect(!outer.isEditable)
    }
}
