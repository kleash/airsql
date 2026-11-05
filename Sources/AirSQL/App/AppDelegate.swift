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
    /// .sql files asked for before the window was up (those that opened AirSQL).
    private var filesToOpen: [URL] = []

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
            // File work, off the main thread: airsql.json, then the tables' view settings, and what earlier runs left
            // in the client tools' private folder.
            let data = await Task.detached { () -> AirSQLData in
                OptionFile.removeLeftovers()
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
        observers.append(model.$data.map(\.settings.keymap).removeDuplicates().sink { Keymap.apply($0) })
        let main = MainWindowController(model: model)
        self.main = main
        agents = AgentService(model: model, main: main)
        agents?.consoles = main
        SQLEditorView.settings = { [weak model] in model?.data.settings ?? AppSettings() }
        // The console's sessions, schema and query timeout: the connected connection's.
        ConsoleViewController.openConnection = { [weak model] in model?.openConnection($0)?.connection }
        ConsoleViewController.schemaCache = { [weak model] in model?.openConnection($0)?.schema }
        ConsoleViewController.queryTimeout = { [weak model] in model?.connection($0)?.queryTimeout ?? 0 }
        // The compare window connects a connection that isn't, as the main window does (its prompts on the compare
        // window), then works on tools sessions of its own.
        ReconWindowController.connect = { [weak model] saved, window in
            guard let model else { throw AirSQLError.disconnected }
            return try await model.connector.connection(saved.id, on: window)
        }
        main.showWindow(nil)
        ConsoleDocuments.shared.restore(into: main)
        if !filesToOpen.isEmpty { main.openFiles(filesToOpen) }
        filesToOpen = []
        NSApp.activate(ignoringOtherApps: true)
        log.log("launched with \(model.data.connections.count, privacy: .public) connection(s)")
    }

    /// A click on the Dock icon: a closed window comes back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = main?.window, !window.isVisible, !window.isMiniaturized { main?.showWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// .sql files opened from Finder or dropped on the Dock icon: console tabs of the active connection.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let main else { return filesToOpen += urls }
        main.showWindow(nil)
        main.openFiles(urls)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        agents?.close()
        ToolSheet.open.filter(\.running).forEach { $0.stop() }  // a dump or client program would outlive the app
        Store.flush()
        TableViewSettingsStore.shared.flush()
        PendingChangesStore.shared.flush()
    }

    // MARK: Commands available in every window

    /// AirSQL ▸ About AirSQL: the standard panel (Info.plist gives the version and the copyright).
    @objc func showAbout(_ sender: Any?) { NSApp.orderFrontStandardAboutPanel(options: HelpPage.about) }

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
    @objc func showShortcuts(_ sender: Any?) { ShortcutsWindowController.show() }

    /// The help's text, kept in the app for a Mac that can't reach the site (build.sh copies docs/llms-full.txt).
    private var offlineHelp: URL? { Bundle.main.url(forResource: "AirSQL Help", withExtension: "txt") }
    @objc func showOfflineHelp(_ sender: Any?) { offlineHelp.map { _ = NSWorkspace.shared.open($0) } }
    @objc func showReleaseNotes(_ sender: Any?) { NSWorkspace.shared.open(HelpPage.releases) }

    @objc func reportProblem(_ sender: Any?) { NSWorkspace.shared.open(HelpPage.reportProblem) }

    /// Help ▸ Copy Diagnostics: AirSQL's, macOS's and the client library's versions.
    @objc func copyDiagnostics(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HelpPage.diagnostics, forType: .string)
    }

    @objc func setUpAgents(_ sender: Any?) { showSettings(pane: .agents) }

    /// ⌘W in a window with no tabs of its own (Settings, SQL Log, Compare); the main window answers for itself.
    @objc func closeTab(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == Commands.closeTab.action {
            // A sheet has its own buttons.
            guard let window = NSApp.keyWindow, window.styleMask.contains(.closable), window.sheetParent == nil else {
                item.toolTip = NSApp.keyWindow == nil ? "No window is open" : "Answer the sheet first"
                return false
            }
            item.toolTip = Commands.closeWindow.tip
            return true
        }
        if item.action == Commands.offlineHelp.action, offlineHelp == nil {
            item.toolTip = "This build has no copy of the help"
            return false
        }
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
    case shortcuts = "shortcuts.html"
    case settings = "settings.html"
    case safety = "settings.html#safety"
    case sqlPreview = "sql-preview.html"
    case trust = "trust-a-server.html"
    case clientTools = "client-tools.html"
    case editors = "editors.html"
    case compare = "compare.html"
    case compareResults = "compare.html#compare-two-results-or-a-result-with-a-table"
    case agents = "agents.html"
    case connections = "connections.html"
    case tableData = "table-data.html"
    case dataGrid = "data-grid.html"
    case liquibase = "liquibase.html"
    case troubleshooting = "troubleshooting.html#a-connection-fails"
    case navigator = "navigator.html"
    case console = "console.html"
    case sqlLog = "sql-log.html"
    case users = "users.html"

    /// The site: GitHub Pages, built from docs/.
    static let site = URL(string: "https://kleash.github.io/airsql/")!

    var url: URL { URL(string: rawValue, relativeTo: Self.site)?.absoluteURL ?? Self.site }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Help ▸ Release Notes: what each version changed, and the newest one to download.
    static let releases = URL(string: "https://github.com/kleash/airsql/releases")!

    /// Help ▸ Report a Problem: the repository's issue form, with AirSQL's and macOS's versions filled in.
    static var reportProblem: URL {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        var form = URLComponents(string: "https://github.com/kleash/airsql/issues/new")!
        form.queryItems = [URLQueryItem(name: "template", value: "bug_report.yml"), URLQueryItem(name: "version", value: version),
                           URLQueryItem(name: "macos", value: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")]
        return form.url!
    }

    /// What Copy Diagnostics copies (no names, hosts or paths).
    static var diagnostics: String {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return ["AirSQL \(version)", "macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
                "MariaDB Connector/C \(MariaDB.clientVersion)"].joined(separator: "\n")
    }

    /// The About panel's options. Its credits: the client library's version, AirSQL's licence, and links to the site and
    /// to NOTICE (the app's copy, next to the licence texts it names; the repository's outside the app, as in tests). No
    /// build number: build.sh makes it the version, which the panel shows already.
    static var about: [NSApplication.AboutPanelOptionKey: Any] {
        let notice = Bundle.main.url(forResource: "NOTICE", withExtension: "txt", subdirectory: "Licenses")
            ?? URL(string: "https://github.com/kleash/airsql/blob/main/NOTICE")!
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                                    .foregroundColor: NSColor.labelColor, .paragraphStyle: centred]
        let text = NSMutableAttributedString(string: "MariaDB Connector/C \(MariaDB.clientVersion)\nLicensed under the Apache "
                                             + "License 2.0\n", attributes: plain)
        text.append(NSAttributedString(string: "Website", attributes: plain.merging(
            [.link: site, .toolTip: "Open AirSQL Help on the web"]) { $1 }))
        text.append(NSAttributedString(string: " · ", attributes: plain))
        text.append(NSAttributedString(string: "Licences", attributes: plain.merging(
            [.link: notice, .toolTip: "Read AirSQL's licence and those of the libraries it includes"]) { $1 }))
        return [.credits: text, .version: ""]
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
