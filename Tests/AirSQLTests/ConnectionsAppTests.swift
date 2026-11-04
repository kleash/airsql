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
@MainActor
func folderRowIndex(_ main: MainWindowController, _ id: UUID) -> Int? {
    let outline = main.sidebar.outline
    return (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode)?.kind == .folder(id) }
}
