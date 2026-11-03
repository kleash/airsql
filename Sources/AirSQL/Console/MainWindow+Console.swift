import AirSQLCore
import AppKit
import UniformTypeIdentifiers

/// The window's console commands: New Query (⌘T) on the active connection, Open… a .sql file, and opening a console
/// with SQL in it (the navigator's Generate SELECT, agents' open_in_console). The console's own commands reach the
/// console shown even while the sidebar has the focus.
extension MainWindowController: AgentConsoles {
    /// A new console on the active connection, which starts connecting if it isn't connected.
    @objc func newQuery(_ sender: Any?) {
        guard let connection = activeConnection else { return NSSound.beep() }
        if !isConnected(connection.id) { model.connector.connect(connection.id, on: window) }
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

    /// Agents' open_in_console: the SQL in a new console tab, which says an agent proposed it and never runs it.
    func open(sql: String, title: String, connection: UUID?) -> Tab? {
        let tab = openConsole(text: sql, title: title, connection: connection)
        (tab.content as? ConsoleViewController)?.note(.info, "An agent proposed this SQL: read it before you run it. Nothing "
                                                       + "runs until you press Run.")
        return tab
    }
}

/// A console tab as agents' read_console sees it: its text, its database and the person's last statement.
extension ConsoleViewController: AgentConsole {
    var agentText: String { text }
    var agentDatabase: String? { database }

    var agentLastRun: AgentConsoleRun? {
        if let run = running, run.kind != .explain, run.statements.indices.contains(run.index),
           !run.statements[run.index].range.isEmpty {
            return AgentConsoleRun(sql: run.statements[run.index].sql)
        }
        guard let outcome = lastOutcome else { return nil }
        let rows = outcome.results.compactMap(\.rows).first
        // read_console tells only whether it finished, not when.
        return AgentConsoleRun(sql: outcome.statement.sql, finished: Date(), error: outcome.error?.message, rows: rows,
                               affectedRows: rows == nil ? outcome.results.last?.affectedRows : nil)
    }
}
