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
        // A change has run and the person ticked "Save as Liquibase changeset": the editors and the tree that run them are
        // in the main window.
        SQLPreviewSheet.changesetWriter = { [weak main] change, noBackslashEscapes in
            guard let main, let window = main.window else { return }
            ChangesetSheet.show([Liquibase.changeset(change, noBackslashEscapes: noBackslashEscapes,
                                                     rollback: main.model.data.settings.liquibase.rollback)],
                                heading: "Save “\(change.title)” as a changeset", model: main.model, on: window)
        }
    }

    // MARK: Commands

    /// The tree's database (a database's right-click menu), else the window's connection with its own database chosen.
    @objc func generateLiquibase(_ sender: Any?) {
        guard let main, let window = main.window, window.attachedSheet == nil else { return }
        let tree = main.sidebar.treeSelection
        guard let saved = tree.flatMap({ main.model.connection($0.open.id) }) ?? main.activeConnection else { return }
        Task {
            guard let options = await ToolsResponder.options(for: saved, model: main.model, on: window),
                  window.attachedSheet == nil else { return }
            LiquibaseSheet(model: main.model, connection: saved, options: options, database: tree?.nodes.first?.database).show(on: window)
        }
    }

    /// The console's selected statements, else the one at the caret, as Run picks them. A compare's sync script goes back
    /// to its compare, as Run does, which saves a changeset per step.
    @objc func saveAsChangeset(_ sender: Any?) {
        guard let main, let window = main.window, let console = main.selectedTab?.content as? ConsoleViewController,
              console.isViewLoaded else { return }
        if let compare = console.syncChangesets {
            if !compare() { console.note(.info, "The compare window that made this script is closed: compare again to save it.") }
            return
        }
        let selection = console.editor.selectedRange()
        let statements = ConsoleScript.statements(in: console.text, selection: selection.length > 0 ? Range(selection) : nil,
                                                  caret: selection.location, all: false,
                                                  noBackslashEscapes: console.editor.noBackslashEscapes).map(\.sql)
        guard !statements.isEmpty else {
            return console.note(.info, "There is no statement here to save: type one, or put the cursor in one.")
        }
        let title = main.selectedTab?.title ?? "Query"
        let changeset = Liquibase.changeset(title: title, statements: statements, noBackslashEscapes: console.editor.noBackslashEscapes,
                                            rollback: main.model.data.settings.liquibase.rollback)
        ChangesetSheet.show([changeset], heading: "Save " + (statements.count == 1 ? "the statement" : "\(statements.count) statements")
                            + " as a changeset", model: main.model, on: window)
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
                return "Open a query tab with the statements to save"
            }
            return console.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Type the statements to save first" : nil
        default:
            if main.sidebar.treeSelection != nil { return nil }
            guard let connection = main.activeConnection else {
                return main.selectedConnections.count > 1 ? "Select only one connection" : "Select a connection in the sidebar first"
            }
            if connection.route != .direct, main.model.openConnection(connection.id) == nil {
                return "Connect to \(connection.displayName) first: the changelog is read through its SSH or proxy route"
            }
            return nil
        }
    }
}
