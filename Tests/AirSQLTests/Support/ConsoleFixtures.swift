import AppKit
import CMariaDB
@testable import AirSQL
@testable import AirSQLCore

/// A console as the screens show it, without a server: the mockups' query, a result tab of top customers, Messages with
/// a warning and an error, and a plan.
@MainActor
enum ConsoleFixtures {
    static let query = """
        -- Top customers by paid orders, last 90 days
        SELECT c.id, c.`name`, c.email, COUNT(o.id) AS orders, SUM(o.total) AS spent
        FROM customers c
        JOIN orders o ON o.customer_id = c.id
        WHERE o.status = 'paid' AND o.created_at >= NOW() - INTERVAL 90 DAY
        GROUP BY c.id ORDER BY spent DESC LIMIT 200;

        -- Refunds per product
        SELECT p.sku, SUM(r.amount) FROM refunds r JOIN products p ON p.id = r.product_id GROUP BY p.sku;
        """

    /// Five columns of customers, the long and odd ones among them (plan §2.13).
    static func customers(rows: Int = 200) -> ResultStore {
        let store = ResultStore(columns: [
            ResultStore.Column(name: "id", table: "c", type: MYSQL_TYPE_LONG, flags: UInt32(PRI_KEY_FLAG)),
            ResultStore.Column(name: "name", table: "c", type: MYSQL_TYPE_VAR_STRING),
            ResultStore.Column(name: "email", table: "c", type: MYSQL_TYPE_VAR_STRING),
            ResultStore.Column(name: "orders", type: MYSQL_TYPE_LONGLONG),
            ResultStore.Column(name: "spent", type: MYSQL_TYPE_NEWDECIMAL),
        ])
        let names = ["Harbor Supply Co.", "Nordlicht GmbH", "Ama Mensah", "Lucía Ortega", "Kestrel Outdoor", "Wei Zhang",
                     "שרת לקוחות ראשי", "🐬 Dolphin Diving Club", String(repeating: "Very long customer name ", count: 10)]
        for row in 0..<rows {
            let name = names[row % names.count]
            let email: [UInt8]? = row % 6 == 5 ? nil : Array("customer\(row)@mail.example".utf8)
            store.append([Array("\(10_482 - row * 7)".utf8), Array(name.utf8), email, Array("\(318 - row)".utf8),
                          Array(String(format: "%.2f", 184_220.5 - Double(row) * 331.25).utf8)])
        }
        return store
    }

    /// The console with the query, a result tab and Messages.
    static func dress(_ console: ConsoleViewController) {
        console.editor.setText(query)
        console.addResult(customers(), title: "Top customers by paid orders, last 90 days", summary: "38 ms · 200 rows")
        console.messagesView.append(ConsoleMessage(level: .ok, range: NSRange(location: 47, length: 300), line: 2,
                                                   statement: "SELECT c.id, c.`name`, c.email, COUNT(o.id) AS orders, SUM(o.total) AS spent",
                                                   text: "200 rows · 38 ms"))
        console.messagesView.append(ConsoleMessage(level: .warning, range: nil, line: 2, statement: "SELECT c.id, c.`name`",
                                                   text: "Warning 1292: Truncated incorrect DOUBLE value: 'n/a'"))
        console.messagesView.append(ConsoleMessage(level: .error, range: nil, line: 9, statement: "SELECT p.sku, SUM(r.amount) FROM refunds r",
                                                   text: "The table doesn't exist. Error 1146 (42S02): Table 'shop.refunds' doesn't exist"))
        console.showResults()
    }
}
