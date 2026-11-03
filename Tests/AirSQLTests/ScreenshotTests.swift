import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

// Light and dark pictures of each screen of this batch, drawn by the harness with neutral demo data, for people and
// reviewers to compare with docs/dev/mockups.html. Only with AIRSQL_SCREENSHOTS=1: they go to build/screenshots.
extension AppTests {
    @MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["AIRSQL_SCREENSHOTS"] == "1")) struct ScreenshotTests {
        static let folder: URL = {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let folder = root.appendingPathComponent("build/screenshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }()

        /// On a screen while it is photographed: until a window has been shown, AppKit hasn't made the vibrancy of its
        /// toolbar's text (it came out black in Deep Water), and a popover is put on a screen anyway.
        func onScreen(_ window: NSWindow?) {
            window?.setFrameOrigin(NSPoint(x: 40, y: 40))
            window?.orderFront(nil)
            window?.displayIfNeeded()
        }

        func save(_ harness: AgentServer, _ name: String, target: String = "main") async throws {
            let reply = await call(harness, "screenshot", ["target": target, "scale": 2])
            let image = try #require(reply.image, "\(name): \(reply.error ?? "")")
            let png = try #require(image.representation(using: .png, properties: [:]))
            try png.write(to: Self.folder.appendingPathComponent(name + ".png"))
        }

        private func dressed(_ model: AppModel, _ main: MainWindowController) {
            model.states[Fixtures.production.id] = .connected(server: "MariaDB 11.8.3")
            model.agentStatus = "Claude Code · reading schema"
            let content = FixtureContent("-- Top customers by paid orders, last 90 days\nSELECT c.id, c.`name`, COUNT(o.id) AS orders, "
                                         + "SUM(o.total) AS spent\nFROM customers c JOIN orders o ON o.customer_id = c.id\n"
                                         + "WHERE o.status = 'paid'\nGROUP BY c.id ORDER BY spent DESC LIMIT 200;")
            content.badge = "Transaction open · 2 changes"
            content.edited = true
            main.open(content, title: "Top customers.sql", connection: Fixtures.production.id)
            main.open(FixtureContent("SELECT * FROM customers;"), title: "customers", connection: Fixtures.production.id)
            main.open(FixtureContent("SHOW CREATE TABLE orders;"), title: "orders · structure", connection: Fixtures.production.id)
            main.open(FixtureContent("SELECT 1;"), title: "Query 4", connection: Fixtures.staging.id)
            main.sidebar.select([Fixtures.production.id])
            main.select(main.tabs[0])
        }

        @Test func screens() async throws {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let look = NSAppearance(named: appearance)

                // The first run.
                let (first, firstHarness) = appWindow(testModel())
                first.window?.appearance = look
                onScreen(first.window)
                try await save(firstHarness, "first-run-\(suffix)")
                first.window?.orderOut(nil)

                // A connection's summary.
                let summaryModel = testModel(Fixtures.shop)
                let (summary, summaryHarness) = appWindow(summaryModel)
                summary.window?.appearance = look
                summary.sidebar.select([Fixtures.staging.id])
                onScreen(summary.window)
                try await save(summaryHarness, "summary-\(suffix)")
                summary.window?.orderOut(nil)

                // The main window at work, with the activity popover.
                let model = testModel(Fixtures.shop)
                let (main, harness) = appWindow(model)
                main.window?.appearance = look
                dressed(model, main)
                onScreen(main.window)
                try await save(harness, "main-\(suffix)")
                let work = model.activity.start("Exporting shop with mariadb-dump", connection: Fixtures.production.id) {}
                work.progress = 0.62
                work.detail = "1.9 GB of 3.1 GB"
                main.refresh()  // the status bar shows the work (it follows the list a moment later by itself)
                main.statusBar.activity.showPopover()
                _ = await call(harness, "wait", ["until": "popover", "timeout": 5])
                try await save(harness, "main-activity-\(suffix)")
                main.statusBar.activity.shown?.close()
                work.end()

                // The SQL preview sheet.
                var request = SQLPreviewRequest(change: ChangeSQL(title: "Apply", statements: [
                    "UPDATE `orders` SET `status` = 'refunded', `note` = 'Customer asked for refund on 2 Nov' WHERE `id` = 2400977",
                    "DELETE FROM `orders` WHERE `id` IN (2400969)",
                    "INSERT INTO `orders` (`customer_id`, `status`, `total`, `gift`, `tags`) VALUES (27650, 'paid', 129.00, 0, 'web')",
                ], connection: Fixtures.production.id), heading: "Apply 3 changes to shop.orders?",
                                                caption: "They run in one transaction. If one fails, none are kept and the grid "
                                                    + "points to the row.")
                request.warnings = ["Deleting from orders also deletes rows in order_items (ON DELETE CASCADE)."]
                request.accessory = checkbox("Read new rows back (shows the new id)", id: "preview.readBack",
                                             tip: "Read the new rows back after Apply", on: true, target: nil, action: nil)
                SQLPreviewSheet.changesetWriter = { _ in }
                SQLPreviewSheet.show(request, connection: Fixtures.production, on: main.window!) { _ in }
                _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
                try await save(harness, "sql-preview-\(suffix)")
                _ = await call(harness, "press", ["title": "Cancel"])
                _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
                SQLPreviewSheet.changesetWriter = nil

                // Trust and password.
                showTrust(server: "db.example.com", fingerprint: "SHA256:9F:2C:41:7A:0B:E3:55:D8:6C:11:AF:30:72:9E:C4:5B:"
                          + "08:DD:3A:61:F7:24:9C:B0:13:6E:85:C2:4F:70:A9:1D",
                          details: ["Issued to db.example.com by Example Private CA", "Valid from 1 Jan 2026 until 1 Jan 2028"],
                          on: main.window!) { _ in }
                _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
                try await save(harness, "trust-\(suffix)")
                _ = await call(harness, "press", ["title": "Cancel"])
                _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
                showPasswordPrompt(for: "Production · shop", user: "app", retry: false, canRemember: true, on: main.window!) { _, _ in }
                _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
                try await save(harness, "password-\(suffix)")
                _ = await call(harness, "press", ["title": "Cancel"])
                _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])

                // Settings, every pane.
                let settings = SettingsWindowController(model: model)
                keptWindows.append(settings)
                let window = try #require(settings.window)
                window.appearance = look
                onScreen(window)
                let settingsHarness = AgentServer(main: main, model: model, windows: { [window] })
                for pane in SettingsPane.allCases {
                    settings.show(pane)
                    window.layoutIfNeeded()
                    try await save(settingsHarness, "settings-\(pane.rawValue)-\(suffix)", target: "window:\(pane.title)")
                }
                window.orderOut(nil)
                main.window?.orderOut(nil)
            }
        }
    }
}
