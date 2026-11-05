import AppKit
import CMariaDB
import Testing
@testable import AirSQL
@testable import AirSQLCore

// The interaction contract (plan §2.12): on every surface a click selects or shows, a double-click opens or acts, and a
// right-click opens the item's menu, whose items are enabled or say why not, and are all in the menu bar too. One row
// per surface; each lane adds the rows of its surfaces (and moves its commands into `enabled` as it implements them).

/// A surface of the contract and what each click must do there.
@MainActor
struct Surface {
    let name: String
    /// Sets the window up and gives the point to click (from the window's top left).
    let place: (MainWindowController, AgentServer) async -> (Double, Double)?
    /// After a click.
    let clicked: (MainWindowController) -> Bool
    /// After a double-click (the commands that reached the end of the responder chain are given).
    let doubleClicked: (MainWindowController, [String]) -> Bool
    /// The right-click menu's titles, in order, and those that must be enabled now (the others may be off, with a
    /// reason, until their lane implements them).
    let menu: [String]
    let enabled: Set<String>
}

/// A point of `rect` (in `view`'s coordinates) from the window's top left.
@MainActor
func windowPoint(_ rect: NSRect, in view: NSView) -> (Double, Double) {
    let inWindow = view.convert(rect, to: nil)
    let height = view.window?.frame.height ?? 0
    return (Double(inWindow.midX), Double(height - inWindow.midY))
}

/// The middle of a sidebar row showing `name`.
@MainActor
func sidebarRow(_ main: MainWindowController, _ name: String) -> (Double, Double)? {
    guard let id = main.model.data.connections.first(where: { $0.displayName == name })?.id else { return nil }
    let outline = main.sidebar.outline
    for row in 0..<outline.numberOfRows where (outline.item(atRow: row) as? SidebarNode)?.connectionID == id {
        return windowPoint(outline.rect(ofRow: row), in: outline)
    }
    return nil
}

/// The middle of the sidebar row of the folder named `name`.
@MainActor
func folderRow(_ main: MainWindowController, _ name: String) -> (Double, Double)? {
    guard let id = main.model.data.folders.first(where: { $0.name == name })?.id else { return nil }
    let outline = main.sidebar.outline
    for row in 0..<outline.numberOfRows where (outline.item(atRow: row) as? SidebarNode)?.kind == .folder(id) {
        return windowPoint(outline.rect(ofRow: row), in: outline)
    }
    return nil
}

/// The tab button showing `title`.
@MainActor
func tabButton(_ main: MainWindowController, _ title: String) -> TabButton {
    main.tabBar.buttons[main.tabs.firstIndex { $0.title == title } ?? 0]
}

/// The viewer of a console result showing a few customers (opened the first time).
@MainActor
func resultViewer(_ main: MainWindowController) -> GridViewer? {
    if let console = main.selectedTab?.content as? ConsoleViewController, let view = console.resultTabs.first?.view as? ResultGridView {
        return view.viewer
    }
    let console = ConsoleViewController(model: main.model, connection: Fixtures.production.id)
    main.open(console, title: "Query 1", connection: Fixtures.production.id)
    console.addResult(ConsoleFixtures.customers(rows: 5), title: "Top customers", summary: "38 ms · 5 rows")
    console.showResults()
    main.window?.layoutIfNeeded()
    return (console.resultTabs.first?.view as? ResultGridView)?.viewer
}

@MainActor
func resultGrid(_ main: MainWindowController) -> DataGridView { resultViewer(main)!.grid }

/// Whether the console shown has put the keyboard in its editor, as it does once it has appeared (a turn of the run
/// loop after it opens): a test's own focus set after that stays.
@MainActor
func consoleTookTheFocus(_ main: MainWindowController) async -> Bool {
    guard let console = main.selectedTab?.content as? ConsoleViewController else { return false }
    return await eventually(timeout: 10) { main.window?.firstResponder === console.editor }
}

@MainActor
func statusItem(_ item: StatusItemView) -> (Double, Double)? {
    item.isHidden ? nil : windowPoint(item.bounds, in: item)
}

extension AppTests {
    @MainActor @Suite struct InteractionTests {
        static let surfaces: [Surface] = [
            // Production is connected: a double-click shows it (its tab) rather than connecting again.
            Surface(name: "Connection in the sidebar",
                    place: { main, _ in sidebarRow(main, "Production · shop") },
                    clicked: { $0.sidebar.selectedConnectionIDs == [Fixtures.production.id]
                        && $0.selectedTab?.connectionID == Fixtures.production.id },
                    doubleClicked: { main, _ in
                        main.window?.attachedSheet == nil && main.selectedTab?.connectionID == Fixtures.production.id
                            && main.model.states[Fixtures.production.id] == .connected(server: "MariaDB 11.8.3")
                    },
                    menu: ["Connect", "Disconnect", "Edit…", "Duplicate", "New Query", "Open in Terminal", "Export…", "Restore…",
                           "Compare With…", "Compare", "Disk Usage", "Users and Roles", "Colour", "Move to Folder", "Delete…"],
                    enabled: ["Connect", "Disconnect", "Edit…", "Duplicate", "Open in Terminal", "Export…", "Restore…", "Colour",
                              "Delete…"]),
            Surface(name: "Folder in the sidebar",
                    place: { main, _ in folderRow(main, "Clients") },
                    clicked: { $0.sidebar.selectedFolderNodeID == InteractionTests.folder.id },
                    doubleClicked: { main, _ in
                        main.sidebar.outline.isItemExpanded(main.sidebar.selectedNodes.first) == false
                    },
                    menu: ["New Connection…", "New Folder…", "Rename Folder…", "Delete Folder…"],
                    enabled: ["New Connection…", "New Folder…", "Rename Folder…", "Delete Folder…"]),
            Surface(name: "Editor tab",
                    place: { main, _ in
                        main.open(FixtureContent(), title: "Query 1", connection: Fixtures.production.id)
                        main.open(FixtureContent(), title: "Query 2", connection: Fixtures.staging.id)
                        main.tabBar.layoutSubtreeIfNeeded()
                        let button = tabButton(main, "Query 1")
                        return windowPoint(button.bounds, in: button)
                    },
                    clicked: { $0.selectedTab?.title == "Query 1" && $0.contentKind == "tab" },
                    doubleClicked: { main, _ in tabButton(main, "Query 1").renameField != nil },
                    menu: ["Close Tab", "Close Other Tabs", "Close All Tabs", "Duplicate Tab", "Rename Tab…", "Reveal in Finder",
                           "Change Connection…"],
                    enabled: ["Close Tab", "Close Other Tabs", "Close All Tabs", "Duplicate Tab", "Rename Tab…"]),
            Surface(name: "Result tab",
                    place: { main, _ in
                        let console = ConsoleViewController(model: main.model, connection: Fixtures.production.id)
                        main.open(console, title: "Query 1", connection: Fixtures.production.id)
                        try? await Task.sleep(nanoseconds: 100_000_000)  // shown: the editor and results take their share
                        console.addResult(ConsoleFixtures.customers(rows: 3), title: "Top customers", summary: "38 ms · 3 rows")
                        console.selectResult(console.messagesTab)
                        main.window?.layoutIfNeeded()
                        guard let button = console.results.tabButton(for: console.resultTabs[0]) else { return nil }
                        return windowPoint(button.bounds, in: button)
                    },
                    clicked: { main in
                        let console = main.selectedTab?.content as? ConsoleViewController
                        return console.map { $0.selectedResult === $0.resultTabs.first } ?? false
                    },
                    doubleClicked: { main, _ in
                        guard let console = main.selectedTab?.content as? ConsoleViewController else { return false }
                        return console.results.tabButton(for: console.resultTabs[0])?.renameField != nil
                    },
                    menu: ["Run Result Again", "Copy Result's Query", "Open Result in Window", "Pin Result", "Rename Result…", "Close Result", "Close Other Results", "Export Result…", "Compare With…"],
                    enabled: ["Pin Result", "Rename Result…", "Close Result", "Export Result…"]),
            // region: a plain text cell (a foreign key's double-click opens its drop-down, an ENUM's its list).
            Surface(name: "Table rows: cell",
                    place: { main, _ in
                        guard let tab = try? await GridDataAppTests.open(in: main, connection: Fixtures.local) else { return nil }
                        return windowPoint(tab.grid.cellRect(GridPosition(row: 1, column: 2)), in: tab.grid)
                    },
                    clicked: { main in
                        (main.selectedTab?.content as? TableDataController)?.grid.selection.cursor == GridPosition(row: 1, column: 2)
                    },
                    doubleClicked: { main, _ in (main.selectedTab?.content as? TableDataController)?.grid.editor != nil },
                    menu: ["Copy", "Copy with Headers", "Copy As", "Cut", "Paste", "Quick Filter", "Clear Filter", "Set NULL", "Set DEFAULT", "Insert Value",
                           "Related Rows", "Add Row", "Duplicate Row", "Duplicate Row Without Keys", "Delete Rows", "Revert", "Preview SQL…", "Apply Changes", "Export Rows…",
                           "Value Panel", "Record View", "Transpose", "Column Summary…", "Chart", "Open URL", "Compare Cells", "Display As"],
                    enabled: ["Copy", "Copy with Headers", "Copy As", "Cut", "Quick Filter", "Set DEFAULT", "Insert Value", "Related Rows", "Add Row",
                              "Duplicate Row", "Duplicate Row Without Keys", "Delete Rows", "Export Rows…", "Value Panel", "Record View", "Transpose", "Column Summary…", "Chart"]),
            // Near a header's left (its sort control is at the right): a double-click sorts by the column.
            Surface(name: "Table rows: column header",
                    place: { main, _ in
                        guard let tab = try? await GridDataAppTests.open(in: main, connection: Fixtures.local) else { return nil }
                        tab.grid.columnWidths[tab.grid.columnOrder[2]] = 400
                        main.window?.layoutIfNeeded()
                        guard let header = tab.grid.header else { return nil }
                        let left = header.edges(2).left
                        return windowPoint(NSRect(x: left + 10, y: 0, width: 20, height: header.bounds.height), in: header)
                    },
                    clicked: { main in
                        (main.selectedTab?.content as? TableDataController)?.grid.selection.containsColumn(2) == true
                    },
                    doubleClicked: { main, _ in
                        (main.selectedTab?.content as? TableDataController)?.source?.sort.isEmpty == false
                    },
                    // region: not a key (Use as Label) nor a foreign key (Add Virtual Foreign Key…).
                    menu: ["Copy Column Name", "Sort Ascending", "Sort Descending", "Add to Sort", "Sort by Columns…", "Clear Sort", "Filter by Values…",
                           "Clear Filter", "Use as Label", "Add Virtual Foreign Key…", "Remove Virtual Foreign Key", "Column Summary…",
                           "Hide Column", "Hide Other Columns", "Freeze", "Column List…", "Heatmap", "Chart", "Display As"],
                    enabled: ["Copy Column Name", "Sort Ascending", "Sort Descending", "Sort by Columns…", "Filter by Values…",
                              "Use as Label", "Add Virtual Foreign Key…", "Column Summary…", "Hide Column", "Hide Other Columns", "Freeze", "Column List…", "Chart"]),
            Surface(name: "Grid cell",
                    place: { main, _ in
                        let grid = resultGrid(main)
                        try? await Task.sleep(nanoseconds: 100_000_000)  // shown: the editor and results take their share
                        main.window?.layoutIfNeeded()
                        return windowPoint(grid.cellRect(GridPosition(row: 1, column: 1)), in: grid)
                    },
                    clicked: { main in resultGrid(main).selection.cursor == GridPosition(row: 1, column: 1) },
                    doubleClicked: { main, _ in resultViewer(main)?.valuePanel != nil },
                    menu: ["Copy", "Copy with Headers", "Copy As", "Quick Filter", "Clear Filter", "Export Rows…", "Value Panel",
                           "Record View", "Transpose", "Column Summary…", "Chart", "Open URL", "Compare Cells", "Display As"],
                    enabled: ["Copy", "Copy with Headers", "Copy As", "Quick Filter", "Export Rows…", "Value Panel", "Record View",
                              "Transpose", "Column Summary…", "Chart"]),
            // A console result of one table with its key: a double-click edits the cell.
            Surface(name: "Editable result cell",
                    place: { main, _ in
                        let console = ConsoleViewController(model: main.model, connection: Fixtures.production.id)
                        main.open(console, title: "Query 1", connection: Fixtures.production.id)
                        try? await Task.sleep(nanoseconds: 100_000_000)  // shown: the editor and results take their share
                        let c = { AppTests.GridEditResultAppTests.column("customers", "customers", $0, $1) }
                        let store = ResultStore(columns: [c("id", MYSQL_TYPE_LONG), c("email", MYSQL_TYPE_VAR_STRING)])
                        for row in [["7", "ann@example.com"], ["9", "cy@example.org"]] { store.append(row.map { Array($0.utf8) }) }
                        let view = ResultGridView(store: store, nullText: "NULL", fontSize: 12, editable: true)
                        view.editingContext = try? await recordedEditorContext(Fixtures.production)
                        view.model = main.model
                        view.openSession = { FakeTableSession() }
                        console.addResult(store, title: "Customers", summary: "1 ms · 2 rows")
                        console.resultTabs.last?.makeView = { view }
                        console.showResults()
                        view.prepareEditing(sql: "SELECT id, email FROM customers", database: "airsql_fixture", noBackslashEscapes: false)
                        await ready { view.edits?.editing == nil }
                        main.window?.layoutIfNeeded()
                        return windowPoint(view.grid.cellRect(GridPosition(row: 1, column: 1)), in: view.grid)
                    },
                    clicked: { main in resultGrid(main).selection.cursor == GridPosition(row: 1, column: 1) },
                    doubleClicked: { main, _ in resultGrid(main).editor != nil },
                    menu: ["Copy", "Copy with Headers", "Copy As", "Quick Filter", "Clear Filter", "Cut", "Paste", "Set NULL", "Set DEFAULT", "Insert Value", "Delete Rows", "Revert",
                           "Preview SQL…", "Apply Changes", "Export Rows…", "Value Panel", "Record View", "Transpose", "Column Summary…", "Chart", "Open URL", "Compare Cells", "Display As"],
                    // email is NOT NULL: Set NULL is off, saying so.
                    enabled: ["Copy", "Copy with Headers", "Copy As", "Quick Filter", "Cut", "Set DEFAULT", "Insert Value", "Delete Rows", "Export Rows…", "Value Panel",
                              "Record View", "Column Summary…", "Chart"]),
            // A console result's header: its rows sort and filter here.
            Surface(name: "Grid column header",
                    place: { main, _ in
                        let grid = resultGrid(main)
                        try? await Task.sleep(nanoseconds: 100_000_000)  // shown: the editor and results take their share
                        grid.columnWidths[grid.columnOrder[1]] = 300
                        main.window?.layoutIfNeeded()
                        guard let header = grid.header else { return nil }
                        let left = header.edges(1).left
                        return windowPoint(NSRect(x: left + 10, y: 0, width: 20, height: header.bounds.height), in: header)
                    },
                    clicked: { main in resultGrid(main).selection.containsColumn(1) },
                    doubleClicked: { main, _ in !resultGrid(main).sortOrder.isEmpty },
                    menu: ["Copy Column Name", "Sort Ascending", "Sort Descending", "Add to Sort", "Sort by Columns…", "Clear Sort", "Filter by Values…",
                           "Clear Filter", "Column Summary…", "Hide Column", "Hide Other Columns", "Freeze", "Column List…", "Heatmap", "Chart", "Display As"],
                    enabled: ["Copy Column Name", "Sort Ascending", "Sort Descending", "Sort by Columns…", "Filter by Values…",
                              "Column Summary…", "Hide Column", "Hide Other Columns", "Freeze", "Column List…", "Chart"]),
            Surface(name: "Grid row number",
                    place: { main, _ in
                        let grid = resultGrid(main)
                        try? await Task.sleep(nanoseconds: 100_000_000)  // shown: the editor and results take their share
                        main.window?.layoutIfNeeded()
                        return windowPoint(NSRect(x: 0, y: grid.rowRect(1).minY, width: grid.rowNumbers.bounds.width, height: grid.rowHeight),
                                           in: grid.rowNumbers)
                    },
                    clicked: { main in resultGrid(main).selection.containsRow(1) },
                    doubleClicked: { main, _ in resultViewer(main)?.record == 1 },
                    // In Record View now (the double-click), so without Display As.
                    menu: ["Copy", "Copy with Headers", "Copy As", "Export Rows…", "Record View", "Transpose", "Value Panel"],
                    enabled: ["Copy", "Copy with Headers", "Copy As", "Export Rows…", "Record View", "Transpose", "Value Panel"]),
            // View As ▸ Tree: the result's first row, an object (so Copy, of a value, is off).
            Surface(name: "JSON tree",
                    place: { main, _ in
                        guard let viewer = resultViewer(main) else { return nil }
                        viewer.present(.tree)
                        try? await Task.sleep(nanoseconds: 100_000_000)  // shown: the editor and results take their share
                        main.window?.layoutIfNeeded()
                        guard let tree = find(JSONTreeView.self, in: viewer) else { return nil }
                        return windowPoint(tree.outline.rect(ofRow: 1), in: tree.outline)
                    },
                    clicked: { main in resultViewer(main).flatMap { find(JSONTreeView.self, in: $0) }?.outline.selectedRow == 1 },
                    doubleClicked: { main, _ in
                        guard let outline = resultViewer(main).flatMap({ find(JSONTreeView.self, in: $0) })?.outline else { return false }
                        return outline.isItemExpanded(outline.item(atRow: 1))
                    },
                    menu: ["Copy", "Expand All", "Collapse All"], enabled: ["Expand All", "Collapse All"]),
            Surface(name: "Status bar: route",
                    place: { main, _ in statusItem(main.statusBar.route) },
                    clicked: { $0.statusBar.route.shown?.isShown == true },
                    doubleClicked: { main, _ in main.statusBar.route.shown?.isShown == true },
                    menu: ["Copy"], enabled: ["Copy"]),
            Surface(name: "Status bar: server",
                    place: { main, _ in statusItem(main.statusBar.server) },
                    clicked: { $0.statusBar.server.shown?.isShown == true },
                    doubleClicked: { main, _ in main.statusBar.server.shown?.isShown == true },
                    menu: ["Copy"], enabled: ["Copy"]),
            Surface(name: "Status bar: transaction",
                    place: { main, _ in statusItem(main.statusBar.transaction) },
                    clicked: { $0.statusBar.transaction.shown?.isShown == true },
                    doubleClicked: { main, _ in main.statusBar.transaction.shown?.isShown == true },
                    menu: ["Copy", "Commit", "Roll Back"], enabled: ["Copy"]),
            Surface(name: "Status bar: activity",
                    place: { main, _ in statusItem(main.statusBar.activity) },
                    clicked: { $0.statusBar.activity.shown?.isShown == true },
                    doubleClicked: { main, _ in main.statusBar.activity.shown?.isShown == true },
                    menu: ["Copy", "Cancel All Work"], enabled: ["Copy", "Cancel All Work"]),
            Surface(name: "Status bar: agents",
                    place: { main, _ in statusItem(main.statusBar.agent) },
                    clicked: { $0.statusBar.agent.shown?.isShown == true },
                    doubleClicked: { main, _ in main.statusBar.agent.shown?.isShown == true },
                    menu: ["Copy", "Agent Activity", "Turn Agents Off"], enabled: ["Copy", "Turn Agents Off"]),
            Surface(name: "Status bar: SQL log",
                    place: { main, _ in windowPoint(main.statusBar.sqlLog.bounds, in: main.statusBar.sqlLog) },
                    clicked: { _ in true },
                    doubleClicked: { _, received in received.contains("showSQLLog(_:)") },
                    menu: ["SQL Log", "Clear SQL Log"], enabled: ["SQL Log"]),
            Surface(name: "Status bar: grid",
                    place: { main, _ in
                        guard let viewer = resultViewer(main) else { return nil }
                        viewer.grid.selection.select(GridPosition(row: 1, column: 1))
                        viewer.status.update()
                        main.refresh()
                        main.window?.layoutIfNeeded()
                        let position = viewer.status.position
                        return position.isHiddenOrHasHiddenAncestor ? nil : windowPoint(position.bounds, in: position)
                    },
                    clicked: { _ in true },
                    doubleClicked: { _, _ in true },
                    menu: ["Copy"], enabled: ["Copy"]),
            Surface(name: "Agent tab statement",
                    place: { main, _ in
                        main.model.data.settings.agentsAllowed = false  // this row's service opens no socket
                        let service = AgentService(model: main.model, main: main, directory: FileManager.default.temporaryDirectory)
                        let call = service.record("claude-code 2", "run_queries · SELECT 1")
                        service.keep(["results": [["sql": "SELECT 1", "ok": true, "columns": ["1"], "rowCount": 1, "capped": false]]],
                                     [:], call: call, client: "claude-code 2", connection: Fixtures.production.id)
                        service.showResults(Fixtures.production.id)
                        main.window?.layoutIfNeeded()
                        guard let tab = main.selectedTab?.content as? AgentResultsContent else { return nil }
                        return windowPoint(tab.table.rect(ofRow: 0), in: tab.table)
                    },
                    clicked: { ($0.selectedTab?.content as? AgentResultsContent)?.table.selectedRowIndexes == [0] },
                    doubleClicked: { main, _ in
                        // The statement in a new console; back to the Agent tab for the right-click.
                        let opened = (main.selectedTab?.content as? ConsoleViewController)?.agentText == "SELECT 1;"
                        if let tab = main.tabs.first(where: { $0.content is AgentResultsContent }) { main.select(tab) }
                        return opened
                    },
                    menu: ["Open in New Query", "Copy"], enabled: ["Open in New Query", "Copy"]),
        ] + navigatorSurfaces

        /// A window in the state every row starts from: the shop's connections, Production connected, a transaction
        /// open in its tab, an agent at work and an export running.
        /// The folder the local connection sits in.
        static let folder = ConnectionFolder(name: "Clients")

        static func window() async -> (MainWindowController, AgentServer, CommandRecorder, Activity) {
            var local = Fixtures.local
            local.folderID = folder.id
            let model = testModel([Fixtures.production, Fixtures.staging, local, Fixtures.replica], folders: [folder])
            model.data.settings.agentsAllowed = true
            let (main, harness) = appWindow(model)
            let recorder = CommandRecorder()
            recorder.nextResponder = main.nextResponder
            main.nextResponder = recorder
            model.states[Fixtures.production.id] = .connected(server: "MariaDB 11.8.3")
            await openReplayed(model, Fixtures.production.id)
            let content = FixtureContent()
            content.badge = "Transaction open · 2 changes"
            main.open(content, title: "Top customers.sql", connection: Fixtures.production.id)
            model.agentStatus = "Claude Code · reading schema"
            let work = model.activity.start("Exporting shop", connection: Fixtures.production.id) {}
            main.refresh()
            return (main, harness, recorder, work)
        }

        /// The rows' names, for the test's arguments (`surfaces` holds their checks).
        nonisolated static let rows = ["Connection in the sidebar", "Folder in the sidebar", "Editor tab", "Result tab", "Table rows: cell",
                                       "Table rows: column header", "Grid cell", "Editable result cell", "Grid column header", "Grid row number",
                                       "JSON tree", "Status bar: route",
                                       "Status bar: server", "Status bar: transaction",
                                       "Status bar: activity", "Status bar: agents", "Status bar: SQL log", "Status bar: grid",
                                       "Agent tab statement",
                                       "Database in the tree",
                                       "Table or view in the tree", "Routine, trigger or event", "Folder or category in the tree",
                                       "Table in the database view", "Process list row"]

        @Test func everyRowHasItsChecks() {
            #expect(Self.surfaces.map(\.name) == Self.rows)
        }

        @Test(arguments: InteractionTests.rows)
        func surfaceAnswersEveryClick(_ row: String) async throws {
            let surface = try #require(Self.surfaces.first { $0.name == row })
            let (main, harness, recorder, work) = await Self.window()
            defer { work.end() }
            let window = try #require(main.window)
            window.layoutIfNeeded()
            let point = try #require(await surface.place(main, harness), "\(surface.name): not shown")
            closePopovers(main)

            let click = await call(harness, "click", ["x": point.0, "y": point.1])
            #expect(click.error == nil, "\(surface.name): \(click.error ?? "")")
            #expect(surface.clicked(main), "\(surface.name): a click doesn't select or show")
            closePopovers(main)

            let double = await call(harness, "click", ["x": point.0, "y": point.1, "count": 2])
            #expect(double.error == nil, "\(surface.name): \(double.error ?? "")")
            #expect(surface.doubleClicked(main, recorder.received), "\(surface.name): a double-click doesn't act (\(recorder.received))")
            main.window?.makeFirstResponder(nil)  // ends a rename in place
            closePopovers(main)

            let right = await call(harness, "click", ["x": point.0, "y": point.1, "button": "right"])
            #expect(right.error == nil, "\(surface.name): \(right.error ?? "")")
            let items = right["menu"] as? [[String: Any]] ?? []
            #expect(titles(items) == surface.menu, "\(surface.name): \(titles(items))")
            let bar = menuBarCommands()
            for item in items {
                let title = item["title"] as? String ?? ""
                let enabled = item["enabled"] as? Bool ?? false
                if surface.enabled.contains(title) {
                    #expect(enabled, "\(surface.name): “\(title)” is off: \(item["reason"] as? String ?? "")")
                } else if !enabled {
                    #expect(!(item["reason"] as? String ?? "").isEmpty, "\(surface.name): “\(title)” is off without a reason")
                }
                #expect(!(item["help"] as? String ?? "").isEmpty, "\(surface.name): “\(title)” has no tooltip")
                #expect(bar.contains(title), "\(surface.name): “\(title)” isn't in the menu bar")
            }
            closePopovers(main)
        }

        @Test func rightClickSelectsTheRowUnderThePointerAndKeepsAMultipleSelection() async throws {
            let (main, harness, _, work) = await Self.window()
            defer { work.end() }
            let staging = try #require(sidebarRow(main, "Staging · shop"))
            let local = try #require(sidebarRow(main, "Local MariaDB 11.8"))
            _ = await call(harness, "click", ["x": staging.0, "y": staging.1])
            _ = await call(harness, "click", ["x": local.0, "y": local.1, "button": "right"])
            #expect(main.sidebar.selectedConnectionIDs == [Fixtures.local.id])
            _ = await call(harness, "click", ["x": staging.0, "y": staging.1, "modifiers": "cmd"])
            #expect(Set(main.sidebar.selectedConnectionIDs) == [Fixtures.local.id, Fixtures.staging.id])
            let menu = await call(harness, "click", ["x": staging.0, "y": staging.1, "button": "right"])
            #expect(Set(main.sidebar.selectedConnectionIDs) == [Fixtures.local.id, Fixtures.staging.id])
            #expect(titles(menu["menu"]).contains("Delete…"))
            // The menu acts on all of the selection.
            #expect(await call(harness, "menu", ["path": "context > Colour > Test"]).error == nil)
            #expect(main.model.connection(Fixtures.local.id)?.colour == .test && main.model.connection(Fixtures.staging.id)?.colour == .test)
        }

        /// F2 renames what has the focus, as in HeidiSQL: the tree's table (Rename…), a folder (Rename Folder…), else the tab
        /// shown. In a grid it is the grid's (editing the cell, the grid lanes'), so the window leaves it to the grid.
        @Test func f2RenamesWhatHasTheFocus() async throws {
            let (main, harness, _, work) = await Self.window()
            defer { work.end() }
            let window = try #require(main.window)
            window.layoutIfNeeded()
            func renamed(_ select: (Double, Double)?, field id: String) async throws -> String? {
                let point = try #require(select)
                _ = await call(harness, "click", ["x": point.0, "y": point.1])
                #expect(await call(harness, "key", ["combo": "f2"]).error == nil)
                _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
                let sheet = try #require(window.attachedSheet?.contentView)
                let name = find(NSTextField.self, id: id, in: sheet)?.stringValue
                _ = await call(harness, "press", ["title": "Cancel", "in": "sheet"])
                _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
                return name
            }
            let orders = DatabaseObject(.table, "airsql_fixture", "orders")
            #expect(try await renamed(treeRow(main, .object(Fixtures.production.id, orders))?.point, field: "rename.name") == "orders")
            #expect(try await renamed(folderRow(main, Self.folder.name), field: "folder.name") == Self.folder.name)

            // In a console, the tab's name in place; in its result grid, nothing of the window's.
            window.makeFirstResponder(nil)
            let console = try #require(main.openConsole(text: "SELECT 1", title: nil, connection: Fixtures.production.id).content
                                       as? ConsoleViewController)
            #expect(await eventually(timeout: 5) { window.firstResponder === console.editor })  // as the tab appeared
            #expect(await call(harness, "key", ["combo": "f2"]).error == nil)
            #expect(tabButton(main, main.selectedTab?.title ?? "").renameField != nil)
            window.makeFirstResponder(nil)
            let grid = DataGridView()
            console.view.addSubview(grid)
            window.makeFirstResponder(grid)
            let item = try #require(harness.menuItems(for: try KeyCombo("f2")).first)
            #expect(!main.validateMenuItem(item) && tabButton(main, main.selectedTab?.title ?? "").renameField == nil)
            grid.removeFromSuperview()
        }

        /// Full keyboard use: Tab goes from field to field of what is shown, though the window's content changes.
        @Test func tabGoesOnIntoWhatIsShown() async throws {
            /// The ids of the views Tab reaches, `count` times from the first responder (through a field editor, as the key).
            func tabs(_ window: NSWindow, _ count: Int) -> [String] {
                (0..<count).map { _ in
                    if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { editor.insertTab(nil) }
                    else { window.selectNextKeyView(nil) }
                    let responder = (window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSView : $0 }
                        ?? window.firstResponder as? NSView
                    return responder?.accessibilityIdentifier() ?? ""
                }
            }
            let model = testModel(Fixtures.shop)
            let (main, harness) = appWindow(model)
            let window = try #require(main.window)
            // The connection editor, on a tab chosen after it opened.
            let editor = ConnectionEditor.show(Fixtures.routed(long: false), isNew: false, model: model, on: window) { _, _ in }
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            editor.show(.route)
            let sheet = try #require(window.attachedSheet)
            #expect(tabs(sheet, 3) == ["editor.proxyHost", "editor.proxyPort", "editor.proxyUser"])
            _ = await call(harness, "press", ["title": "Cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            // The main window: from the sidebar into the tab's content.
            main.openConsole(text: "SELECT 1", title: nil, connection: Fixtures.production.id)
            window.makeFirstResponder(main.sidebar.filter)
            let reached = tabs(window, 3)
            #expect(reached.contains { !$0.hasPrefix("sidebar.") }, "Tab stays in the sidebar: \(reached)")
            // The compare window: on to the list of what differs.
            let compare = AppTests.ReconAppTests.window(AppTests.ReconAppTests.result())
            compare.window?.makeFirstResponder(nil)
            #expect(tabs(try #require(compare.window), 4).contains("recon.list"))
        }

        private func closePopovers(_ main: MainWindowController) {
            for item in [main.statusBar.route, main.statusBar.server, main.statusBar.transaction, main.statusBar.activity,
                         main.statusBar.agent] { item.shown?.close() }
        }

        /// Every command title of the menu bar (submenus' items too), as the menus show them.
        private func menuBarCommands() -> Set<String> {
            func walk(_ menu: NSMenu) -> [String] {
                menu.items.flatMap { item in [item.title] + (item.submenu.map(walk) ?? []) }
            }
            return Set(NSApp.mainMenu.map(walk) ?? [])
        }
    }
}
