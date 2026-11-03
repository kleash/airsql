import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

// The app shell driven as a person would, through the harness: the first run, the sidebar's commands, tabs, the status
// bar, Settings, the SQL preview sheet, the Trust and password sheets, and the harness's own tools.
extension AppTests {
    @Test func firstRunOffersTheFirstConnection() async throws {
        let model = testModel()
        let (main, harness) = appWindow(model)
        #expect(main.contentKind == "firstRun")
        let snapshot = await call(harness, "snapshot", ["include": ["elements"]])
        let ids = (snapshot["elements"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        #expect(ids.contains("firstRun.addConnection") && ids.contains("firstRun.setUpAgents"))
        #expect(await call(harness, "press", ["id": "firstRun.addConnection"]).error == nil)
        // The connection editor; Save keeps the connection and shows it.
        #expect(await call(harness, "wait", ["until": "sheet", "timeout": 10]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.host", "value": "db.example.com"]).error == nil)
        #expect(await call(harness, "press", ["id": "editor.save"]).error == nil)
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        #expect(model.data.connections.map(\.host) == ["db.example.com"])
        #expect(await eventually { main.contentKind == "summary" })
        #expect(main.sidebar.selectedConnectionIDs == model.data.connections.map(\.id))
    }

    @Test func theSummaryOffersWhatTheConnectionsStateCallsFor() async throws {
        let model = testModel(Fixtures.shop)
        let (main, harness) = appWindow(model)
        _ = await call(harness, "select", ["pane": "sidebar", "names": ["Production · shop"]])
        let window = try #require(main.window)
        func button(_ id: String) -> NSButton? { find(NSButton.self, id: id, in: window.contentView!) }
        #expect(button("summary.connect")?.keyEquivalent == "\r" && button("summary.disconnect") == nil)
        model.states[Fixtures.production.id] = .connecting(step: "Opening the SSH tunnel")
        #expect(await eventually(timeout: 10) { button("summary.disconnect")?.toolTip == "Stop connecting (⇧⌘K)" })
        model.states[Fixtures.production.id] = .connected(server: "MariaDB 11.8.3")
        #expect(await eventually(timeout: 10) { button("summary.disconnect")?.toolTip == Commands.disconnect.tip + " (⇧⌘K)" })
        #expect(button("summary.connect") == nil && button("summary.newQuery")?.keyEquivalent == "\r")
        // Disconnect there: Connect again.
        #expect(await call(harness, "press", ["id": "summary.disconnect"]).error == nil)
        #expect(await eventually(timeout: 10) { button("summary.connect") != nil && model.states[Fixtures.production.id] == nil })
    }

    @Test func duplicateColourAndDeleteFromTheConnectionMenu() async throws {
        let model = testModel(Fixtures.shop)
        model.setSavedPassword(Fixtures.production.id.uuidString, "secret")
        let (main, harness) = appWindow(model)
        #expect(await call(harness, "select", ["pane": "sidebar", "names": ["Production · shop"]]).error == nil)
        #expect(main.contentKind == "summary")
        #expect(await call(harness, "menu", ["path": "Connection > Duplicate"]).error == nil)
        let copy = try #require(model.data.connections.first { $0.name == "Production · shop copy" })
        #expect(await eventually { model.savedPassword(copy.id.uuidString) == "secret" })
        #expect(main.sidebar.selectedConnectionIDs == [copy.id])

        #expect(await call(harness, "menu", ["path": "Connection > Colour > Staging"]).error == nil)
        #expect(model.connection(copy.id)?.colour == .staging)
        let menus = await call(harness, "snapshot", ["include": ["menus"]])
        let staging = (menus["menus"] as? [[String: Any]])?.first { $0["path"] as? String == "Connection > Colour > Staging" }
        #expect(staging?["state"] as? String == "on")

        #expect(await call(harness, "menu", ["path": "Connection > Delete…"]).error == nil)
        let sheet = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        #expect((sheet["title"] as? String)?.contains("Delete “Production · shop copy”?") == true)
        #expect((sheet["buttons"] as? [[String: Any]])?.first { $0["title"] as? String == "Delete" }?["destructive"] as? Bool == true)
        #expect(await call(harness, "press", ["title": "Delete"]).error == nil)
        #expect(await eventually { !model.data.connections.contains { $0.id == copy.id } })
        #expect(await eventually { model.savedPassword(copy.id.uuidString) == nil })
        // With nothing selected, the connection commands say why they are off.
        main.sidebar.select([])
        let off = await call(harness, "menu", ["path": "Connection > Duplicate"])
        #expect(off.error?.contains("Select a connection in the sidebar first") == true)
    }

    @Test func tabsOpenCloseRenameAndCycle() async throws {
        let model = testModel(Fixtures.shop)
        let (main, harness) = appWindow(model)
        let first = main.open(FixtureContent("SELECT 1"), title: "Query 1", connection: Fixtures.production.id)
        main.open(FixtureContent("SELECT 2"), title: "Query 2", connection: Fixtures.staging.id)
        main.open(FixtureContent("SELECT 3"), title: "Query 3", connection: nil)
        #expect(main.tabs.map(\.title) == ["Query 1", "Query 2", "Query 3"] && main.selectedTab?.title == "Query 3")
        #expect(main.contentKind == "tab")
        #expect(await call(harness, "menu", ["path": "Window > Show Next Tab"]).error == nil)
        #expect(main.selectedTab === first)
        // The tab's connection colours the strip under the toolbar.
        #expect(main.activeConnection?.id == Fixtures.production.id)
        #expect(await call(harness, "menu", ["path": "Window > Query 2"]).error == nil)
        #expect(main.selectedTab?.title == "Query 2")
        #expect(await call(harness, "key", ["combo": "cmd+w"]).error == nil)
        #expect(main.tabs.map(\.title) == ["Query 1", "Query 3"])
        #expect(await call(harness, "menu", ["path": "File > Close Other Tabs"]).error == nil)
        #expect(main.tabs.count == 1)
        // A tab that has unsaved work and says no stays open.
        let stubborn = FixtureContent("unsaved")
        stubborn.closes = false
        main.open(stubborn, title: "Unsaved", connection: nil)
        #expect(await call(harness, "menu", ["path": "File > Close Tab"]).error == nil)
        #expect(main.tabs.map(\.title).contains("Unsaved"))
        // Rename from the menu, typed in place.
        #expect(await call(harness, "menu", ["path": "File > Rename Tab…"]).error == nil)
        let field = try #require(main.tabBar.buttons.last?.renameField)
        field.stringValue = "Top customers"
        main.window?.makeFirstResponder(nil)
        #expect(await eventually { main.selectedTab?.title == "Top customers" })
        #expect(await call(harness, "menu", ["path": "File > Duplicate Tab"]).error == nil)
        #expect(main.tabs.map(\.title).filter { $0 == "Top customers" }.count == 2)
    }

    @Test func manyTabsKeepAReadableTitleAndScroll() throws {
        let model = testModel()
        let (main, _) = appWindow(model)
        for index in 1...12 { main.open(FixtureContent(), title: index == 12 ? "Agent update" : "Query \(index)", connection: nil) }
        main.tabBar.layoutSubtreeIfNeeded()
        let buttons = main.tabBar.buttons
        #expect(buttons.allSatisfy { $0.frame.width >= TabBarView.minimumTabWidth })
        // The last tab opened is selected and scrolled into view, its title whole.
        let last = try #require(buttons.last)
        #expect(!last.visibleRect.isEmpty)
        let title = try #require(find(NSTextField.self, in: last))
        let cell = try #require(title.cell)
        let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 20)).width
        #expect(title.stringValue == "Agent update" && needed <= title.frame.width + 1, "needs \(needed), has \(title.frame.width)")
    }

    @Test func statusItemsStayInOrderWhateverTheWidth() {
        let model = testModel(Fixtures.shop)
        let (main, _) = appWindow(model, size: MainWindowController.minimumSize)
        model.states[Fixtures.production.id] = .connected(server: "MariaDB 11.8.3")
        model.agentStatus = "Claude Code · reading schema"
        let content = FixtureContent()
        content.badge = "Transaction open · 2 changes"
        main.open(content, title: "Query", connection: Fixtures.production.id)
        let work = model.activity.start("Exporting shop with mariadb-dump", connection: Fixtures.production.id) {}
        defer { work.end() }
        main.refresh()
        let bar = main.statusBar
        // Narrow (the server steps out), then wide: the route keeps its own width and the server follows it, far from
        // the SQL log.
        for width in [1180, MainWindowController.minimumSize.width, 1500] {
            main.window?.setFrame(NSRect(origin: main.window!.frame.origin, size: NSSize(width: width, height: 720)), display: false)
            main.window?.layoutIfNeeded()
        }
        #expect(bar.route.frame.width <= bar.route.fittingSize.width + 1, "the route is \(bar.route.frame.width) wide")
        #expect(abs(bar.server.frame.minX - bar.route.frame.maxX - 12) < 1)
        #expect(bar.sqlLog.frame.minX - bar.server.frame.maxX > 300)
    }

    @Test func statusBarShowsRouteTransactionWorkAndAgents() async throws {
        let model = testModel(Fixtures.shop)
        let (main, harness) = appWindow(model)
        model.states[Fixtures.production.id] = .connected(server: "MariaDB 11.8.3")
        let content = FixtureContent()
        content.badge = "Transaction open · 2 changes"
        main.open(content, title: "Query 1", connection: Fixtures.production.id)
        model.agentStatus = "Claude Code · reading schema"
        var cancelled = false
        let work = model.activity.start("Exporting shop", connection: Fixtures.production.id) { cancelled = true }
        #expect(await eventually { main.statusBar.agent.isHidden == false && main.statusBar.activity.isHidden == false })
        let status = await call(harness, "snapshot", ["include": ["status", "activity"]])["status"] as? [String: Any] ?? [:]
        #expect(status["route"] as? String == "SSH tunnel to db.example.com")
        #expect(status["server"] as? String == "MariaDB 11.8.3")
        #expect(status["transaction"] as? String == "Transaction open · 2 changes")
        #expect(status["activity"] as? String == "Exporting shop")
        #expect(status["agent"] as? String == "Claude Code · reading schema")
        // The activity popover cancels the work; once it ends, AirSQL is idle.
        let activity = try #require(await element(harness, "status.activity"))
        #expect(await call(harness, "click", ["x": activity.center.0, "y": activity.center.1]).error == nil)
        let popover = await call(harness, "wait", ["until": "popover", "timeout": 10])
        #expect(popover["popovers"] as? [String] == ["activity.popover"])
        let cancel = await call(harness, "press", ["id": "activity.cancel", "in": "popover"])
        #expect(cancel.error == nil, "\(cancel.error ?? "")")
        #expect(cancelled)
        work.end()
        #expect(await call(harness, "wait", ["until": "idle", "timeout": 10]).error == nil)
        main.statusBar.activity.shown?.close()
    }

    @Test func settingsChangeTheSavedSettings() async throws {
        let model = testModel()
        let settings = SettingsWindowController(model: model)
        keptWindows.append(settings)
        let window = try #require(settings.window)
        window.setFrameOrigin(NSPoint(x: -21000, y: -21000))
        window.orderFront(nil)
        let (_, harness) = appWindow(model, windows: { [window] })
        settings.show(.safety)
        #expect(await call(harness, "set", ["id": "settings.safety.consoleWrite", "value": true]).error == nil)
        #expect(model.data.settings.safety.askBeforeConsoleWrite)
        #expect(await call(harness, "set", ["id": "settings.safety.agentRowCap", "value": "250"]).error == nil)
        #expect(model.data.settings.safety.agentRowCap == 250)
        let sync = try #require(await element(harness, "settings.safety.sync", in: "window:Safety"))
        #expect(sync.json["enabled"] as? Bool == false && sync.json["value"] as? Int == 1)
        #expect(await call(harness, "press", ["id": "settings.safety.restoreDefaults"]).error == nil)
        #expect(model.data.settings.safety == SafetySettings())
        settings.show(.general)
        #expect(await call(harness, "set", ["id": "settings.appearance", "value": "Dark"]).error == nil)
        #expect(model.data.settings.appearance == .dark)
        settings.show(.grid)
        #expect(await call(harness, "set", ["id": "settings.rowsPerPage", "value": "999999"]).error == nil)
        #expect(model.data.settings.rowsPerPage == 100_000)  // the largest allowed
        settings.show(.agents)
        #expect(await call(harness, "set", ["id": "settings.agentsAllowed", "value": true]).error == nil)
        #expect(model.data.settings.agentsAllowed)
        window.orderOut(nil)
    }

    @Test func sqlPreviewWaitsForTheTypedNameAndReportsTheChoice() async throws {
        let model = testModel(Fixtures.shop)
        let (main, harness) = appWindow(model)
        let window = try #require(main.window)
        var request = SQLPreviewRequest(change: ChangeSQL(title: "Drop shop", statements: ["DROP DATABASE `shop`"],
                                                          connection: Fixtures.production.id),
                                        heading: "Drop the database shop?", caption: "Every table in it is deleted.")
        request.actionTitle = "Drop"
        request.destructive = true
        request.typeToConfirm = "shop"
        request.warnings = ["orders uses MyISAM: a failed change can't be rolled back."]
        var result: SQLPreviewResult?
        SQLPreviewSheet.show(request, connection: Fixtures.production, on: window) { result = $0 }
        let sheet = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        let drop = (sheet["buttons"] as? [[String: Any]])?.first { $0["title"] as? String == "Drop" }
        #expect(drop?["enabled"] as? Bool == false && drop?["destructive"] as? Bool == true)
        #expect(drop?["help"] as? String == "Type “shop” first")
        #expect(!(sheet["fields"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == "preview.saveChangeset" },
                "only requests that offer a changeset show the box")
        let elements = await call(harness, "snapshot", ["include": ["elements"], "in": "sheet"])
        let ids = (elements["elements"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        #expect(ids.contains("preview.production") && ids.contains("preview.warning") && ids.contains("preview.sql"))
        #expect(await call(harness, "press", ["title": "Drop"]).error != nil)
        #expect(await call(harness, "set", ["id": "preview.confirm", "value": "shop"]).error == nil)
        #expect(await call(harness, "press", ["title": "Drop"]).error == nil)
        #expect(await eventually { result != nil })
        #expect(result?.approved == true && result?.saveAsChangeset == false)
        #expect(await call(harness, "wait", ["until": "no_sheet", "timeout": 10]).error == nil)

        // A request that offers a changeset shows the box; an agent's request names the agent and can be declined.
        var agentRequest = SQLPreviewRequest(change: ChangeSQL(title: "Apply", statements: ["UPDATE `t` SET `a` = 1 WHERE `id` = 2"],
                                                               connection: Fixtures.local.id),
                                             heading: "Apply 1 change to shop.t?", caption: "It runs in one transaction.")
        agentRequest.agent = "Claude Code"
        agentRequest.offersChangeset = true
        result = nil
        SQLPreviewSheet.show(agentRequest, connection: Fixtures.local, on: window) { result = $0 }
        let agentSheet = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        #expect((agentSheet["text"] as? String)?.contains("Asked by Claude Code") == true)
        #expect(titles(agentSheet["buttons"]).contains("Decline"))
        let fields = agentSheet["fields"] as? [[String: Any]] ?? []
        #expect(fields.contains { $0["id"] as? String == "preview.saveChangeset" })
        #expect(await call(harness, "press", ["title": "Decline"]).error == nil)
        #expect(await eventually { result != nil })
        #expect(result?.approved == false)
    }

    @Test func sqlPreviewColoursTheSQL() {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        func colour(_ part: String, in sql: String, noBackslashEscapes: Bool = false) -> NSColor? {
            let text = SQLPreviewSheet.coloured(sql, font: font, noBackslashEscapes: noBackslashEscapes)
            return text.attribute(.foregroundColor, at: (sql as NSString).range(of: part).location, effectiveRange: nil) as? NSColor
        }
        let sql = "UPDATE `t` SET a = CONCAT(b, 'x\\'y'), n = 1.5 -- why\nWHERE id IN (2) /*!50000 AND c */"
        #expect(colour("UPDATE", in: sql) == .sqlKeyword && colour("`t`", in: sql) == .sqlIdentifier)
        #expect(colour("CONCAT", in: sql) == .sqlFunction && colour("b,", in: sql) == .sqlIdentifier)
        #expect(colour("'x", in: sql) == .sqlString && colour("1.5", in: sql) == .sqlNumber && colour("=", in: sql) == .labelColor)
        #expect(colour("-- why", in: sql) == .sqlComment && colour("/*!50000", in: sql) == .sqlComment)
        #expect(colour("AND", in: sql) == .sqlKeyword)
        // The string ends where the session's server will end it.
        #expect(colour("FROM", in: "SELECT 'C:\\' FROM t", noBackslashEscapes: true) == .sqlKeyword)
        #expect(colour("FROM", in: "SELECT 'C:\\' FROM t'", noBackslashEscapes: false) == .sqlString)
    }

    /// A SHA-256 fingerprint shows as two lines of 16 pairs, broken by the field's width alone: the text copied is the
    /// fingerprint as it is.
    @Test func fingerprintsShowAsTwoLinesOfSixteenPairs() {
        let fingerprint = ConnectionsScreens.certificateFingerprint
        let field = fingerprintField(fingerprint)
        #expect(field.stringValue == fingerprint && field.isSelectable && field.lineBreakMode == .byCharWrapping)
        // Two lines as wide as 48 characters (16 pairs and their colons), and the label's 2 pt a side: the 49th went on.
        let font = field.font ?? .systemFont(ofSize: 10)
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width, size = field.fittingSize
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        #expect(abs(size.height - 2 * lineHeight) < lineHeight / 2, "\(size)")
        #expect(size.width >= 48 * advance + 4 && size.width < 49 * advance + 4, "\(size) \(advance)")
    }

    @Test func trustAndPasswordSheetsAnswer() async throws {
        let model = testModel(Fixtures.shop)
        let (main, harness) = appWindow(model)
        let window = try #require(main.window)
        var trusted: Bool?
        showTrust(server: "db.example.com", fingerprint: "SHA256:" + String(repeating: "AB:", count: 31) + "CD",
                  details: ["Issued to db.example.com by Example Private CA", "Valid until 1 Jan 2030"], on: window) { trusted = $0 }
        let trust = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        #expect((trust["title"] as? String)?.contains("db.example.com") == true)
        #expect(Set(titles(trust["buttons"])).isSuperset(of: ["Trust", "Cancel", "Help"]))
        #expect(await call(harness, "press", ["title": "Trust"]).error == nil)
        #expect(await eventually { trusted == true })
        #expect(await call(harness, "wait", ["until": "no_sheet", "timeout": 10]).error == nil)

        var answer: (String?, Bool)?
        showPasswordPrompt(for: "Production · shop", user: "app", retry: true, canRemember: true, on: window) { answer = ($0, $1) }
        let prompt = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        #expect((prompt["text"] as? String)?.contains("didn't accept") == true)
        #expect(await call(harness, "set", ["id": "password", "value": "hunter2"]).error == nil)
        let secure = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        let field = (secure["fields"] as? [[String: Any]])?.first { $0["secure"] as? Bool == true }
        #expect(field?["value"] as? String == "•••(7)")  // never the password itself
        #expect(await call(harness, "set", ["id": "password.remember", "value": true]).error == nil)
        #expect(await call(harness, "press", ["title": "Connect"]).error == nil)
        #expect(await eventually { answer != nil })
        #expect(answer?.0 == "hunter2" && answer?.1 == true)
    }

    @Test func harnessSnapshotsScreenshotsAndExplainsDisabledCommands() async throws {
        let model = testModel(Fixtures.shop)
        let (main, harness) = appWindow(model)
        let shot = await call(harness, "screenshot")
        let image = try #require(shot.image)
        #expect(image.pixelsWide == Int(main.window!.frame.width) && image.pixelsHigh == Int(main.window!.frame.height))
        let snapshot = await call(harness, "snapshot")
        let sections = (snapshot["sidebar"] as? [String: Any])?["sections"] as? [[String: Any]] ?? []
        #expect(sections.flatMap { ($0["connections"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }.count == 4)
        // Lanes' commands are in the menu bar; nothing handles them yet, and the menu says so.
        let run = await call(harness, "menu", ["path": "Query > Run Statement"])
        #expect(run.error?.contains("disabled") == true)
        #expect(await call(harness, "menu", ["path": "Nope > Nothing"]).error?.contains("No menu item") == true)
        #expect(await call(harness, "wait", ["until": "idle", "timeout": 5]).error == nil)
        #expect(await call(harness, "nope").error?.contains("no tool") == true)
        // Filter Sidebar focuses the filter; typed text narrows the connections.
        #expect(await call(harness, "menu", ["path": "View > Filter Sidebar"]).error == nil)
        #expect(main.window?.firstResponder === main.sidebar.filter.currentEditor())
        #expect(await call(harness, "type", ["text": "Prod"]).error == nil)
        #expect(await eventually {
            main.sidebar.reload()
            return main.model.sections(filter: main.sidebar.filter.stringValue).flatMap(\.connections).map(\.name) == ["Production · shop"]
        })
        #expect(await call(harness, "wait", ["until": "text", "text": "Production · shop", "timeout": 5]).error == nil)
    }
}
