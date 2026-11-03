import AirSQLCore
import AppKit

/// The Maintenance submenu: one item per operation, told apart by their tags.
@MainActor
enum NavigatorMenus {
    static func maintenance() -> NSMenuItem {
        MainMenu.submenu("Maintenance", Maintenance.allCases.enumerated().map { index, operation in
            let item = Commands.maintenance.item()
            item.title = operation.title
            item.tag = index
            item.toolTip = tips[operation]
            return item
        })
    }

    static func operation(_ sender: Any?) -> Maintenance? {
        Maintenance.allCases[safe: (sender as? NSMenuItem)?.tag ?? 0]
    }

    static let tips: [Maintenance: String] = [
        .analyze: "Read the selected tables' key distribution again, so the optimizer chooses well",
        .check: "Check the selected tables for errors",
        .optimize: "Rebuild the selected tables to reclaim space and defragment them (locks them while it runs)",
        .repair: "Repair the selected MyISAM, ARIA or ARCHIVE tables",
        .checksum: "Compute a checksum of each selected table's rows, to compare copies",
    ]
}

/// What the navigator's commands do, for the tree and the database view alike: each asks what it needs, shows the
/// SQL before anything changes (plan §1, Data safety), runs it on a session of its own and reads the changes back.
@MainActor
enum NavigatorActions {
    /// Why a command can't act on these objects or databases now; nil: it can.
    static func reason(for action: Selector?, objects: [DatabaseObject], databases: [String], open: OpenConnection?,
                       target: OpenConnection?, model: AppModel?) -> String? {
        let tables = objects.filter { $0.kind == .table }
        let tableLike = objects.filter { $0.kind.isTableLike }
        func writable(_ open: OpenConnection?) -> String? {
            guard let connection = model?.connection(open?.id), connection.readOnly else { return nil }
            return "“\(connection.displayName)” is read-only: turn that off in its connection settings to change anything"
        }
        let onlyTables = tables.isEmpty || tables.count != objects.count ? "Select tables first (not views or other objects)"
            : writable(open)
        switch action {
        case Commands.openData.action?, Commands.openStructure.action?:
            return tableLike.isEmpty ? "Select a table or view in the tree first" : nil
        case Commands.openObject.action?:
            return objects.contains { !$0.kind.isTableLike } ? nil : "Select a routine, trigger or event first"
        case Commands.copyName.action?:
            return objects.isEmpty && databases.isEmpty ? "Select a database or object first" : nil
        case Commands.copyCreate.action?:
            return objects.count == 1 ? nil : "Select one object first"
        case Commands.generateSelect.action?:
            return tableLike.isEmpty || tableLike.count != objects.count ? "Select tables or views first" : nil
        case Commands.generateInsert.action?, Commands.generateUpdate.action?:
            let rows = objects.filter { $0.kind == .table || $0.kind == .view }
            return rows.isEmpty || rows.count != objects.count ? "Select tables or views first (a sequence has no rows to write)" : nil
        case Commands.runRoutine.action?:
            return objects.count == 1 && [.procedure, .function].contains(objects[0].kind) ? nil
                : "Select one procedure or function first"
        case Commands.copyTable.action?:
            return tables.count == 1 && objects.count == 1 ? writable(open) : "Select one table first (a view can't be copied)"
        case Commands.maintenance.action?:
            return onlyTables
        case Commands.truncate.action?, Commands.bulkEdit.action?:
            return onlyTables
        case Commands.rename.action?:
            return tableLike.count == 1 && objects.count == 1 ? writable(open) : "Select one table or view first"
        case Commands.drop.action?:
            if databases.isEmpty == objects.isEmpty {
                return databases.isEmpty ? "Select what to drop first" : "Select databases or objects, not both"
            }
            return writable(open)
        case Commands.newDatabase.action?:
            return target == nil ? "Connect first: databases are created on a connected server" : writable(target)
        case Commands.findOnServer.action?, Commands.processList.action?:
            return target == nil ? "Connect first: this works on a connected server" : nil
        default:
            return nil
        }
    }

    /// Asks, shows the SQL, runs it, and says what went wrong, if anything. `refreshing`: what the cache reads again.
    static func confirmAndRun(_ request: SQLPreviewRequest, on open: OpenConnection, window: NSWindow?, ask: Bool = true,
                              refreshing objects: [SchemaObject], done: (([[StatementResult]]) -> Void)? = nil) {
        let saved = open.model?.connection(open.id)
        // The change is saved as a changeset only once it has run (the preview's box).
        let run: (Bool) -> Void = { changeset in
            Task {
                do {
                    let results = try await open.run(request.change.statements, title: request.change.title, refreshing: objects)
                    if changeset { SQLPreviewSheet.changesetWriter?(request.change) }
                    done?(results)
                } catch {
                    let message = (error as? AirSQLError)?.message ?? error.localizedDescription
                    showError(message, title: "Couldn't \(request.actionTitle.lowercased()): the server said no", on: window)
                }
            }
        }
        // What an agent set off asks whatever the setting (the agents' gate, plan §2.8).
        let agent = AgentGate.agent != nil && safety(open).askBeforeAgentChanges
        guard ask || agent else { return run(false) }
        guard let window else { return }
        SQLPreviewSheet.show(request, connection: saved, on: window) { result in
            if result.approved { run(result.saveAsChangeset) }
        }
    }

    static func safety(_ open: OpenConnection) -> SafetySettings {
        guard let model = open.model, let connection = model.connection(open.id) else { return SafetySettings() }
        return model.data.safety(for: connection)
    }

    static func drop(_ objects: [DatabaseObject], on open: OpenConnection, window: NSWindow?) {
        guard let first = objects.first else { return }
        let statements = NavigatorSQL.drop(objects)
        let what = objects.count == 1 ? "\(first.kind.noun) \(first.name)" : "\(objects.count) objects"
        var request = SQLPreviewRequest(change: ChangeSQL(title: "Drop \(what)", statements: statements, connection: open.id),
                                        heading: "Drop \(what) from \(first.database)?",
                                        caption: "They are deleted from the server for good, with their rows. Each statement "
                                            + "runs on its own; the first that fails stops the rest.")
        request.actionTitle = "Drop"
        request.destructive = true
        let safety = safety(open)
        if safety.typeNameForTables, objects.contains(where: { $0.kind == .table }) {
            request.typeToConfirm = objects.count == 1 ? first.name : first.database
        }
        confirmAndRun(request, on: open, window: window, ask: safety.askBeforeDrop || request.typeToConfirm != nil,
                      refreshing: objects.map(\.schemaObject))
    }

    static func dropDatabases(_ names: [String], on open: OpenConnection, window: NSWindow?) {
        guard let first = names.first else { return }
        let what = names.count == 1 ? "database \(first)" : "\(names.count) databases"
        var request = SQLPreviewRequest(change: ChangeSQL(title: "Drop \(what)", statements: names.map(NavigatorSQL.dropDatabase),
                                                          connection: open.id),
                                        heading: "Drop \(what)?",
                                        caption: "Every table, view, routine, trigger and event in \(names.count == 1 ? "it" : "them") "
                                            + "is deleted from the server for good.")
        request.actionTitle = "Drop"
        request.destructive = true
        request.typeToConfirm = first  // dropping a database always needs its name typed
        confirmAndRun(request, on: open, window: window, refreshing: names.map { .database($0) })
    }

    static func truncate(_ tables: [DatabaseObject], on open: OpenConnection, window: NSWindow?) {
        guard let first = tables.first else { return }
        let what = tables.count == 1 ? first.name : "\(tables.count) tables"
        var request = SQLPreviewRequest(change: ChangeSQL(title: "Empty \(what)", statements: NavigatorSQL.truncate(tables),
                                                          connection: open.id),
                                        heading: "Delete every row of \(what)?",
                                        caption: "TRUNCATE can't be rolled back. Auto-increment counters start again at 1.")
        request.actionTitle = "Truncate"
        request.destructive = true
        let safety = safety(open)
        if safety.typeNameForTables { request.typeToConfirm = tables.count == 1 ? first.name : first.database }
        confirmAndRun(request, on: open, window: window, ask: safety.askBeforeDrop || request.typeToConfirm != nil,
                      refreshing: tables.map(\.schemaObject)) { _ in
            if open.snapshot.database(first.database)?.statistics != nil { open.loadStatistics(first.database) }
        }
    }

    static func rename(_ object: DatabaseObject, on open: OpenConnection, window: NSWindow?) {
        guard let window else { return }
        let field = textField(object.name, placeholder: "New name", id: "rename.name", tip: "The \(object.kind.noun)’s new name",
                              width: 280)
        ask("Rename \(object.name)", "Give \(object.database).\(object.name) a new name.", field: field, action: "Next…",
            on: window) {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != object.name else { return }
            var request = SQLPreviewRequest(change: ChangeSQL(title: "Rename \(object.name)", statements: [
                NavigatorSQL.rename(object, to: name)], connection: open.id),
                heading: "Rename \(object.name) to \(name)?",
                caption: "Views, routines and triggers that use the old name aren't changed and stop working until you edit them.")
            request.actionTitle = "Rename"
            confirmAndRun(request, on: open, window: window,
                          refreshing: [object.schemaObject, DatabaseObject(object.kind, object.database, name).schemaObject])
        }
    }

    static func copyCreate(_ object: DatabaseObject, on open: OpenConnection, window: NSWindow?) {
        Task {
            do {
                let text = try await open.createStatement(object) + ";"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } catch {
                showError((error as? AirSQLError)?.message ?? error.localizedDescription, title: "Couldn't read the definition",
                          on: window)
            }
        }
    }

    enum Generated { case select, insert, update }

    /// Generate SELECT, INSERT or UPDATE: the statement of each table or view, built from the schema cache (their
    /// columns read first where they aren't yet), in a new console tab. Nothing runs until the person presses Run.
    static func generate(_ kind: Generated, _ objects: [DatabaseObject], on open: OpenConnection, main: MainWindowController?) {
        let tables = objects.filter { $0.kind.isTableLike }
        guard let main, !tables.isEmpty else { return }
        Task {
            try? await open.schema.loadDetails(Array(Set(tables.map(\.database))))
            var statements: [String] = []
            for table in tables {
                let schema = open.schema.snapshot.table(table.database, table.name)
                guard kind == .select || schema?.columns.isEmpty == false, let schema else {
                    return showError("AirSQL couldn't read the columns of \(table.name). Refresh and try again.",
                                     title: "Couldn't write the statement", on: main.window)
                }
                switch kind {
                case .select: statements.append(NavigatorSQL.select(table, schema.columns))
                case .insert: statements.append(NavigatorSQL.insert(table, schema.columns))
                case .update: statements.append(NavigatorSQL.update(table, schema))
                }
            }
            let console = main.openConsole(text: statements.joined(separator: "\n\n") + "\n", title: nil, connection: open.id)
                .content as? ConsoleViewController
            if kind != .select { console?.note(.info, "Put a value in place of each ?, then press Run: nothing runs until you do.") }
        }
    }

    /// Run…: a CALL of the procedure (or a SELECT of the function) in a new console tab, `?` for each value it takes
    /// (its parameters read through the schema session). Nothing runs until the person presses Run.
    static func runRoutine(_ routine: DatabaseObject, on open: OpenConnection, main: MainWindowController?) {
        guard let main else { return }
        Task {
            do {
                let parameters = try await open.parameters(routine)
                let console = main.openConsole(text: NavigatorSQL.run(routine, parameters) + "\n", title: nil, connection: open.id)
                    .content as? ConsoleViewController
                if parameters.contains(where: { $0.mode == "IN" || $0.mode == "INOUT" }) {
                    console?.note(.info, "Put a value in place of each ?, then press Run: nothing runs until you do.")
                }
            } catch {
                showError((error as? AirSQLError)?.message ?? error.localizedDescription,
                          title: "Couldn't read the parameters of \(routine.name)", on: main.window)
            }
        }
    }

    /// An alert with one field (or other accessory), as a sheet: `done` when the person chooses `action`.
    static func ask(_ title: String, _ message: String, field: NSView, action: String,
                    tip: String = "Go on: the next step shows the SQL before anything runs", on window: NSWindow,
                    done: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        // An alert lays its accessory out by its frame: as big as its constraints want it.
        field.layoutSubtreeIfNeeded()
        let size = field.fittingSize
        field.translatesAutoresizingMaskIntoConstraints = true
        field.frame = NSRect(origin: .zero, size: size)
        alert.accessoryView = field
        alert.addButton(withTitle: action).toolTip = tip
        alert.addButton(withTitle: "Cancel").toolTip = "Change nothing"
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { done() }
        }
    }
}
