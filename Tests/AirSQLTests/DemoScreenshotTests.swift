import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

// The pictures in the README and AirSQL Help (docs/assets/screenshots), light and dark: the main screens on the demo
// shop that scripts/demo-shop.sql makes on the lab's MySQL 8.4, under made-up connection names and hosts; the databases
// are dropped again when done. The repository's copies were then cut to 256 colours, the most common ones kept exact
// (a third of the size, no visible change).
//   AIRSQL_LAB=1 AIRSQL_SCREENSHOTS=1 ./test.sh --filter DemoScreenshotTests
extension AppTests {
    @MainActor @Suite(.enabled(if: Lab.enabled && ProcessInfo.processInfo.environment["AIRSQL_SCREENSHOTS"] == "1"))
    struct DemoScreenshotTests {
        static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        static let folder = root.appendingPathComponent("docs/assets/screenshots", isDirectory: true)
        static let size = NSSize(width: 1280, height: 800)
        static let server = Lab.mysql84

        /// Production is the lab's MySQL 8.4 (attached as connecting would attach it); the others are only listed.
        static let production: SavedConnection = {
            var connection = SavedConnection(name: "Shop · Production", host: "db-primary.internal.example", port: 3306,
                                             user: "app", colour: .production, route: .ssh)
            connection.sshHost = SSHHop(host: "bastion.example.com", user: "deploy", login: .agent)
            connection.database = "shop"
            connection.databaseFilter = "shop"
            connection.safety = .production
            connection.agentAccess = .schema
            return connection
        }()
        static let staging: SavedConnection = {
            var connection = SavedConnection(name: "Shop · Staging", host: "10.20.0.15", port: 3306, user: "deploy",
                                             colour: .staging, route: .sshJump)
            connection.jumpHosts = [SSHHop(host: "bastion.example.com", user: "deploy", login: .agent)]
            connection.sshHost = SSHHop(host: "gateway.internal.example", user: "deploy", login: .keyFile,
                                        keyFile: "~/.ssh/id_ed25519")
            connection.database = "shop_staging"
            connection.comment = "Refreshed from Production every Monday"
            connection.agentAccess = .schemaRead
            return connection
        }()
        static let replica: SavedConnection = {
            var connection = SavedConnection(name: "Analytics replica", host: "replica.example.net", port: 3306, user: "reports",
                                             colour: .test, route: .proxy)
            connection.proxy = ProxySettings(kind: .socks5, host: "proxy.example.com", port: 1080, user: "reports")
            connection.readOnly = true
            connection.agentAccess = .schemaReadAnalytics
            connection.agentSampleRows = true
            return connection
        }()
        static let local: SavedConnection = {
            var connection = SavedConnection(name: "Local MariaDB 11.8", user: "root", colour: .development)
            connection.socket = "/tmp/mysql.sock"
            return connection
        }()

        static let query = """
            -- Best customers by spend
            SELECT c.id, CONCAT(c.first_name, ' ', c.last_name) AS customer, c.city, c.tier,
                   COUNT(*) AS orders, SUM(o.total) AS spent
            FROM orders o
            JOIN customers c ON c.id = o.customer_id
            WHERE o.status NOT IN ('cancelled', 'refunded')
            GROUP BY c.id
            ORDER BY spent DESC
            LIMIT 50;
            """

        @Test func pictures() async throws {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let setup = DBConnection(options: DBLab.options(Self.server), role: .tools, log: DBLab.log)
            try await setup.connect()
            let script = try String(contentsOf: Self.root.appendingPathComponent("scripts/demo-shop.sql"), encoding: .utf8)
            for statement in SQLSplitter.statements(in: script) { _ = try await setup.query(statement.sql) }
            var failure: Error?
            do {
                for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                    try await pictures(NSAppearance(named: appearance), suffix)
                }
            } catch {
                failure = error
            }
            for name in ["shop", "shop_staging"] {
                _ = try? await setup.query("DROP DATABASE IF EXISTS " + SQLQuote.identifier(name))
            }
            await setup.close()
            if let failure { throw failure }
        }

        private func pictures(_ look: NSAppearance?, _ suffix: String) async throws {
            let model = testModel([Self.production, Self.staging, Self.replica, Self.local])
            model.data.settings.liquibase.author = "shop-team"
            let (main, harness) = appWindow(model, size: Self.size)
            let window = try #require(main.window)
            window.appearance = look
            let connection = Connection(options: DBLab.options(Self.server), log: DBLab.log)
            try await connection.connect()
            let open = model.attach(connection, to: Self.production.id) { $0 == "shop" }
            defer { model.detach(open.id) }
            model.states[Self.production.id] = .connected(server: "MySQL " + Self.server.version)
            _ = await eventually(timeout: 60) { open.snapshot.server != nil && open.loading.isEmpty }
            open.currentDatabase = "shop"
            ConsoleViewController.openConnection = { [weak model] in model?.openConnection($0)?.connection }
            ConsoleViewController.schemaCache = { [weak model] in model?.openConnection($0)?.schema }
            ReconWindowController.connect = { _, _ in Connection(options: DBLab.options(Self.server), log: DBLab.log) }
            defer {
                ConsoleViewController.openConnection = { _ in nil }
                ConsoleViewController.schemaCache = { _ in nil }
                ReconWindowController.connect = nil
            }
            window.setFrameOrigin(NSPoint(x: 40, y: 40))
            window.orderFront(nil)
            main.sidebar.select([Self.production.id])

            // The console, then the main window on the orders table.
            let consoleTab = main.openConsole(text: Self.query, title: "Best customers.sql", connection: Self.production.id)
            let console = try #require(consoleTab.content as? ConsoleViewController)
            _ = treeRow(main, .object(open.id, DatabaseObject(.table, "shop", "orders")))
            main.openTableData(DatabaseObject(.table, "shop", "orders"), of: open)
            let orders = try #require(main.selectedTab?.content as? TableDataController)
            await ready { orders.loading != nil || orders.source == nil }
            // The newest first: the id header's sort (the table keeps it from the last run) until it is descending.
            for _ in 0..<3 where orders.source?.sort.map(\.ascending) != [false] {
                orders.sort(by: 0, adding: false)
                await ready { orders.loading != nil }
            }
            try await save(harness, "main-\(suffix)")

            main.select(consoleTab)
            console.runAll(nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 30])
            #expect(console.resultTabs.first?.title != nil && console.messagesView.messages.last?.level == .ok)
            try await save(harness, "console-\(suffix)")
            #expect(await call(harness, "menu", ["path": "Query > Explain"]).error == nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 30])
            #expect(console.selectedResult?.title == "Plan")
            try await save(harness, "explain-\(suffix)")

            // Two edits on products, and the SQL Apply would run (cancelled: nothing is written).
            main.openTableData(DatabaseObject(.table, "shop", "products"), of: open)
            let products = try #require(main.selectedTab?.content as? TableDataController)
            await ready { products.loading != nil || products.source == nil }
            products.source?.set(.text("109.00"), row: 15, column: 4)  // the brass desk lamp's price
            products.source?.set(.text("30"), row: 8, column: 5)  // the walnut tray's stock
            products.changesDidChange()
            products.applyChanges(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            try await save(harness, "edit-\(suffix)")
            _ = await call(harness, "press", ["title": "Cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            products.revertAllChanges(nil)

            // Staging's route: a jump host, then the SSH host that reaches the database.
            main.edit(Self.staging, isNew: false, tab: .route)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            try await save(harness, "connection-\(suffix)")
            _ = await call(harness, "press", ["title": "Cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])

            // Generate Liquibase Changelog on shop, read from the server.
            let liquibase = LiquibaseSheet(model: model, connection: Self.production, options: DBLab.options(Self.server),
                                           database: "shop")
            liquibase.show(on: window)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            let (list, _) = try AppTests.LiquibaseAppTests.parts(liquibase)
            _ = await eventually(timeout: 30) { list.numberOfRows > 0 }
            list.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)  // orders
            try await Task.sleep(nanoseconds: 300_000_000)
            try await save(harness, "liquibase-\(suffix)")
            liquibase.close()
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])

            // Compare Production's shop with Staging's, and the products whose rows differ.
            let compare = ReconWindowController(model: model)
            keptWindows.append(compare)
            let compareWindow = try #require(compare.window)
            compareWindow.appearance = look
            compareWindow.setFrame(NSRect(origin: NSPoint(x: 40, y: 40), size: Self.size), display: false)
            compare.main = main
            compare.source.choose(Self.production, database: "shop")
            compare.target.choose(Self.staging, database: "shop_staging")
            _ = await eventually(timeout: 15) {
                compare.source.databases.numberOfItems > 0 && compare.target.databases.numberOfItems > 0
            }
            compare.refresh(nil)
            _ = await eventually(timeout: 120) { !compare.isRunning }
            let result = try #require(compare.result)
            let changed = try #require(compare.results.objects.firstIndex { $0.name == "products" })
            compare.results.list.selectRowIndexes(IndexSet(integer: changed), byExtendingSelection: false)
            compare.results.detail.show(compare.results.objects[changed], result: result, data: true)
            compareWindow.orderFront(nil)
            compareWindow.makeFirstResponder(compare.results.list)
            compareWindow.displayIfNeeded()
            let compareHarness = AgentServer(main: main, model: model, windows: { [compareWindow] })
            try await save(compareHarness, "compare-\(suffix)", target: "window:Compare")
            compareWindow.orderOut(nil)

            // Settings: agents allowed, each connection's access; then the safety checks.
            model.data.settings.agentsAllowed = true
            let settings = SettingsWindowController(model: model)
            keptWindows.append(settings)
            let settingsWindow = try #require(settings.window)
            settingsWindow.appearance = look
            settingsWindow.setFrameOrigin(NSPoint(x: 40, y: 40))
            settingsWindow.orderFront(nil)
            let settingsHarness = AgentServer(main: main, model: model, windows: { [settingsWindow] })
            settings.show(.agents)
            try await Task.sleep(nanoseconds: 500_000_000)  // the toolbar's selection moves to it (it animates)
            // The paths this Mac's test run has, as an installed AirSQL shows them.
            retitle(settingsWindow.contentView, [
                AgentsPane.shown(AgentsPane.exportFolder): "~/Library/Application Support/AirSQL/Agent Exports",
                AgentsPane.program + " --mcp": "/Applications/AirSQL.app/Contents/MacOS/AirSQL --mcp",
            ])
            try await save(settingsHarness, "agents-\(suffix)", target: "window:Agents")
            settings.show(.safety)
            try await Task.sleep(nanoseconds: 500_000_000)
            try await save(settingsHarness, "settings-\(suffix)", target: "window:Safety")
            settingsWindow.orderOut(nil)
            window.orderOut(nil)
        }

        private func save(_ harness: AgentServer, _ name: String, target: String = "main") async throws {
            let reply = await call(harness, "screenshot", ["target": target, "scale": 2])
            let image = try #require(reply.image, "\(name): \(reply.error ?? "")")
            let png = try #require(image.representation(using: .png, properties: [:]))
            try png.write(to: Self.folder.appendingPathComponent(name + ".png"))
        }

        private func retitle(_ view: NSView?, _ texts: [String: String]) {
            guard let view else { return }
            if let field = view as? NSTextField, let text = texts[field.stringValue] { field.stringValue = text }
            for subview in view.subviews { retitle(subview, texts) }
        }
    }
}
