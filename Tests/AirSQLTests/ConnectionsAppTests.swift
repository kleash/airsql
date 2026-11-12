import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

// The connections lane's screens driven as a person would: the editor's tabs, saving and its checks, connecting and
// its failure, folders, and the ssh config import.
extension AppTests {
    /// The editor sheet shown on `main`, once it is there.
    private func editor(_ main: MainWindowController) async -> ConnectionEditor? {
        _ = await eventually(timeout: 10) { main.window?.attachedSheet?.windowController is ConnectionEditor }
        return main.window?.attachedSheet?.windowController as? ConnectionEditor
    }

    @Test func editorChangesEveryTabAndSavesThePasswordInTheKeychain() async throws {
        let model = testModel(Fixtures.shop)
        let (main, harness) = appWindow(model)
        _ = await call(harness, "select", ["pane": "sidebar", "names": ["Staging · shop"]])
        #expect(await call(harness, "menu", ["path": "Connection > Edit…"]).error == nil)
        let sheet = try #require(await editor(main))
        #expect(sheet.tab == .general)
        for (id, value) in [("editor.name", "Staging two"), ("editor.host", "10.20.0.16"), ("editor.port", "3307"),
                            ("editor.password", "s3cret"), ("editor.database", "shop")] {
            #expect(await call(harness, "set", ["id": id, "value": value]).error == nil, "\(id)")
        }
        #expect(await call(harness, "press", ["title": "TLS"]).error == nil)
        #expect(sheet.tab == .tls)
        #expect(await call(harness, "set", ["id": "editor.tlsMode", "value": "Encrypt, check the certificate"]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.cleartext", "value": true]).error == nil)
        #expect(await call(harness, "press", ["title": "SSH and Proxy"]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.jump0.host", "value": "bastion.example.com"]).error == nil)
        #expect(await call(harness, "press", ["id": "editor.addJump"]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.jump1.host", "value": "jump.example.com"]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.ssh.host", "value": "db-gw.example.com"]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.ssh.login", "value": "Password"]).error == nil)
        #expect(await call(harness, "press", ["title": "Options"]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.readOnly", "value": true]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.startupSQL", "value": "SET time_zone = '+00:00';"]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.databaseFilter", "value": "shop, reports_*"]).error == nil)
        #expect(await call(harness, "press", ["title": "Agents"]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.agentAccess", "value": "Schema + read"]).error == nil)
        #expect(await call(harness, "press", ["id": "editor.save"]).error == nil)
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])

        let saved = try #require(model.connection(Fixtures.staging.id))
        #expect(saved.name == "Staging two" && saved.host == "10.20.0.16" && saved.port == 3307 && saved.database == "shop")
        #expect(saved.tls.mode == .verifyCA && saved.cleartextLogin && saved.readOnly && saved.agentAccess == .schemaRead)
        #expect(saved.jumpHosts.map(\.host) == ["bastion.example.com", "jump.example.com"])
        #expect(saved.sshHost.host == "db-gw.example.com" && saved.sshHost.login == .password)
        #expect(saved.startupSQL == "SET time_zone = '+00:00';" && saved.databaseFilter == "shop, reports_*")
        #expect(await eventually(timeout: 10) { model.savedPassword(Fixtures.staging.id.uuidString) == "s3cret" })
    }

    @Test func editorsPathLineFollowsTheRouteAndOptionsKeepTheConnectionsTools() async throws {
        let model = testModel(Fixtures.shop)
        let (main, harness) = appWindow(model)
        _ = await call(harness, "select", ["pane": "sidebar", "names": ["Staging · shop"]])
        #expect(await call(harness, "menu", ["path": "Connection > Edit…"]).error == nil)
        let sheet = try #require(await editor(main))
        #expect(await call(harness, "press", ["title": "SSH and Proxy"]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.jump0.host", "value": "bastion.example.com"]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.ssh.host", "value": "gateway.example.com"]).error == nil)
        #expect(shownText("editor.routePath", in: sheet.window)?.contains("SSH bastion.example.com → SSH gateway.example.com") == true,
                "\(shownText("editor.routePath", in: sheet.window) ?? "")")
        // A tool of its own, checked as Settings ▸ Client Tools checks it.
        #expect(await call(harness, "press", ["title": "Options"]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.clientPath", "value": "/nonexistent/bin/mysql"]).error == nil)
        #expect(await eventually(timeout: 10) {
            shownText("editor.clientFound", in: sheet.window)?.contains("isn't there or can't be run") == true
        }, "\(shownText("editor.clientFound", in: sheet.window) ?? "")")
        #expect(sheet.draft.clientPath == "/nonexistent/bin/mysql")
        #expect(await call(harness, "press", ["id": "editor.save"]).error == nil)
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        #expect(model.connection(Fixtures.staging.id)?.clientPath == "/nonexistent/bin/mysql")
    }

    /// A connection's own safety checks start from the settings that applied (Settings ▸ Safety, its row cap changed
    /// here) and cover every switch and limit there: the restore, sort and close prompts and the agents' limits too.
    @Test func ownSafetyChecksStartFromSettingsAndCoverEverySwitch() async throws {
        let model = testModel(Fixtures.shop)
        model.data.settings.safety.agentRowCap = 7_777
        let (main, harness) = appWindow(model)
        _ = await call(harness, "select", ["pane": "sidebar", "names": ["Local MariaDB 11.8"]])
        #expect(await call(harness, "menu", ["path": "Connection > Edit…"]).error == nil)
        let sheet = try #require(await editor(main))
        #expect(await call(harness, "press", ["title": "Safety"]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.ownSafety", "value": true]).error == nil)
        #expect(sheet.draft.safety?.agentRowCap == 7_777)
        // Each switch says what it protects against, as Settings ▸ Safety's does.
        let switches = descendants(of: try #require(sheet.window?.contentView)).compactMap { $0 as? NSButton }
            .filter { $0.accessibilityIdentifier().hasPrefix("editor.safety.") }
        #expect(switches.count == 9 && Set(switches.compactMap(\.toolTip)).count == 9, "\(switches.map { $0.toolTip ?? "" })")
        #expect(switches.allSatisfy { $0.toolTip == SafetyPane.tips[$0.accessibilityIdentifier().replacingOccurrences(of: "editor.safety.", with: "")] })
        let changes: [(String, Any)] = [("editor.safety.restore", false), ("editor.safety.unindexedSort", false),
                                        ("editor.safety.warnOnClose", false), ("editor.safety.agentRowCap", "500"),
                                        ("editor.safety.agentTimeout", "20")]
        for (id, value) in changes {
            #expect(await call(harness, "set", ["id": id, "value": value]).error == nil, "\(id)")
        }
        #expect(await call(harness, "press", ["id": "editor.save"]).error == nil)
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        let safety = try #require(model.connection(Fixtures.local.id)?.safety)
        #expect(!safety.askBeforeRiskyRestore && !safety.askBeforeUnindexedSort && !safety.warnOnClose)
        #expect(safety.agentRowCap == 500 && safety.agentTimeout == 20)
        #expect(safety.askBeforeUnboundedWrite && safety.openTransactionMinutes == 15, "the others as Settings ▸ Safety has them")
    }

    /// Unticking Own safety checks with a click while a limit is being typed in: the limit's field used to end its
    /// editing after the checks were gone and write into them, which ended the app.
    @Test func untickingOwnSafetyChecksWhileTypingALimit() async throws {
        let (main, harness) = appWindow(testModel(Fixtures.shop))
        _ = await call(harness, "select", ["pane": "sidebar", "names": ["Local MariaDB 11.8"]])
        #expect(await call(harness, "menu", ["path": "Connection > Edit…"]).error == nil)
        let sheet = try #require(await editor(main))
        #expect(await call(harness, "press", ["title": "Safety"]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.ownSafety", "value": true]).error == nil)
        let window = try #require(sheet.window), content = try #require(window.contentView)
        let cap = try #require(find(NSTextField.self, id: "editor.safety.agentRowCap", in: content))
        let own = try #require(find(NSButton.self, id: "editor.ownSafety", in: content))
        window.makeFirstResponder(cap)
        let typing = try #require(cap.currentEditor() as? NSTextView)
        typing.insertText("500", replacementRange: NSRange(location: 0, length: typing.string.utf16.count))
        AXNode.click(own)  // as a click does it: the field keeps the keyboard
        #expect(sheet.draft.safety == nil && find(NSTextField.self, id: "editor.safety.agentRowCap", in: content) == nil)
        _ = await call(harness, "press", ["id": "editor.cancel"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
    }

    /// The editor's tallest tab (Safety, with the connection's own checks) scrolls within what an 800 pt high screen
    /// leaves, so the sheet fits there; on a taller screen it shows all of it.
    @Test func editorFitsAnEightHundredPointScreen() async throws {
        var connection = Fixtures.routed(long: true)
        connection.safety = connection.safety(defaults: SafetySettings())
        let model = testModel([connection])
        let (main, harness) = appWindow(model)
        let editor = ConnectionEditor.show(connection, isNew: false, model: model, on: try #require(main.window)) { _, _ in }
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        editor.show(.safety)
        let window = try #require(editor.window)
        let tab = try #require(editor.tabHeight).constant
        // 775 pt under the menu bar, the main window's 52 pt title bar and toolbar above the sheet.
        #expect(window.frame.height - tab + ConnectionEditor.tabLimit(screen: 775) <= 775 - 52, "\(window.frame.height) \(tab)")
        let shown = (NSScreen.main?.visibleFrame.height).map(ConnectionEditor.tabLimit) ?? 0
        let sheet = try #require(window.contentView)
        #expect(tab <= shown && find(NSTextField.self, id: "editor.safety.openTransaction", in: sheet) != nil)
        _ = await call(harness, "press", ["id": "editor.cancel"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
    }

    @Test func editorSaysWhatIsMissingAndNewConnectionsGoInTheSelectedFolder() async throws {
        let folder = ConnectionFolder(name: "Clients")
        var local = Fixtures.local
        local.folderID = folder.id
        let model = testModel([local], folders: [folder])
        let (main, harness) = appWindow(model)
        _ = await call(harness, "select", ["pane": "sidebar", "names": ["Local MariaDB 11.8"]])
        #expect(await call(harness, "menu", ["path": "File > New Connection…"]).error == nil)
        let sheet = try #require(await editor(main))
        #expect(sheet.draft.folderID == folder.id)
        _ = await call(harness, "set", ["id": "editor.host", "value": ""])
        _ = await call(harness, "press", ["id": "editor.saveAndConnect"])
        #expect(main.window?.attachedSheet != nil && sheet.status.stringValue.contains("host name"))
        _ = await call(harness, "press", ["title": "SSH and Proxy"])
        _ = await call(harness, "set", ["id": "editor.route", "value": "Proxy, no SSH"])
        _ = await call(harness, "press", ["title": "General"])
        _ = await call(harness, "set", ["id": "editor.host", "value": "db.internal"])
        _ = await call(harness, "press", ["id": "editor.save"])
        #expect(sheet.status.stringValue.contains("proxy"))
        #expect(await call(harness, "press", ["id": "editor.cancel"]).error == nil)
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        #expect(model.data.connections.count == 1)
    }

    /// A new connection starts with TLS off only while it goes straight to this Mac: another host or a route brings the
    /// strict check back, and what the person sets stays.
    @Test func aNewConnectionsTLSFollowsItsHostUntilThePersonSetsIt() async throws {
        let model = testModel([])
        let (main, harness) = appWindow(model)
        let editor = ConnectionEditor.show(SavedConnection(host: "127.0.0.1", user: "root"), isNew: true, model: model,
                                           on: try #require(main.window)) { _, _ in }
        #expect(editor.draft.tls.mode == .off)
        editor.draft.host = "db.example.com"
        #expect(editor.draft.tls.mode == .verifyIdentity)
        editor.draft.host = "LOCALHOST"
        #expect(editor.draft.tls.mode == .off)
        editor.draft.route = .ssh
        #expect(editor.draft.tls.mode == .verifyIdentity, "127.0.0.1 through a route is the far end's")
        editor.draft.route = .direct
        editor.draft.tls.mode = .required
        editor.draft.host = "127.0.0.1"
        #expect(editor.draft.tls.mode == .required, "the person's choice stays")
        _ = await call(harness, "press", ["id": "editor.cancel"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])

        // A connection already saved keeps its TLS whatever its host says.
        var saved = SavedConnection(host: "db.example.com", user: "root")
        saved.tls.mode = .verifyIdentity
        let existing = ConnectionEditor.show(saved, isNew: false, model: model, on: try #require(main.window)) { _, _ in }
        existing.draft.host = "127.0.0.1"
        #expect(existing.draft.tls.mode == .verifyIdentity)
        _ = await call(harness, "press", ["id": "editor.cancel"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
    }

    /// Import lists a file's connections with ticks: one that is already here starts unticked.
    @Test func importListsAFilesConnectionsAndLeavesOutThoseAlreadyHere() async throws {
        var here = SavedConnection(name: "Here", host: "db.example.com", user: "app")
        here.database = "shop"
        let model = testModel([here])
        let (main, harness) = appWindow(model)
        let file = URL(fileURLWithPath: try scratch() + "/connections.json")
        try ConnectionImport.export([here, SavedConnection(name: "New", host: "other.example.com", user: "app")]).write(to: file)
        main.importConnections(from: file)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        _ = await call(harness, "press", ["title": "Import"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        #expect(model.data.connections.map(\.displayName).sorted() == ["Here", "New"])
    }

    /// A connect that fails says why in a sheet, and the sidebar marks the connection; Disconnect is off again.
    @Test func aFailedConnectIsReported() async throws {
        var nowhere = SavedConnection(name: "Nowhere", host: "127.0.0.1", port: 1, user: "root")
        nowhere.tls.mode = .off
        let model = testModel([nowhere])
        let (main, harness) = appWindow(model)
        _ = await call(harness, "select", ["pane": "sidebar", "names": ["Nowhere"]])
        #expect(await call(harness, "menu", ["path": "Connection > Connect"]).error == nil)
        #expect(await eventually(timeout: 30) { main.window?.attachedSheet != nil })
        if case .failed(let reason)? = model.states[nowhere.id] {
            #expect(reason.hasPrefix("Can't connect to the server"), "\(reason)")
        } else {
            Issue.record("not failed: \(String(describing: model.states[nowhere.id]))")
        }
        #expect(model.activity.isIdle)
        // Try Again connects again and fails again; Edit Connection… opens the settings; Close ends it.
        _ = await call(harness, "press", ["title": "Try Again"])
        #expect(await eventually(timeout: 30) { main.window?.attachedSheet != nil && model.activity.isIdle })
        _ = await call(harness, "press", ["title": "Edit Connection…"])
        #expect(await eventually(timeout: 10) { main.window?.attachedSheet?.windowController is ConnectionEditor })
        _ = await call(harness, "press", ["id": "editor.cancel"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        _ = await call(harness, "menu", ["path": "Connection > Connect"])
        #expect(await eventually(timeout: 30) { main.window?.attachedSheet != nil })
        _ = await call(harness, "press", ["title": "Close"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        let item = Commands.disconnect.item()
        #expect(main.validateMenuItem(item) == false)
    }

    /// MongoDB in the editor: its port, and none of MySQL's own settings (cleartext login, compression, time zone,
    /// isolation, startup SQL, client tools); back to MySQL they come back.
    @Test func theEditorLeavesOutMySQLsSettingsForMongoDB() async throws {
        let docs = SavedConnection(name: "Docs", host: "db.example.com", user: "app")
        let model = testModel([docs])
        let (main, harness) = appWindow(model)
        _ = await call(harness, "select", ["pane": "sidebar", "names": ["Docs"]])
        #expect(await call(harness, "menu", ["path": "Connection > Edit…"]).error == nil)
        let sheet = try #require(await editor(main))
        let window = try #require(sheet.window)
        #expect(await call(harness, "set", ["id": "editor.engine", "value": "MongoDB"]).error == nil)
        #expect(sheet.draft.engine == .mongodb)
        #expect(find(NSTextField.self, id: "editor.port", in: window.contentView!)?.placeholderString == "27017")
        #expect(await call(harness, "press", ["title": "TLS"]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.tlsMode", "value": "Encrypt, check the certificate"]).error == nil)
        #expect(find(NSButton.self, id: "editor.cleartext", in: window.contentView!) == nil)
        #expect(await call(harness, "press", ["title": "Options"]).error == nil)
        for id in ["editor.compress", "editor.timeZone", "editor.startIsolation", "editor.startupSQL", "editor.clientPath", "editor.dumpPath"] {
            #expect(find(NSView.self, id: id, in: window.contentView!) == nil, "\(id)")
        }
        #expect(find(NSView.self, id: "editor.readOnly", in: window.contentView!) != nil)
        #expect(await call(harness, "press", ["title": "General"]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.engine", "value": "MySQL or MariaDB"]).error == nil)
        #expect(await call(harness, "press", ["title": "Options"]).error == nil)
        #expect(find(NSView.self, id: "editor.compress", in: window.contentView!) != nil)
        #expect(await call(harness, "press", ["title": "General"]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.engine", "value": "MongoDB"]).error == nil)
        #expect(await call(harness, "press", ["id": "editor.save"]).error == nil)
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        #expect(model.connection(docs.id)?.engine == .mongodb)
    }

    /// MongoDB's General tab: Paste Address fills the fields and keeps the password for the Keychain (never the file),
    /// says what it understood, warns when the address asks for no TLS and says why a bad one can't be read; the DNS
    /// seed list takes one host without a port and turns TLS on; MySQL's editor has none of it.
    @Test func aPastedMongoDBAddressFillsTheEditorAndTheKeychain() async throws {
        let board = NSPasteboard.general, kept = board.string(forType: .string)
        defer { board.clearContents(); if let kept { board.setString(kept, forType: .string) } }
        func paste(_ text: String) {
            board.clearContents()
            board.setString(text, forType: .string)
        }
        var docs = SavedConnection(name: "Docs", host: "db.example.com", port: 27018, user: "old")
        docs.engine = .mongodb
        docs.mongoHosts = ["m2:27017"]
        docs.tls.mode = .off
        let model = testModel([docs, Fixtures.local])
        let (main, harness) = appWindow(model)
        _ = await call(harness, "select", ["pane": "sidebar", "names": ["Docs"]])
        #expect(await call(harness, "menu", ["path": "Connection > Edit…"]).error == nil)
        let sheet = try #require(await editor(main))
        let content = try #require(sheet.window?.contentView)

        paste("mongodb://a,,b")
        #expect(await call(harness, "press", ["id": "editor.pasteAddress"]).error == nil)
        #expect(sheet.status.stringValue == "That isn't a MongoDB address: The connection string names no server.")
        #expect(sheet.draft.host == "db.example.com")

        paste("mongodb+srv://us%40er:p%40ss%3Aw@cluster0.example.net/sales?authSource=admin&readPreference=secondary")
        #expect(await call(harness, "press", ["id": "editor.pasteAddress"]).error == nil)
        #expect(sheet.draft.mongoSRV && sheet.draft.host == "cluster0.example.net" && sheet.draft.port == nil)
        #expect(sheet.draft.mongoHosts.isEmpty && sheet.draft.user == "us@er" && sheet.draft.database == "sales")
        #expect(sheet.draft.authSource == "admin" && sheet.draft.mongoOptions == "readPreference=secondary")
        #expect(sheet.draft.tls.mode == .verifyIdentity && sheet.password == "p@ss:w")
        #expect(sheet.status.stringValue.hasPrefix("Understood: the servers DNS lists for cluster0.example.net, user us@er"),
                "\(sheet.status.stringValue)")
        #expect(find(NSButton.self, id: "editor.mongoSRV", in: content)?.state == .on)
        #expect(find(NSTextField.self, id: "editor.port", in: content)?.isEnabled == false)
        #expect(find(NSView.self, id: "editor.mongoHosts", in: content) == nil && find(NSView.self, id: "editor.directConnection", in: content) == nil)
        #expect(find(NSTextField.self, id: "editor.mongoOptions", in: content)?.stringValue == "readPreference=secondary")

        // Copy Address: the user, never the password.
        #expect(await call(harness, "press", ["id": "editor.copyAddress"]).error == nil)
        #expect(board.string(forType: .string) == "mongodb+srv://us%40er@cluster0.example.net/sales?tls=true&authSource=admin"
                + "&readPreference=secondary")

        // An address without tls=true: no TLS, and the editor says so.
        paste("mongodb://app@10.1.2.3:27017,10.1.2.4/?replicaSet=rs0")
        #expect(await call(harness, "press", ["id": "editor.pasteAddress"]).error == nil)
        #expect(!sheet.draft.mongoSRV && sheet.draft.host == "10.1.2.3" && sheet.draft.mongoHosts == ["10.1.2.4"])
        #expect(sheet.draft.replicaSet == "rs0" && sheet.draft.tls.mode == .off && sheet.password == "p@ss:w")
        #expect(sheet.status.stringValue.hasSuffix("This server's address doesn't ask for TLS: the connection isn't encrypted."))

        // Direct connection is for one server.
        #expect(await call(harness, "set", ["id": "editor.directConnection", "value": true]).error == nil)
        _ = await call(harness, "press", ["id": "editor.save"])
        #expect(sheet.status.stringValue.hasPrefix("Direct connection talks to one server"))
        #expect(await call(harness, "set", ["id": "editor.directConnection", "value": false]).error == nil)
        // The DNS seed list: one host, no port or other members, TLS on.
        #expect(await call(harness, "set", ["id": "editor.mongoSRV", "value": true]).error == nil)
        #expect(sheet.draft.mongoHosts.isEmpty && sheet.draft.port == nil && sheet.draft.tls.mode == .verifyIdentity)
        #expect(await call(harness, "set", ["id": "editor.mongoSRV", "value": false]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.mongoHosts", "value": "10.1.2.4:27017, [::1]:27019"]).error == nil)
        #expect(await call(harness, "set", ["id": "editor.mongoOptions", "value": "w"]).error == nil)
        _ = await call(harness, "press", ["id": "editor.save"])
        #expect(sheet.status.stringValue == "The option “w” has no value.")
        #expect(await call(harness, "set", ["id": "editor.mongoOptions", "value": "w=majority"]).error == nil)
        #expect(await call(harness, "press", ["id": "editor.save"]).error == nil)
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        let saved = try #require(model.connection(docs.id))
        #expect(saved.mongoHosts == ["10.1.2.4:27017", "[::1]:27019"] && saved.replicaSet == "rs0" && saved.user == "app")
        #expect(await eventually(timeout: 10) { model.savedPassword(docs.id.uuidString) == "p@ss:w" })
        #expect(!String(decoding: try JSONEncoder().encode(model.data), as: UTF8.self).contains("p@ss"))

        // MySQL's editor is as it was.
        _ = await call(harness, "select", ["pane": "sidebar", "names": ["Local MariaDB 11.8"]])
        #expect(await call(harness, "menu", ["path": "Connection > Edit…"]).error == nil)
        let mysql = try #require(await editor(main))
        for id in ["editor.pasteAddress", "editor.copyAddress", "editor.mongoSRV", "editor.mongoHosts", "editor.replicaSet",
                   "editor.directConnection", "editor.authSource", "editor.mongoOptions"] {
            #expect(find(NSView.self, id: id, in: try #require(mysql.window?.contentView)) == nil, "\(id)")
        }
        #expect(find(NSView.self, id: "editor.socket", in: try #require(mysql.window?.contentView)) != nil)
        _ = await call(harness, "press", ["id": "editor.cancel"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
    }

    /// File ▸ New Connection from URL… takes a mongodb:// address too: a new MongoDB connection, filled from it.
    @Test func aNewConnectionFromAMongoDBURL() async throws {
        let board = NSPasteboard.general, kept = board.string(forType: .string)
        defer { board.clearContents(); if let kept { board.setString(kept, forType: .string) } }
        board.clearContents()
        board.setString("mongodb://reader:pw@db1.example.com:27017,db2.example.com/shop?replicaSet=rs1&tls=true", forType: .string)
        let model = testModel([])
        let (main, harness) = appWindow(model)
        main.newConnectionFromURL(nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        #expect(await call(harness, "press", ["title": "Continue"]).error == nil)
        let sheet = try #require(await editor(main))
        #expect(sheet.isNew && sheet.draft.engine == .mongodb && sheet.draft.host == "db1.example.com")
        #expect(sheet.draft.mongoHosts == ["db2.example.com"] && sheet.draft.replicaSet == "rs1" && sheet.password == "pw")
        #expect(sheet.draft.tls.mode == .verifyIdentity)
        _ = await call(harness, "press", ["id": "editor.cancel"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
    }

    /// The lab's replica set set up in the editor as a person would (its members, its name, TLS with the lab's CA,
    /// through the SOCKS proxy), then the standalone from a pasted address: each connects.
    @Test(.enabled(if: MongoLab.enabled)) func aMongoReplicaSetAndStandaloneSetUpInTheEditorConnect() async throws {
        let board = NSPasteboard.general, kept = board.string(forType: .string)
        defer { board.clearContents(); if let kept { board.setString(kept, forType: .string) } }
        let model = testModel([])
        let (main, harness) = appWindow(model)
        func connectNew(_ fill: (ConnectionEditor) async -> Void) async throws -> UUID {
            #expect(await call(harness, "menu", ["path": "File > New Connection…"]).error == nil)
            let sheet = try #require(await editor(main))
            #expect(await call(harness, "set", ["id": "editor.engine", "value": "MongoDB"]).error == nil)
            await fill(sheet)
            let id = sheet.draft.id
            #expect(await call(harness, "press", ["id": "editor.saveAndConnect"]).error == nil)
            #expect(await eventually(timeout: 30) { model.openMongo[id] != nil }, "\(String(describing: model.states[id])) \(sheet.status.stringValue)")
            return id
        }
        let set = try await connectNew { _ in
            for (id, value) in [("editor.name", "Set"), ("editor.host", MongoLab.members[0]), ("editor.port", "27017"),
                                ("editor.mongoHosts", MongoLab.members.dropFirst().map { $0 + ":27017" }.joined(separator: ", ")),
                                ("editor.replicaSet", "rs0"), ("editor.user", MongoLab.airsql.user),
                                ("editor.password", MongoLab.airsql.password)] {
                #expect(await call(harness, "set", ["id": id, "value": value]).error == nil, "\(id)")
            }
            _ = await call(harness, "press", ["title": "TLS"])
            #expect(await call(harness, "set", ["id": "editor.tlsMode", "value": "Encrypt, check certificate and host name"]).error == nil)
            #expect(await call(harness, "set", ["id": "editor.caFile", "value": Lab.caFile]).error == nil)
            _ = await call(harness, "press", ["title": "SSH and Proxy"])
            for (id, value) in [("editor.route", "Proxy, no SSH"), ("editor.proxyKind", "SOCKS5"), ("editor.proxyHost", "127.0.0.1"),
                                ("editor.proxyPort", String(Lab.socksProxy.port)), ("editor.proxyUser", Lab.socksProxy.user),
                                ("editor.proxyPassword", Lab.socksProxy.password)] {
                #expect(await call(harness, "set", ["id": id, "value": value]).error == nil, "\(id)")
            }
        }
        if case .connected(let server)? = model.states[set] { #expect(server.hasSuffix("replica set rs0"), "\(server)") }
        board.clearContents()
        board.setString("mongodb://\(MongoLab.airsql.user):\(MongoLab.airsql.password)@127.0.0.1:\(MongoLab.soloPort)/fixture?authSource=admin",
                        forType: .string)
        let solo = try await connectNew { sheet in
            #expect(await call(harness, "press", ["id": "editor.pasteAddress"]).error == nil)
            #expect(sheet.draft.tls.mode == .off && sheet.password == MongoLab.airsql.password)
        }
        if case .connected(let server)? = model.states[solo] { #expect(server.hasSuffix("standalone"), "\(server)") }
        for id in [set, solo] {
            model.connector.disconnect(id)
            #expect(await eventually(timeout: 10) { model.openMongo[id] == nil })
        }
    }

    /// A MongoDB connection logs in with MongoDB's driver, never MySQL's, and fails in its own words where nothing
    /// listens; SQL's commands say it isn't for them.
    @Test func aMongoDBConnectionFailsInItsOwnWords() async throws {
        var mongo = SavedConnection(name: "Documents", host: "127.0.0.1", port: 1, user: "root")
        mongo.engine = .mongodb
        mongo.tls.mode = .off
        let model = testModel([mongo])
        let (main, harness) = appWindow(model)
        _ = await call(harness, "select", ["pane": "sidebar", "names": ["Documents"]])
        let newQuery = Commands.newQuery.item()
        #expect(main.validateMenuItem(newQuery) == false && newQuery.toolTip == NotForMongo.reason)
        #expect(main.validateMenuItem(Commands.connect.item()))
        #expect(await call(harness, "menu", ["path": "Connection > Connect"]).error == nil)
        #expect(await eventually(timeout: 30) { main.window?.attachedSheet != nil })
        if case .failed(let reason)? = model.states[mongo.id] {
            #expect(reason == "Nothing answers at 127.0.0.1:1.", "\(reason)")
        } else {
            Issue.record("not failed: \(String(describing: model.states[mongo.id]))")
        }
        #expect(model.open[mongo.id] == nil && model.openMongo[mongo.id] == nil && model.activity.isIdle)
        _ = await call(harness, "press", ["title": "Close"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
    }

    @Test func foldersAreMadeRenamedAndDeleted() async throws {
        let model = testModel(Fixtures.shop)
        let (main, harness) = appWindow(model)
        _ = await call(harness, "select", ["pane": "sidebar", "names": ["Staging · shop", "Reports replica"]])
        #expect(await call(harness, "menu", ["path": "Connection > New Folder…"]).error == nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        _ = await call(harness, "set", ["id": "folder.name", "value": "Clients"])
        _ = await call(harness, "press", ["title": "Create"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        let folder = try #require(model.data.folders.first)
        #expect(folder.name == "Clients")
        #expect(Set(model.data.connections.filter { $0.folderID == folder.id }.map(\.id)) == [Fixtures.staging.id, Fixtures.replica.id])
        main.sidebar.outline.selectRowIndexes(IndexSet(integer: try #require(folderRowIndex(main, folder.id))),
                                              byExtendingSelection: false)
        #expect(await call(harness, "menu", ["path": "Connection > Rename Folder…"]).error == nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        _ = await call(harness, "set", ["id": "folder.name", "value": "Customers"])
        _ = await call(harness, "press", ["title": "Rename"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        #expect(model.data.folders.map(\.name) == ["Customers"])
        #expect(await call(harness, "menu", ["path": "Connection > Delete Folder…"]).error == nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        _ = await call(harness, "press", ["title": "Delete"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        #expect(model.data.folders.isEmpty && model.data.connections.count == 4 && model.data.connections.allSatisfy { $0.folderID == nil })
    }

    @Test func importMakesAConnectionForEachTickedHost() async throws {
        let model = testModel(Fixtures.shop)
        let (main, harness) = appWindow(model)
        let file = try scratch() + "/config"
        try "Host bastion\n  HostName bastion.example.com\nHost db-gw\n  ProxyJump bastion\nHost *\n  User x\n"
            .write(toFile: file, atomically: true, encoding: .utf8)
        main.importHosts(from: URL(fileURLWithPath: file))
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        _ = await call(harness, "set", ["id": "import.host.bastion", "value": false])
        _ = await call(harness, "press", ["title": "Import"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        let made = model.data.connections.filter { $0.name == "db-gw" }
        #expect(made.count == 1 && made.first?.route == .ssh && made.first?.sshHost.host == "db-gw")
        #expect(model.data.connections.count == 5 && main.sidebar.selectedConnectionIDs == made.map(\.id))
    }
}

/// The outline row of folder `id`.
extension AppTests {
    /// A deleted connection comes back from the menu without its password, out of a folder that has gone; the list keeps
    /// the last few.
    @Test func aDeletedConnectionComesBack() async throws {
        var saved = SavedConnection(name: "Gone", host: "127.0.0.1", user: "u")
        saved.folderID = UUID()
        let model = testModel([saved])
        model.setSavedPassword(saved.id.uuidString, "secret")
        let (_, harness) = appWindow(model)
        model.delete([saved.id])
        #expect(model.data.connections.isEmpty && model.data.deletedConnections.map(\.id) == [saved.id])
        #expect(await eventually(timeout: 5) { model.savedPassword(saved.id.uuidString) == nil })
        #expect(await call(harness, "menu", ["path": "Connection > Deleted Connections > Gone"]).error == nil)
        #expect(model.connection(saved.id)?.folderID == nil && model.data.deletedConnections.isEmpty)
        #expect(model.savedPassword(saved.id.uuidString) == nil)

        let many = (0..<25).map { SavedConnection(name: "c\($0)") }
        model.data.connections = many
        model.delete(Set(many.map(\.id)))
        #expect(model.data.deletedConnections.count == AppModel.deletedKept)
    }

    /// File ▸ Connect To connects the one chosen, as `--connect` does at launch.
    @Test func connectToAndTheLaunchSwitchConnectByName() async throws {
        let one = SavedConnection(name: "One", host: "127.0.0.1", port: 1, user: "u")
        let two = SavedConnection(name: "Two", host: "127.0.0.1", port: 1, user: "u")
        let model = testModel([one, two])
        let (main, harness) = appWindow(model)
        #expect(await call(harness, "menu", ["path": "File > Connect To > One"]).error == nil)
        #expect(model.states[one.id] != nil && model.states[two.id] == nil)
        model.connector.cancel(one.id)
        model.connector.connectAtLaunch(on: main.window, arguments: ["AirSQL", "--connect", "Two"])
        #expect(model.states[two.id] != nil)
        model.connector.cancel(two.id)
    }

    /// At launch only what was chosen connects, never Production; the editor says why Production can't.
    @Test func connectingAtLaunchLeavesOutProduction() async throws {
        var chosen = SavedConnection(name: "Chosen", host: "127.0.0.1", port: 1, user: "u")
        chosen.reconnectAtLaunch = true
        var production = chosen
        production.id = UUID()
        production.colour = .production
        let other = SavedConnection(name: "Other", host: "127.0.0.1", port: 1, user: "u")
        let model = testModel([chosen, production, other])
        let (main, harness) = appWindow(model)
        model.connector.connectAtLaunch(on: main.window)
        #expect(model.states[chosen.id] != nil && model.states[production.id] == nil && model.states[other.id] == nil)
        model.connector.cancel(chosen.id)

        main.edit(production, isNew: false, on: main.window)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        #expect(await call(harness, "press", ["title": "Options"]).error == nil)
        let sheet = try #require(main.window?.attachedSheet)
        func find(_ view: NSView) -> NSButton? {
            if let box = view as? NSButton, box.accessibilityIdentifier() == "editor.reconnectAtLaunch" { return box }
            return view.subviews.lazy.compactMap(find).first
        }
        let box = try #require(sheet.contentView.flatMap(find))
        #expect(!box.isEnabled && box.toolTip == "A Production connection connects only when you ask")
        #expect(await call(harness, "press", ["id": "editor.cancel"]).error == nil)
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
    }
}

/// A MongoDB connection's address and back: Copy Address gives what Paste Address reads into the same fields, with the
/// user but never the password.
@MainActor
struct MongoAddressTests {
    @Test func copiedAddressesReadBackToTheSameFields() throws {
        for text in ["mongodb+srv://us%40er:p%40ss@cluster0.example.net/shop?retryWrites=true&w=majority&authSource=admin",
                     "mongodb://app:pw@[::1]:27018,m2:27019/orders?replicaSet=rs0&tls=true&tlsAllowInvalidHostnames=true"
                        + "&tlsCAFile=%2Ftmp%2Fca.pem&readPreference=secondary&connectTimeoutMS=900",
                     "mongodb://h:1/?directConnection=true&tlsInsecure=true&tls=true",
                     "mongodb://plain.example.com", "mongodb+srv://c.example.net/?tls=false&appName=a%26b"] {
            var first = SavedConnection()
            first.engine = .mongodb
            let password = first.apply(try MongoURI(text))
            let copied = ConnectionEditor.mongoAddress(first)
            var again = first
            #expect(again.apply(try MongoURI(copied)) == nil, "\(copied)")
            #expect(again == first, "\(text) → \(copied)")
            if let password { #expect(!copied.contains(password) && !copied.contains("pw@")) }
        }
        var srv = SavedConnection()
        _ = srv.apply(try MongoURI("mongodb+srv://us%40er:p%40ss@cluster0.example.net/shop?w=majority"))
        #expect(ConnectionEditor.mongoAddress(srv) == "mongodb+srv://us%40er@cluster0.example.net/shop?tls=true&w=majority")
    }
}

@MainActor
func folderRowIndex(_ main: MainWindowController, _ id: UUID) -> Int? {
    let outline = main.sidebar.outline
    return (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode)?.kind == .folder(id) }
}
