import AirSQLCore
import AppKit

// What each edit in the list does to the design, and the rows' own commands: add, duplicate, delete, drag to reorder.
extension TableEditorController {
    @objc func cellEdited(_ sender: NSControl) {
        let row = list.row(for: sender)
        guard row >= 0, let id = sender.identifier?.rawValue else { return }
        let value = sender.stringValue, on = (sender as? NSButton)?.state == .on
        let index = (sender as? NSPopUpButton)?.indexOfSelectedItem ?? 0
        let nbe = server.noBackslashEscapes
        switch section {
        case .columns where row < design.columns.count:
            update { table in
                var column = table.columns[row]
                switch id {
                case "name":
                    table.renameColumn(at: row, to: value)
                    return
                case "type":
                    column.type.name = ((sender as? NSPopUpButton)?.titleOfSelectedItem ?? column.type.name).lowercased()
                    let type = column.columnType
                    if type?.length == EditorColumnType.Length.none { column.type.length = "" }
                    if !(type?.numeric ?? false) { column.type.unsigned = false; column.type.zerofill = false }
                    if !(type?.text ?? false) { column.collation = nil; column.charset = nil }
                    if !(type?.integer ?? false) { column.autoIncrement = false }
                case "length": column.type.length = value.trimmingCharacters(in: .whitespaces)
                case "unsigned": column.type.unsigned = on
                case "null":
                    column.nullable = on
                    if !on, column.defaultValue == .null { column.defaultValue = .none }
                case "default":
                    if column.generated != nil {
                        column.generated?.expression = value
                    } else {
                        column.defaultValue = EditorText.defaultValue(from: value, noBackslashEscapes: nbe)
                    }
                case "extra":
                    let extra = Self.extras[index]
                    let expression = column.generated?.expression ?? (column.defaultValue == .none ? "" : value)
                    column.autoIncrement = extra == "AUTO_INCREMENT"
                    column.onUpdate = extra == "ON UPDATE CURRENT_TIMESTAMP"
                        ? "CURRENT_TIMESTAMP" + (column.type.length.isEmpty ? "" : "(\(column.type.length))") : nil
                    column.generated = extra.hasSuffix("GENERATED")
                        ? SchemaColumn.Generated(expression, stored: extra.hasPrefix("STORED")) : nil
                    if column.autoIncrement || column.generated != nil { column.defaultValue = .none }
                    if column.autoIncrement { column.nullable = false }
                case "collation":
                    let name = value.trimmingCharacters(in: .whitespaces)
                    column.collation = name.isEmpty ? nil : name
                    column.charset = collations.first { $0.name == name }?.charset
                default: column.comment = value
                }
                table.columns[row] = column
            }
        case .indexes where row < design.indexes.count:
            var failure: DesignError?
            update { table in
                switch id {
                case "name": table.indexes[row].name = value
                case "kind":
                    let kind = IndexDesign.Kind.allCases[index]
                    table.indexes[row].kind = kind
                    if kind == .primary {
                        table.indexes[row].name = "PRIMARY"
                        table.indexes[row].visible = true
                    }
                    if !table.indexes[row].takesAlgorithm { table.indexes[row].algorithm = nil }
                case "columns":
                    do { table.indexes[row].parts = try EditorText.parts(from: value) } catch { failure = error as? DesignError }
                case "using":
                    table.indexes[row].algorithm = index == 0 ? nil : IndexDesign.algorithms[index]
                case "visible": table.indexes[row].visible = on
                default: table.indexes[row].comment = value
                }
            }
            if let failure { showError(failure.message, title: "That isn't a list of index columns", on: view.window) }
        case .foreignKeys where row < design.foreignKeys.count:
            update { table in
                switch id {
                case "name": table.foreignKeys[row].name = value
                case "columns": table.foreignKeys[row].columns = EditorText.names(from: value)
                case "references":
                    let reference = EditorText.qualified(from: value)
                    table.foreignKeys[row].referencedDatabase = reference.database ?? database ?? ""
                    table.foreignKeys[row].referencedTable = reference.name
                case "referencedColumns": table.foreignKeys[row].referencedColumns = EditorText.names(from: value)
                case "onUpdate": table.foreignKeys[row].onUpdate = ForeignKeyDesign.rules[index]
                default: table.foreignKeys[row].onDelete = ForeignKeyDesign.rules[index]
                }
            }
        case .checks where row < design.checks.count:
            update { table in
                switch id {
                case "name": table.checks[row].name = value
                case "clause": table.checks[row].clause = value
                default: table.checks[row].enforced = on
                }
            }
        case .checks:
            let column = columnCheckRows[row - design.checks.count]
            update { table in
                let clause = value.trimmingCharacters(in: .whitespacesAndNewlines)
                table.columns[column].check = clause.isEmpty ? nil : clause
            }
        default:
            return
        }
        // The other cells of the row follow (the mark, and those a type or Extra turns on or off).
        if !(sender is NSTextField) || id == "name" || section == .checks {
            list.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<list.numberOfColumns))
        } else {
            list.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
        list.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
    }

    // MARK: Rows

    @objc func addRow(_ sender: Any?) {
        guard !isBusy, editsRows else { return }
        endEditing()
        let at = (list.selectedRowIndexes.last.map { $0 + 1 }) ?? numberOfRows(in: list)
        update { table in
            switch section {
            case .columns:
                var column = ColumnDesign(name: Self.unused("column", in: table.columns.map(\.name)), type: TypeSpec(name: "varchar", length: "255"))
                column.defaultValue = .null
                table.columns.insert(column, at: min(at, table.columns.count))
            case .indexes:
                let first = table.columns.first.map { [IndexDesign.Part(column: $0.name)] } ?? []
                table.indexes.append(IndexDesign(name: Self.unused("index", in: table.indexes.map(\.name)), kind: .index, parts: first))
            case .foreignKeys:
                table.foreignKeys.append(ForeignKeyDesign(name: Self.unused(table.name + "_fk", in: table.foreignKeys.map(\.name)),
                                                          columns: [], referencedDatabase: database ?? "", referencedTable: "",
                                                          referencedColumns: []))
            case .checks, .options, .references, .partitions:
                table.checks.append(CheckDesign(name: Self.unused(table.name + "_chk", in: table.checks.map(\.name)), clause: ""))
            }
        }
        reloadList()
        let row = section == .columns ? min(at, design.columns.count - 1) : numberOfRows(in: list) - 1
        list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        list.scrollRowToVisible(row)
        list.editColumn(1, row: row, with: nil, select: true)
    }

    @objc func duplicateRow(_ sender: Any?) {
        let rows = list.selectedRowIndexes
        guard !isBusy, !rows.isEmpty, editsRows else { return }
        update { table in
            switch section {
            case .columns:
                for row in rows.reversed() where row < table.columns.count {
                    var copy = table.columns[row]
                    copy.original = nil
                    copy.name = Self.unused(copy.name + "_copy", in: table.columns.map(\.name))
                    copy.autoIncrement = false
                    table.columns.insert(copy, at: row + 1)
                }
            case .indexes:
                for row in rows where row < table.indexes.count && table.indexes[row].kind != .primary {
                    var copy = table.indexes[row]
                    copy.original = nil
                    copy.name = Self.unused(copy.name + "_copy", in: table.indexes.map(\.name))
                    table.indexes.append(copy)
                }
            case .foreignKeys:
                for row in rows where row < table.foreignKeys.count {
                    var copy = table.foreignKeys[row]
                    copy.original = nil
                    copy.name = Self.unused(copy.name + "_copy", in: table.foreignKeys.map(\.name))
                    table.foreignKeys.append(copy)
                }
            case .checks, .options, .references, .partitions:
                for row in rows where row < table.checks.count {
                    var copy = table.checks[row]
                    copy.original = nil
                    copy.name = Self.unused(copy.name + "_copy", in: table.checks.map(\.name))
                    table.checks.append(copy)
                }
            }
        }
        reloadList()
    }

    @objc func deleteRows(_ sender: Any?) {
        let rows = list.selectedRowIndexes
        guard !isBusy, !rows.isEmpty, editsRows else { return }
        endEditing()
        let checkColumns = columnCheckRows
        update { table in
            for row in rows.reversed() {
                switch section {
                case .columns where row < table.columns.count: table.removeColumn(at: row)
                case .indexes where row < table.indexes.count: table.indexes.remove(at: row)
                case .foreignKeys where row < table.foreignKeys.count: table.foreignKeys.remove(at: row)
                case .checks where row < table.checks.count: table.checks.remove(at: row)
                case .checks where row - table.checks.count < checkColumns.count:
                    table.columns[checkColumns[row - table.checks.count]].check = nil
                default: break
                }
            }
        }
        reloadList()
    }

    // MARK: Copying rows, between tables too

    /// The rows last copied, while the pasteboard still holds them; as a design of their own, so ⌘V is Duplicate's.
    private static var copied: (changeCount: Int, rows: TableDesign)?

    private var copiedRows: TableDesign? {
        guard let copied = Self.copied, copied.changeCount == NSPasteboard.general.changeCount else { return nil }
        let rows = copied.rows
        switch section {
        case .columns: return rows.columns.isEmpty ? nil : rows
        case .indexes: return rows.indexes.isEmpty ? nil : rows
        case .foreignKeys: return rows.foreignKeys.isEmpty ? nil : rows
        case .checks: return rows.checks.isEmpty ? nil : rows
        case .options, .references, .partitions: return nil
        }
    }

    var canCopyRows: Bool { editsRows && !list.selectedRowIndexes.isEmpty }
    var canPasteRows: Bool { !isBusy && copiedRows != nil }

    /// As text the rows are the lines of a CREATE TABLE; ⌘V in a table editor adds the rows themselves.
    @objc func copy(_ sender: Any?) {
        guard canCopyRows else { return }
        let selected = list.selectedRowIndexes
        var rows = TableDesign(name: design.name)
        switch section {
        case .columns: rows.columns = selected.filter { $0 < design.columns.count }.map { design.columns[$0] }
        case .indexes: rows.indexes = selected.filter { $0 < design.indexes.count }.map { design.indexes[$0] }
        case .foreignKeys: rows.foreignKeys = selected.filter { $0 < design.foreignKeys.count }.map { design.foreignKeys[$0] }
        case .checks, .options, .references, .partitions: rows.checks = selected.filter { $0 < design.checks.count }.map { design.checks[$0] }
        }
        // A row still being typed may not write as SQL yet: its name is all there is to say.
        let names = rows.columns.map(\.name) + rows.indexes.map(\.name) + rows.foreignKeys.map(\.name) + rows.checks.map(\.name)
        let text = (try? rows.definitions(server: server)) ?? names
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.joined(separator: ",\n"), forType: .string)
        Self.copied = (NSPasteboard.general.changeCount, rows)
    }

    /// Adds the copied rows as new ones, after the selection, under names of their own.
    @objc func paste(_ sender: Any?) {
        guard canPasteRows, let rows = copiedRows else { return }
        endEditing()
        var first = 0, count = 0
        update { table in
            switch section {
            case .columns:
                first = (list.selectedRowIndexes.last ?? table.columns.count - 1) + 1
                count = rows.columns.count
                for (offset, row) in rows.columns.enumerated() {
                    var column = row
                    column.original = nil
                    column.name = Self.unused(column.name, in: table.columns.map(\.name))
                    column.autoIncrement = false
                    table.columns.insert(column, at: first + offset)
                }
            case .indexes:
                first = table.indexes.count
                count = rows.indexes.count
                for row in rows.indexes {
                    var index = row
                    index.original = nil
                    index.name = Self.unused(index.name, in: table.indexes.map(\.name))
                    table.indexes.append(index)
                }
            case .foreignKeys:
                first = table.foreignKeys.count
                count = rows.foreignKeys.count
                for row in rows.foreignKeys {
                    var key = row
                    key.original = nil
                    key.name = Self.unused(key.name, in: table.foreignKeys.map(\.name))
                    table.foreignKeys.append(key)
                }
            case .checks, .options, .references, .partitions:
                first = table.checks.count
                count = rows.checks.count
                for row in rows.checks {
                    var check = row
                    check.original = nil
                    check.name = Self.unused(check.name, in: table.checks.map(\.name))
                    table.checks.append(check)
                }
            }
        }
        reloadList()
        list.selectRowIndexes(IndexSet(integersIn: first..<(first + count)), byExtendingSelection: false)
    }

    /// `base`, or base_2, base_3…: the first that isn't taken.
    static func unused(_ base: String, in names: [String]) -> String {
        let taken = Set(names.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        return (2...).lazy.map { base + "_\($0)" }.first { !taken.contains($0.lowercased()) }!
    }

    // MARK: Indexes from the columns selected

    @objc func indexFromColumns(_ sender: Any?) { newIndex(.index) }
    @objc func uniqueFromColumns(_ sender: Any?) { newIndex(.unique) }

    /// A new index on the selected columns, in their order, shown in the Indexes list.
    private func newIndex(_ kind: IndexDesign.Kind) {
        let names = selectedColumns
        guard !isBusy, !names.isEmpty else { return }
        endEditing()
        update { table in
            let name = Self.unused(String(((kind == .unique ? "uq_" : "idx_") + names.joined(separator: "_")).prefix(60)), in: table.indexes.map(\.name))
            table.indexes.append(IndexDesign(name: name, kind: kind, parts: names.map { IndexDesign.Part(column: $0) }))
        }
        showSection(.indexes)
        list.selectRowIndexes(IndexSet(integer: design.indexes.count - 1), byExtendingSelection: false)
    }

    private var selectedColumns: [String] {
        section == .columns ? list.selectedRowIndexes.filter { $0 < design.columns.count }.map { design.columns[$0].name } : []
    }

    /// Add to Index: the indexes that can take a column.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (row, index) in design.indexes.enumerated() where section == .columns && !selectedColumns.isEmpty {
            let item = NSMenuItem(title: index.name, action: #selector(addColumnsToIndex(_:)), keyEquivalent: "")
            item.target = self
            item.tag = row
            item.toolTip = "Add the selected columns to the end of \(index.name)"
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "No Index to Add To", action: nil, keyEquivalent: "")
            none.toolTip = "Select columns in the Columns list of a table with an index first"
            menu.addItem(none)
        }
    }

    /// Adds the selected columns the index hasn't yet to its end.
    @objc func addColumnsToIndex(_ sender: NSMenuItem) {
        let names = selectedColumns
        update { table in
            guard table.indexes.indices.contains(sender.tag) else { return }
            let held = table.indexes[sender.tag].parts.compactMap(\.column)
            table.indexes[sender.tag].parts += names.filter { !held.contains($0) }.map { IndexDesign.Part(column: $0) }
        }
    }

    // MARK: Moving columns

    @objc func moveRowsUp(_ sender: Any?) {
        guard let first = list.selectedRowIndexes.first, canMoveRows, first > 0 else { return }
        moveColumns(list.selectedRowIndexes, to: first - 1)
    }

    @objc func moveRowsDown(_ sender: Any?) {
        guard let last = list.selectedRowIndexes.last, canMoveRows, last + 1 < design.columns.count else { return }
        moveColumns(list.selectedRowIndexes, to: last + 2)
    }

    /// Not while a cell is being typed in: there ⇧⌘↑ and ⇧⌘↓ are the text's.
    var canMoveRows: Bool { !isBusy && section == .columns && !list.selectedRowIndexes.isEmpty && !(view.window?.firstResponder is NSText) }

    // MARK: Dragging columns into a new order

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard section == .columns, !isBusy else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .editorRow)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard section == .columns, info.draggingSource as? NSTableView === list else { return [] }
        if operation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let rows = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .editorRow).flatMap(Int.init) }
        guard !rows.isEmpty else { return false }
        moveColumns(IndexSet(rows), to: row)
        return true
    }

    /// Moves columns to before the row `destination` (as it was before the move).
    func moveColumns(_ rows: IndexSet, to destination: Int) {
        update { table in
            let moving = rows.map { table.columns[$0] }
            let target = destination - rows.filter { $0 < destination }.count
            for row in rows.reversed() { table.columns.remove(at: row) }
            table.columns.insert(contentsOf: moving, at: target)
        }
        reloadList()
        let target = destination - rows.filter { $0 < destination }.count
        list.selectRowIndexes(IndexSet(integersIn: target..<(target + rows.count)), byExtendingSelection: false)
    }
}
