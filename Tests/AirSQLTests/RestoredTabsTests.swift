import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// The tabs after a relaunch: consoles as they were, the others as placeholders in their old places, with no server
/// contacted until the person presses a placeholder's button.
extension AppTests {
    @MainActor @Suite struct RestoredTabsTests {
        private static func saved(_ title: String, _ connection: UUID?, _ place: SavedPlace, preview: Bool? = nil,
                                  selected: Bool? = nil) -> SavedConsole {
            SavedConsole(id: UUID(), title: title, connection: connection, path: nil, text: nil, caret: 0, place: place,
                         preview: preview, selected: selected)
        }

        /// Runs `body` with the tabs kept in a file of its own.
        private static func withFile(_ body: (URL) async throws -> Void) async rethrows {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            ConsoleDocuments.shared.fileURL = url
            defer {
                ConsoleDocuments.shared.fileURL = ConsoleTabStore.fileURL
                try? FileManager.default.removeItem(at: url)
            }
            try await body(url)
        }

        /// A window launched on `window`'s saved tabs.
        private static func relaunched(_ model: AppModel, _ window: SavedWindow, in url: URL) async throws
            -> (MainWindowController, AgentServer) {
            try ConsoleTabStore.save(window, to: url)
            let (main, harness) = appWindow(model)
            ConsoleDocuments.shared.restore(into: main)
            await ConsoleDocuments.shared.restoring?.value
            return (main, harness)
        }

        /// A connection that looks connected, with sessions that lead nowhere.
        private static func connect(_ model: AppModel, _ id: UUID) {
            let stand = Connection(options: ConnectOptions(host: "127.0.0.1", port: 1, user: "nobody", connectTimeout: 2))
            model.attach(stand, to: id)
            model.states[id] = .connected(server: "MariaDB 11.8.3")
        }

        private static func placeholderText(_ main: MainWindowController, _ id: String) -> String? {
            main.window?.layoutIfNeeded()
            return main.selectedTab.flatMap { find(NSTextField.self, id: id, in: $0.shown.view)?.stringValue }
        }

        /// 1.0.0's file, a plain list of consoles, still reads; the new one keeps every field.
        @Test func theStoreReadsTheOldListAndKeepsNames() async throws {
            try await Self.withFile { url in
                let console = SavedConsole(id: UUID(), title: "Query 1", connection: nil, path: nil, text: "SELECT 1", caret: 3)
                try JSONEncoder().encode([console]).write(to: url)
                #expect(ConsoleTabStore.load(from: url) == SavedWindow(tabs: [console]))
                let window = SavedWindow(tabs: [Self.saved("orders", UUID(), SavedPlace(kind: .table, database: "shop", object: "orders"),
                                                           preview: true, selected: true)], sidebar: [UUID()])
                try ConsoleTabStore.save(window, to: url)
                #expect(ConsoleTabStore.load(from: url) == window)
            }
        }

        /// Quit and launch again: every tab in its old place, the old one shown, the sidebar's selection back, only names
        /// in the file, and nothing sent to the server; Quit has nothing to ask and a placeholder closes without a word.
        @Test func aRelaunchBringsTheTabsBackWithoutContactingTheServer() async throws {
            try await Self.withFile { url in
                let port = try listener()
                defer { close(port.fd); close(port.fd6) }
                var production = SavedConnection(name: "Shop", host: "127.0.0.1", port: port.port, user: "app", colour: .production)
                production.readOnly = true
                let staging = SavedConnection(name: "Staging", host: "127.0.0.1", port: port.port, user: "app")
                let model = testModel([production, staging])
                let (main, _) = appWindow(model)
                ConsoleDocuments.shared.main = main
                Self.connect(model, production.id)
                defer { model.detach(production.id) }
                let open = try #require(model.openConnection(production.id))
                let context = try #require(Editors.context(production, in: model))
                main.openConsole(text: "SELECT 1", title: nil, connection: production.id)
                main.openTableData("orders", database: "shop", context: context, condition: "`email` = 'someone-secret'")
                main.openTableEditor("orders", database: "shop", context: context)
                main.open(ProcessListContent(open), title: "Processes", connection: production.id)
                main.preview(TableDataController(model: model, context: context, database: "shop", table: "customers", filter: nil),
                             title: "customers", connection: production.id)
                main.open(TextContent(title: "Report", caption: "", text: "not kept"), title: "Report", connection: production.id)
                main.sidebar.select([staging.id])
                main.select(main.tabs[2])
                let titles = ["Query 1", "orders", "orders · structure", "Processes", "customers"]

                ConsoleDocuments.shared.saveNow()
                let file = try String(contentsOf: url, encoding: .utf8)
                #expect(!file.contains("someone-secret"))

                let fresh = testModel([production, staging])
                let (relaunched, _) = appWindow(fresh)
                ConsoleDocuments.shared.restore(into: relaunched)
                await ConsoleDocuments.shared.restoring?.value
                #expect(relaunched.tabs.map(\.title) == titles)
                #expect(relaunched.tabs.allSatisfy { $0.connectionID == production.id })
                #expect(relaunched.selectedTab === relaunched.tabs[2])
                #expect(relaunched.sidebar.selectedConnectionIDs == [staging.id])
                #expect(relaunched.tabs[0].content is ConsoleViewController)
                #expect(relaunched.tabs[1...].allSatisfy { $0.shown is RestoredTabContent })
                #expect(relaunched.tabs[4].content is PreviewContent)
                #expect(relaunched.tabs[3].place == SavedPlace(kind: .processes))
                #expect(relaunched.tabs[2].place == SavedPlace(kind: .structure, database: "shop", object: "orders"))
                let what = try #require(Self.placeholderText(relaunched, "restored.what"))
                #expect(what == "The structure of orders in shop, on Shop (Production, read-only)")
                #expect(Self.placeholderText(relaunched, "restored.state") == "Not connected")
                let button = try #require(find(NSButton.self, id: "restored.open", in: relaunched.tabs[2].shown.view))
                #expect(button.title == "Connect and Open")

                // Nothing connected, nothing started, and no knock on the server's port.
                _ = await eventually(timeout: 0.5) { false }
                #expect(fresh.states.isEmpty && fresh.open.isEmpty && fresh.activity.running.isEmpty)
                var knock = [pollfd(fd: port.fd, events: Int16(POLLIN), revents: 0), pollfd(fd: port.fd6, events: Int16(POLLIN), revents: 0)]
                #expect(poll(&knock, 2, 0) == 0)

                // A second relaunch keeps the placeholders; Quit asks nothing; closing one asks nothing.
                #expect(ConsoleDocuments.shared.snapshot.tabs.map(\.place) == ConsoleTabStore.load(from: url).tabs.map(\.place))
                #expect(relaunched.unfinishedWork().isEmpty)
                relaunched.close(relaunched.tabs[3])
                #expect(relaunched.tabs.count == 4 && relaunched.window?.attachedSheet == nil)
            }
        }

        /// A tab whose connection was deleted is dropped without a word; so is the sidebar's row.
        @Test func aDeletedConnectionsTabIsDropped() async throws {
            try await Self.withFile { url in
                let kept = SavedConnection(name: "Kept", host: "127.0.0.1", user: "app")
                let place = SavedPlace(kind: .table, database: "shop", object: "orders")
                let window = SavedWindow(tabs: [Self.saved("gone", UUID(), place, selected: true), Self.saved("orders", kept.id, place)],
                                         sidebar: [UUID()])
                let (main, _) = try await Self.relaunched(testModel([kept]), window, in: url)
                #expect(main.tabs.map(\.title) == ["orders"] && main.selectedTab === main.tabs.first)
                #expect(main.sidebar.selectedConnectionIDs.isEmpty && main.window?.attachedSheet == nil)
            }
        }

        /// Already connected, the button just loads: each kind's real tab, in the placeholder's place.
        @Test func theButtonLoadsTheRealTabInItsPlace() async throws {
            try await Self.withFile { url in
                let saved = SavedConnection(name: "Shop", host: "127.0.0.1", port: 1, user: "app")
                let model = testModel([saved])
                let table = SavedPlace(kind: .table, database: "shop", object: "orders")
                let window = SavedWindow(tabs: [
                    Self.saved("first", saved.id, SavedPlace(kind: .table, database: "shop", object: "first")),
                    Self.saved("orders", saved.id, table),
                    Self.saved("orders · structure", saved.id, SavedPlace(kind: .structure, database: "shop", object: "orders")),
                    Self.saved("v · view", saved.id, SavedPlace(kind: .view, database: "shop", object: "v")),
                    Self.saved("Processes", saved.id, SavedPlace(kind: .processes)),
                    Self.saved("customers", saved.id, SavedPlace(kind: .table, database: "shop", object: "customers"), preview: true),
                ])
                let (main, harness) = try await Self.relaunched(model, window, in: url)
                Self.connect(model, saved.id)
                defer { model.detach(saved.id) }
                let titles = main.tabs.map(\.title)
                for index in 1...5 {
                    main.select(main.tabs[index])
                    #expect(await eventually(timeout: 5) {
                        find(NSButton.self, id: "restored.open", in: main.tabs[index].shown.view)?.title == "Open"
                    })
                    #expect(await call(harness, "press", ["id": "restored.open"]).error == nil)
                    #expect(!(main.tabs[index].shown is RestoredTabContent))
                    #expect(main.selectedTab === main.tabs[index])
                    #expect(main.tabs.map(\.title) == titles)
                }
                #expect(main.tabs[1].shown is TableDataController && main.tabs[2].shown is TableEditorController)
                #expect(main.tabs[3].shown is ObjectEditorController && main.tabs[4].shown is ProcessListContent)
                #expect(main.tabs[5].content is PreviewContent && main.tabs[5].shown is TableDataController)
                #expect(main.tabs[0].shown is RestoredTabContent, "only the tab pressed loads")

                // The table is open meanwhile: the placeholder on it goes and that tab shows.
                let copy = RestoredTabContent(table, title: "orders", connection: saved.id, main: main)
                let tab = main.open(copy, title: "orders", connection: saved.id)
                #expect(await call(harness, "press", ["id": "restored.open"]).error == nil)
                #expect(!main.tabs.contains { $0 === tab } && main.selectedTab === main.tabs[1])
            }
        }

        /// A failed connect stays in the placeholder and says so, with the normal actions; Try Again's connect loads it.
        @Test func aFailedConnectStaysInThePlaceholder() async throws {
            try await Self.withFile { url in
                let saved = SavedConnection(name: "Closed port", host: "127.0.0.1", port: 1, user: "nobody")
                let model = testModel([saved])
                let window = SavedWindow(tabs: [Self.saved("orders", saved.id, SavedPlace(kind: .table, database: "shop", object: "orders"))])
                let (main, harness) = try await Self.relaunched(model, window, in: url)
                #expect(await call(harness, "press", ["id": "restored.open"]).error == nil)
                #expect(await eventually(timeout: 10) { main.window?.attachedSheet != nil }, "the normal error sheet")
                if let sheet = main.window?.attachedSheet { main.window?.endSheet(sheet) }
                #expect(await eventually(timeout: 5) { Self.placeholderText(main, "restored.state")?.hasPrefix("Not connected: ") == true })
                let view = try #require(main.selectedTab?.shown.view)
                #expect(main.selectedTab?.shown is RestoredTabContent)
                #expect(find(NSButton.self, id: "restored.open", in: view)?.title == "Try Again")
                #expect(find(NSButton.self, id: "restored.edit", in: view)?.isHidden == false)
                #expect(find(NSButton.self, id: "restored.help", in: view)?.isHidden == false)
                Self.connect(model, saved.id)
                defer { model.detach(saved.id) }
                #expect(await eventually(timeout: 5) { main.selectedTab?.shown is TableDataController })
            }
        }

        /// Not pressed, a placeholder stays one when its connection connects: no read nobody asked for. Agents see no
        /// console in it either.
        @Test func connectingElsewhereLoadsNothing() async throws {
            try await Self.withFile { url in
                let saved = SavedConnection(name: "Shop", host: "127.0.0.1", port: 1, user: "app")
                let model = testModel([saved])
                let window = SavedWindow(tabs: [Self.saved("orders", saved.id, SavedPlace(kind: .table, database: "shop", object: "orders"))])
                let (main, _) = try await Self.relaunched(model, window, in: url)
                Self.connect(model, saved.id)
                defer { model.detach(saved.id) }
                #expect(await eventually(timeout: 5) { find(NSButton.self, id: "restored.open", in: main.tabs[0].shown.view)?.title == "Open" })
                #expect(main.tabs[0].shown is RestoredTabContent)
                #expect(AgentService(model: model, main: main).consoleTabs().isEmpty)
            }
        }

        /// The button's whole path on a real server: the Connector connects with the saved login, then the rows load.
        @Test(.enabled(if: Lab.enabled, "AIRSQL_LAB=1 runs the lab tests")) func theButtonConnectsAndLoadsOnTheLab() async throws {
            try await Self.withFile { url in
                var saved = SavedConnection(name: "Lab", host: "127.0.0.1", port: Lab.mariadb118.port, user: Lab.airsql.user)
                saved.tls = TLSOptions(mode: .off)
                let model = testModel([saved])
                model.setSavedPassword(saved.id.uuidString, Lab.airsql.password)
                let window = SavedWindow(tabs: [Self.saved("customers", saved.id, SavedPlace(kind: .table, database: "fixture", object: "customers"))])
                let (main, harness) = try await Self.relaunched(model, window, in: url)
                #expect(model.states.isEmpty)
                #expect(await call(harness, "press", ["id": "restored.open"]).error == nil)
                #expect(await eventually(timeout: 30) { (main.selectedTab?.shown as? TableDataController)?.source != nil })
                model.connector.disconnect(saved.id)
            }
        }
    }
}
