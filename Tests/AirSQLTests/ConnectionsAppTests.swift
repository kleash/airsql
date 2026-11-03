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
        #expect(await call(harness, "set", ["id": "editor.tlsMode", "value": "Check the authority"]).error == nil)
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
        _ = await call(harness, "press", ["title": "OK"])
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
