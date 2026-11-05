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
        let tableMenu = ["Open Data", "Open Structure", "Select Top 1000 Rows", "Copy Name", "Copy Name Without Quotes", "Copy CREATE", "Add to Favourites", "Find Where Used…",
                         "New Column…", "New Index…", "New Foreign Key…", "Edit Comment…", "Generate SELECT",
                         "Generate INSERT", "Generate UPDATE", "Export…", "Copy Table…", "Bulk Table Editor…", "Compare With…", "Compare", "Maintenance", "Truncate…", "Rename…", "Drop…", "Disk Usage", "Modify Grants…", "Refresh"]
        let treeOnly: Set<String> = ["Add to Favourites", "Find Where Used…", "New Column…", "New Index…", "New Foreign Key…", "Edit Comment…"]
        let viewMenu = tableMenu.filter { !treeOnly.contains($0) && !$0.hasPrefix("Compare") && $0 != "Modify Grants…" }
        let tableCommands: Set<String> = ["Open Data", "Open Structure", "Copy Name", "Add to Favourites", "Find Where Used…", "New Column…", "New Index…",
                                          "New Foreign Key…", "Edit Comment…", "Generate SELECT", "Generate INSERT",
                                          "Generate UPDATE", "Copy Table…", "Bulk Table Editor…", "Compare With…", "Maintenance", "Truncate…",
                                          "Rename…", "Drop…", "Refresh"]
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
                    menu: ["New Query", "New Database…", "Create Table…", "Copy Name", "Copy Name Without Quotes", "Export…", "Restore…", "Generate Liquibase Changelog…",
                           "Compare With…", "Compare", "Disk Usage", "Modify Grants…", "Edit Database…", "Refresh", "Drop…"],
                    enabled: ["New Query", "New Database…", "Create Table…", "Export…", "Restore…", "Compare With…", "Refresh", "Drop…"]),
            Surface(name: "Table or view in the tree",
                    place: { main, _ in treeRow(main, .object(id, orders))?.point },
                    clicked: { $0.selectedTab?.title == "orders" && preview($0) != nil },
                    doubleClicked: { main, _ in main.tabs.filter { $0.title == "orders" }.count == 1 && main.selectedTab?.content is TableDataController },
                    menu: tableMenu, enabled: tableCommands),
            Surface(name: "Routine, trigger or event",
                    place: { main, _ in treeRow(main, .object(id, procedure))?.point },
                    clicked: { preview($0) is TextContent && $0.selectedTab?.title == "add_customer" },
                    doubleClicked: { main, _ in main.selectedTab?.content is ObjectEditorController },
                    menu: ["Open", "Run…", "Copy CREATE", "Add to Favourites", "Find Where Used…", "Edit Comment…", "Compare With…", "Compare", "Modify Grants…", "Drop…", "Refresh"],
                    enabled: ["Open", "Run…", "Copy CREATE", "Add to Favourites", "Find Where Used…", "Edit Comment…", "Compare With…", "Drop…", "Refresh"]),
            Surface(name: "Folder or category in the tree",
                    place: { main, _ in treeRow(main, views)?.point },
                    clicked: { $0.sidebar.selectedNodes.map(\.kind) == [views] },
                    doubleClicked: { main, _ in expanded(main, views) },
                    menu: ["New…", "Refresh", "Expand All", "Collapse All"],
                    enabled: ["New…", "Refresh", "Expand All", "Collapse All"]),
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
                    menu: viewMenu, enabled: tableCommands.subtracting(treeOnly).subtracting(["Compare With…"])),
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
