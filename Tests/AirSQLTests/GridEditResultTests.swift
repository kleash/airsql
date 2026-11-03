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
        #expect(Self.reasons(log)[0].hasPrefix("To edit, log: It has no primary key or NOT NULL unique key"))
        let view = Self.editing("SELECT * FROM customer_emails", [Self.column("customer_emails", "customer_emails", "id")], snapshot)
        #expect(Self.reasons(view)[0].hasPrefix("To edit, customer_emails: A view has no key"))
        let unknown = Self.editing("SELECT * FROM nope", [Self.column("nope", "nope", "id")], snapshot)
        #expect(Self.reasons(unknown) == ["To edit, AirSQL hasn't read the columns of nope yet"])
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
