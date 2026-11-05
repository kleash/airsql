import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

// Connecting from the app on the lab (AIRSQL_LAB=1), answering its sheets as a person would: the Trust sheet for a
// self-signed certificate, and ssh's host key and password questions through askpass.
extension AppTests {
    /// The text of the sheet shown on `window`, or nil.
    private func sheetText(_ window: NSWindow?) -> String? {
        guard let content = window?.attachedSheet?.contentView else { return nil }
        func texts(_ view: NSView) -> [String] {
            ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts)
        }
        return texts(content).joined(separator: "\n")
    }

    /// A drop keeps the login, so Connect sets the same sessions up again through the same route (plan §2.2, R8) and the
    /// tabs holding them work on. It used to wipe the password: the reconnect then failed its login and started over.
    @Test(.enabled(if: Lab.enabled)) func aDroppedConnectionReconnectsWithItsLogin() async throws {
        var saved = SavedConnection(name: "Drops", host: "127.0.0.1", port: Lab.mariadb114.port, user: Lab.airsql.user)
        saved.tls = TLSOptions(mode: .off)
        let model = testModel([saved])
        model.setSavedPassword(saved.id.uuidString, Lab.airsql.password)
        func connected() async -> Bool {
            await eventually(timeout: 30) { if case .connected? = model.states[saved.id] { return true } else { return false } }
        }
        model.connector.connect(saved.id, on: nil)
        #expect(await connected(), "\(String(describing: model.states[saved.id]))")
        let open = try #require(model.connector.open[saved.id])
        let main = try await open.connection.session(.main)
        let tab = try await open.connection.toolsSession(role: .query)
        _ = try await main.query("START TRANSACTION")
        let thread = try #require(main.server?.threadID)
        _ = try await tab.query("KILL \(thread)")
        try? await main.ping()
        #expect(main.wasLost)

        model.connector.dropped(saved.id, open, "Lost.")
        #expect(model.openConnection(saved.id) == nil && model.states[saved.id] == .failed("Lost."))
        #expect(await eventually(timeout: 5) { !tab.isConnected }, "its transaction is gone, as the tab says")
        await #expect(throws: AirSQLError.self, "nothing opens until the person connects") { _ = try await open.connection.session(.data) }

        model.connector.connect(saved.id, on: nil)
        #expect(await connected(), "\(String(describing: model.states[saved.id]))")
        let again = try #require(model.connector.open[saved.id])
        #expect(again.connection === open.connection, "the kept connection, not a fresh connect")
        #expect(try await again.connection.session(.main) === main && main.isConnected && !main.wasLost)
        let data = try await again.connection.session(.data)
        #expect(try await data.query("SELECT 1").first?.rows?.string(0, 0) == "1")
        model.connector.disconnect(saved.id)
    }

    /// What a connect sets up from the saved connection: its time zone in each session, the database last worked in
    /// while it's there, and a disconnect once idle, never with a transaction open.
    @Test(.enabled(if: Lab.enabled)) func aConnectionComesBackWhereItWasAndClosesWhenIdle() async throws {
        var saved = SavedConnection(name: "Back", host: "127.0.0.1", port: Lab.mariadb114.port, user: Lab.airsql.user)
        saved.tls = TLSOptions(mode: .off)
        saved.timeZone = "+03:00"
        saved.idleDisconnectMinutes = 5
        let model = testModel([saved])
        model.setSavedPassword(saved.id.uuidString, Lab.airsql.password)
        func connect() async throws -> OpenConnection {
            model.connector.connect(saved.id, on: nil)
            #expect(await eventually(timeout: 30) { model.openConnection(saved.id)?.snapshot.server != nil })
            return try #require(model.openConnection(saved.id))
        }
        var open = try await connect()
        #expect(open.currentDatabase == nil)
        open.currentDatabase = "fixture"
        #expect(model.connection(saved.id)?.lastDatabase == "fixture")
        let main = try await open.connection.session(.main)
        #expect(try await main.query("SELECT @@time_zone").first?.rows?.string(0, 0) == "+03:00")
        model.connector.disconnect(saved.id)
        open = try await connect()
        #expect(open.currentDatabase == "fixture")
        model.connector.disconnect(saved.id)

        var gone = try #require(model.connection(saved.id))
        gone.lastDatabase = "no_such_database"
        model.save(gone)
        open = try await connect()
        #expect(open.currentDatabase == nil)

        let connected = try #require(model.connector.open[saved.id])
        let later = Date().addingTimeInterval(600)
        await model.connector.closeIfIdle(saved.id, connected, now: Date())
        #expect(model.connector.open[saved.id] != nil, "not idle long enough")
        let session = try await open.connection.session(.main)
        _ = try await session.query("START TRANSACTION")
        await model.connector.closeIfIdle(saved.id, connected, now: later)
        #expect(model.connector.open[saved.id] != nil, "a transaction is open")
        _ = try await session.query("ROLLBACK")
        await model.connector.closeIfIdle(saved.id, connected, now: later)
        #expect(model.connector.open[saved.id] == nil && model.states[saved.id] == nil)
    }

    /// A password typed with Remember, then found expired, must not be what gets saved; Test Connection changes nothing,
    /// as the editor would go on to save what was typed. Only the throwaway user `lane_expired` is touched.
    @Test(.enabled(if: Lab.enabled)) func theExpiredPasswordIsNotWhatGetsRemembered() async throws {
        let admin = DBConnection(options: DBLab.options(Lab.mariadb114), role: .tools, log: DBLab.log)
        try await admin.connect()
        _ = try await admin.query("DROP USER IF EXISTS 'lane_expired'@'%'")
        _ = try await admin.query("CREATE USER 'lane_expired'@'%' IDENTIFIED BY 'old-Pass1' PASSWORD EXPIRE")
        var saved = SavedConnection(name: "Expired", host: "127.0.0.1", port: Lab.mariadb114.port, user: "lane_expired")
        saved.tls = TLSOptions(mode: .off)
        let model = testModel([saved])
        let (main, harness) = appWindow(model)
        await #expect(throws: AirSQLError.self) {
            _ = try await model.connector.test(saved, password: "old-Pass1", proxyPassword: nil, on: main.window) { _ in }
        }
        #expect(main.window?.attachedSheet == nil, "it asks for nothing")

        model.setSavedPassword(saved.id.uuidString, "old-Pass1")
        model.connector.remembered[saved.id] = [saved.id.uuidString: "old-Pass1"]
        model.connector.connect(saved.id, on: main.window)
        #expect(await eventually(timeout: 20) { main.window?.attachedSheet != nil })
        #expect(await call(harness, "set", ["id": "password.new", "value": "new-Pass1"]).error == nil)
        #expect(await call(harness, "set", ["id": "password.repeat", "value": "new-Pass1"]).error == nil)
        #expect(await call(harness, "press", ["title": "Change"]).error == nil)
        #expect(await eventually(timeout: 20) { model.savedPassword(saved.id.uuidString) == "new-Pass1" })
        model.connector.disconnect(saved.id)
        _ = try await admin.query("DROP USER 'lane_expired'@'%'")
        await admin.close()
    }

    /// A table tab outlives its sessions: after Disconnect and Connect, as after a drop that lost the route too, it reads
    /// through the new ones.
    @Test(.enabled(if: Lab.enabled)) func aTableTabReadsThroughANewConnect() async throws {
        var saved = SavedConnection(name: "Again", host: "127.0.0.1", port: Lab.mariadb114.port, user: Lab.airsql.user)
        saved.tls = TLSOptions(mode: .off)
        let model = testModel([saved])
        model.setSavedPassword(saved.id.uuidString, Lab.airsql.password)
        let (main, _) = appWindow(model)
        func connect() async {
            model.connector.connect(saved.id, on: nil)
            #expect(await eventually(timeout: 30) { model.openConnection(saved.id) != nil })
        }
        await connect()
        let tab = TableDataController(model: model, context: try #require(Editors.context(saved, in: model)), database: "fixture", table: "customers")
        main.select(main.open(tab, title: "customers", connection: saved.id))
        func read() async -> Bool {
            await eventually(timeout: 20) { try? await Task.sleep(nanoseconds: 50_000_000); return tab.source != nil && tab.loading == nil }
        }
        #expect(await read())
        model.connector.disconnect(saved.id)
        await connect()
        tab.problem = nil
        tab.refresh(nil)
        #expect(await read() && tab.problem == nil, "\(tab.problem ?? "")")
        model.connector.disconnect(saved.id)
    }

    @Test(.enabled(if: Lab.enabled)) func trustingASelfSignedCertificatePinsIt() async throws {
        var mysql = SavedConnection(name: "MySQL 8.4", host: "127.0.0.1", port: Lab.mysql84.port, user: Lab.airsql.user)
        mysql.tls = TLSOptions(mode: .verifyIdentity)
        let model = testModel([mysql])
        model.setSavedPassword(mysql.id.uuidString, Lab.airsql.password)
        let (main, harness) = appWindow(model)
        _ = await call(harness, "select", ["pane": "sidebar", "names": ["MySQL 8.4"]])
        #expect(await call(harness, "menu", ["path": "Connection > Connect"]).error == nil)
        #expect(await eventually(timeout: 30) { sheetText(main.window)?.contains("Trust the certificate") == true })
        #expect(sheetText(main.window)?.contains("SHA-256 fingerprint") == true)
        #expect(await call(harness, "press", ["title": "Trust"]).error == nil)
        #expect(await eventually(timeout: 30) { model.states[mysql.id] == .connected(server: "MySQL " + Lab.mysql84.version) },
                "\(String(describing: model.states[mysql.id]))")
        let pinned = try #require(model.connection(mysql.id)?.tls.pinnedFingerprint)
        #expect(model.connector.open[mysql.id]?.server.certificate?.fingerprint == pinned)
        #expect(await call(harness, "menu", ["path": "Connection > Disconnect"]).error == nil)
        #expect(model.states[mysql.id] == nil && model.connector.open[mysql.id] == nil)
    }

    @Test(.enabled(if: Lab.enabled)) func connectingThroughTheBastionAsksForItsPassword() async throws {
        _ = RouteTesting.prepared
        Connector.askpassHelper = RouteTesting.askpassHelper
        var tunnelled = SavedConnection(name: "Secure via bastion", host: Lab.secure.name, user: Lab.airsql.user, route: .ssh)
        tunnelled.tls = TLSOptions(mode: .verifyIdentity, caFile: Lab.caFile)
        tunnelled.sshHost = SSHHop(host: Lab.bastion.host, port: Lab.bastion.port, user: Lab.bastion.user, login: .password)
        let model = testModel([tunnelled])
        model.setSavedPassword(tunnelled.id.uuidString, Lab.airsql.password)
        let (main, harness) = appWindow(model)
        _ = await call(harness, "select", ["pane": "sidebar", "names": ["Secure via bastion"]])
        #expect(await call(harness, "menu", ["path": "Connection > Connect"]).error == nil)
        var answered = false
        let connected = await eventually(timeout: 60) {
            if case .connected? = model.states[tunnelled.id] { return true }
            guard let text = sheetText(main.window) else { return false }
            if text.contains("Trust the SSH host") {
                _ = await call(harness, "press", ["title": "Trust"])
            } else if text.contains("SSH password") {
                _ = await call(harness, "set", ["id": "prompt.answer", "value": Lab.bastion.password])
                _ = await call(harness, "set", ["id": "prompt.remember", "value": true])
                _ = await call(harness, "press", ["title": "OK"])
                answered = true
            }
            return false
        }
        #expect(connected && answered, "\(String(describing: model.states[tunnelled.id])) \(sheetText(main.window) ?? "")")
        let socket = try #require(model.connector.open[tunnelled.id]?.route.socket)
        #expect(FileManager.default.fileExists(atPath: socket))
        #expect(await eventually(timeout: 10) { model.savedPassword(tunnelled.secretKey(for: tunnelled.sshHost)) == Lab.bastion.password })
        let version = try await model.connector.open[tunnelled.id]?.connection.session(.main).query("SELECT VERSION()")
        #expect(version?.first?.rows?.string(0, 0)?.hasPrefix(Lab.secure.version) == true)
        // The navigator's schema loads through the tunnel, and goes at Disconnect.
        #expect(await eventually(timeout: 30) { model.openConnection(tunnelled.id)?.snapshot.server != nil })
        #expect(await call(harness, "menu", ["path": "Connection > Disconnect"]).error == nil)
        #expect(model.openConnection(tunnelled.id) == nil)
        #expect(await eventually(timeout: 10) { !FileManager.default.fileExists(atPath: socket) })
    }
}
