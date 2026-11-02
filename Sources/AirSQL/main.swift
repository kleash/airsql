import AirSQLCore
import AppKit

// `AirSQL --version` prints AirSQL's version and its client library's, and opens no window (CI runs it to check that the
// app finds the libmariadb in its bundle).
if CommandLine.arguments.dropFirst().first == "--version" {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "(not bundled)"
    print("AirSQL \(version), MariaDB Connector/C \(MariaDB.clientVersion)")
    exit(0)
}

/// For now one empty window and a menu with Quit; the app shell replaces it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let appMenu = NSMenu(title: "AirSQL")
        let quit = appMenu.addItem(withTitle: "Quit AirSQL", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.toolTip = "Quit AirSQL"
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(appItem)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "AirSQL"
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.run()
