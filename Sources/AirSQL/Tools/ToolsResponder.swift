import AirSQLCore
import AppKit
import ObjectiveC

/// The client tools' and transfer commands (lane L6): Export…, Restore…, Run SQL File…, Import CSV…, Copy to Another
/// Server… and Open in Terminal, for the connection the window is about. It sits in the main window's responder chain
/// after the window controller (`install`), so the menu bar and the sidebar's menu reach it.
@MainActor
final class ToolsResponder: NSResponder, NSMenuItemValidation {
    private weak var main: MainWindowController?
    private static var key = 0

    /// Puts the commands in `main`'s responder chain (`MainWindowController.init` does), kept as long as the window
    /// controller.
    static func install(on main: MainWindowController) {
        let tools = ToolsResponder()
        tools.main = main
        tools.nextResponder = main.nextResponder
        main.nextResponder = tools
        objc_setAssociatedObject(main, &key, tools, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: Commands

    @objc func exportDatabase(_ sender: Any?) { open { ExportSheet(model: $0, connection: $1, options: $2) } }

    @objc func restoreDatabase(_ sender: Any?) { open { RestoreSheet(model: $0, connection: $1, options: $2, builtIn: false) } }

    @objc func runSQLFile(_ sender: Any?) { open { RestoreSheet(model: $0, connection: $1, options: $2, builtIn: true) } }

    @objc func copyToServer(_ sender: Any?) { open { CopySheet(model: $0, connection: $1, options: $2) } }

    @objc func importCSV(_ sender: Any?) { open { CSVImportSheet(model: $0, connection: $1, options: $2) } }

    @objc func importClipboard(_ sender: Any?) {
        open({ CSVImportSheet(model: $0, connection: $1, options: $2) }, then: { ($0 as? CSVImportSheet)?.pasteRows(nil) })
    }

    /// Copy Result to Table…: `rows` (the column names first) into a table of the window's connection.
    func copyToTable(rows: [[String?]], title: String) {
        open({ CSVImportSheet(model: $0, connection: $1, options: $2) }, then: { ($0 as? CSVImportSheet)?.use(rows: rows, title: title) })
    }

    @objc func openInTerminal(_ sender: Any?) {
        guard let main, let window = main.window, let saved = main.activeConnection else { return }
        Task {
            guard let options = await Self.options(for: saved, model: main.model, on: window) else { return }
            let work = main.model.activity.start("Opening Terminal on \(saved.displayName)", connection: saved.id)
            defer { work.end() }
            do {
                let tools = await ClientTools.find(.client, chosen: saved.clientPath.isEmpty ? main.model.data.settings.clientPath
                                                                                             : saved.clientPath)
                guard let tool = ClientTools.best(ToolCommand.runnable(tools, options: options, server: nil), for: nil)
                        ?? ClientTools.best(tools, for: nil) else {
                    throw AirSQLError(.other, "AirSQL found no mysql or mariadb program. Install MySQL's or MariaDB's client tools "
                        + "(for example with Homebrew), or choose one in Settings ▸ Client Tools.")
                }
                var command = ToolCommand(tool: tool, options: options, server: nil)
                if command.tlsProblem != nil, command.mayRunUnchecked {
                    let alert = Self.uncheckedAlert(name: saved.displayName)
                    guard await alert.beginSheetModal(for: window) == .alertSecondButtonReturn else { return }
                    command.uncheckedCertificate = true  // this time only: nothing is saved
                }
                if let problem = command.tlsProblem { throw AirSQLError(.tls, problem) }
                if let note = command.uncheckedNote {
                    let context = saved.displayName + " tools"
                    DispatchQueue.global(qos: .utility).async { SQLLog.shared.note(note, context: context) }
                }
                try await ToolRun.openInTerminal(command, database: saved.database, name: saved.displayName)
            } catch {
                showError(error.localizedDescription, title: "Can't open Terminal", on: window)
            }
        }
    }

    /// Asks each time Terminal would open without the certificate check: Cancel is the default, and going on is marked
    /// destructive, so it is the person's alone.
    static func uncheckedAlert(name: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open Terminal without checking the certificate?"
        alert.informativeText = "This tool can't check the certificate you trusted for \(name). The connection stays encrypted, "
            + "but it can't prove it's this server, so your login and what you type could be exposed."
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.toolTip = "Don't open Terminal"
        cancel.keyEquivalent = "\r"  // AppKit gives a Cancel button Esc, even as the first one: here it is the default
        let open = alert.addButton(withTitle: "Open Without Checking")
        open.hasDestructiveAction = true
        open.toolTip = "Open Terminal this once with TLS required but no certificate check"
        return alert
    }

    /// The connection the sheets work on: the window's, or, from the navigator (a database's or table's menu, or while
    /// the tree has the focus), the tree's, starting in the selected rows' database.
    private var connection: SavedConnection? {
        guard let main, let (open, database) = main.sidebar.focusedDatabase, var saved = main.model.connection(open.id) else {
            return main?.activeConnection
        }
        saved.database = database
        return saved
    }

    /// Asks for the password if need be, then shows the sheet `make` builds on the main window.
    private func open(_ make: @escaping (AppModel, SavedConnection, ConnectOptions) -> ToolSheet, then: ((ToolSheet) -> Void)? = nil) {
        guard let main, let window = main.window, window.attachedSheet == nil, let saved = connection else { return }
        Task {
            guard let options = await Self.options(for: saved, model: main.model, on: window), window.attachedSheet == nil else { return }
            let sheet = make(main.model, saved, options)
            sheet.show(on: window)
            then?(sheet)
        }
    }

    /// A .csv, .xlsx, .json or .sql.gz dropped or opened from Finder: Import File… or Run SQL File… with the file chosen;
    /// nothing runs until the person presses the sheet's button.
    func open(file url: URL) {
        let csv = ["csv", "tsv", "xlsx", "json", "jsonl"].contains(url.pathExtension.lowercased())
        let (enabled, reason) = availability(csv ? #selector(importCSV(_:)) : #selector(runSQLFile(_:)))
        guard enabled else {
            return showError(reason ?? "Select a connection in the sidebar first", title: "AirSQL can't open “\(url.lastPathComponent)” yet",
                             on: main?.window)
        }
        if csv {
            open({ CSVImportSheet(model: $0, connection: $1, options: $2) }, then: { ($0 as? CSVImportSheet)?.use(url) })
        } else {
            open({ RestoreSheet(model: $0, connection: $1, options: $2, builtIn: true) }, then: { ($0 as? RestoreSheet)?.use(url) })
        }
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let (enabled, reason) = availability(item.action)
        item.explain(enabled: enabled, reason: reason)
        return enabled
    }

    /// Whether a command can run now, and why not.
    func availability(_ action: Selector?) -> (Bool, String?) {
        guard let main else { return (false, nil) }
        // Copy to Another Server only reads this connection: its sheet checks the one it writes to.
        let writes = [#selector(restoreDatabase(_:)), #selector(runSQLFile(_:)), #selector(importCSV(_:)), #selector(importClipboard(_:))]
        if main.window?.attachedSheet != nil { return (false, "A sheet is open: answer it first") }
        guard let connection else {
            return (false, main.selectedConnections.count > 1 ? "Select only one connection" : "Select a connection in the sidebar first")
        }
        if connection.route != .direct, main.model.openConnection(connection.id) == nil {
            return (false, "Connect to \(connection.displayName) first: the client tools go through its SSH or proxy route")
        }
        if let action, writes.contains(action), connection.readOnly {
            return (false, "\(connection.displayName) is read-only: turn that off in the connection's settings to write to it")
        }
        return (true, nil)
    }

    // MARK: The connection's login

    /// The connection's options for the client tools and AirSQL's own sessions, with its password: the connected
    /// connection's (its route's socket, TLS settings and password), else a direct connection's saved settings with the
    /// Keychain's password, or one asked when it isn't saved or is asked each time. Nil when the person cancels.
    static func options(for saved: SavedConnection, model: AppModel, on window: NSWindow) async -> ConnectOptions? {
        if let open = model.openConnection(saved.id) { return open.connection.options }
        let read = model.savedPassword, key = saved.id.uuidString
        var password = saved.askPassword ? nil : await Task.detached { read(key) }.value
        if password == nil {
            password = await withCheckedContinuation { continuation in
                showPasswordPrompt(for: saved.displayName, user: saved.user, retry: false, canRemember: !saved.askPassword,
                                   on: window) { password, remember in
                    // Credentials are the person's (plan §2.8): an agent's typing logs in once, never saved.
                    if let password, remember, !AgentGuard.refuses("Only the person at the Mac can save a password: it was used for this login only.") {
                        let write = model.setSavedPassword
                        DispatchQueue.global(qos: .userInitiated).async { write(key, password) }
                    }
                    continuation.resume(returning: password)
                }
            }
        }
        guard let password else { return nil }
        return saved.connectOptions(password: password, routeSocket: nil)
    }
}
