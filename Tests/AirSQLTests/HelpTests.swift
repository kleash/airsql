// Ported from AirSCP 1.4.0 Tests/AirSCPTests/HelpTests.swift (the walk of controls and menus without help).
import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

// AirSQL explains itself (plan §1): every menu item and every interactive control, in every window, sheet, popover and
// state, has a one-line tooltip. Lanes add their screens' states to `everyControlSaysWhatItDoes`.

/// The interactive controls of `windows` without a tooltip or help text: "where: role id “title”".
@MainActor
func unexplained(_ windows: [NSWindow], where place: String) -> [String] {
    let interactive: Set<String> = ["button", "checkbox", "radiobutton", "popupbutton", "menubutton", "textfield", "combobox",
                                    "slider", "link", "disclosuretriangle", "searchfield"]
    // AppKit's own parts, which say nothing of AirSQL: the window's buttons and the scroll bars' arrows and pages.
    let exempt: Set<String> = ["closebutton", "minimizebutton", "zoombutton", "fullscreenbutton", "sortbutton",
                               "incrementarrow", "decrementarrow", "incrementpage", "decrementpage"]
    // The toolbar's overflow menu (») is AppKit's own too.
    return windows.flatMap { window in
        AXNode.flatten(window).filter { interactive.contains($0.role) && !exempt.contains($0.subrole) && $0.help == nil
            && $0.title != "more toolbar items" }
            .map { "\(place): \($0.role) \($0.id) “\($0.title)”" }
    }
}

/// Every item of `menu` and its submenus without a tooltip: their paths.
@MainActor
func unexplained(_ menu: NSMenu, path: [String] = []) -> [String] {
    menu.delegate?.menuNeedsUpdate?(menu)
    return menu.items.filter { !$0.isSeparatorItem && !$0.isHidden && !$0.title.isEmpty }.flatMap { item -> [String] in
        let here = path + [item.title]
        var missing = (item.toolTip ?? "").isEmpty && !path.isEmpty ? [here.joined(separator: " > ")] : []
        if let submenu = item.submenu, submenu !== NSApp.servicesMenu, item.title != "Services" {
            missing += unexplained(submenu, path: here)
        }
        return missing
    }
}

extension AppTests {
    @MainActor @Suite struct HelpTests {
        @Test func everyMenuItemSaysWhatItDoes() {
            _ = NSApplication.shared
            _ = TestEnvironment.isolated
            let bar = MainMenu.build()
            #expect(unexplained(bar).isEmpty, "\(unexplained(bar))")
            // The menus in their order (empty ones hidden until a lane fills them).
            #expect(bar.items.map(\.title) == ["AirSQL", "File", "Edit", "View", "Query", "Data", "Database", "Connection", "Tools",
                                               "Window", "Help"])
            // ⌘? is macOS's (the Help menu's search).
            #expect(bar.item(withTitle: "Help")?.submenu?.items.allSatisfy { $0.keyEquivalent != "?" } == true)
            #expect(bar.item(withTitle: "View")?.submenu?.items.last?.title == "Enter Full Screen")
        }

        @Test func everyControlSaysWhatItDoes() async throws {
            var missing: [String] = []
            // The first run.
            let empty = testModel()
            let (first, _) = appWindow(empty)
            missing += unexplained([first.window!], where: "first run")

            // Connections, a summary, tabs and every status item; their popovers.
            let model = testModel(Fixtures.shop + Fixtures.odd)
            let (main, harness) = appWindow(model)
            let window = try #require(main.window)
            missing += unexplained([window], where: "nothing selected")
            _ = await call(harness, "select", ["pane": "sidebar", "names": ["Production · shop"]])
            missing += unexplained([window], where: "summary")
            model.states[Fixtures.production.id] = .connected(server: "MySQL 8.4.3")
            model.agentStatus = "Claude Code · reading schema"
            let content = FixtureContent()
            content.badge = "Transaction open · 2 changes"
            content.edited = true
            main.open(content, title: "Top customers.sql", connection: Fixtures.production.id)
            main.open(FixtureContent(), title: "Query 2", connection: Fixtures.staging.id)
            let work = model.activity.start("Exporting shop", connection: Fixtures.production.id) {}
            defer { work.end() }
            main.select(main.tabs[0])
            try await Task.sleep(nanoseconds: 200_000_000)
            missing += unexplained([window], where: "tabs and status")
            for id in ["status.route", "status.server", "status.transaction", "status.activity", "status.agent"] {
                guard let item = await element(harness, id) else {
                    missing.append("status: \(id) not shown")
                    continue
                }
                _ = await call(harness, "click", ["x": item.center.0, "y": item.center.1])
                if await call(harness, "wait", ["until": "popover", "timeout": 5]).error != nil {
                    missing.append("\(id): no popover")
                    continue
                }
                missing += unexplained(window.childWindows ?? [], where: "\(id) popover")
                window.childWindows?.forEach { $0.orderOut(nil) }
                for item in [main.statusBar.route, main.statusBar.server, main.statusBar.transaction, main.statusBar.activity,
                             main.statusBar.agent] { item.shown?.close() }
                _ = await eventually(timeout: 5) { (window.childWindows ?? []).allSatisfy { !$0.isVisible } }
            }

            // Settings, every pane.
            let settings = SettingsWindowController(model: model)
            keptWindows.append(settings)
            settings.window?.setFrameOrigin(NSPoint(x: -21000, y: -21000))
            for pane in SettingsPane.allCases {
                settings.show(pane)
                settings.window?.layoutIfNeeded()
                missing += unexplained([settings.window!], where: "Settings ▸ \(pane.title)")
            }

            // The sheets: the SQL preview (with every part), Trust, the password, Delete.
            var request = SQLPreviewRequest(change: ChangeSQL(title: "t", statements: ["DROP TABLE `orders`"], connection: Fixtures.production.id),
                                            heading: "Drop orders?", caption: "Its rows are deleted.")
            request.typeToConfirm = "orders"
            request.agent = "Claude Code"
            request.warnings = ["Deleting from orders also deletes rows in payments (ON DELETE CASCADE)."]
            SQLPreviewSheet.changesetWriter = { _ in }
            defer { SQLPreviewSheet.changesetWriter = nil }
            SQLPreviewSheet.show(request, connection: Fixtures.production, on: window) { _ in }
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            missing += unexplained(harness.openSheets(), where: "SQL preview")
            _ = await call(harness, "press", ["title": "Decline"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            showTrust(server: "db.example.com", fingerprint: "SHA256:AB:CD", details: ["Issued by Example CA"], on: window) { _ in }
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            missing += unexplained(harness.openSheets(), where: "Trust")
            _ = await call(harness, "press", ["title": "Cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            showPasswordPrompt(for: "Production · shop", user: "app", retry: false, canRemember: true, on: window) { _, _ in }
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            missing += unexplained(harness.openSheets(), where: "password")
            _ = await call(harness, "press", ["title": "Cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            // The client tools' sheets (L6).
            let export = ExportSheet(model: model, connection: ToolFixtures.local, options: ToolFixtures.options)
            export.show(on: window, loads: false)
            export.show(server: ToolFixtures.server, tools: ToolFixtures.dumps, databases: ToolFixtures.databases())
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            missing += unexplained(harness.openSheets(), where: "Export")
            _ = export.begin("Exporting shop")
            missing += unexplained(harness.openSheets(), where: "Export running")
            export.finish("Stopped.", failed: true)
            export.close()
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            let restore = RestoreSheet(model: model, connection: ToolFixtures.local, options: ToolFixtures.options, builtIn: false)
            restore.show(on: window, loads: false)
            restore.show(server: ToolFixtures.server, tools: ToolFixtures.clients, databases: ["shop"])
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            missing += unexplained(harness.openSheets(), where: "Restore")
            restore.close()
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            let copy = CopySheet(model: model, connection: ToolFixtures.local, options: ToolFixtures.options)
            copy.show(on: window, loads: false)
            copy.show(databases: ToolFixtures.databases())
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            missing += unexplained(harness.openSheets(), where: "Copy to Another Server")
            copy.close()
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            let csv = CSVImportSheet(model: model, connection: ToolFixtures.local, options: ToolFixtures.options)
            csv.show(on: window, loads: false)
            csv.show(databases: ToolFixtures.databases())
            csv.show(columns: ToolFixtures.customerColumns)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            missing += unexplained(harness.openSheets(), where: "Import CSV")
            csv.close()
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            _ = await call(harness, "menu", ["path": "Connection > Delete…"])
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            missing += unexplained(harness.openSheets(), where: "Delete")
            _ = await call(harness, "press", ["title": "Cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            // The connections lane's: the editor's tabs with every part of a route, the Trust sheets, ssh's questions.
            try await ConnectionsScreens.each(main, harness, long: false) { _, name in
                missing += unexplained(harness.openSheets(), where: name)
            }

            #expect(missing.isEmpty, "\(missing.joined(separator: "\n"))")
        }
    }
}
