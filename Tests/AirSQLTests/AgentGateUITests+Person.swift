import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// What stays the person's whatever an agent tries (plan §2.8): settings, saved connections and their person-only
/// parts, the clipboard, a production console's text, and files.
extension AppTests.AgentGateUITests {
    @Test func settingsAreToLookAt() async throws {
        let (_, _, service) = try await Self.agents()
        let model = service.model
        let settings = SettingsWindowController(model: model)
        keptWindows.append(settings)
        settings.window?.orderFront(nil)
        settings.window?.setFrameOrigin(NSPoint(x: -21000, y: -21000))
        settings.show(.safety)
        settings.window?.layoutIfNeeded()
        let window = try #require(settings.window)
        defer {
            service.close()
            settings.close()
        }
        service.harness = AgentServer(main: service.main, model: model, windows: { [window] })
        let person = AgentServer(main: service.main, model: model, windows: { [window] })
        let content = try #require(window.contentView)
        let box = try #require(find(NSButton.self, id: "settings.safety.agentChanges", in: content))
        for (tool, arguments) in [("set", ["id": "settings.safety.agentChanges", "value": false]),
                                  ("press", ["id": "settings.safety.agentChanges"]), ("press", ["id": "settings.safety.restoreDefaults"]),
                                  ("set", ["id": "settings.safety.agentRowCap", "value": "1000000", "in": "window:Safety"]),
                                  ("key", ["combo": "space", "in": "window:Safety"])] as [(String, [String: Any])] {
            let refused = await agentCall(service, tool, arguments)
            #expect(refused.error?.contains("Settings are the person's") == true, "\(tool) \(arguments): \(refused.error ?? "let through")")
        }
        #expect(box.state == .on && model.data.settings.safety == SafetySettings())
        // The person's own click still works.
        #expect(await call(person, "set", ["id": "settings.safety.agentChanges", "value": false, "in": "window:Safety"]).error == nil)
        #expect(!model.data.settings.safety.askBeforeAgentChanges)
    }

    @Test func savedConnectionsKeepWhatOnlyThePersonChanges() async throws {
        let (main, harness, service) = try await Self.agents()
        defer { service.close() }
        let model = service.model
        model.setSavedPassword(Fixtures.local.id.uuidString, "secret")
        main.sidebar.select([Fixtures.local.id])
        let before = model.data
        for path in ["Connection > Colour > Production", "Connection > Duplicate"] {
            let refused = await agentCall(service, "menu", ["path": path])
            #expect(refused.error?.hasPrefix("Only the person at the Mac can change") == true, "\(path): \(refused.error ?? "let through")")
        }
        // The connection editor opens for an agent, but its Save keeps nothing of theirs.
        #expect(await agentCall(service, "menu", ["path": "File > New Connection"]).error == nil)
        for (id, value) in [("editor.name", "Sneaky"), ("editor.host", "db.example.com"), ("editor.user", "root")] {
            #expect(await agentCall(service, "set", ["id": id, "value": value]).error == nil, "\(id)")
        }
        let saved = await agentCall(service, "press", ["id": "editor.save"])
        #expect(saved.error?.contains("a connection's server, route, login") == true, "\(saved.error ?? "let through")")
        #expect(await agentCall(service, "set", ["id": "editor.password", "value": "guess"]).error == nil)
        let password = await agentCall(service, "press", ["id": "editor.save"])
        #expect(password.error?.contains("can save a password") == true, "\(password.error ?? "let through")")
        #expect(main.window?.attachedSheet != nil && model.data == before)
        #expect(await agentCall(service, "press", ["id": "editor.cancel"]).error == nil)
        _ = await agentCall(service, "wait", ["until": "no_sheet", "timeout": 5])
        main.sidebar.select([Fixtures.local.id])  // a refused Duplicate selects the copies it didn't make: none
        #expect(await agentCall(service, "menu", ["path": "Connection > Delete…"]).error == nil)
        _ = await agentCall(service, "wait", ["until": "sheet", "timeout": 5])
        let delete = await agentCall(service, "press", ["title": "Delete"])
        #expect(delete.error?.contains("“Delete” can't be undone") == true, "\(delete.error ?? "let through")")
        #expect(model.data == before && model.savedPassword(Fixtures.local.id.uuidString) == "secret")

        // What the connection editor (the connections lane's) would save for an agent's request goes back too.
        var local = try #require(model.connection(Fixtures.local.id))
        let changes: [(String, (inout SavedConnection) -> Void)] = [
            ("what agents may do", { $0.agentAccess = .schemaReadAnalytics }), ("colour", { $0.colour = .none }),
            ("read-only", { $0.readOnly = true }), ("safety settings", { $0.safety = SafetySettings.production }),
            ("server, route", { $0.host = "elsewhere.example.com" }), ("client tools", { $0.clientPath = "/tmp/mysql" }),
            ("startup SQL", { $0.startupSQL = "DROP TABLE orders" }), ("TLS", { $0.tls.mode = .off }),
            ("route", { $0.jumpHosts.append(SSHHop()) }),
        ]
        let notes = AgentGuard.Notes()
        AgentGuard.$notes.withValue(notes) { AgentGate.$agent.withValue("Claude Code") {
            for (what, change) in changes {
                var changed = local
                change(&changed)
                model.save(changed)
                #expect(notes.refusal?.contains(what) == true, "\(what): \(notes.refusal ?? "let through")")
            }
            model.data.settings.agentsAllowed = false
            model.data.settings.safety.askBeforeAgentChanges = false
            local.name = "Renamed"
            model.save(local)
        } }
        #expect(model.data == before && model.data.settings.agentsAllowed)
        // With the person's "ask" off, an agent may rename; person-only things stay theirs.
        model.data.settings.safety.askBeforeAgentChanges = false
        AgentGate.$agent.withValue("Claude Code") {
            model.save(local)
            local.colour = .test
            model.save(local)
        }
        #expect(model.connection(Fixtures.local.id)?.name == "Renamed" && model.connection(Fixtures.local.id)?.colour == .development)
        // No tool reaches settings or access levels.
        let tools = AgentTools.list.compactMap { $0["name"] as? String }
        #expect(!tools.contains { $0.contains("setting") || $0.contains("access") || $0.contains("connection") })
        #expect(await agentCall(service, "set_access", ["connection": "Local", "access": "schemaRead"]).error?.contains("no tool") == true)
        _ = harness
    }

    @Test func theClipboardAndAProductionConsoleAreThePersons() async throws {
        let (main, harness, service) = try await Self.agents()
        defer {
            service.close()
            ConsoleViewController.openConnection = { _ in nil }
        }
        let console = try await Self.console(main, harness, on: Fixtures.production.id)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("DROP TABLE orders", forType: .string)
        for (tool, arguments) in [("menu", ["path": "Edit > Paste"]), ("key", ["combo": "cmd+v"])] as [(String, [String: Any])] {
            let refused = await agentCall(service, tool, arguments)
            #expect(refused.error?.contains("The clipboard is the person's") == true, "\(tool): \(refused.error ?? "let through")")
        }
        for (tool, arguments) in [("menu", ["path": "AirSQL > Quit AirSQL"]), ("key", ["combo": "cmd+q"])] as [(String, [String: Any])] {
            #expect(await agentCall(service, tool, arguments).error?.contains("can quit AirSQL") == true, "\(tool)")
        }
        let keyed = await agentCall(service, "key", ["combo": "d"])
        #expect(keyed.error?.contains("needs the person's OK") == true, "\(keyed.error ?? "let through")")

        let typing = Task { await agentCall(service, "type", ["text": "DELETE FROM orders"]) }
        #expect(await eventually(timeout: 5) { Self.preview(main) != nil })
        let sheet = try #require(Self.preview(main))
        #expect(sheet.window?.title == "Put this text in a query tab of Production · shop?")
        let content = try #require(sheet.window?.contentView)
        #expect(find(NSTextView.self, id: "preview.sql", in: content)?.string == "DELETE FROM orders", "the text exactly")
        #expect(await agentCall(service, "press", ["id": "preview.run"]).error != nil)
        #expect(await call(harness, "press", ["id": "preview.cancel"]).error == nil)
        #expect(await typing.value.error?.contains("declined") == true && console.editor.string.isEmpty)

        let setting = Task { await agentCall(service, "set", ["id": "console.editor", "value": "SELECT 1"]) }
        #expect(await eventually(timeout: 5) { Self.preview(main) != nil })
        #expect(await call(harness, "press", ["id": "preview.run"]).error == nil)
        #expect(await setting.value.error == nil && console.editor.string == "SELECT 1")
        // Find and Replace puts the agent's text in too: refused.
        #expect(await agentCall(service, "menu", ["path": "Edit > Find > Find and Replace…"]).error == nil)
        for (id, value) in [("find.search", "1"), ("find.replace", "1; DROP TABLE orders")] {
            #expect(await agentCall(service, "set", ["id": id, "value": value]).error == nil, "\(id)")
        }
        let replaced = await agentCall(service, "press", ["id": "find.replaceAll"])
        #expect(replaced.error?.contains("Replacing text in a production console") == true, "\(replaced.error ?? "let through")")
        #expect(console.editor.string == "SELECT 1")
        // So are the commands that change it: deleting a WHERE line changes what the person runs.
        for (tool, arguments) in [("menu", ["path": "Edit > Lines > Delete Line"]), ("menu", ["path": "Edit > Comment Lines"]),
                                  ("menu", ["path": "Edit > Cut"]), ("key", ["combo": "ctrl+d"])] as [(String, [String: Any])] {
            console.editor.setSelectedRange(NSRange(location: 0, length: 3))
            main.window?.makeFirstResponder(console.editor)
            let refused = await agentCall(service, tool, arguments)
            #expect(refused.error?.contains("Changing a production console's text") == true, "\(arguments): \(refused.error ?? "let through")")
        }
        #expect(throws: (any Error).self, "the history is the person's clipboard") {
            try AgentGate.$agent.withValue("Claude Code") { try harness.checkAgentMayChoose(Commands.pasteFromHistory.action, target: console.editor) }
        }
        console.editor.setSelectedRange(NSRange(location: 0, length: 0))
        let killed = await agentCall(service, "key", ["combo": "ctrl+k"])
        #expect(killed.error?.contains("needs the person's OK") == true, "the text view's own: \(killed.error ?? "let through")")
        #expect(console.editor.string == "SELECT 1")
        // The person's own commands, and an agent's that only move the cursor, still work.
        #expect(await agentCall(service, "menu", ["path": "Edit > Statements > Select Statement"]).error == nil)
        #expect(await call(harness, "menu", ["path": "Edit > Lines > Duplicate Line"]).error == nil)
        #expect(console.editor.string == "SELECT 1\nSELECT 1")
    }

    /// An agent's reach is one connection at a time: it can't turn on the history of every connection, and if the person
    /// has it on, it reads none of it.
    @Test func everyConnectionsHistoryIsThePersons() async throws {
        let (main, harness, service) = try await Self.agents()
        defer { service.close() }
        var production = Fixtures.production
        production.agentAccess = .schemaRead
        service.model.save(production)
        let console = try await Self.console(main, harness, on: Fixtures.production.id)
        defer { ConsoleViewController.openConnection = { _ in nil } }
        QueryHistory.shared.add(HistoryEntry(sql: "SELECT 'Elsewhere secret'", connection: Fixtures.staging.id))
        QueryHistory.shared.flush()
        console.showHistory(nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        let sheet = try #require(main.window?.attachedSheet)
        let content = try #require(sheet.contentView)
        let box = try #require(find(NSButton.self, id: "history.all", in: content))
        let list = try #require(find(NSTableView.self, id: "history.list", in: content))

        let refused = await agentCall(service, "press", ["id": "history.all"])
        #expect(refused.error?.contains("Only the person at the Mac can list every connection's statements") == true, "\(refused.error ?? "let through")")
        #expect(box.state == .off && list.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("connection"))?.isHidden == true)
        let what: [String: Any] = ["include": ["elements", "sheets"]]
        func agentSees() async -> String { "\((await agentCall(service, "snapshot", what)).json)" }
        #expect(await !agentSees().contains("Elsewhere secret"))

        // The person turns it on: they read it, and an agent still doesn't, though it may read this connection's rows.
        #expect(await call(harness, "press", ["id": "history.all"]).error == nil)
        #expect(box.state == .on)
        _ = await eventually(timeout: 5) { list.numberOfRows > 0 }
        #expect("\((await call(harness, "snapshot", what)).json)".contains("Elsewhere secret"))
        #expect(await !agentSees().contains("Elsewhere secret"))
        QueryHistory.shared.clear(Fixtures.staging.id)
        _ = await call(harness, "press", ["id": "history.cancel"])
    }

    @Test func filesAreThePersons() async throws {
        let (main, harness, service) = try await Self.agents()
        defer {
            service.close()
            ConsoleViewController.openConnection = { _ in nil }
        }
        let console = try await Self.console(main, harness, on: Fixtures.local.id)
        let file = URL(fileURLWithPath: try scratch() + "/query.sql")
        try "SELECT 1".write(to: file, atomically: true, encoding: .utf8)
        console.editor.setText("SELECT 1")
        console.setFile(file, savedText: "SELECT 1")
        #expect(await agentCall(service, "set", ["id": "console.editor", "value": "DROP TABLE orders"]).error == nil)
        let save = await agentCall(service, "key", ["combo": "cmd+s"])
        #expect(save.error?.contains("only the person at the Mac can save") == true, "\(save.error ?? "let through")")
        #expect(try String(contentsOf: file, encoding: .utf8) == "SELECT 1")
    }
}
