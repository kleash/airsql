import AirSQLCore
import AppKit

// A console result's cells edit by type as a table tab's do (`TableDataController+Values`, grid-spec §5): booleans toggle,
// ENUM and SET pick from their members, dates step, foreign keys have their drop-down; Insert Value and Paste.
extension ResultGridView {
    func dataGrid(_ grid: DataGridView, step text: String, at offset: Int, by amount: Int, row: Int, column: Int)
        -> (text: String, part: NSRange)? {
        edits?.type(column)?.step(text, at: offset, by: amount)
    }

    /// As in a table tab, by the column's type; typing anything but a boolean's letters edits as text.
    func dataGrid(_ grid: DataGridView, edit row: Int, column: Int, typed: String?) -> Bool {
        guard let edits, let type = edits.type(column) else { return false }
        let current = rows.value(row, column)
        if type.isBoolean {
            guard let value = booleanValue(typed: typed, current: current) else { return false }
            setSelected { edits.type($0)?.isBoolean == true ? value : nil }
            return true
        }
        guard typed == nil else { return false }
        if foreignKey(column) != nil {
            showLookup(column: column)
            return true
        }
        switch type.kind {
        case .enumeration(let members):
            let menu = pickListMenu(members, title: edits.columns[column].name, current: current, nullable: edits.nullable(column),
                                    nullText: grid.nullText, target: self)
            menu.popUp(positioning: menu.items.first { $0.state == .on }, at: editedRect.origin, in: grid)
        case .set(let members):
            let chosen = Set((current ?? "").split(separator: ",").map(String.init))
            checklist = SetChecklist(members: members, chosen: chosen) { [weak self] picked in
                self?.setSelected { _ in .text(type.setText(picked)) }
            }
            checklist?.show(relativeTo: editedRect, of: grid)
        default:
            let value = current ?? ""
            guard value.utf16.count > 256 || value.contains(where: \.isNewline) else { return false }
            viewer.editInValuePanel()
        }
        return true
    }

    private var editedRect: NSRect { grid.selection.cursor.map { grid.cellRect($0) } ?? .zero }

    @objc func pickMember(_ sender: NSMenuItem) {
        let member = sender.representedObject as? String
        setSelected { _ in member.map(PendingChanges.Value.text) ?? .null }
    }

    // MARK: Insert Value

    func insertValueItems() -> [NSMenuItem] {
        guard let column = viewer.focusedCell?.column, let info = edits?.info(column) else { return [] }
        return AirSQL.insertValueItems(info, values)
    }

    @objc func insertCellValue(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let chosen = InsertValue(rawValue: raw), let edits else {
            return NSSound.beep()
        }
        setSelected { column in edits.info(column).flatMap { insertedValue(chosen, $0, self.values) } }
    }

    // MARK: Foreign keys

    /// The foreign key a result column is part of, when the result has all its columns to edit, and those columns.
    func foreignKey(_ column: Int) -> (key: SchemaForeignKey, columns: [Int])? {
        guard let edits, let editing = edits.editing, case .editable(let source, let name) = editing.columns[column],
              let key = ForeignKeyQueries.foreignKey(of: name, in: edits.tables[source]) else { return nil }
        let columns = key.columns.compactMap { part in editing.columns.firstIndex(of: .editable(source: source, column: part)) }
        return columns.count == key.columns.count ? (key, columns) : nil
    }

    /// Choose Referenced Row…: the focused foreign key column's drop-down.
    @objc func chooseReferencedRow(_ sender: Any?) {
        guard let cell = viewer.focusedCell else { return NSSound.beep() }
        showLookup(column: cell.column)
    }

    /// The referenced table's rows under the cell, searched on the data session (a table tab's `showLookup`).
    private func showLookup(column: Int) {
        guard editingOff == nil, let (key, columns) = foreignKey(column), let schema = editingContext?.schema, let open = openSession else {
            return NSSound.beep()
        }
        guard let referenced = schema.snapshot.table(key.referencedDatabase, key.referencedTable) else {
            Task {
                try? await schema.loadDetails([key.referencedDatabase])
                if schema.snapshot.table(key.referencedDatabase, key.referencedTable) != nil { showLookup(column: column) } else { NSSound.beep() }
            }
            return
        }
        let label = ForeignKeyQueries.defaultLabel(referenced, key: key.referencedColumns), values = self.values
        lookup = ForeignKeyLookup(title: key.referencedTable, keyCount: key.referencedColumns.count, read: { text in
            let sql = ForeignKeyQueries.lookup(key, referenced: referenced, label: label, search: text, context: values)
            return try await open().query(sql, rowCap: 100).first?.rows
        }, pick: { [weak self] picked in self?.setForeignKey(columns, to: picked) })
        lookup?.show(relativeTo: editedRect, of: grid)
    }

    /// The selected rows' foreign key columns take the chosen row's key, one step for undo.
    private func setForeignKey(_ columns: [Int], to picked: [String]) {
        guard let edits else { return }
        edits.group {
            for row in Set(viewer.selectedCells().map { rows.baseRow($0.row) }).sorted() {
                for (column, value) in zip(columns, picked) where edits.canEdit(row, column) && refusal(.text(value), column: column) == nil {
                    edits.set(.text(value), row: row, column: column)
                }
            }
        }
        updateEditing()
    }

    // MARK: Paste

    /// Fills the cells from the focused one as pending edits (one value over several selected cells fills them all); a
    /// result can't take new rows, so rows past its last are left out, and nothing goes in if a cell is refused.
    /// shortcut: no Paste Format sheet, numbers and dates as Paste guesses them; a table tab has it, if results come to need it.
    @objc func paste(_ sender: Any?) {
        guard let edits, editingOff == nil, !AgentGuard.refuses("The clipboard is the person's: agents can't paste. Nothing was pasted."),
              let clipboard = TableDataController.clipboard else { return NSSound.beep() }
        let cells = Paste.cells(clipboard.text, separator: clipboard.csv ? .comma : .auto)
        let format = PasteFormat(nullText: grid.nullText), values = self.values
        if cells.count == 1, cells[0].count == 1, viewer.selectedCells().count > 1 {
            return setSelected { column in edits.info(column).flatMap { Paste.values(cells, columns: [$0], format: format, context: values).values[0][0] } }
        }
        let shown = viewer.shownColumns
        guard let focused = viewer.focusedCell, let first = shown.firstIndex(of: focused.column) else { return NSSound.beep() }
        var changes: [(row: Int, column: Int, value: PendingChanges.Value)] = [], refused: PasteFailure?
        for (offset, column) in shown[first...].prefix(cells.map(\.count).max() ?? 0).enumerated() {
            guard let info = edits.info(column) else { continue }
            let part = Paste.values(cells.map { offset < $0.count ? [$0[offset]] : [] }, columns: [info], format: format, context: values)
            refused = refused ?? part.failures.first
            for (line, value) in part.values.enumerated() where focused.row + line < rows.rowCount {
                let row = rows.baseRow(focused.row + line)
                if let value = value.first ?? nil, edits.canEdit(row, column) { changes.append((row, column, value)) }
            }
        }
        if let refused, let window {
            let alert = NSAlert()
            alert.messageText = "“\(refused.text.prefix(30))” can't go in its column"
            alert.informativeText = "\(refused.reason). Nothing was pasted."
            return alert.beginSheetModal(for: window)
        }
        guard refused == nil, !changes.isEmpty else { return NSSound.beep() }
        edits.group { changes.forEach { edits.set($0.value, row: $0.row, column: $0.column) } }
        updateEditing()
    }
}
