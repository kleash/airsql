// The app tests' support: a model and an off-screen main window with the harness that drives it (ported from AirSCP
// 1.4.0 Tests/AirSCPTests/AgentTests.swift: the harness's call and Reply), and the fixtures the screens show.
import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// A model for one test: its own data, activity and saved passwords (in memory); what it saves is recorded.
@MainActor
func testModel(_ connections: [SavedConnection] = [], folders: [ConnectionFolder] = []) -> AppModel {
    _ = TestEnvironment.isolated
    var passwords: [String: String] = [:]
    let model = AppModel(data: AirSQLData(connections: connections, folders: folders), activity: ActivityCenter(), store: { _ in })
    model.savedPassword = { passwords[$0] }
    model.setSavedPassword = { passwords[$0] = $1 }
    return model
}

/// The windows of the app tests, kept for the whole run (a window freed while a sheet still animates away makes AppKit
/// crash later), and the menu bar, made once.
@MainActor var keptWindows: [NSWindowController] = []

@MainActor
func useAppMenuBar() {
    guard NSApp.mainMenu == nil else { return }
    NSApp.mainMenu = MainMenu.build()
}

/// An off-screen main window on `model`, and the harness that drives it (it sees only this test's windows).
@MainActor
func appWindow(_ model: AppModel, size: NSSize = MainWindowController.defaultSize,
               windows: @escaping () -> [NSWindow] = { [] }) -> (main: MainWindowController, harness: AgentServer) {
    _ = NSApplication.shared
    _ = TestEnvironment.isolated
    useAppMenuBar()
    let main = MainWindowController(model: model)
    keptWindows.append(main)
    // Off the screen: placed after it is ordered in (ordering in moves a window back onto a screen).
    main.window?.orderFront(nil)
    main.window?.setFrame(NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), display: false)
    main.window?.layoutIfNeeded()
    main.refresh()  // the toolbar's items exist now
    return (main, AgentServer(main: main, model: model, windows: windows))
}

/// A tool's reply: its text as JSON, or the error text; and its image, if any.
struct Reply {
    var json: [String: Any] = [:]
    var error: String?
    var image: NSBitmapImageRep?

    subscript(key: String) -> Any? { json[key] }
}

@MainActor
func call(_ server: AgentServer, _ tool: String, _ arguments: [String: Any] = [:]) async -> Reply {
    let reply = await server.handle(tool, arguments)
    let content = reply["content"] as? [[String: Any]] ?? []
    var result = Reply()
    let text = content.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
    if reply["isError"] as? Bool == true {
        result.error = text
    } else {
        result.json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
    if let data = (content.first { $0["type"] as? String == "image" }?["data"] as? String).flatMap({ Data(base64Encoded: $0) }) {
        result.image = NSBitmapImageRep(data: data)
    }
    return result
}

func titles(_ items: Any?) -> [String] {
    (items as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
}

/// The element with `id` in a snapshot's elements, and its frame's middle (points from the window's top left).
@MainActor
func element(_ server: AgentServer, _ id: String, in spec: String? = nil) async -> (json: [String: Any], center: (Double, Double))? {
    var arguments: [String: Any] = ["include": ["elements"]]
    if let spec { arguments["in"] = spec }
    let snapshot = await call(server, "snapshot", arguments)
    guard let node = (snapshot["elements"] as? [[String: Any]])?.first(where: { $0["id"] as? String == id }),
          let frame = node["frame"] as? [Double], frame.count == 4 else { return nil }
    return (node, (frame[0] + frame[2] / 2, frame[1] + frame[3] / 2))
}

/// Records the commands that reach the end of a window's responder chain (the lanes' commands, which nothing in P0
/// implements): put after the window controller.
final class CommandRecorder: NSResponder {
    private(set) var received: [String] = []
    @objc func connect(_ sender: Any?) { received.append(#function) }
    @objc func newQuery(_ sender: Any?) { received.append(#function) }
    @objc func editConnection(_ sender: Any?) { received.append(#function) }
    @objc func showSQLLog(_ sender: Any?) { received.append(#function) }
    @objc func commit(_ sender: Any?) { received.append(#function) }
    @objc func rollback(_ sender: Any?) { received.append(#function) }
}

/// A tab's content for the tests: a label, and what a console would report.
@MainActor
final class FixtureContent: NSViewController, TabContent {
    var text: String
    var edited = false
    var badge: String?
    var renamable = true
    var closes = true

    init(_ text: String = "Fixture") {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = SurfaceView(.content)
        let text = label(self.text, font: .monospacedSystemFont(ofSize: 12.5, weight: .regular), color: .labelColor, wraps: true)
        root.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            text.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            text.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
        ])
        view = root
    }

    var canRename: Bool { renamable }
    var isEdited: Bool { edited }
    var transactionBadge: String? { badge }
    var canDuplicate: Bool { true }
    func duplicate() -> NSViewController? { FixtureContent(text) }
    func shouldClose(_ answer: @escaping (Bool) -> Void) { answer(closes) }
}

/// Connections for the screens: a production one through SSH, staging through jump hosts, a local socket, a proxy.
enum Fixtures {
    static let production: SavedConnection = {
        var connection = SavedConnection(name: "Production · shop", host: "db.example.com", user: "app", colour: .production,
                                         route: .ssh)
        connection.database = "shop"
        connection.agentAccess = .schema
        return connection
    }()
    static let staging: SavedConnection = {
        var connection = SavedConnection(name: "Staging · shop", host: "10.20.0.15", user: "deploy", colour: .staging, route: .sshJump)
        connection.safety = SafetySettings.production
        return connection
    }()
    static let local: SavedConnection = {
        var connection = SavedConnection(name: "Local MariaDB 11.8", user: "root", colour: .development)
        connection.socket = "/tmp/mysql.sock"
        return connection
    }()
    static let replica = SavedConnection(name: "Reports replica", host: "replica.example.net", port: 3307, user: "reports",
                                         colour: .test, route: .proxy)

    static var shop: [SavedConnection] { [production, staging, local, replica] }

    /// Long and odd content (plan §2.13): a 60-character name, a 255-character comment, right-to-left text, emoji, empty.
    static var odd: [SavedConnection] {
        var long = SavedConnection(name: String(repeating: "Analytics warehouse ", count: 3).trimmingCharacters(in: .whitespaces),
                                   host: "warehouse-primary-0001.analytics.internal.example.com", user: "a_very_long_user_name_for_reports")
        long.comment = String(repeating: "Reports read from here every night; ask the data team before changing anything. ", count: 4)
        long.comment = String(long.comment.prefix(255))
        var hebrew = SavedConnection(name: "שרת הפקה ראשי", host: "db.example.org", user: "app")
        hebrew.colour = .production
        let emoji = SavedConnection(name: "🐬 Dolphin dev 🧪", host: "localhost", user: "root", colour: .development)
        let empty = SavedConnection(host: "", user: "")
        return [long, hebrew, emoji, empty]
    }
}

/// The suite of the app tests: one at a time, as they share NSApp (their sheets and keys go to whichever window is
/// key). Each file adds its tests in an extension.
@MainActor @Suite(.serialized) struct AppTests {}
