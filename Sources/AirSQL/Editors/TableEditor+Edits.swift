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
                    if kind == .primary { table.indexes[row].name = "PRIMARY" }
                case "columns":
                    do { table.indexes[row].parts = try EditorText.parts(from: value) } catch { failure = error as? DesignError }
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
        guard !isBusy, section != .options else { return }
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
            case .checks, .options:
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
        guard !isBusy, !rows.isEmpty else { return }
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
            case .checks, .options:
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
        guard !isBusy, !rows.isEmpty else { return }
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

    /// The selected rows' names, for ⌘C.
    var selectedNames: [String] {
        list.selectedRowIndexes.compactMap { row in
            switch section {
            case .columns: return design.columns[safe: row]?.name
            case .indexes: return design.indexes[safe: row]?.name
            case .foreignKeys: return design.foreignKeys[safe: row]?.name
            case .checks: return design.checks[safe: row]?.name
            case .options: return nil
            }
        }
    }

    @objc func copy(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedNames.joined(separator: ", "), forType: .string)
    }

    /// `base`, or base_2, base_3…: the first that isn't taken.
    static func unused(_ base: String, in names: [String]) -> String {
        let taken = Set(names.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        return (2...).lazy.map { base + "_\($0)" }.first { !taken.contains($0.lowercased()) }!
    }

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
