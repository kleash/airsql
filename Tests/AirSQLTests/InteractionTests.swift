import AppKit
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
                           "Compare…", "Colour", "Delete…"],
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
                    menu: ["Close Tab", "Close Other Tabs", "Duplicate Tab", "Rename Tab…", "Reveal in Finder", "Change Connection…"],
                    enabled: ["Close Tab", "Close Other Tabs", "Duplicate Tab", "Rename Tab…"]),
            Surface(name: "Result tab",
                    place: { main, _ in
                        let console = ConsoleViewController(model: main.model, connection: Fixtures.production.id)
                        main.open(console, title: "Query 1", connection: Fixtures.production.id)
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
                    menu: ["Pin Result", "Rename Result…", "Close Result", "Close Other Results", "Export Result…", "Compare With…"],
                    enabled: ["Pin Result", "Rename Result…", "Close Result"]),
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
                    menu: ["Copy", "Commit", "Rollback"], enabled: ["Copy"]),
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
        nonisolated static let rows = ["Connection in the sidebar", "Folder in the sidebar", "Editor tab", "Result tab", "Status bar: route",
                                       "Status bar: server", "Status bar: transaction", "Status bar: activity", "Status bar: agents", "Status bar: SQL log",
                                       "Database in the tree", "Table or view in the tree", "Routine, trigger or event",
                                       "Folder or category in the tree", "Table in the database view", "Process list row"]

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
