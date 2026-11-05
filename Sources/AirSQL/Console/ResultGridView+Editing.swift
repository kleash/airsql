import AirSQLCore
import AppKit

extension ResultEditSource: GridBytes {}

// Editing a console result (grid-spec §5, R15): a SELECT from one table that includes its key, or an inner join with
// every table's key, edits as a table tab does: changes wait until Apply, which runs them in one transaction on the data
// session (a join's shows the SQL first), then reads the edited rows back. Read-only cells say why when double-clicked.
extension ResultGridView {
    var edits: ResultEditSource? { source as? ResultEditSource }

    /// Works out which columns of the result of `sql` can be edited: the tables it names are read into the schema cache
    /// first, then the rules run off the main thread. `database`: the console's, for columns that don't name theirs.
    func prepareEditing(sql: String, database: String?, noBackslashEscapes: Bool) {
        guard let edits, let context = editingContext else { return }
        let sessions = context.sessions
        let open = openSession ?? { try await sessions.session(.data) }
        openSession = open
        viewer.keepValue = { [weak self] row, column, text in self?.keep(.text(text), row: row, column: column) }
        viewer.whyReadOnly = { [weak self] row, column in self?.whyReadOnly(row, column) }
        let store = edits.store, schema = context.schema
        let databases = Set(store.columns.map { $0.database.isEmpty ? database ?? "" : $0.database }).filter { !$0.isEmpty }
        Task {
            if ResultEditing.statementRefusal(sql, noBackslashEscapes: noBackslashEscapes) == nil, !databases.isEmpty {
                try? await schema.loadDetails(databases.sorted())
            }
            let snapshot = schema.snapshot
            let editing = await Task.detached {
                ResultEditing(sql: sql, store: store, snapshot: snapshot, defaultDatabase: database, noBackslashEscapes: noBackslashEscapes)
            }.value
            edits.setEditing(editing, snapshot: snapshot)
            if editing.isEditable, editingOff == nil, let session = try? await open(),
               let values = try? await session.query("SELECT @@SESSION.sql_mode, @@SESSION.time_zone", rowCap: 1).first?.rows,
               values.rowCount > 0, values.columns.count == 2 {
                editContext = EditContext(server: snapshot.server ?? SchemaServer(version: ""), sqlMode: values.string(0, 0) ?? "",
                                          timeZone: values.string(0, 1) ?? "SYSTEM")
            }
            updateEditing()
        }
    }

    /// Why nothing here can be edited, if so: a read-only connection.
    var editingOff: String? {
        editingContext?.connection.readOnly == true
            ? "This connection is read-only: turn that off in Edit Connection… ▸ Options to change rows" : nil
    }

    /// Why a cell (the viewer's row) can't be edited; nil when it can.
    func whyReadOnly(_ row: Int, _ column: Int) -> String? {
        guard let edits else { return nil }
        return editingOff ?? edits.reason(column) ?? (edits.canEdit(rows.baseRow(row), column) ? nil : "The row is marked for deletion")
    }

    /// What the values may be: the data session's sql_mode, or the server's alone until it is read.
    var values: EditContext {
        editContext ?? EditContext(server: editingContext?.schema.snapshot.server ?? SchemaServer(version: ""), sqlMode: "")
    }

    /// The notice and the status bar's word after every change.
    func updateEditing() {
        guard let edits else { return }
        let rowsChanged = edits.pendingRows
        let join = edits.editing?.needsPreview == true
        notice.show(.pending, edits.isEmpty ? nil : "\(rowsChanged.formatted()) \(rowsChanged == 1 ? "row has" : "rows have") pending "
                    + "changes. Apply (⌘S with the rows focused) writes them in one transaction" + (join ? ", after showing the SQL." : "."))
        editState.isHidden = edits.editing == nil
        if edits.editing?.isEditable == true, editingOff == nil {
            editState.stringValue = "Editable"
            editState.toolTip = "Double-click a cell to change it; changes wait until you apply them"
                + (join ? ". Apply shows the SQL first, as the result joins several tables" : "")
        } else {
            editState.stringValue = "Read-only"
            let first = edits.store.columns.indices.first { !edits.store.columns[$0].originalTable.isEmpty } ?? 0
            editState.toolTip = editingOff ?? (edits.columns.isEmpty ? nil : edits.reason(first))
        }
        viewer.reloadData()
        viewer.status.update()
        updateToolbarEditing()
    }

    /// A result that can't be edited has no editing buttons.
    func updateToolbarEditing() {
        toolbar.left = edits?.editing?.isEditable == true ? [] : Set(GridToolbar.Item.changeItems.map(\.command.action))
    }

    // MARK: Changes

    /// Not while an Apply runs on the connection (it would take the edit with the others).
    func dataGrid(_ grid: DataGridView, canEditRow row: Int, column: Int) -> Bool {
        guard let id = editingContext?.connection.id, !TableDataController.applying.contains(id) else { return false }
        return editingOff == nil && edits?.canEdit(rows.baseRow(row), column) == true
    }

    func dataGrid(_ grid: DataGridView, check text: String, row: Int, column: Int) -> String? {
        refusal(.text(text), column: column)
    }

    /// Typing over several selected cells sets each one that takes the value.
    func dataGrid(_ grid: DataGridView, didEditRow row: Int, column: Int, text: String) {
        let cells = viewer.selectedCells()
        if cells.count > 1, cells.contains(where: { $0.row == row && $0.column == column }) {
            setSelected { _ in .text(text) }
        } else {
            keep(.text(text), row: row, column: column)
        }
    }

    /// Why the value can't go in the column, nil when it can.
    func refusal(_ value: PendingChanges.Value, column: Int) -> String? {
        guard let edits else { return nil }
        guard case .text(let text) = value, let type = edits.type(column) else {
            return value == .null && !edits.nullable(column) ? "\(edits.columns[column].name) can't be NULL" : nil
        }
        do {
            _ = try type.literal(text, values)
            return nil
        } catch {
            return (error as? EditError)?.message ?? error.localizedDescription
        }
    }

    /// Keeps a value as the cell's pending change (the viewer's row).
    func keep(_ value: PendingChanges.Value, row: Int, column: Int) {
        guard let edits, refusal(value, column: column) == nil else { return NSSound.beep() }
        edits.set(value, row: rows.baseRow(row), column: column)
        updateEditing()
    }

    /// Gives each selected cell that takes it the value `make` returns for its column, as one step for undo.
    func setSelected(_ make: (Int) -> PendingChanges.Value?) {
        guard let edits, editingOff == nil else { return NSSound.beep() }
        edits.group {
            for cell in viewer.selectedCells() where edits.canEdit(rows.baseRow(cell.row), cell.column) {
                guard let value = make(cell.column), refusal(value, column: cell.column) == nil else { continue }
                edits.set(value, row: rows.baseRow(cell.row), column: cell.column)
            }
        }
        updateEditing()
    }

    /// The source's rows the selection touches.
    private var selectedRows: [Int] { viewer.selectedRows().map(rows.baseRow) }

    @objc func setCellNull(_ sender: Any?) { setSelected { _ in .null } }
    @objc func setCellDefault(_ sender: Any?) { setSelected { _ in .default } }

    /// Cut: copies the selected cells, then clears them (NULL where the column allows it), as pending edits.
    @objc func cut(_ sender: Any?) {
        viewer.copy(sender)
        setSelected { [edits] in edits?.nullable($0) == true ? .null : .text("") }
    }

    @objc func deleteRows(_ sender: Any?) {
        guard let edits, edits.canDelete, editingOff == nil else { return NSSound.beep() }
        edits.delete(selectedRows)
        updateEditing()
    }

    @objc func revertChanges(_ sender: Any?) {
        edits?.revert(selectedRows)
        updateEditing()
    }

    @objc func revertAllChanges(_ sender: Any?) {
        edits?.revert()
        updateEditing()
    }

    @objc func undo(_ sender: Any?) {
        edits?.undo()
        updateEditing()
    }

    @objc func redo(_ sender: Any?) {
        edits?.redo()
        updateEditing()
    }

    /// ⌘S with pending changes applies them: the console's Save stands aside (`responds(to:)`) while the rows have the
    /// keyboard.
    @objc func saveQuery(_ sender: Any?) { applyChanges(sender) }

    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(AirSQLActions.saveQuery(_:)) { return edits?.isEmpty == false }
        // Text being typed undoes itself: ⌘Z goes on past the result to the window's undo manager.
        // Likewise ⌘⌫: off here, it reaches the text as delete to the line's start.
        if [Commands.undo.action, Commands.redo.action, Commands.deleteRows.action].contains(selector), window?.firstResponder is NSTextView { return false }
        if Self.editingActions.contains(selector) { return edits?.editing?.isEditable == true }
        return super.responds(to: selector)
    }

    private static let editingActions: Set<Selector> = [
        Commands.setNull.action, Commands.setDefault.action, Commands.insertValue.action, Commands.chooseReferencedRow.action,
        Commands.cut.action, Commands.paste.action, Commands.deleteRows.action, Commands.revert.action, Commands.apply.action,
        Commands.previewChanges.action, #selector(revertAllChanges(_:)), Commands.undo.action, Commands.redo.action,
    ]

    /// Whether an editing command can act now, and why not; nil for the other commands (`validateMenuItem`).
    func editingState(_ menuItem: NSMenuItem) -> (Bool, String?)? {
        guard let edits else { return nil }
        switch menuItem.action {
        case Commands.setNull.action:
            if let off = editingOff { return (false, off) }
            let cells = viewer.selectedCells(limit: 10_000).filter { edits.canEdit(rows.baseRow($0.row), $0.column) }
            return (cells.contains { edits.nullable($0.column) }, cells.isEmpty ? "Select cells you can edit first" : "These columns can't be NULL")
        case Commands.paste.action:
            if let off = editingOff { return (false, off) }
            return (TableDataController.clipboard != nil, "Copy some cells first")
        case Commands.chooseReferencedRow.action:
            if let off = editingOff { return (false, off) }
            return (viewer.focusedCell.map { foreignKey($0.column) != nil } ?? false, "Select a cell of a foreign key column first")
        case Commands.cut.action, Commands.setDefault.action, Commands.insertValue.action:
            if let off = editingOff { return (false, off) }
            return (viewer.selectedCells(limit: 10_000).contains { edits.canEdit(rows.baseRow($0.row), $0.column) }, "Select cells you can edit first")
        case Commands.deleteRows.action:
            return editingOff.map { (false, $0) } ?? (!selectedRows.isEmpty, "Select the rows first")
        case Commands.revert.action:
            return (selectedRows.contains(where: edits.isChanged), "The selected rows have no pending changes")
        case Commands.apply.action, Commands.save.action, Commands.previewChanges.action, #selector(revertAllChanges(_:)):
            return (!edits.isEmpty, "No changes are pending")
        case Commands.undo.action: return (edits.canUndo, "Nothing to undo")
        case Commands.redo.action: return (edits.canRedo, "Nothing to redo")
        default: return nil
        }
    }

    // MARK: Apply

    @objc func applyChanges(_ sender: Any?) { startApply(preview: false) }
    @objc func previewChanges(_ sender: Any?) { startApply(preview: true) }

    /// Shows the SQL first when asked, for a join, when Settings ▸ Safety wants it, when an agent asked, or when there is
    /// a warning; then runs it.
    private func startApply(preview: Bool) {
        guard grid.endEditing(commit: true), let edits, !edits.isEmpty, let context = editingContext, let model, let window else {
            return NSSound.beep()
        }
        let title = "Nothing was applied"
        if let off = editingOff { return showError(off + ".", title: title, on: window) }
        // A transaction open in the console may hold these rows: Apply's own would wait for it.
        if transactionOpen() {
            return showError("This query tab has a transaction open. Commit or roll it back first, so Apply doesn't wait for its locks.",
                             title: title, on: window)
        }
        let statements: [PendingChanges.Statement]
        do {
            statements = try edits.statements(context: values)
        } catch {
            if let failure = error as? ApplyFailure { point(at: failure) }
            return showError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, title: title, on: window)
        }
        guard let editing = edits.editing else { return }
        let warnings = edits.tables.indices.flatMap { index in
            TableEditing.warnings(edits.tables[index], database: editing.sources[index].database,
                                  deleting: !edits.changes[index].state.deletes.isEmpty, in: context.schema.snapshot)
        }
        let names = edits.tables.map(\.name).joined(separator: ", ")
        let change = ChangeSQL(title: "Apply changes to \(names)", statements: statements.map(\.sql), connection: context.connection.id)
        let safety = model.data.safety(for: context.connection)
        let agent = AgentGate.agent != nil && safety.askBeforeAgentChanges
        guard preview || editing.needsPreview || safety.previewBeforeApply || agent || !warnings.isEmpty else {
            return run(statements, change: change, saveAsChangeset: false)
        }
        let count = edits.pendingRows
        var request = SQLPreviewRequest(change: change, heading: "Apply \(count) \(count == 1 ? "change" : "changes") to \(names)?",
                                        caption: TableEditing.applyCaption(reading: "the query read it", unchecked: edits.uncheckedColumns))
        request.warnings = warnings
        request.destructive = edits.changes.contains { !$0.state.deletes.isEmpty }
        request.noBackslashEscapes = values.noBackslashEscapes
        request.offersChangeset = true
        SQLPreviewSheet.show(request, connection: context.connection, on: window) { [weak self] result in
            guard result.approved else { return }
            self?.run(statements, change: change, saveAsChangeset: result.saveAsChangeset)
        }
    }

    /// Runs the statements on the data session; on success the edited rows are read back, on failure nothing was
    /// applied and the grid shows the cell.
    private func run(_ statements: [PendingChanges.Statement], change: ChangeSQL, saveAsChangeset: Bool) {
        guard let edits, let context = editingContext, let model, let open = openSession else { return }
        // One Apply at a time on a connection's data session: a second START TRANSACTION would commit the first's work.
        let connection = context.connection.id
        guard !TableDataController.applying.contains(connection) else {
            return showError("Another tab is applying its changes on this connection. Apply again once it has finished.",
                             title: "Nothing was applied", on: window)
        }
        TableDataController.applying.insert(connection)
        notice.apply.isEnabled = false
        let stop = ApplyStop()
        let activity = model.activity.start("Applying changes to a result", connection: connection) { stop.stop() }
        Task {
            defer {
                TableDataController.applying.remove(connection)
                notice.apply.isEnabled = true
                activity.end()
            }
            do {
                let session = try await open()
                stop.session = session
                try await PendingChanges.apply(statements) { sql in
                    try stop.starting(sql)
                    return try await session.query(sql, rowCap: 1).last?.affectedRows ?? 0
                }
                var read: [(rows: ResultStore, source: Int, columns: [Int])] = []
                for item in edits.readBack(noBackslashEscapes: session.noBackslashEscapes) {
                    if let rows = try? await session.query(item.sql, rowCap: PendingChanges.deleteBatch).first?.rows {
                        read.append((rows, item.source, item.columns))
                    }
                }
                edits.applied(read)
                if saveAsChangeset { SQLPreviewSheet.changesetWriter?(change, self.values.noBackslashEscapes) }
                // Deleted rows are gone: filter and sort what is left again.
                if rows.order != nil { reorder() }
                updateEditing()
            } catch {
                if let failure = error as? ApplyFailure { point(at: failure) }
                showError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, title: "Nothing was applied",
                          on: window)
            }
        }
    }

    /// Selects the cell (or the row) a failed statement was for.
    private func point(at failure: ApplyFailure) {
        guard let place = edits?.position(of: failure) else { return }
        viewer.backToGrid(nil)
        let row = rows.order?.firstIndex(of: place.row) ?? place.row
        guard let column = place.column.flatMap(grid.columnOrder.firstIndex(of:)) else {
            grid.selection.selectRow(row)
            return grid.reveal(grid.rowRect(row))
        }
        grid.selection.select(GridPosition(row: row, column: column))
        grid.reveal(grid.cellRect(GridPosition(row: row, column: column)))
        window?.makeFirstResponder(grid)
    }
}
