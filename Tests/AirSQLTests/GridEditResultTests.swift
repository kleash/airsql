import CMariaDB
import Testing
@testable import AirSQLCore

/// Which columns of a console result can be edited: one table with its key, or an inner join with every table's key
/// (R15); the rest read-only with a reason.
struct GridEditResultTests {
    /// A result column from `alias` (a table of the fixture), or an expression when `table` is "".
    static func column(_ alias: String, _ table: String, _ name: String, as label: String? = nil,
                       database: String = "airsql_fixture") -> ResultStore.Column {
        ResultStore.Column(name: label ?? name, originalName: table.isEmpty ? "" : name, table: alias, originalTable: table,
                           database: table.isEmpty ? "" : database, type: MYSQL_TYPE_VAR_STRING)
    }

    static func editing(_ sql: String, _ columns: [ResultStore.Column], rows: [[String?]] = [], _ snapshot: SchemaSnapshot,
                        defaultDatabase: String? = nil) -> ResultEditing {
        let store = ResultStore(columns: columns)
        for row in rows { store.append(row.map { $0.map { Array($0.utf8) } }) }
        return ResultEditing(sql: sql, store: store, snapshot: snapshot, defaultDatabase: defaultDatabase)
    }

    /// Every column's reason when none is editable.
    static func reasons(_ editing: ResultEditing) -> [String] {
        editing.columns.map { if case .readOnly(let reason) = $0 { return reason } else { return "editable" } }
    }

    @Test(arguments: [SchemaFixtures.mariadb118, SchemaFixtures.mysql84])
    func oneTableWithItsKey(_ recording: String) async throws {
        let snapshot = try await GridEditTests.snapshot(recording)
        let c = { (name: String) in Self.column("customers", "customers", name) }
        let plain = Self.editing("SELECT id, email, name_upper, NOW() AS t FROM customers",
                                 [c("id"), c("email"), c("name_upper"), Self.column("", "", "t")], rows: [["1", "a", "A", "x"]], snapshot)
        #expect(plain.sources == [.init(database: "airsql_fixture", table: "customers", key: ["id"], keyColumns: [0])])
        #expect(Array(plain.columns.prefix(2)) == [.editable(source: 0, column: "id"), .editable(source: 0, column: "email")])
        #expect(Self.reasons(plain)[2].hasPrefix("Generated (stored) from "))
        #expect(Self.reasons(plain)[3] == "Worked out by the query, not a column of a table")
        #expect(plain.isEditable && !plain.needsPreview)

        let keyless = Self.editing("select email from customers", [c("email")], snapshot)
        #expect(Self.reasons(keyless) == ["To edit, add customers.id to the SELECT"] && !keyless.isEditable)
        let log = Self.editing("SELECT * FROM log", [Self.column("log", "log", "at")], snapshot)
        #expect(Self.reasons(log)[0].hasPrefix("log: It has no primary key or NOT NULL unique key"))
        let view = Self.editing("SELECT * FROM customer_emails", [Self.column("customer_emails", "customer_emails", "id")], snapshot)
        #expect(Self.reasons(view)[0].hasPrefix("customer_emails: A view has no key"))
        let unknown = Self.editing("SELECT * FROM nope", [Self.column("nope", "nope", "id")], snapshot)
        #expect(Self.reasons(unknown) == ["AirSQL hasn't read the columns of nope yet"])
        // A column that doesn't name its database is in the session's; a composite key in its own order.
        let line = { (name: String) in Self.column("l", "order_lines", name, database: "") }
        let lines = Self.editing("/* lines */ SELECT /*+ NO_ICP(l) */ line, qty, number, region FROM order_lines l",
                                 [line("line"), line("qty"), line("number"), line("region")], snapshot, defaultDatabase: "airsql_fixture")
        #expect(lines.sources.first?.keyColumns == [3, 2, 0] && lines.isEditable)
        #expect(lines.columns[1] == .editable(source: 0, column: "qty"))
    }

    @Test(arguments: [SchemaFixtures.mariadb118, SchemaFixtures.mysql84])
    func innerJoinsNeedEveryTablesKey(_ recording: String) async throws {
        let snapshot = try await GridEditTests.snapshot(recording)
        let o = { (name: String) in Self.column("o", "orders", name) }, c = { (name: String) in Self.column("c", "customers", name) }
        let sql = "SELECT o.id, o.total, c.id, c.email FROM orders o JOIN customers c ON c.id = o.customer_id"
        let columns = [o("id"), o("total"), c("id"), c("email")]
        let join = Self.editing(sql, columns, rows: [["1", "10.00", "7", "a"], ["2", "20.00", "8", "b"]], snapshot)
        #expect(join.columns == [.editable(source: 0, column: "id"), .editable(source: 0, column: "total"),
                                 .editable(source: 1, column: "id"), .editable(source: 1, column: "email")])
        #expect(join.sources.map(\.table) == ["orders", "customers"] && join.sources[1].keyColumns == [2] && join.needsPreview)
        // A customer with two orders shows twice: its columns are read-only, the orders' still editable.
        let repeated = Self.editing(sql, columns, rows: [["1", "10.00", "7", "a"], ["2", "20.00", "7", "a"]], snapshot)
        #expect(Array(repeated.columns.prefix(2)) == [.editable(source: 0, column: "id"), .editable(source: 0, column: "total")])
        #expect(Self.reasons(repeated)[3] == "A customers row shows in more than one result row here: edit it in its own tab")
        let missing = Self.editing("SELECT o.id, c.email FROM orders o, customers c WHERE c.id = o.customer_id", [o("id"), c("email")], snapshot)
        #expect(Self.reasons(missing) == Array(repeating: "A joined result can be edited only when every table's key is in it: "
            + "add customers.id to the SELECT", count: 2))
        let selfJoin = Self.editing("SELECT a.id, b.id FROM orders a JOIN orders b ON b.parent_id = a.id",
                                    [Self.column("a", "orders", "id"), Self.column("b", "orders", "id")], snapshot)
        #expect(Self.reasons(selfJoin) == Array(repeating: "orders appears twice in the query (a self-join): edit it in its own tab", count: 2))
        let leftFunction = Self.editing("SELECT c.id, LEFT(c.email, 3) AS e FROM customers c", [c("id"), Self.column("", "", "e")], snapshot)
        #expect(leftFunction.columns[0] == .editable(source: 0, column: "id"))
    }

    @Test func statementsThatCanNeverBeEdited() {
        let refused: [(String, String)] = [
            ("SELECT * FROM orders o LEFT JOIN customers c ON c.id = o.customer_id", "Outer joins are read-only"),
            ("SELECT * FROM orders o NATURAL RIGHT OUTER JOIN customers c", "Outer joins are read-only"),
            ("SELECT customer_id, COUNT(*) FROM orders GROUP BY customer_id", "Grouped results are read-only"),
            ("SELECT DISTINCT customer_id FROM orders", "DISTINCT results are read-only"),
            ("SELECT id FROM orders UNION SELECT id FROM customers", "Combined results (UNION) are read-only"),
            ("SELECT * FROM (SELECT * FROM orders) d", "subquery in FROM"),
            ("WITH x AS (SELECT 1) SELECT * FROM x", "Only the results of a plain SELECT"),
            ("SHOW TABLES", "Only the results of a plain SELECT"), ("CALL p()", "Only the results of a plain SELECT"),
        ]
        for (sql, reason) in refused {
            #expect(ResultEditing.statementRefusal(sql, noBackslashEscapes: false)?.contains(reason) == true, "\(sql)")
        }
        for sql in ["SELECT * FROM orders WHERE id IN (SELECT parent_id FROM orders) ORDER BY id LIMIT 5",
                    "SELECT `left`, RIGHT(x, 2) FROM t STRAIGHT_JOIN u CROSS JOIN v", "SELECT * FROM t WHERE x = 'LEFT JOIN'",
                    "SELECT COUNT(DISTINCT a) FROM t", "  select * from t for update"] {
            #expect(ResultEditing.statementRefusal(sql, noBackslashEscapes: false) == nil, "\(sql)")
        }
    }
}

/// Editing a console result: each table's pending changes over the rows, undo across tables, the statements Apply runs,
/// and the values read back after it.
struct ResultEditSourceTests {
    static func source(_ sql: String, _ columns: [ResultStore.Column], rows: [[String?]], _ snapshot: SchemaSnapshot) -> ResultEditSource {
        let store = ResultStore(columns: columns)
        for row in rows { store.append(row.map { $0.map { Array($0.utf8) } }) }
        let source = ResultEditSource(store)
        source.setEditing(ResultEditing(sql: sql, store: store, snapshot: snapshot), snapshot: snapshot)
        return source
    }

    @Test func aJoinsEditsGoToEachTableByItsKey() async throws {
        let snapshot = try await GridEditTests.snapshot(SchemaFixtures.mariadb118)
        let context = EditContext(flavour: .mariadb, version: [11, 8, 0], sqlMode: "STRICT_TRANS_TABLES")
        let o = { (name: String) in GridEditResultTests.column("o", "orders", name) }
        let c = { (name: String) in GridEditResultTests.column("c", "customers", name) }
        let source = Self.source("SELECT o.id, o.region, c.id, c.email FROM orders o JOIN customers c ON c.id = o.customer_id",
                                 [o("id"), o("region"), c("id"), c("email")], rows: [["1", "EU", "7", "a@x"], ["2", "US", "8", "b@x"]], snapshot)
        #expect(source.canEdit(0, 1) && source.canEdit(1, 3) && !source.canDelete && source.reason(1) == nil)
        source.group {
            source.set(.text("US"), row: 0, column: 1)
            source.set(.text("c@x"), row: 1, column: 3)
        }
        source.set(.null, row: 0, column: 3)
        #expect(source.cell(0, 1) == .text("US") && source.mark(0, 1) == .edited && source.cell(0, 3) == .null && source.pendingRows == 3)
        #expect(source.mark(0, 0) == GridMark.none && source.isChanged(1))
        let statements = try source.statements(context: context).map(\.sql)
        #expect(statements == ["UPDATE `airsql_fixture`.`orders` SET `region` = 'US' WHERE `id` = 1",
                               "UPDATE `airsql_fixture`.`customers` SET `email` = NULL WHERE `id` = 7",
                               "UPDATE `airsql_fixture`.`customers` SET `email` = 'c@x' WHERE `id` = 8"])
        // Undo takes back the NULL, then both edits of the multi-cell step at once.
        source.undo()
        #expect(source.cell(0, 3) == .text("a@x") && source.cell(1, 3) == .text("c@x"))
        source.undo()
        #expect(source.isEmpty && source.cell(0, 1) == .text("EU") && source.canRedo)
        source.redo()
        #expect(source.cell(0, 1) == .text("US") && source.cell(1, 3) == .text("c@x"))
        // Read back by key: the server's values show after Apply (here it upper-cased the email).
        let reads = source.readBack(noBackslashEscapes: false)
        #expect(reads.map(\.sql) == ["SELECT `id`, `region` FROM `airsql_fixture`.`orders` WHERE `id` IN (1)",
                                     "SELECT `id`, `email` FROM `airsql_fixture`.`customers` WHERE `id` IN (8)"])
        let back = ResultStore(columns: [.init(name: "id", type: MYSQL_TYPE_LONG), .init(name: "email", type: MYSQL_TYPE_VAR_STRING)])
        back.append([Array("8".utf8), Array("C@X".utf8)])
        source.applied([(back, 1, reads[1].columns)])
        #expect(source.isEmpty && !source.canUndo && source.cell(1, 3) == .text("C@X") && source.cell(0, 1) == .text("US"))
        #expect(source.mark(1, 3) == GridMark.none)
        // A value its column refuses names the column.
        source.set(.text("x".padding(toLength: 300, withPad: "x", startingAt: 0)), row: 0, column: 3)
        #expect(throws: ApplyFailure.self) { try source.statements(context: context) }
    }

    @Test func aOneTableResultCanDeleteRows() async throws {
        let snapshot = try await GridEditTests.snapshot(SchemaFixtures.mysql84)
        let c = { (name: String) in GridEditResultTests.column("customers", "customers", name) }
        let source = Self.source("SELECT id, email FROM customers", [c("id"), c("email")], rows: [["7", "a@x"], ["8", "b@x"]], snapshot)
        #expect(source.canDelete)
        source.delete([0])
        #expect(source.mark(0, 1) == .deleted && !source.canEdit(0, 1))
        let context = EditContext(flavour: .mysql, version: [8, 4, 0], sqlMode: "")
        #expect(try source.statements(context: context).map(\.sql) == ["DELETE FROM `airsql_fixture`.`customers` WHERE `id` IN (7)"])
        source.applied([])
        #expect(source.rowCount == 1 && source.cell(0, 0) == .text("8"))
        // Until the schema is read, nothing can be edited, and it says why.
        let waiting = ResultEditSource(source.store)
        #expect(!waiting.canEdit(0, 1) && waiting.reason(1)?.hasPrefix("AirSQL is still reading") == true)
    }
}

/// Edit as Table: INSERT statements read back into a table, its columns and rows of pending values.
struct InsertRowsTests {
    @Test func insertsBecomeRowsOfValues() throws {
        let sql = """
            INSERT INTO `shop`.`items` (`id`, name, price, made) VALUES (1, 'it''s', -2.5, NOW()), (2, "two\\nlines", NULL, DEFAULT);
            /* the next one */ insert ignore into shop.items (id, name, price, made) value (0x0A, _utf8mb4'x', TRUE, b'101');
            """
        let rows = try InsertRows.parse(sql, noBackslashEscapes: false)
        #expect(rows.database == "shop" && rows.table == "items" && rows.columns == ["id", "name", "price", "made"])
        #expect(rows.rows == [[.text("1"), .text("it's"), .text("-2.5"), .sql("NOW()")],
                              [.text("2"), .text("two\nlines"), .null, .default],
                              [.text("0x0A"), .text("x"), .text("1"), .text("101")]])
        // Without NO_BACKSLASH_ESCAPES a backslash escapes; with it, it is itself.
        #expect(try InsertRows.parse("INSERT INTO t VALUES ('a\\\\b', 'c\\%')", noBackslashEscapes: false).rows == [[.text("a\\b"), .text("c\\%")]])
        #expect(try InsertRows.parse("INSERT INTO t VALUES ('a\\b')", noBackslashEscapes: true).rows == [[.text("a\\b")]])
        #expect(try InsertRows.parse("INSERT INTO t VALUES (1 + 2, CONCAT('a', ',', 'b'))", noBackslashEscapes: false).rows
                == [[.sql("1 + 2"), .sql("CONCAT('a', ',', 'b')")]])
    }

    @Test func theStatementAtTheCursorReads() throws {
        let text = "SELECT 1;\nINSERT INTO airsql_fixture.orders (region, number, total) VALUES ('EU', 7, 1.5), ('US', 8, DEFAULT);"
        let statements = ConsoleScript.statements(in: text, selection: nil, caret: 20, all: false, noBackslashEscapes: false)
        let rows = try InsertRows.parse(statements.map(\.sql).joined(separator: ";\n"), noBackslashEscapes: false)
        #expect(rows.table == "orders" && rows.rows.count == 2, "\(statements.map(\.sql))")
    }

    @Test func otherStatementsAreRefusedSayingWhy() {
        for sql in ["SELECT 1", "INSERT INTO t SELECT * FROM u", "INSERT INTO t SET a = 1", "INSERT INTO t VALUES (1) ON DUPLICATE KEY UPDATE a = 2",
                    "INSERT INTO t (a, b) VALUES (1)", "INSERT INTO t VALUES (1,,2)", "INSERT INTO t VALUES (1); INSERT INTO u VALUES (2)", ""] {
            #expect(throws: EditError.self, "\(sql)") { try InsertRows.parse(sql, noBackslashEscapes: false) }
        }
    }
}
