import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// The connections lane's sheets, for the layout checks and the screenshots: the editor's tabs, the Trust sheets and
/// ssh's questions.
@MainActor
enum ConnectionsScreens {
    static let certificateFingerprint = "9F:2C:41:7A:0B:E3:55:D8:6C:11:AF:30:72:9E:C4:5B:08:DD:3A:61:F7:24:9C:B0:13:6E:85:C2:4F:70:A9:1D"

    /// Shows each sheet on `main`'s window in turn, calls `look` with it and its name, then closes it.
    static func each(_ main: MainWindowController, _ harness: AgentServer, long: Bool,
                     look: (NSWindow, String) async throws -> Void) async throws {
        let window = try #require(main.window)
        func shown() async throws -> NSWindow {
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            return try #require(window.attachedSheet)
        }
        func dismiss(_ title: String = "Cancel") async {
            _ = await call(harness, "press", ["title": title])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        }
        let editor = ConnectionEditor.show(Fixtures.routed(long: long), isNew: false, model: main.model, on: window) { _, _ in }
        for tab in ConnectionEditor.Tab.allCases {
            editor.show(tab)
            try await look(try await shown(), "editor-" + tab.title.lowercased().replacingOccurrences(of: " ", with: "-"))
        }
        // The tallest tab: Options with the connection's own safety checks, which scrolls on a small screen.
        editor.draft.safety = editor.draft.safety(defaults: SafetySettings())
        editor.show(.options)
        try await look(try await shown(), "editor-options-own-safety")
        await dismiss()

        showTrust(server: "db.example.com", fingerprint: certificateFingerprint,
                  details: ["Issued to db.example.com by Example Private CA", "Valid from 1 Jan 2026 until 1 Jan 2028"],
                  on: window) { _ in }
        try await look(try await shown(), "trust-certificate")
        await dismiss()
        let prompt = "The authenticity of host 'bastion.example.com (192.0.2.10)' can't be established.\nED25519 key "
            + "fingerprint is SHA256:Qm9vbGVhbnMgYXJlIGNvb2wgYnV0IGtleXMgYXJlIGNvb2xlcg.\nAre you sure you want to continue "
            + "connecting (yes/no/[fingerprint])?"
        showHostKeyTrust(host: "bastion.example.com", fingerprint: "SHA256:Qm9vbGVhbnMgYXJlIGNvb2wgYnV0IGtleXMgYXJlIGNvb2xlcg",
                         prompt: prompt, on: window) { _ in }
        try await look(try await shown(), "trust-ssh-host")
        await dismiss()
        showSSHPrompt(.password(user: "deploy", host: "db-gw.internal.example"), text: "deploy@db-gw.internal.example's password:",
                      hop: "deploy@db-gw.internal.example", canRemember: true, retry: long, on: window) { _, _ in }
        try await look(try await shown(), "ssh-password")
        await dismiss()
        showSSHPrompt(.other, text: "Verification code:", hop: "bastion.example.com", canRemember: false, retry: false,
                      on: window) { _, _ in }
        try await look(try await shown(), "ssh-code")
        await dismiss()
        showChangedCertificate(server: "db.example.com", certificate: try certificate(), on: window) { _ in }
        try await look(try await shown(), "trust-changed-certificate")
        await dismiss()
        showLoginPrompt(for: "Production · shop", user: "", retry: false, on: window) { _ in }
        try await look(try await shown(), "login")
        await dismiss()
    }

    /// A certificate signed by the tests' authority, for the changed-certificate sheet.
    static func certificate() throws -> TLSCertificate {
        let der = try TestCertificates().server("db.example.com")
        return TLSCertificate(der, try #require(SecCertificateCreateWithData(nil, der as CFData)))
    }
}

extension AppTests.LayoutTests {
    /// The connections lane's sheets at one appearance: with the full route, and with long names.
    func connectionScreens(_ main: MainWindowController, _ harness: AgentServer, check: (NSWindow, String) -> Void) async throws {
        for long in [false, true] {
            try await ConnectionsScreens.each(main, harness, long: long) { sheet, name in check(sheet, name + (long ? " (long)" : "")) }
        }
    }
}

extension AppTests.ScreenshotTests {
    /// The connection editor's tabs, the Trust sheets and ssh's questions, light and dark, in build/screenshots.
    @Test func connectionSheets() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let model = testModel(Fixtures.shop)
            let (main, harness) = appWindow(model)
            main.window?.appearance = NSAppearance(named: appearance)
            main.sidebar.select([Fixtures.production.id])
            main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
            main.window?.orderFront(nil)
            main.window?.displayIfNeeded()
            try await ConnectionsScreens.each(main, harness, long: false) { _, name in
                let reply = await call(harness, "screenshot", ["target": "main", "scale": 2])
                let image = try #require(reply.image, "\(name): \(reply.error ?? "")")
                let png = try #require(image.representation(using: .png, properties: [:]))
                try png.write(to: Self.folder.appendingPathComponent("\(name)-\(suffix).png"))
            }
            main.window?.orderOut(nil)
        }
    }
}
