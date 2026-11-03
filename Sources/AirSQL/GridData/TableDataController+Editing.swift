import AirSQLCore
import AppKit

// Editing a table's rows (grid-spec §5): edits, new rows and deletes wait as pending changes, kept on disk for a crash,
// until Apply runs them in one transaction on the data session; Preview SQL shows them first; Revert and undo take
// them back. Typing over several selected cells sets them all.
extension TableDataController: DataGridViewDelegate {
    /// Not on a read-only connection, nor a generated column or a row being deleted. A long value is edited in the
    /// value panel (`dataGrid(_:edit:column:typed:)`).
    func dataGrid(_ grid: DataGridView, canEditRow row: Int, column: Int) -> Bool {
        guard let source, editingOff == nil else { return false }
        return source.canEdit(row, column)
    }

    /// Why nothing can be edited here, if so: a read-only connection, or a table without a key (a view, a sequence).
    var editingOff: String? {
        if context.connection.readOnly {
            return "This connection is read-only: turn that off in Edit Connection… ▸ Options to change rows"
        }
        return source?.readOnlyReason
    }

    /// Typing over several selected cells gives each one the value its column takes (multi-cell edit).
    func dataGrid(_ grid: DataGridView, didEditRow row: Int, column: Int, text: String) {
        let cells = selectedCells()
        if cells.count > 1, cells.contains(where: { $0.row == row && $0.column == column }) {
            setSelected { _ in .text(text) }
        } else {
            keep(.text(text), row: row, column: column)
        }
    }

    func dataGrid(_ grid: DataGridView, sortBy column: Int, adding: Bool) {
        sort(by: column, adding: adding)
    }

    /// The tab's items in the grid's menu, after the viewer's Copy items and before its own.
    func dataGrid(_ grid: DataGridView, menuFor target: DataGridView.Target) -> NSMenu? {
        let menu = NSMenu(title: tableName)
        switch target {
        case .column:
            menu.add([Commands.sortAscending, Commands.sortDescending, Commands.clearSort, nil, Commands.filterByValues,
                      Commands.clearFilter])
        case .row:
            menu.add([Commands.addRow, Commands.duplicateRow, Commands.duplicateRowWithoutKeys, Commands.deleteRows, Commands.revert])
        case .cells:
            menu.addItem(quickFilterItem())
            menu.add([Commands.clearFilter, nil, Commands.setNull, Commands.setDefault])
            let values = insertValueItems()
            if !values.isEmpty { menu.addItem(MainMenu.submenu("Insert Value", values)) }
            if let column = viewer.focusedCell?.column, foreignKey(column) != nil { menu.add([Commands.chooseReferencedRow]) }
            menu.add([nil, Commands.addRow, Commands.duplicateRow, Commands.deleteRows, Commands.revert, nil, Commands.previewChanges,
                      Commands.apply, nil, Commands.exportRows])
        }
        for item in menu.items + (menu.items.compactMap(\.submenu).flatMap(\.items)) where item.target == nil { item.target = self }
        return menu
    }

    // MARK: Selection

    /// The selected cells as (row, source column), the focused cell when nothing is selected; in Transpose and Record
    /// View, the cells they show.
    func selectedCells() -> [(row: Int, column: Int)] { viewer.selectedCells() }

    /// The rows the selection touches, as loaded rows' keys and new rows' ids.
    func selectedRows() -> (keys: [PendingChanges.Key], inserts: [UUID]) {
        guard let source else { return ([], []) }
        var keys: [PendingChanges.Key] = [], inserts: [UUID] = []
        for row in viewer.selectedRows() {
            switch source.row(row) {
            case .loaded: if let key = source.rowKey(row) { keys.append(key) }
            case .inserted(let id): inserts.append(id)
            case nil: break
            }
        }
        return (keys, inserts)
    }

    // MARK: Commands

    @objc func addRow(_ sender: Any?) {
        guard let source, editingOff == nil else { return NSSound.beep() }
        let id = source.changes.addRow()
        changesDidChange()
        focus(row: source.index(of: id))
    }

    @objc func duplicateRow(_ sender: Any?) { duplicate(keepingKeys: true) }
    @objc func duplicateRowWithoutKeys(_ sender: Any?) { duplicate(keepingKeys: false) }

    /// Adds a copy of each selected row; without keys, the key and AUTO_INCREMENT columns are left to the server.
    /// Generated columns are always left out.
    private func duplicate(keepingKeys: Bool) {
        guard let source, editingOff == nil else { return NSSound.beep() }
        var last: UUID?
        for row in viewer.selectedRows() {
            var values: [String: PendingChanges.Value] = [:]
            for (index, column) in source.table.columns.enumerated() where column.generated == nil {
                if !keepingKeys, source.columns[index].isKey || column.autoIncrement { continue }
                if case .inserted(let id) = source.row(row) {
                    values[column.name] = source.changes.insert(id)?.values[column.name]  // a new row's own values only
                } else {
                    values[column.name] = source.value(row, index).map(PendingChanges.Value.text) ?? .null
                }
            }
            last = source.changes.addRow(values)
        }
        changesDidChange()
        focus(row: last.flatMap(source.index(of:)))
    }

    @objc func deleteRows(_ sender: Any?) {
        guard let source, editingOff == nil else { return NSSound.beep() }
        let (keys, inserts) = selectedRows()
        source.changes.delete(keys, inserts: inserts)
        changesDidChange()
    }

    @objc func setCellNull(_ sender: Any?) { setSelected { _ in .null } }
    @objc func setCellDefault(_ sender: Any?) { setSelected { _ in .default } }

    /// Revert (⌥⌘Z): the selected rows' changes.
    @objc func revertChanges(_ sender: Any?) {
        guard let source else { return }
        let (keys, inserts) = selectedRows()
        source.changes.revert(keys, inserts: inserts)
        changesDidChange()
    }

    @objc func revertAllChanges(_ sender: Any?) {
        source?.changes.revertAll()
        changesDidChange()
    }

    @objc func undo(_ sender: Any?) {
        source?.changes.undo()
        changesDidChange()
    }

    @objc func redo(_ sender: Any?) {
        source?.changes.redo()
        changesDidChange()
    }

    /// Selects a row's first cell and scrolls to it (in the grid: out of Transpose and Record View).
    func focus(row: Int?) {
        viewer.backToGrid(nil)
        guard let row, row < grid.rowCount, grid.columnCount > 0 else { return }
        grid.selection.select(GridPosition(row: row, column: 0))
        grid.reveal(grid.cellRect(GridPosition(row: row, column: 0)))
        view.window?.makeFirstResponder(grid)
    }

    /// After every change: kept on disk, redrawn, the bars and the tab's dot brought up to date.
    func changesDidChange() {
        guard let source else { return }
        PendingChangesStore.shared.save(source.changes, connection: context.connection.id, database: database, table: tableName)
        if source.changes.isEmpty { restored = false }
        viewer.reloadData()
        updateBars()
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
    }

    // MARK: Apply

    @objc func applyChanges(_ sender: Any?) { startApply(preview: false) }
    @objc func previewChanges(_ sender: Any?) { startApply(preview: true) }

    /// Shows the SQL first when asked, when Settings ▸ Safety wants it (Production connections), when an agent asked for
    /// it (the person approves it there once, not statement by statement), or when there is a warning (an engine that
    /// can't roll back, cascading deletes); then runs it.
    private func startApply(preview: Bool) {
        // A value being edited is kept first; one its column refuses stays in its editor, which says why.
        viewer.valuePanel?.keepValue(nil)
        guard grid.endEditing(commit: true), viewer.valuePanel?.edited != true else { return }
        guard let source, !source.changes.isEmpty, loading == nil else { return NSSound.beep() }
        bar.busy = true
        loading = Task {
            defer { bar.busy = false }
            let session: TableSession
            do {
                session = try await openSession()
            } catch {
                loading = nil
                return showError((error as? AirSQLError)?.message ?? error.localizedDescription,
                                 title: "AirSQL couldn't reach the server", on: view.window)
            }
            loading = nil
            // Each value as SQL for its column's type, checked again as the server's sql_mode will (a value restored
            // from before, or found and replaced, wasn't checked as it was typed).
            let types = Dictionary(source.table.columns.map { ($0.name, ColumnType($0)) }, uniquingKeysWith: { first, _ in first })
            let values = self.values, statements: [PendingChanges.Statement]
            do {
                statements = try source.changes.statements(database: database, table: tableName, columns: source.columns,
                                                           noBackslashEscapes: session.noBackslashEscapes) { text, column in
                    guard let type = types[column] else { throw EditError("The table has no column \(column) any more") }
                    return try type.literal(text, values)
                }
            } catch {
                if let failure = error as? ApplyFailure { point(at: failure) }
                return showError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                                 title: "Nothing was applied to \(tableName)", on: view.window)
            }
            let warnings = TableEditing.warnings(source.table, database: database, deleting: !source.changes.state.deletes.isEmpty,
                                                 in: context.schema.snapshot)
            let change = ChangeSQL(title: "Apply changes to \(tableName)", statements: statements.map(\.sql), connection: context.connection.id)
            let safety = model.data.safety(for: context.connection)
            let agent = AgentGate.agent != nil && safety.askBeforeAgentChanges
            guard preview || safety.previewBeforeApply || agent || !warnings.isEmpty else {
                return run(statements, on: session, change: change, saveAsChangeset: false)
            }
            guard let window = view.window else { return }
            let rows = source.changes.rowCount
            var request = SQLPreviewRequest(change: change, heading: "Apply \(rows) \(rows == 1 ? "change" : "changes") to \(database).\(tableName)?",
                                            caption: "They run in one transaction. If a row was changed or deleted by someone else "
                                                + "since it was loaded, nothing is applied.")
            request.warnings = warnings
            request.destructive = !source.changes.state.deletes.isEmpty
            request.noBackslashEscapes = session.noBackslashEscapes
            request.offersChangeset = true
            SQLPreviewSheet.show(request, connection: context.connection, on: window) { result in
                guard result.approved else { return }
                self.run(statements, on: session, change: change, saveAsChangeset: result.saveAsChangeset)
            }
        }
    }

    /// Runs the statements; on success the changes are done and the rows read back, on failure nothing was applied and
    /// the grid shows the row.
    private func run(_ statements: [PendingChanges.Statement], on session: TableSession, change: ChangeSQL, saveAsChangeset: Bool) {
        guard let source, loading == nil else { return }
        // One Apply at a time on a connection's data session: a second START TRANSACTION would commit the first's work.
        let connection = context.connection.id
        guard !Self.applying.contains(connection) else {
            return showError("Another tab is applying its changes on this connection. Apply again once it has finished.",
                             title: "Nothing was applied to \(tableName)", on: view.window)
        }
        Self.applying.insert(connection)
        bar.busy = true
        let activity = model.activity.start("Applying changes to \(tableName)", connection: connection)
        loading = Task {
            defer { Self.applying.remove(connection) }
            do {
                var insertIDs: [UInt64] = []
                try await PendingChanges.apply(statements) { sql in
                    let result = try await session.query(sql, rowCap: 1).last
                    if sql.hasPrefix("INSERT ") { insertIDs.append(result?.insertID ?? 0) }
                    return result?.affectedRows ?? 0
                }
                // New rows stay where they were, with what the server filled in (their AUTO_INCREMENT key, defaults);
                // rows read back by an earlier Apply are read again (this one may have changed them) or dropped (deleted).
                let readBack = savedQueries(deleted: source.changes.state.deletes) + readBackQueries(statements, insertIDs: insertIDs)
                source.changes = PendingChanges(keyColumns: source.changes.keyColumns)
                changesDidChange()
                if saveAsChangeset { SQLPreviewSheet.changesetWriter?(change) }
                var saved: [ResultStore] = []
                for sql in readBack {
                    if let row = try? await session.query(sql, rowCap: 1).first?.rows, row.rowCount == 1 { saved.append(row) }
                }
                source.setSaved(saved)
                activity.end()
                loading = nil
                loadRows(more: false, through: source.loadedRows, keepingSaved: true)
            } catch {
                activity.end()
                loading = nil
                bar.busy = false
                if let failure = error as? ApplyFailure { point(at: failure) }
                showError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                          title: "Nothing was applied to \(tableName)", on: view.window)
            }
        }
    }

    /// The SELECTs that read the new rows back after Apply, by their key: the insert ID stands in for an AUTO_INCREMENT
    /// key left to the server. None for a row whose key the server made some other way (a DEFAULT such as UUID()), nor
    /// past 100 new rows: the rows loading again show those.
    private func readBackQueries(_ statements: [PendingChanges.Statement], insertIDs: [UInt64]) -> [String] {
        guard let source, let keyColumns = source.table.editingKey else { return [] }
        let inserts = statements.compactMap { statement -> UUID? in
            if case .insert(let id) = statement.target { return id }
            return nil
        }
        guard inserts.count == insertIDs.count, inserts.count <= 100 else { return [] }
        return zip(inserts, insertIDs).compactMap { id, insertID in
            guard let given = source.changes.insert(id)?.values else { return nil }
            var literals: [String: String] = [:]
            for name in keyColumns {
                guard case .text(let text)? = given[name], let column = source.table.column(name) else { continue }
                literals[name] = try? ColumnType(column).literal(text, values)
            }
            return try? source.table.readBackQuery(database: database, values: literals, insertID: insertID)
        }
    }

    /// The SELECTs that read the rows an earlier Apply read back again, by their key, but not the ones deleted.
    private func savedQueries(deleted: Set<PendingChanges.Key>) -> [String] {
        guard let source, let keyColumns = source.table.editingKey else { return [] }
        let columns = Dictionary(source.columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return source.savedKeys.filter { !deleted.contains($0) }.compactMap { key in
            let literals = Dictionary(zip(keyColumns, key).map { name, text in
                (name, (columns[name] ?? GridColumn(name: name)).literal(text, noBackslashEscapes: noBackslashEscapes))
            }, uniquingKeysWith: { first, _ in first })
            return try? source.table.readBackQuery(database: database, values: literals, insertID: 0)
        }
    }

    /// The connections whose data session is running an Apply.
    static var applying: Set<UUID> = []

    /// Selects the row a failed statement was for: the cell, when the failure names its column.
    private func point(at failure: ApplyFailure) {
        guard let source else { return }
        let row: Int?
        switch failure.statement.target {
        case .update(let key): row = source.index(of: key)
        case .delete(let keys): row = keys.lazy.compactMap(source.index(of:)).first
        case .insert(let id): row = source.index(of: id)
        }
        guard let row else { return }
        viewer.backToGrid(nil)
        let name = failure.column(in: source.table)
        guard let column = source.columns.firstIndex(where: { $0.name == name }), let shown = grid.columnOrder.firstIndex(of: column) else {
            grid.selection.selectRow(row)
            return grid.reveal(grid.rowRect(row))
        }
        let cell = GridPosition(row: row, column: shown)
        grid.selection.select(cell)
        grid.reveal(grid.cellRect(cell))
        view.window?.makeFirstResponder(grid)
    }
}
