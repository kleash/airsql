import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

// Light and dark pictures of the navigator's screens (AIRSQL_SCREENSHOTS=1, into build/screenshots), with the schema
// replayed from a recording.
extension AppTests.ScreenshotTests {
    /// What a MariaDB server offers, for the dialogs.
    static let choices: ServerChoices = {
        var choices = ServerChoices()
        choices.charsets = ["latin1", "utf8mb3", "utf8mb4"]
        choices.collations = ["latin1": ["latin1_bin", "latin1_swedish_ci"], "utf8mb3": ["utf8mb3_general_ci"],
                              "utf8mb4": ["utf8mb4_bin", "utf8mb4_general_ci", "utf8mb4_unicode_ci", "utf8mb4_uca1400_ai_ci"]]
        choices.defaultCollation = ["latin1": "latin1_swedish_ci", "utf8mb3": "utf8mb3_general_ci", "utf8mb4": "utf8mb4_general_ci"]
        choices.serverCharset = "utf8mb4"
        choices.serverCollation = "utf8mb4_unicode_ci"
        choices.engines = ["Aria", "InnoDB", "MEMORY", "MyISAM"]
        return choices
    }()

    @Test func navigatorScreens() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let model = testModel(Fixtures.shop)
            let (main, harness) = appWindow(model)
            main.window?.appearance = NSAppearance(named: appearance)
            model.states[Fixtures.production.id] = .connected(server: "MariaDB 11.8.9")
            let id = Fixtures.production.id
            let open = await openReplayed(model, id)
            open.currentDatabase = "airsql_fixture"
            onScreen(main.window)

            // The tree and the database view.
            let database = try #require(treeRow(main, .database(id, "airsql_fixture")))
            _ = treeRow(main, .object(id, DatabaseObject(.table, "airsql_fixture", "orders")))
            _ = await call(harness, "click", ["x": database.point.0, "y": database.point.1])
            _ = await eventually(timeout: 10) { open.snapshot.database("airsql_fixture")?.statistics != nil && open.loading.isEmpty }
            ((main.selectedTab?.content as? PreviewContent)?.shown as? DatabaseViewController)?.reload()
            try await save(harness, "navigator-\(suffix)")

            // The dialogs and the SQL shown before a drop.
            let orders = DatabaseObject(.table, "airsql_fixture", "orders")
            let window = try #require(main.window)
            for (name, show) in [
                ("new-database", { NavigatorActions.newDatabase(Self.choices, on: open, window: window) }),
                ("copy-table", { NavigatorActions.copyTable(orders, on: open, window: window) }),
                ("bulk-edit", { NavigatorActions.bulkEdit([orders, DatabaseObject(.table, "airsql_fixture", "customers")],
                                                          Self.choices, on: open, window: window) }),
                ("drop-table", { NavigatorActions.drop([orders], on: open, window: window) }),
            ] as [(String, () -> Void)] {
                show()
                _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
                try await save(harness, "\(name)-\(suffix)")
                _ = await call(harness, "press", ["title": "Cancel", "in": "sheet"])
                _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            }

            // The process list and Find Text.
            let list = ProcessListContent(open)
            main.open(list, title: "Processes", connection: id)
            list.show([
                ServerProcess(id: 8, user: "event_scheduler", host: "localhost", database: nil, command: "Daemon", time: 9_120,
                              state: "Waiting on empty queue", info: nil, queryID: 0),
                ServerProcess(id: 41, user: "app", host: "10.0.4.17:51244", database: "shop", command: "Query", time: 12,
                              state: "Sending data", info: "SELECT c.id, SUM(o.total) FROM customers c JOIN orders o ON o.customer_id "
                                + "= c.id GROUP BY c.id", queryID: 90211),
                ServerProcess(id: 42, user: "app", host: "10.0.4.17:51250", database: "shop", command: "Sleep", time: 3, state: nil,
                              info: nil, queryID: 0),
                ServerProcess(id: 57, user: "reports", host: "10.0.9.2:40112", database: "analytics", command: "Query", time: 1,
                              state: "Creating sort index", info: "SELECT day, COUNT(*) FROM visits GROUP BY day ORDER BY day",
                              queryID: 90240),
            ])
            _ = await eventually(timeout: 10) { !list.isRefreshing }  // the demo has no server: its own refresh fails
            list.show(list.processes)
            try await save(harness, "processes-\(suffix)")
            main.open(FindTextContent(open, database: "airsql_fixture"), title: "Find Text", connection: id)
            try await save(harness, "find-text-\(suffix)")
            main.window?.orderOut(nil)
        }
    }
}
