import Foundation
import Testing
@testable import AirSQLCore

// The saved data (airsql.json): round trips, files from other versions, unreadable files; the Keychain kept in memory;
// the safety settings and their Production preset; per-table view settings; the Activity list.
struct ModelsTests {
    @Test func dataRoundTripsThroughTheStore() throws {
        _ = TestEnvironment.isolated
        let url = URL(fileURLWithPath: try scratch() + "/AirSQL/airsql.json")
        var connection = SavedConnection(name: "Production · shop", host: "db.example.com", port: 3307, user: "app",
                                         colour: .production, route: .sshJump)
        connection.safety = .production
        connection.agentAccess = .schemaRead
        let folder = ConnectionFolder(name: "Clients")
        connection.folderID = folder.id
        var data = AirSQLData(connections: [connection], folders: [folder])
        data.settings.rowsPerPage = 500
        data.settings.safety.askBeforeConsoleWrite = true
        try Store.save(data, to: url)
        #expect(Store.load(from: url) == data)
        // A folder only this user can open.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
    }

    @Test func filesFromOtherVersionsLoadWithDefaults() throws {
        // An older file: a connection with a name and a host only, settings without the newer keys.
        let json = #"{"connections": [{"id": "6C1F7A62-7B7D-4E7B-9E8B-2A1C3D4E5F60", "name": "old", "host": "h"}],"#
            + #""settings": {"appearance": "dark"}, "somethingNewer": 1}"#
        let data = try JSONDecoder().decode(AirSQLData.self, from: Data(json.utf8))
        let connection = try #require(data.connections.first)
        #expect(connection.name == "old" && connection.host == "h" && connection.route == .direct && connection.colour == .none)
        #expect(connection.safety == nil && connection.agentAccess == .off && !connection.readOnly)
        #expect(data.settings.appearance == .dark && data.settings.rowsPerPage == 1_000 && data.settings.safety == SafetySettings())
        #expect(!data.settings.agentsAllowed)
    }

    /// 1.0.1 saved `editorWraps` as false for everyone, so the default wrap has to reach those files; a choice since stays.
    @Test func wordWrapIsOnForFilesThatSavedTheOldDefault() throws {
        func wraps(_ settings: String) throws -> Bool {
            try JSONDecoder().decode(AirSQLData.self, from: Data(#"{"settings": \#(settings)}"#.utf8)).settings.editorWordWrap
        }
        #expect(try wraps(#"{"editorWraps": false}"#))
        #expect(try !wraps(#"{"editorWraps": false, "editorWordWrap": false}"#))
    }

    @Test func anUnreadableFileIsMovedAsideNeverOverwritten() throws {
        let url = URL(fileURLWithPath: try scratch() + "/airsql.json")
        try Data("{ not json".utf8).write(to: url)
        #expect(Store.load(from: url) == AirSQLData())
        #expect(FileManager.default.fileExists(atPath: url.path + ".unreadable"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func saveLaterWritesTheNewestOnce() throws {
        let url = URL(fileURLWithPath: try scratch() + "/airsql.json")
        for count in 1...20 {
            Store.saveLater(AirSQLData(connections: (0..<count).map { SavedConnection(name: "c\($0)") }), to: url)
        }
        Store.flush()
        #expect(Store.load(from: url).connections.count == 20)
    }

    @Test func passwordsStayInMemoryForAThrowawayInstance() {
        _ = TestEnvironment.isolated
        var writes = 0
        let saved = Keychain.writeItem
        Keychain.writeItem = { _ in writes += 1; return errSecSuccess }
        defer { Keychain.writeItem = saved }
        let id = UUID()
        Keychain.setPassword("secret", for: id)
        #expect(Keychain.password(for: id) == "secret")
        Keychain.setPassword(nil, for: id)
        #expect(Keychain.password(for: id) == nil)
        #expect(writes == 0)
        #expect(Env.isThrowaway(["AIRSQL_SUPPORT_DIR": "/tmp/x"]) && !Env.isThrowaway([:]))
    }

    @Test func productionStartsStrictAndOverridesWin() {
        let defaults = SafetySettings()
        #expect(defaults.askBeforeUnboundedWrite && !defaults.askBeforeConsoleWrite && !defaults.previewBeforeApply)
        #expect(defaults.agentRowCap == 10_000 && defaults.agentTimeout == 30 && defaults.openTransactionMinutes == 15)
        let production = SafetySettings.production
        #expect(production.askBeforeConsoleWrite && production.previewBeforeApply && production.typeNameForTables)
        #expect(production.agentRowCap == 1_000 && production.agentTimeout == 15 && production.openTransactionMinutes == 5)
        #expect(SafetySettings.syncLeavesOutDestructive)

        var settings = AppSettings()
        settings.safety.askBeforeConsoleWrite = true
        let data = AirSQLData(settings: settings)
        var plain = SavedConnection(name: "dev")
        #expect(data.safety(for: plain).askBeforeConsoleWrite && !plain.hasCustomSafety)
        plain.colour = .production
        #expect(data.safety(for: plain) == .production)
        var custom = plain
        custom.safety = SafetySettings()
        custom.safety?.agentRowCap = 5
        #expect(data.safety(for: custom).agentRowCap == 5 && custom.hasCustomSafety)
    }

    @Test func namesAndRouteBadges() {
        #expect(SavedConnection(host: "db", port: 3307, user: "app").displayName == "app@db:3307")
        var socket = SavedConnection(user: "root")
        socket.socket = "/tmp/mysql.sock"
        #expect(socket.displayName == "root@/tmp/mysql.sock" && socket.routeBadge == "Socket")
        #expect(SavedConnection(name: "x", route: .sshJump).routeBadge == "Jump")
        #expect(SavedConnection(name: "x").routeBadge == "Direct")
    }

    @Test func tableViewSettingsAreKeptPerTable() throws {
        let url = URL(fileURLWithPath: try scratch() + "/tableviews.json")
        let store = TableViewSettingsStore(fileURL: url)
        let connection = UUID()
        var settings = TableViewSettings()
        settings.filter = "status = 'paid'"
        for index in 0..<25 { settings.remember("id > \(index)") }
        settings.remember("id > 3")
        settings.sort = [.init(column: "created_at", ascending: false)]
        settings.hiddenColumns = ["meta"]
        settings.widths = ["name": 180]
        settings.displayTypes = ["receipt_hash": "hex"]
        #expect(settings.recentFilters.count == TableViewSettings.recentLimit && settings.recentFilters.first == "id > 3")
        store.set(settings, connection: connection, database: "shop", table: "orders")
        store.flush()
        let reread = TableViewSettingsStore(fileURL: url)
        #expect(reread.settings(connection: connection, database: "shop", table: "orders") == settings)
        #expect(reread.settings(connection: connection, database: "shop", table: "customers") == TableViewSettings())
        // A dot in a name doesn't mix two tables up.
        #expect(reread.settings(connection: connection, database: "shop.orders", table: "") == TableViewSettings())
        reread.removeAll(connection: connection)
        reread.flush()
        #expect(TableViewSettingsStore(fileURL: url).settings(connection: connection, database: "shop", table: "orders") == TableViewSettings())
    }

    @MainActor @Test func activityListsWorkUntilItEnds() {
        let center = ActivityCenter()
        var cancelled = 0
        let query = center.start("Running a query", connection: UUID()) { cancelled += 1 }
        let connect = center.start("Connecting")
        #expect(!center.isIdle && center.running.count == 2)
        #expect(query.canCancel && !connect.canCancel)
        center.cancelAll()
        query.cancel()
        #expect(cancelled == 1 && query.cancelling && !query.canCancel)
        query.end()
        connect.end()
        #expect(center.isIdle)
    }

    /// Connecting at launch is the person's choice for each connection, and Production never does, however it's marked.
    @Test func onlyAChosenConnectionOutsideProductionConnectsAtLaunch() throws {
        var saved = SavedConnection(name: "dev")
        #expect(!saved.connectsAtLaunch)
        saved.reconnectAtLaunch = true
        #expect(saved.connectsAtLaunch)
        var coloured = saved
        coloured.colour = .production
        #expect(!coloured.connectsAtLaunch)
        var strict = saved
        strict.safety = .production
        #expect(!strict.connectsAtLaunch)
        let older = try JSONDecoder().decode(SavedConnection.self, from: Data(#"{"name":"old"}"#.utf8))
        #expect(!older.reconnectAtLaunch)
    }

    @Test func aTimeZoneGoesToTheSessions() {
        var saved = SavedConnection(name: "dev")
        #expect(saved.connectOptions(password: "", routeSocket: nil).timeZone == nil)
        saved.timeZone = "+02:00"
        #expect(saved.connectOptions(password: "", routeSocket: nil).timeZone == "+02:00")
    }

    @Test func changeSQLEndsEachStatement() {
        let change = ChangeSQL(title: "t", statements: ["DELETE FROM `t` WHERE `id` = 1", " UPDATE `t` SET `a` = 2;\n"], connection: UUID())
        #expect(change.text == "DELETE FROM `t` WHERE `id` = 1;\nUPDATE `t` SET `a` = 2;")
    }
}
