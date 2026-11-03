import AirSQLCore
import AppKit

/// The session a running Apply uses, for its Cancel.
final class RunningSession: @unchecked Sendable {
    var session: DBConnection?
}

// Apply: the statements in the SQL preview sheet, with what can't be undone said first; then, once the person runs
// them, one at a time on a tools session, and the table read back from the server.
extension TableEditorController {
    func preview(run: Bool) {
        endEditing()  // an edit in progress counts
        guard let window = view.window, applyReason == nil, case .success(let statements) = statements, let database else { return }
        let name = before?.name ?? design.name
        let creating = before == nil
        let change = ChangeSQL(title: (creating ? "Create table " : "Change table ") + database + "." + name, statements: statements,
                               connection: context.connection.id)
        var request = SQLPreviewRequest(
            change: change, heading: creating ? "Create the table \(database).\(name)?" : "Change the table \(database).\(name)?",
            caption: creating ? "The table is created as soon as this runs."
                : "Each statement takes effect as it runs and can't be rolled back. A large table may be copied while it changes, "
                + "and writes to it wait until that is done.")
        request.actionTitle = creating ? "Create" : "Apply"
        request.offersChangeset = true
        request.warnings = warnings(statements)
        request.destructive = !droppedColumns.isEmpty
        SQLPreviewSheet.show(request, connection: context.connection, on: window) { [weak self] result in
            guard result.approved else { return }
            self?.run(change, saveAsChangeset: result.saveAsChangeset)
        }
    }

    /// The columns the design drops (their data goes with them).
    var droppedColumns: [String] {
        guard let before else { return [] }
        let kept = Set(design.columns.compactMap(\.original))
        return before.columns.map(\.name).filter { !kept.contains($0) }
    }

    /// What the preview sheet warns about: several statements that can't be rolled back together, dropped columns, and
    /// columns whose values are converted.
    func warnings(_ statements: [String]) -> [String] {
        var warnings: [String] = []
        if statements.count > 1 {
            warnings.append("These \(statements.count) statements run one after another, and MySQL and MariaDB can't roll table "
                            + "changes back: if one fails, the ones before it stay done.")
        }
        let dropped = droppedColumns
        if !dropped.isEmpty {
            warnings.append("This drops " + (dropped.count == 1 ? "the column " : "the columns ") + dropped.joined(separator: ", ")
                            + ", and every value in " + (dropped.count == 1 ? "it." : "them."))
        }
        let retyped = design.columns.filter { column in
            before?.columns.first { $0.name == column.original }.map { $0.type != column.type } ?? false
        }
        if !retyped.isEmpty {
            warnings.append("Changing the type of " + retyped.map(\.name).joined(separator: ", ") + " converts the values: values "
                            + "that don't fit are refused (strict mode) or cut.")
        }
        return warnings
    }

    /// Runs the change on a tools session, then reads the table back. After a failure the design stays, compared with
    /// what the server has now.
    func run(_ change: ChangeSQL, saveAsChangeset: Bool) {
        guard let database else { return }
        isBusy = true
        updateButtons()
        let running = RunningSession()
        let work = activity.start((before == nil ? "Creating " : "Changing ") + database + "." + (before?.name ?? design.name),
                                  connection: context.connection.id) {
            Task { _ = try? await running.session?.cancel() }
        }
        let context = self.context, oldName = table, newName = design.name
        Task {
            var done = 0
            var failure: Error?
            do {
                try await context.withTools { session in
                    running.session = session
                    for statement in change.statements {
                        _ = try await session.query(statement)
                        done += 1
                    }
                }
            } catch {
                failure = error
            }
            work.end()
            // The server's tables as they are now: the old name, and the new one after a rename or create.
            let applied = failure == nil
            if applied { table = newName }
            let names = Set([oldName, applied ? newName : nil].compactMap { $0 })
            try? await context.schema.refresh(names.map { .table(database: database, name: $0) })
            if let current = applied ? newName : oldName, let fresh = try? await readTable(database, current) {
                before = fresh
                if applied { design = fresh }
            }
            isBusy = false
            undo.removeAllActions()
            designChanged()
            reloadList()
            renameTab()
            if applied, saveAsChangeset { SQLPreviewSheet.changesetWriter?(change, server.noBackslashEscapes) }
            if let failure {
                let message = (failure as? AirSQLError).map { $0.message + "\n\n" + $0.details } ?? failure.localizedDescription
                let state = done == 0 ? "Nothing was changed." : "The first \(done) of \(change.statements.count) statements ran and stay "
                    + "done; the SQL below the table now shows what is left to do."
                showError(message + "\n\n" + state, title: "The server didn't apply the changes", on: view.window)
            }
        }
    }

    /// The table as the editor reads it: from the schema cache, with its options and column checks from a tools session.
    func readTable(_ database: String, _ table: String) async throws -> TableDesign {
        let context = self.context, server = self.server
        guard let cached = context.schema.snapshot.table(database, table) else { throw DesignError("\(table) isn't on the server any more") }
        guard cached.kind == .table else { throw DesignError("\(table) is a \(cached.kind.rawValue), not a table") }
        let read = try await context.read { session in
            try await EditorQueries.table(database, table, server: server, from: session)
        }
        return TableDesign(cached, options: read.options, columnChecks: read.columnChecks, server: server)
    }

    /// The tab's title, after the table got its name on the server.
    func renameTab() {
        guard let main = view.window?.windowController as? MainWindowController,
              let tab = main.tabs.first(where: { $0.content === self }), tab.title != tabTitle else { return }
        main.rename(tab, to: tabTitle)
    }
}
