import AirSQLCore
import AppKit
import UniformTypeIdentifiers

/// The window's console commands: New Query (⌘T) on the active connection, Open… a .sql file, and opening a console
/// with SQL in it (the navigator's Generate SELECT, agents' open_in_console). The console's own commands reach the
/// console shown even while the sidebar has the focus.
extension MainWindowController {
    @objc func newQuery(_ sender: Any?) {
        guard let connection = activeConnection else { return NSSound.beep() }
        openConsole(text: "", title: nil, connection: connection.id)
    }

    /// Opens a console tab on `connection` holding `text`, named `title` or "Query N".
    @discardableResult
    func openConsole(text: String, title: String?, connection: UUID?, fileURL: URL? = nil) -> Tab {
        let console = ConsoleViewController(model: model, connection: connection, text: text, fileURL: fileURL)
        let tab = open(console, title: title ?? fileURL?.lastPathComponent ?? nextQueryTitle(), connection: connection)
        ConsoleDocuments.shared.changed(console)
        return tab
    }

    /// "Query N", N one more than the largest open.
    func nextQueryTitle() -> String {
        let numbers = tabs.compactMap { tab -> Int? in
            guard tab.title.hasPrefix("Query ") else { return nil }
            return Int(tab.title.dropFirst("Query ".count))
        }
        return "Query \((numbers.max() ?? 0) + 1)"
    }

    @objc func openSQLFile(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = true
        panel.message = "Open .sql files in console tabs"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.openFiles(panel.urls)
        }
    }

    /// Opens each file in a console tab of the active connection (reading them off the main thread); a file already
    /// open shows its tab.
    func openFiles(_ urls: [URL]) {
        let connection = activeConnection?.id
        Task {
            for url in urls {
                if let tab = tabs.first(where: { ($0.content as? ConsoleViewController)?.fileURL == url }) {
                    select(tab)
                    continue
                }
                let read = await Task.detached { () -> Result<String, Error> in
                    Result { try String(contentsOf: url, encoding: .utf8) }
                }.value
                switch read {
                case .success(let text): openConsole(text: text, title: nil, connection: connection, fileURL: url)
                case .failure(let error):
                    showError(error.localizedDescription, title: "AirSQL couldn't open “\(url.lastPathComponent)”", on: window)
                }
            }
        }
    }

    /// A console command sent while the focus is elsewhere in the window (the sidebar, the tab bar) goes to the console
    /// shown, as the toolbar's Run does.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let console = selectedTab?.content as? ConsoleViewController, console.isViewLoaded, console.responds(to: action) {
            return console
        }
        return super.supplementalTarget(forAction: action, sender: sender)
    }
}
