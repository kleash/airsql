import Foundation
import Testing
@testable import AirSQLCore

/// Compare and reconcile against the lab (AIRSQL_LAB=1): structure and data on MariaDB and MySQL, across the two
/// flavours, the hashing's edge cases on real servers, the million-row table, and a sync script that makes the target
/// match. Writes only in databases named lane_l8a_*.
@Suite(.serialized, .enabled(if: Lab.enabled, "AIRSQL_LAB=1 runs the lab tests"))
struct ReconLabTests {
    static let log = SQLLog(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("airsql-recon-lab-\(getpid())/SQL.log"))

    static func session(_ server: Lab.Server) async throws -> DBConnection {
        let options = ConnectOptions(name: server.name, host: "127.0.0.1", port: try #require(server.port),
                                     user: Lab.airsql.user, password: Lab.airsql.password,
                                     tls: TLSOptions(mode: server.flavor == .mysql ? .required : .off))
        let session = DBConnection(options: options, role: .tools, log: log)
        try await session.connect()
        return session
    }

    /// Runs statements one at a time.
    static func run(_ session: DBConnection, _ statements: [String]) async throws {
        for statement in statements { _ = try await session.query(statement) }
    }

    /// A fresh database of this lane's with these statements run in it.
    static func database(_ session: DBConnection, _ name: String, _ statements: [String]) async throws {
        try await run(session, ["DROP DATABASE IF EXISTS \(name)", "CREATE DATABASE \(name) CHARACTER SET utf8mb4",
                                "USE \(name)"] + statements)
    }

    static func compare(_ source: DBConnection, _ sourceDB: String, _ target: DBConnection, _ targetDB: String,
                        options: ReconOptions = ReconOptions()) async throws -> ReconResult {
        try await Recon.run(source: ReconSide(name: "Source", database: sourceDB, session: source),
                            target: ReconSide(name: "Target", database: targetDB, session: target), options: options)
    }

    static let shopSource = [
        "CREATE TABLE customers (id INT PRIMARY KEY, name VARCHAR(50) NOT NULL, note TEXT NULL, seen TIMESTAMP NULL)",
        """
        CREATE TABLE orders (id BIGINT PRIMARY KEY, customer_id INT NOT NULL, total DECIMAL(10,2) NOT NULL,
            currency CHAR(3) NOT NULL DEFAULT 'EUR', KEY ix_customer (customer_id),
            CONSTRAINT fk_customer FOREIGN KEY (customer_id) REFERENCES customers (id))
        """,
        "CREATE TABLE gift_cards (code VARCHAR(20) PRIMARY KEY, amount INT)",
        "CREATE VIEW big_orders AS SELECT id, total FROM orders WHERE total > 100",
        """
        INSERT INTO customers VALUES (1, 'Ada', 'first', '2026-01-02 03:04:05'), (2, 'Brook', NULL, NULL),
            (3, 'Cy', '', NULL), (4, 'Dee', 'it''s \\\\ "quoted"', NULL), (5, 'Eve', 'new', NULL)
        """,
        "INSERT INTO orders VALUES (10, 1, 12.50, 'EUR'), (11, 2, 250.00, 'USD')",
        "INSERT INTO gift_cards VALUES ('G-1', 20)",
    ]

    static let shopTarget = [
        "CREATE TABLE customers (id INT PRIMARY KEY, name VARCHAR(50) NOT NULL, note TEXT NULL, seen TIMESTAMP NULL)",
        """
        CREATE TABLE orders (id BIGINT PRIMARY KEY, customer_id INT NOT NULL, total DECIMAL(10,2) NOT NULL,
            KEY ix_customer (customer_id))
        """,
        "CREATE TABLE legacy (id INT PRIMARY KEY)",
        """
        INSERT INTO customers VALUES (1, 'Ada', 'first', '2026-01-02 03:04:05'), (2, 'Brooke', NULL, NULL),
            (3, 'Cy', NULL, NULL), (4, 'Dee', 'it''s \\\\ "quoted"', NULL), (6, 'Fay', 'gone', NULL)
        """,
        "INSERT INTO orders VALUES (10, 1, 12.50), (11, 2, 250.00)",
    ]

    @Test(arguments: [(Lab.mariadb114, Lab.mariadb114), (Lab.mysql84, Lab.mysql84), (Lab.mysql84, Lab.mariadb114)])
    func comparesAndSyncsAShop(_ servers: (Lab.Server, Lab.Server)) async throws {
        let source = try await Self.session(servers.0), target = try await Self.session(servers.1)
        defer { Task { await source.close(); await target.close() } }
        try await Self.database(source, "lane_l8a_shop_src", Self.shopSource)
        try await Self.database(target, "lane_l8a_shop_dst", Self.shopTarget)

        let result = try await Self.compare(source, "lane_l8a_shop_src", target, "lane_l8a_shop_dst")
        let customers = try #require(result.object(.table, "customers"))
        #expect(customers.status == .same, "\(customers.parts)")
        let data = try #require(customers.data)
        #expect(data.outcome == .different)
        #expect(data.missing.map { $0.text(0, kind: .integer) } == ["5"])
        #expect(data.extra.map { $0.text(0, kind: .integer) } == ["6"])
        #expect(Set(data.changed.map { $0.source.text(0, kind: .integer) }) == ["2", "3"])
        let orders = try #require(result.object(.table, "orders"))
        #expect(orders.status == .different)
        #expect(orders.parts.map { "\($0.kind) \($0.name) \($0.change)" }.sorted()
                == ["column currency added", "foreignKey fk_customer added"])
        #expect(result.object(.table, "gift_cards")?.status == .onlyInSource)
        #expect(result.object(.table, "legacy")?.status == .onlyInTarget)
        #expect(result.object(.view, "big_orders")?.status == .onlyInSource)

        // The script with its destructive steps makes the target match the source; the values of a new column come
        // with a second compare.
        try await result.apply(destructive: true, on: target) { _ in }
        let second = try await Self.compare(source, "lane_l8a_shop_src", target, "lane_l8a_shop_dst")
        #expect(second.object(.table, "orders")?.data?.changed.count == 1)
        #expect(second.object(.table, "gift_cards")?.data?.outcome == .same)
        try await second.apply(destructive: true, on: target) { _ in }
        let again = try await Self.compare(source, "lane_l8a_shop_src", target, "lane_l8a_shop_dst")
        // Each flavour writes a view's body its own way, so across flavours the view still reads differently.
        let left = again.objects.filter { $0.differs && !($0.kind == .view && servers.0.flavor != servers.1.flavor) }
            .map { "\($0.kind) \($0.name) \($0.status) \($0.parts.map(\.detail)) \($0.data?.outcome as Any)" }
        #expect(left.isEmpty, "\(left)")
        try await Self.run(source, ["DROP DATABASE lane_l8a_shop_src"])
        try await Self.run(target, ["DROP DATABASE lane_l8a_shop_dst"])
    }

    /// Values that hash alike under a careless encoding must differ; values each server writes differently but that
    /// are equal must not.
    @Test(arguments: [Lab.mariadb114, Lab.mysql84])
    func hashesTellEveryDifference(_ server: Lab.Server) async throws {
        let source = try await Self.session(server), target = try await Self.session(server)
        defer { Task { await source.close(); await target.close() } }
        let table = """
            CREATE TABLE edge (id INT PRIMARY KEY, a VARCHAR(10) NULL, b VARCHAR(10) NULL,
                c VARCHAR(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NULL, t TIMESTAMP NULL,
                bin VARBINARY(10) NULL, bits BIT(8) NULL, j JSON NULL, f DOUBLE NULL)
            """
        let keys = "CREATE TABLE keys_ci (k VARCHAR(5) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci PRIMARY KEY, v INT)"
        try await Self.database(source, "lane_l8a_edge_src", [table, keys, "SET time_zone = '+00:00'", """
            INSERT INTO edge (id, a, b, c, t, bin, bits, j, f) VALUES
                (1, 'ab', 'cd', NULL, NULL, NULL, NULL, NULL, NULL), (2, 'ab', 'c', NULL, NULL, NULL, NULL, NULL, NULL),
                (3, NULL, 'x', NULL, NULL, NULL, NULL, NULL, NULL), (4, '', NULL, NULL, NULL, NULL, NULL, NULL, NULL),
                (5, 'a', '1:b', NULL, NULL, NULL, NULL, NULL, NULL), (6, NULL, NULL, 'abc', NULL, NULL, NULL, NULL, NULL),
                (7, NULL, NULL, 'a', NULL, NULL, NULL, NULL, NULL), (8, NULL, NULL, NULL, NULL, X'00', NULL, NULL, NULL),
                (9, NULL, NULL, NULL, NULL, NULL, b'1', NULL, NULL),
                (10, 'same', 'same', 'same', NULL, X'FF', b'101', '[1, 2]', 0.1),
                (11, NULL, NULL, NULL, '2026-01-01 00:00:00', NULL, NULL, NULL, NULL),
                (12, NULL, NULL, NULL, NULL, NULL, NULL, '{"a": 1, "b": [true, null]}', 1e300)
            """, "INSERT INTO keys_ci VALUES ('a', 1), ('b', 2)"])
        try await Self.database(target, "lane_l8a_edge_dst", [table, keys, "SET time_zone = '+02:00'", """
            INSERT INTO edge (id, a, b, c, t, bin, bits, j, f) VALUES
                (1, 'cd', 'ab', NULL, NULL, NULL, NULL, NULL, NULL), (2, 'a', 'bc', NULL, NULL, NULL, NULL, NULL, NULL),
                (3, 'x', NULL, NULL, NULL, NULL, NULL, NULL, NULL), (4, NULL, '', NULL, NULL, NULL, NULL, NULL, NULL),
                (5, 'a1', ':b', NULL, NULL, NULL, NULL, NULL, NULL), (6, NULL, NULL, 'ABC', NULL, NULL, NULL, NULL, NULL),
                (7, NULL, NULL, 'a ', NULL, NULL, NULL, NULL, NULL), (8, NULL, NULL, NULL, NULL, X'0000', NULL, NULL, NULL),
                (9, NULL, NULL, NULL, NULL, NULL, b'10', NULL, NULL),
                (10, 'same', 'same', 'same', NULL, X'FF', b'101', '[1,2]', 0.1),
                (11, NULL, NULL, NULL, '2026-01-01 02:00:00', NULL, NULL, NULL, NULL),
                (12, NULL, NULL, NULL, NULL, NULL, NULL, '{"b":[true,null],"a":1}', 1e300)
            """, "INSERT INTO keys_ci VALUES ('A', 1), ('b', 2)"])
        let result = try await Self.compare(source, "lane_l8a_edge_src", target, "lane_l8a_edge_dst")
        let edge = try #require(result.object(.table, "edge")?.data)
        let changed = edge.changed.compactMap { $0.source.text(0, kind: .integer) }.sorted { Int($0)! < Int($1)! }
        #expect(changed == ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
        #expect(edge.missing.isEmpty && edge.extra.isEmpty)
        let keyed = try #require(result.object(.table, "keys_ci")?.data)
        #expect(keyed.missing.map { $0.text(0, kind: .text) } == ["a"])
        #expect(keyed.extra.map { $0.text(0, kind: .text) } == ["A"])
        try await Self.run(source, ["DROP DATABASE lane_l8a_edge_src"])
        try await Self.run(target, ["DROP DATABASE lane_l8a_edge_dst"])
    }

    /// The million-row table: the same on two servers of different flavours (checksums only), and a copy with a few
    /// rows changed, deleted and added found by fetching a small share of it.
    @Test func comparesAMillionRows() async throws {
        let mariadb = try await Self.session(Lab.mariadb114), mysql = try await Self.session(Lab.mysql84)
        let copy = try await Self.session(Lab.mariadb114)
        defer { Task { await mariadb.close(); await mysql.close(); await copy.close() } }
        var options = ReconOptions()
        options.mode = .data
        options.tables = Dictionary(uniqueKeysWithValues: ["all_types", "places", "customers", "products", "orders",
            "order_items", "employees", "no_pk_log", "unique_no_pk", "myisam_notes", "latin1_legacy", "texts",
            "legacy_dates", "order details", "טבלה", "x`; DROP TABLE nothing; --",
            "this_table_name_is_sixty_four_characters_long_the_most_mysql_has"].map { ($0, ReconTableChoice(included: false)) })
        let started = Date()
        let same = try await Self.compare(mysql, Lab.fixture, mariadb, Lab.fixture, options: options)
        let big = try #require(same.object(.table, "big")?.data)
        #expect(big.outcome == .same && big.sourceRows == Lab.bigRows && big.targetRows == Lab.bigRows)
        #expect(same.rowsFetched == 0)
        let across = Date().timeIntervalSince(started)

        try await Self.database(copy, "lane_l8a_big", ["CREATE TABLE big LIKE fixture.big",
                                                       "INSERT INTO big SELECT * FROM fixture.big",
                                                       "UPDATE big SET name = 'changed' WHERE id IN (17, 500000, 999999)",
                                                       "UPDATE big SET note = NULL WHERE id = 500001",
                                                       "DELETE FROM big WHERE id IN (250000, 250001)",
                                                       "INSERT INTO big VALUES (1000001, 'new', 1, '2030-01-01', 'red', 1, NULL)"])
        let differs = try await Self.compare(mariadb, Lab.fixture, copy, "lane_l8a_big", options: options)
        let data = try #require(differs.object(.table, "big")?.data)
        #expect(Set(data.changed.compactMap { $0.source.text(0, kind: .integer) }) == ["17", "500000", "500001", "999999"])
        #expect(Set(data.missing.compactMap { $0.text(0, kind: .integer) }) == ["250000", "250001"])
        #expect(data.extra.compactMap { $0.text(0, kind: .integer) } == ["1000001"])
        #expect(differs.rowsFetched < Lab.bigRows / 50, "fetched \(differs.rowsFetched)")
        print("Recon: 1M rows across flavours in \(across) s; with differences \(differs.duration) s, fetched \(differs.rowsFetched)")
        try await Self.run(copy, ["DROP DATABASE lane_l8a_big"])
    }

    /// Tables… choices: a renamed table mapped, a column left out, a WHERE, a table left out.
    @Test func followsTheTableChoices() async throws {
        let source = try await Self.session(Lab.mariadb114), target = try await Self.session(Lab.mariadb114)
        defer { Task { await source.close(); await target.close() } }
        try await Self.database(source, "lane_l8a_opt_src", [
            "CREATE TABLE items (id INT PRIMARY KEY, name VARCHAR(20), touched INT)", "CREATE TABLE skipped (id INT PRIMARY KEY)",
            "INSERT INTO items VALUES (1, 'a', 1), (2, 'b', 2), (3, 'c', 3), (10, 'x', 1)"])
        try await Self.database(target, "lane_l8a_opt_dst", [
            "CREATE TABLE items_v2 (id INT PRIMARY KEY, name VARCHAR(20), touched INT)",
            "INSERT INTO items_v2 VALUES (1, 'a', 9), (2, 'B', 2), (3, 'c', 3), (10, 'y', 1)"])
        var options = ReconOptions()
        options.tables["items"] = ReconTableChoice(target: "items_v2", excludedColumns: ["touched"], filter: "id < 10 -- small ones")
        options.tables["skipped"] = ReconTableChoice(included: false)
        let result = try await Self.compare(source, "lane_l8a_opt_src", target, "lane_l8a_opt_dst", options: options)
        let items = try #require(result.object(.table, "items"))
        #expect(items.targetName == "items_v2" && items.status == .same)
        #expect(items.data?.changed.map { $0.source.text(0, kind: .integer) } == ["2"])
        #expect(items.data?.columns.map(\.name) == ["id", "name"])
        #expect(result.object(.table, "skipped") == nil)
        #expect(result.script().contains("UPDATE `items_v2` SET `name` = 'b' WHERE `id` IN (2)"))
        try await Self.run(source, ["DROP DATABASE lane_l8a_opt_src"])
        try await Self.run(target, ["DROP DATABASE lane_l8a_opt_dst"])
    }

    /// Hostile names and values go through every statement a compare and a sync write, on a target whose sql_mode has
    /// NO_BACKSLASH_ESCAPES, and come out the same.
    @Test(arguments: [Lab.mariadb114, Lab.mysql84])
    func hostileNamesAndValuesSurviveASync(_ server: Lab.Server) async throws {
        let source = try await Self.session(server), target = try await Self.session(server)
        defer { Task { await source.close(); await target.close() } }
        let table = "x`; DROP TABLE nothing; --", columns = ["it's", "a\"b", "`"]
        let names = columns.map(SQLQuote.identifier).joined(separator: ", ")
        let create = "CREATE TABLE \(SQLQuote.identifier(table)) (id INT PRIMARY KEY, "
            + columns.map { SQLQuote.identifier($0) + " TEXT" }.joined(separator: ", ") + ")"
        let values = Hostile.values.enumerated().map { index, value in
            "(\(index), " + [value, String(value.reversed()), "x"].map { SQLQuote.string($0) }.joined(separator: ", ") + ")"
        }
        try await Self.database(source, "lane_l8a_hostile_src", [create,
            "INSERT INTO \(SQLQuote.identifier(table)) (id, \(names)) VALUES " + values.joined(separator: ", ")])
        try await Self.database(target, "lane_l8a_hostile_dst", [create,
            "INSERT INTO \(SQLQuote.identifier(table)) (id, \(names)) VALUES (0, 'stale', NULL, NULL), (999, 'gone', NULL, NULL)",
            "SET SESSION sql_mode = CONCAT(@@sql_mode, ',NO_BACKSLASH_ESCAPES')"])
        let result = try await Self.compare(source, "lane_l8a_hostile_src", target, "lane_l8a_hostile_dst")
        #expect(result.target.noBackslashEscapes)
        #expect(result.object(.table, table)?.data?.differenceCount == Hostile.values.count + 1)
        try await result.apply(destructive: true, on: target) { _ in }
        let again = try await Self.compare(source, "lane_l8a_hostile_src", target, "lane_l8a_hostile_dst")
        #expect(again.object(.table, table)?.data?.outcome == .same)
        try await Self.run(source, ["DROP DATABASE lane_l8a_hostile_src"])
        try await Self.run(target, ["DROP DATABASE lane_l8a_hostile_dst"])
    }
}

/// Compare With… against the lab: a result compared with another result and with a table on MariaDB 11.8 and MySQL 8.4,
/// and results of the two flavours compared as values. Writes only in databases named lane_gridcompare_*.
@Suite(.serialized, .enabled(if: Lab.enabled, "AIRSQL_LAB=1 runs the lab tests"))
struct ReconResultsLabTests {
    /// `items` and `items_copy`, which differs from it by a changed row (2), one row fewer (3) and one more (4).
    static let items = [
        """
        CREATE TABLE items (id INT PRIMARY KEY, name VARCHAR(40) NOT NULL, price DECIMAL(10,2), tags JSON, img BLOB,
            seen TIMESTAMP NULL, ratio DOUBLE)
        """,
        """
        INSERT INTO items VALUES (1, 'pen', 2.50, '{"b":[2,3],"a":1}', X'00FF', '2026-01-02 03:04:05', 0.1),
            (2, 'ink', 4.00, NULL, NULL, NULL, 1e-3), (3, 'pad', 1.00, '[]', '', NULL, 2)
        """,
    ]
    static let copy = ["CREATE TABLE items_copy LIKE items", "INSERT INTO items_copy SELECT * FROM items",
                       "UPDATE items_copy SET name = 'INK', price = 4.10 WHERE id = 2", "DELETE FROM items_copy WHERE id = 3",
                       "INSERT INTO items_copy VALUES (4, 'cap', 7.00, NULL, X'01', NULL, NULL)"]

    static func rows(_ session: DBConnection, _ sql: String) async throws -> ResultStore {
        try #require(try await session.query(sql).first { $0.rows != nil }?.rows)
    }

    @Test(arguments: [Lab.mariadb118, Lab.mysql84])
    func aResultComparesWithAnotherAndWithATable(_ server: Lab.Server) async throws {
        let session = try await ReconLabTests.session(server)
        let database = "lane_gridcompare_\(server.flavor == .mysql ? "mysql" : "mariadb")"
        try await ReconLabTests.database(session, database, Self.items + Self.copy)
        let items = try await Self.rows(session, "SELECT * FROM items"), copy = try await Self.rows(session, "SELECT * FROM items_copy")
        let data = ReconTableData.compare(items, copy, key: ["id"])
        #expect(data.columns.map(\.kind) == [.integer, .text, .decimal, server.flavor == .mysql ? .json : .longText, .blob, .temporal, .float])
        #expect(data.missing.map { $0.text(0, kind: .integer) } == ["3"] && data.extra.map { $0.text(0, kind: .integer) } == ["4"])
        #expect(data.changed.map(\.columns) == [[1, 2]] && data.changed.first?.target.text(1, kind: .text) == "INK")
        // The table read from the server gives the same, its own table nothing; matched on every column, the changed
        // row is on both sides.
        #expect(try await ReconTableData.compare(items, table: "items_copy", database: database, on: session, key: ["id"]) == data)
        #expect(try await ReconTableData.compare(items, table: "items", database: database, on: session, key: ["id"]).outcome == .same)
        let whole = try await ReconTableData.compare(items, table: "items_copy", database: database, on: session, key: [])
        #expect(whole.missing.count == 2 && whole.extra.count == 2 && whole.changed.isEmpty)
        // More rows than a result holds: not compared, saying what to do instead.
        let big = try await ReconTableData.compare(items, table: "big", database: "fixture", on: session, key: ["id"])
        #expect(big.outcome == .notCompared("big has more than 100,000 rows: compare the result of a query with a WHERE instead, "
            + "or whole tables with Tools ▸ Compare."))
        try await ReconLabTests.run(session, ["DROP DATABASE \(database)"])
        await session.close()
    }

    /// The same rows read from MariaDB and from MySQL compare the same either way round, though MySQL rewrites the JSON
    /// (`{"a": 1, "b": [2, 3]}`) and MariaDB keeps it as written; a changed value on one side shows.
    @Test func resultsOfMariaDBAndMySQLCompareAsValues() async throws {
        let maria = try await ReconLabTests.session(Lab.mariadb118), mysql = try await ReconLabTests.session(Lab.mysql84)
        for session in [maria, mysql] { try await ReconLabTests.database(session, "lane_gridcompare_both", Self.items) }
        let a = try await Self.rows(maria, "SELECT * FROM items"), b = try await Self.rows(mysql, "SELECT * FROM items")
        #expect(a.string(0, 3) != b.string(0, 3), "each server writes the JSON its own way")
        #expect(ReconTableData.compare(a, b, key: ["id"]).outcome == .same)
        #expect(ReconTableData.compare(b, a, key: ["id"]).outcome == .same)
        try await ReconLabTests.run(mysql, ["UPDATE items SET tags = '{\"a\": 1, \"b\": [3, 2]}', ratio = 0.25 WHERE id = 1"])
        let changed = ReconTableData.compare(a, try await Self.rows(mysql, "SELECT * FROM items"), key: ["id"])
        #expect(changed.changed.map(\.columns) == [[3, 6]] && changed.missing.isEmpty && changed.extra.isEmpty)
        for session in [maria, mysql] {
            try await ReconLabTests.run(session, ["DROP DATABASE lane_gridcompare_both"])
            await session.close()
        }
    }
}
