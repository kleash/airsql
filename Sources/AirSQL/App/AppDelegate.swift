// Ported from AirSCP 1.4.0 Sources/AirSCP/AppDelegate.swift (the app's lifecycle, its menu bar and the commands
// available in every window) and Help.swift (HelpPage, Report a Problem).
import AirSQLCore
import AppKit
import Combine

/// The app: the main window, the Settings window and the menu bar. At launch it reads the saved data off the main
/// thread, applies the chosen appearance and opens the window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var model: AppModel?
    private(set) var main: MainWindowController?
    private var settings: SettingsWindowController?
    /// Agents' socket and tools (L7), while Settings ▸ Agents allows agents.
    private(set) var agents: AgentService?
    private var observers: [AnyCancellable] = []

    /// main.swift creates the delegate outside the main actor; everything is set up at launch.
    nonisolated override init() {
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false  // one main window: no tab items in the Window and View menus
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            // File work, off the main thread: airsql.json, then the tables' view settings.
            let data = await Task.detached { () -> AirSQLData in
                TableViewSettingsStore.shared.load()
                return Store.load()
            }.value
            start(with: data)
        }
    }

    /// Opens the window on the saved data.
    func start(with data: AirSQLData) {
        let model = AppModel(data: data)
        self.model = model
        // Light or dark as chosen in Settings: before the window opens, and at once when it changes.
        observers.append(model.$data.map(\.settings.appearance).removeDuplicates().sink { NSApp.appearance = appAppearance($0) })
        let main = MainWindowController(model: model)
        self.main = main
        agents = AgentService(model: model, main: main)
        main.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        log.log("launched with \(model.data.connections.count, privacy: .public) connection(s)")
    }

    /// A click on the Dock icon: a closed window comes back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = main?.window, !window.isVisible, !window.isMiniaturized { main?.showWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        agents?.close()
        Store.flush()
        TableViewSettingsStore.shared.flush()
    }

    // MARK: Commands available in every window

    @objc func showMainWindow(_ sender: Any?) { main?.showWindow(nil) }

    @objc func showSettings(_ sender: Any?) { showSettings(pane: nil) }

    /// The Settings window, at `pane` when given.
    func showSettings(pane: SettingsPane?) {
        guard let model else { return }
        if settings == nil { settings = SettingsWindowController(model: model) }
        if let pane { settings?.show(pane) }
        settings?.showWindow(nil)
    }

    /// Help ▸ AirSQL Help and Getting Started: pages on the web.
    @objc func showHelpSite(_ sender: Any?) { NSWorkspace.shared.open(HelpPage.home.url) }

    @objc func showGettingStarted(_ sender: Any?) { NSWorkspace.shared.open(HelpPage.gettingStarted.url) }

    @objc func reportProblem(_ sender: Any?) { NSWorkspace.shared.open(HelpPage.reportProblem) }

    /// Help ▸ Copy Diagnostics: AirSQL's, macOS's and the client library's versions.
    @objc func copyDiagnostics(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HelpPage.diagnostics, forType: .string)
    }

    @objc func setUpAgents(_ sender: Any?) { showSettings(pane: .agents) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.explain(enabled: true, reason: nil)
        return true
    }
}

/// The appearance Settings choose: the Mac's (nil), light or dark.
func appAppearance(_ choice: AppSettings.Appearance) -> NSAppearance? {
    switch choice {
    case .system: return nil
    case .light: return NSAppearance(named: .aqua)
    case .dark: return NSAppearance(named: .darkAqua)
    }
}

/// AirSQL Help on the web: the pages the Help menu and the sheets' "?" buttons open, all in this table (the path of each
/// page on the site, a page of docs/ in the repository).
enum HelpPage: String, CaseIterable {
    case home = ""
    case gettingStarted = "getting-started.html"
    case settings = "settings.html"
    case safety = "settings.html#safety"
    case sqlPreview = "sql-preview.html"
    case trust = "trust-a-server.html"

    /// The site: GitHub Pages, built from docs/.
    static let site = URL(string: "https://kleash.github.io/airsql/")!

    var url: URL { URL(string: rawValue, relativeTo: Self.site)?.absoluteURL ?? Self.site }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Help ▸ Report a Problem: the repository's issue form, with AirSQL's and macOS's versions filled in.
    static var reportProblem: URL {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        var form = URLComponents(string: "https://github.com/kleash/airsql/issues/new")!
        form.queryItems = [URLQueryItem(name: "version", value: version),
                           URLQueryItem(name: "macos", value: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")]
        return form.url!
    }

    /// What Copy Diagnostics copies (no names, hosts or paths).
    static var diagnostics: String {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return ["AirSQL \(version)", "macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
                "MariaDB Connector/C \(MariaDB.clientVersion)"].joined(separator: "\n")
    }

    /// Opens the page in the browser: the "?" buttons' target.
    final class Opener: NSObject {
        static let shared = Opener()
        @objc func open(_ sender: NSButton) {
            NSWorkspace.shared.open(HelpPage(rawValue: sender.identifier?.rawValue.replacingOccurrences(of: "help:", with: "") ?? "")?.url
                ?? HelpPage.site)
        }
    }
}

/// The small "?" button of a sheet: opens its page of AirSQL Help.
@MainActor
func helpButton(_ page: HelpPage) -> NSButton {
    let button = NSButton(title: "", target: HelpPage.Opener.shared, action: #selector(HelpPage.Opener.open(_:)))
    button.bezelStyle = .helpButton
    button.identifier = NSUserInterfaceItemIdentifier("help:" + page.rawValue)
    button.toolTip = "Open the page of AirSQL Help about this, in your browser"
    button.setAccessibilityIdentifier("help")
    button.translatesAutoresizingMaskIntoConstraints = false
    return button
}
