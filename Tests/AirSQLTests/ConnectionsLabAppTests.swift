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
        #expect(await call(harness, "menu", ["path": "Connection > Disconnect"]).error == nil)
        #expect(await eventually(timeout: 10) { !FileManager.default.fileExists(atPath: socket) })
    }
}
