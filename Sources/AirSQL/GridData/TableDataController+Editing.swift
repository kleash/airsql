import AirSQLCore
import AppKit

// Editing a table's rows (grid-spec §5): edits, new rows and deletes wait as pending changes, kept on disk for a crash,
// until Apply runs them in one transaction on the data session; Preview SQL shows them first; Revert and undo take
// them back. Typing over several selected cells sets them all.
extension TableDataController: DataGridViewDelegate {
    func dataGrid(_ grid: DataGridView, canEditRow row: Int, column: Int) -> Bool {
        source?.canEdit(row, column) == true
    }

    func dataGrid(_ grid: DataGridView, didEditRow row: Int, column: Int, text: String) {
        guard let source else { return }
        let cells = selectedCells()
        if cells.count > 1, cells.contains(where: { $0.row == row && $0.column == column }) {
            for cell in cells where source.canEdit(cell.row, cell.column) { source.set(.text(text), row: cell.row, column: cell.column) }
        } else {
            source.set(.text(text), row: row, column: column)
        }
        changesDidChange()
    }

    func dataGrid(_ grid: DataGridView, sortBy column: Int, adding: Bool) {
        sort(by: column, adding: adding)
    }

    func dataGrid(_ grid: DataGridView, menuFor target: DataGridView.Target) -> NSMenu? {
        let menu = NSMenu(title: tableName)
        switch target {
        case .column:
            menu.add([Commands.sortAscending, Commands.sortDescending, Commands.clearSort, nil, Commands.filterByValues,
                      Commands.clearFilter, nil, Commands.copyColumnName])
        case .row:
            menu.add([Commands.copy, Commands.copyWithHeaders])
            menu.addItem(GridCopy.copyAsItem())
            menu.add([nil, Commands.addRow, Commands.duplicateRow, Commands.duplicateRowWithoutKeys, Commands.deleteRows,
                      Commands.revert])
        case .cells:
            menu.add([Commands.copy, Commands.copyWithHeaders])
            menu.addItem(GridCopy.copyAsItem())
            menu.addItem(.separator())
            menu.addItem(quickFilterItem())
            menu.add([Commands.clearFilter, nil, Commands.setNull, Commands.setDefault, nil, Commands.addRow, Commands.duplicateRow,
                      Commands.deleteRows, Commands.revert, nil, Commands.previewChanges, Commands.apply, nil, Commands.exportRows])
        }
        for item in menu.items where item.target == nil { item.target = self }
        return menu
    }

    // MARK: Selection

    /// The selected cells as (row, source column), the focused cell when nothing is selected.
    func selectedCells() -> [(row: Int, column: Int)] {
        let (rows, columns) = GridCopy.covered(grid)
        let selection = grid.selection
        return rows.flatMap { row in
            columns.compactMap { column -> (row: Int, column: Int)? in
                guard let display = grid.columnOrder.firstIndex(of: column) else { return nil }
                let position = GridPosition(row: row, column: display)
                return selection.isEmpty || selection.contains(position) ? (row, column) : nil
            }
        }
    }

    /// The rows the selection touches, as loaded rows' keys and new rows' ids.
    func selectedRows() -> (keys: [PendingChanges.Key], inserts: [UUID]) {
        guard let source else { return ([], []) }
        var keys: [PendingChanges.Key] = [], inserts: [UUID] = []
        for row in GridCopy.covered(grid).rows {
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
        guard let source, source.key != nil else { return NSSound.beep() }
        let id = source.changes.addRow()
        changesDidChange()
        focus(row: source.index(of: id))
    }

    @objc func duplicateRow(_ sender: Any?) { duplicate(keepingKeys: true) }
    @objc func duplicateRowWithoutKeys(_ sender: Any?) { duplicate(keepingKeys: false) }

    /// Adds a copy of each selected row; without keys, the key and AUTO_INCREMENT columns are left to the server.
    /// Generated columns are always left out.
    private func duplicate(keepingKeys: Bool) {
        guard let source, source.key != nil else { return NSSound.beep() }
        var last: UUID?
        for row in GridCopy.covered(grid).rows {
            var values: [String: PendingChanges.Value] = [:]
            for (index, column) in source.table.columns.enumerated() where column.generated == nil {
                if !keepingKeys, source.columns[index].isKey || column.autoIncrement { continue }
                values[column.name] = source.value(row, index).map(PendingChanges.Value.text) ?? .null
            }
            last = source.changes.addRow(values)
        }
        changesDidChange()
        focus(row: last.flatMap(source.index(of:)))
    }

    @objc func deleteRows(_ sender: Any?) {
        guard let source, source.key != nil else { return NSSound.beep() }
        let (keys, inserts) = selectedRows()
        source.changes.delete(keys, inserts: inserts)
        changesDidChange()
    }

    @objc func setCellNull(_ sender: Any?) { setSelected(.null) }
    @objc func setCellDefault(_ sender: Any?) { setSelected(.default) }

    private func setSelected(_ value: PendingChanges.Value) {
        guard let source else { return }
        for cell in selectedCells() where source.canEdit(cell.row, cell.column) {
            source.set(value, row: cell.row, column: cell.column)
        }
        changesDidChange()
    }

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

    /// Selects a row's first cell and scrolls to it.
    func focus(row: Int?) {
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
        grid.reloadData()
        updateBars()
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
    }

    // MARK: Apply

    @objc func applyChanges(_ sender: Any?) { startApply(preview: false) }
    @objc func previewChanges(_ sender: Any?) { startApply(preview: true) }

    /// Shows the SQL first when asked, when Settings ▸ Safety wants it (Production connections), or when there is a
    /// warning (an engine that can't roll back, cascading deletes); then runs it.
    private func startApply(preview: Bool) {
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
            let statements = source.changes.statements(database: database, table: tableName, columns: source.columns,
                                                       noBackslashEscapes: session.noBackslashEscapes)
            let warnings = TableEditing.warnings(source.table, database: database, deleting: !source.changes.state.deletes.isEmpty,
                                                 in: context.schema.snapshot)
            let change = ChangeSQL(title: "Apply changes to \(tableName)", statements: statements.map(\.sql), connection: context.connection.id)
            guard preview || model.data.safety(for: context.connection).previewBeforeApply || !warnings.isEmpty,
                  let window = view.window else { return run(statements, on: session, change: change, saveAsChangeset: false) }
            let rows = source.changes.rowCount
            var request = SQLPreviewRequest(change: change, heading: "Apply \(rows) \(rows == 1 ? "change" : "changes") to \(database).\(tableName)?",
                                            caption: "They run in one transaction. If a row was changed or deleted by someone else "
                                                + "since it was loaded, nothing is applied.")
            request.warnings = warnings
            request.destructive = !source.changes.state.deletes.isEmpty
            request.noBackslashEscapes = session.noBackslashEscapes
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
        bar.busy = true
        let activity = model.activity.start("Applying changes to \(tableName)", connection: context.connection.id)
        loading = Task {
            do {
                try await PendingChanges.apply(statements) { sql in try await session.query(sql, rowCap: 1).last?.affectedRows ?? 0 }
                source.changes = PendingChanges(keyColumns: source.changes.keyColumns)
                changesDidChange()
                if saveAsChangeset { SQLPreviewSheet.changesetWriter?(change) }
                activity.end()
                loading = nil
                loadRows(more: false, through: source.loadedRows)
            } catch {
                activity.end()
                loading = nil
                bar.busy = false
                if let failure = error as? ApplyFailure { point(at: failure.statement.target) }
                showError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                          title: "Nothing was applied to \(tableName)", on: view.window)
            }
        }
    }

    /// Selects the row a failed statement was for.
    private func point(at target: PendingChanges.Statement.Target) {
        guard let source else { return }
        let row: Int?
        switch target {
        case .update(let key): row = source.index(of: key)
        case .delete(let keys): row = keys.lazy.compactMap(source.index(of:)).first
        case .insert(let id): row = source.index(of: id)
        }
        guard let row else { return }
        grid.selection.selectRow(row)
        grid.reveal(grid.rowRect(row))
    }
}
