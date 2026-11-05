import AirSQLCore
import AppKit

/// A result moved off the console's bar into a window of its own, there until it is closed.
@MainActor
final class ResultWindowController: NSWindowController, NSWindowDelegate {
    static var open: [ResultWindowController] = []
    let tab: ResultTab

    init(_ tab: ResultTab, title: String) {
        self.tab = tab
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true)
        super.init(window: window)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        tab.view.removeFromSuperview()
        window.contentView = tab.view
        window.center()
        Self.open.append(self)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let rows = tab.pendingRows
        guard rows > 0 else { return true }
        ConsoleClosing.alert(sender, "Discard the edits to \(rows == 1 ? "a row" : "\(rows.formatted()) rows")?",
                             "They aren't applied yet, and closing the window loses them.",
                             buttons: [("Discard", "Close and lose the edits"), ("Cancel", "Keep the window open to apply them")],
                             destructive: 0) { [weak self] choice in
            if choice == 0 { self?.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) { Self.open.removeAll { $0 === self } }
}
