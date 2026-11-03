import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

// The navigator's rows of the interaction contract (plan §2.12), on Production with its schema replayed (the window of
// `InteractionTests.window()`).
extension AppTests.InteractionTests {
    static let navigatorSurfaces: [Surface] = {
        let id = Fixtures.production.id
        let orders = DatabaseObject(.table, "airsql_fixture", "orders")
        let procedure = DatabaseObject(.procedure, "airsql_fixture", "add_customer")
        let views = SidebarNode.Kind.category(id, "airsql_fixture", .view)
        let tableMenu = ["Open Data", "Open Structure", "Copy Name", "Generate SELECT", "Generate INSERT", "Generate UPDATE",
                         "Export…", "Copy Table…", "Bulk Table Editor…", "Maintenance", "Truncate…", "Rename…", "Drop…", "Refresh"]
        let tableCommands: Set<String> = ["Open Data", "Open Structure", "Copy Name", "Copy Table…", "Bulk Table Editor…",
                                          "Maintenance", "Truncate…", "Rename…", "Drop…", "Refresh"]
        @MainActor func preview(_ main: MainWindowController) -> NSViewController? {
            (main.selectedTab?.content as? PreviewContent)?.shown
        }
        @MainActor func expanded(_ main: MainWindowController, _ kind: SidebarNode.Kind) -> Bool {
            main.sidebar.outline.isItemExpanded(main.sidebar.treeNodes[kind])
        }
        return [
            Surface(name: "Database in the tree",
                    place: { main, _ in treeRow(main, .database(id, "airsql_fixture"))?.point },
                    clicked: { (preview($0) as? DatabaseViewController)?.database == "airsql_fixture" },
                    doubleClicked: { main, _ in
                        main.model.openConnection(id)?.currentDatabase == "airsql_fixture" && expanded(main, .database(id, "airsql_fixture"))
                    },
                    menu: ["New Query", "New Database…", "Create Table…", "Export…", "Restore…", "Generate Liquibase Changelog…",
                           "Compare…", "Refresh", "Drop…"],
                    enabled: ["New Database…", "Refresh", "Drop…"]),
            Surface(name: "Table or view in the tree",
                    place: { main, _ in treeRow(main, .object(id, orders))?.point },
                    clicked: { $0.selectedTab?.title == "orders" && preview($0) != nil },
                    doubleClicked: { main, _ in main.tabs.filter { $0.title == "orders" }.count == 2 },
                    menu: tableMenu, enabled: tableCommands),
            Surface(name: "Routine, trigger or event",
                    place: { main, _ in treeRow(main, .object(id, procedure))?.point },
                    clicked: { preview($0) is TextContent && $0.selectedTab?.title == "add_customer" },
                    doubleClicked: { main, _ in main.tabs.filter { $0.title == "add_customer" }.count == 2 },
                    menu: ["Open", "Run…", "Copy CREATE", "Drop…", "Refresh"],
                    enabled: ["Open", "Copy CREATE", "Drop…", "Refresh"]),
            Surface(name: "Folder or category in the tree",
                    place: { main, _ in treeRow(main, views)?.point },
                    clicked: { $0.sidebar.selectedNodes.map(\.kind) == [views] },
                    doubleClicked: { main, _ in expanded(main, views) },
                    menu: ["New…", "Refresh", "Expand All", "Collapse All"],
                    enabled: ["Refresh", "Expand All", "Collapse All"]),
            Surface(name: "Table in the database view",
                    place: { main, _ in
                        guard let open = main.model.openConnection(id) else { return nil }
                        let view = DatabaseViewController(open, "airsql_fixture")
                        main.open(view, title: "airsql_fixture", connection: id)
                        main.window?.layoutIfNeeded()
                        guard let row = view.rows.firstIndex(where: { $0.name == "orders" }) else { return nil }
                        return windowPoint(view.table.rect(ofRow: row), in: view.table)
                    },
                    clicked: { ($0.selectedTab?.content as? DatabaseViewController)?.selectedObjects == [orders] },
                    doubleClicked: { main, _ in
                        // Opened in a tab of its own; back to the database view for the right-click.
                        let opened = main.selectedTab?.title == "orders"
                        if let tab = main.tabs.first(where: { $0.content is DatabaseViewController }) { main.select(tab) }
                        return opened
                    },
                    menu: tableMenu, enabled: tableCommands),
            Surface(name: "Process list row",
                    place: { main, _ in
                        guard let open = main.model.openConnection(id) else { return nil }
                        let list = ProcessListContent(open)
                        main.open(list, title: "Processes", connection: id)
                        main.window?.layoutIfNeeded()
                        list.show([ServerProcess(id: 42, user: "app", host: "10.0.0.5:50500", database: "shop", command: "Query",
                                                 time: 3, state: "Sending data", info: "SELECT * FROM orders", queryID: 7)])
                        return windowPoint(list.table.rect(ofRow: 0), in: list.table)
                    },
                    clicked: { ($0.selectedTab?.content as? ProcessListContent)?.selected.map(\.id) == [42] },
                    doubleClicked: { main, _ in
                        // The full query, in a sheet.
                        guard let sheet = main.window?.attachedSheet else { return false }
                        main.window?.endSheet(sheet)
                        return true
                    },
                    menu: ["Kill Query…", "Kill Connection…", "Copy Query", "Explain"],
                    enabled: ["Kill Query…", "Kill Connection…", "Copy Query", "Explain"]),
        ]
    }()
}
