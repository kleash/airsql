import AirSQLCore
import AppKit
import ObjectiveC

/// The Liquibase commands (lane L8b): Tools ▸ Generate Liquibase Changelog… for the connection the window is about,
/// and Query ▸ Save as Changeset… for the console's selected statements (the console leaves the command to this). It
/// sits in the main window's responder chain after the window controller and the client tools (`install`), and gives
/// the SQL preview sheet its "Save as Liquibase changeset" writer.
@MainActor
final class LiquibaseResponder: NSResponder, NSMenuItemValidation {
    private weak var main: MainWindowController?
    private static var key = 0

    /// Puts the commands in `main`'s responder chain (`MainWindowController.init` does), kept as long as the window
    /// controller, and sets the preview sheet's changeset writer.
    static func install(on main: MainWindowController) {
        let responder = LiquibaseResponder()
        responder.main = main
        // After the client tools' responder, which comes right after the window controller.
        let after: NSResponder = main.nextResponder as? ToolsResponder ?? main
        responder.nextResponder = after.nextResponder
        after.nextResponder = responder
        objc_setAssociatedObject(main, &key, responder, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let model = main.model
        // A change has run and the person ticked "Save as Liquibase changeset": shown on the window it ran from.
        SQLPreviewSheet.changesetWriter = { change in
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            ChangesetSheet.show([Liquibase.changeset(change, rollback: model.data.settings.liquibase.rollback)],
                                heading: "Save “\(change.title)” as a changeset", model: model, on: window)
        }
    }

    // MARK: Commands

    @objc func generateLiquibase(_ sender: Any?) {
        guard let main, let window = main.window, window.attachedSheet == nil, let saved = main.activeConnection else { return }
        Task {
            guard let options = await ToolsResponder.options(for: saved, model: main.model, on: window),
                  window.attachedSheet == nil else { return }
            LiquibaseSheet(model: main.model, connection: saved, options: options).show(on: window)
        }
    }

    @objc func saveAsChangeset(_ sender: Any?) {
        guard let main, let window = main.window, let console = main.selectedTab?.content as? ConsoleViewController else { return }
        let statements = Self.statements(of: console)
        guard !statements.isEmpty else { return }
        let title = main.selectedTab?.title ?? "Console"
        let changeset = Liquibase.changeset(title: title, statements: statements, rollback: main.model.data.settings.liquibase.rollback)
        ChangesetSheet.show([changeset], heading: "Save " + (statements.count == 1 ? "the statement" : "\(statements.count) statements")
                            + " as a changeset", model: main.model, on: window)
    }

    /// The console's selected statements, else the one at the insertion point.
    static func statements(of console: ConsoleViewController) -> [String] {
        guard console.isViewLoaded else { return [] }
        let text = console.text, range = console.editor.selectedRange(), escapes = console.editor.noBackslashEscapes
        if range.length > 0 {
            return SQLSplitter.statements(in: (text as NSString).substring(with: range), noBackslashEscapes: escapes).map(\.sql)
        }
        return SQLSplitter.statement(at: range.location, in: text, noBackslashEscapes: escapes).map { [$0.sql] } ?? []
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let reason = why(item.action)
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }

    /// Why a command can't run now; nil when it can.
    private func why(_ action: Selector?) -> String? {
        guard let main else { return "" }
        if main.window?.attachedSheet != nil { return "A sheet is open: answer it first" }
        switch action {
        case #selector(saveAsChangeset(_:)):
            guard let console = main.selectedTab?.content as? ConsoleViewController else {
                return "Open a console tab with the statements to save"
            }
            return Self.statements(of: console).isEmpty ? "Type the statements to save, or select them" : nil
        default:
            guard let connection = main.activeConnection else {
                return main.selectedConnections.count > 1 ? "Select only one connection" : "Select a connection in the sidebar first"
            }
            return connection.route == .direct ? nil : "Liquibase changelogs reach SSH and proxy routes once AirSQL has connected through them"
        }
    }
}
