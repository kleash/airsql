import AirSQLCore
import AppKit

extension NSPasteboard.PasteboardType {
    /// A row of the table editor's list being dragged to a new place.
    static let editorRow = NSPasteboard.PasteboardType("com.kleash.airsql.editor-row")
}

/// The table editor's list: Delete removes the selected rows; right-clicking a row that isn't selected selects it.
final class EditorList: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "\u{7f}" || event.specialKey == .deleteForward, !selectedRowIndexes.isEmpty {
            sendCommand(Commands.deleteRows.action)
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return super.menu(for: event)
    }
}

/// A column of a list section: its identifier, header, width and what its header's tooltip says.
struct ListColumn {
    let id: String
    let title: String
    let width: CGFloat
    let tip: String
}

extension TableEditorController: NSTableViewDataSource, NSTableViewDelegate {
    /// The columns of each list section.
    func listColumns(_ section: Section) -> [ListColumn] {
        let mark = ListColumn(id: "mark", title: "#", width: 30, tip: "The row's place; + marks a new one, • a changed one")
        switch section {
        case .columns:
            return [mark, ListColumn(id: "name", title: "Name", width: 150, tip: "The column's name"),
                    ListColumn(id: "type", title: "Type", width: 120, tip: "The column's type, from those this server has"),
                    ListColumn(id: "length", title: "Length / values", width: 140,
                               tip: "The length, the digits and decimals, or ENUM and SET values, as the type takes them"),
                    ListColumn(id: "unsigned", title: "Unsigned", width: 64, tip: "Numbers from zero up only"),
                    ListColumn(id: "null", title: "NULL", width: 44, tip: "The column may hold NULL"),
                    ListColumn(id: "default", title: "Default", width: 150,
                               tip: "Empty for none, NULL, 'text', a number or an expression; a generated column's expression"),
                    ListColumn(id: "extra", title: "Extra", width: 190, tip: "Counts up by itself, follows updates, or is generated"),
                    ListColumn(id: "collation", title: "Collation", width: 170, tip: "How text is compared and sorted; empty for the table's"),
                    ListColumn(id: "comment", title: "Comment", width: 200, tip: "A note kept with the column")]
        case .indexes:
            return [mark, ListColumn(id: "name", title: "Name", width: 170, tip: "The index's name"),
                    ListColumn(id: "kind", title: "Kind", width: 110, tip: "Primary key, unique, plain, full-text or spatial"),
                    ListColumn(id: "columns", title: "Columns", width: 300,
                               tip: "Its columns in order, separated by commas; name(10) indexes the first 10 characters, DESC sorts down"),
                    ListColumn(id: "comment", title: "Comment", width: 220, tip: "A note kept with the index")]
        case .foreignKeys:
            return [mark, ListColumn(id: "name", title: "Name", width: 170, tip: "The key's name"),
                    ListColumn(id: "columns", title: "Columns", width: 160, tip: "This table's columns, separated by commas"),
                    ListColumn(id: "references", title: "References", width: 170, tip: "The table they point at"),
                    ListColumn(id: "referencedColumns", title: "Its columns", width: 150,
                               tip: "The columns there, in the same order, separated by commas"),
                    ListColumn(id: "onUpdate", title: "On update", width: 110, tip: "What happens to these rows when that key changes"),
                    ListColumn(id: "onDelete", title: "On delete", width: 110, tip: "What happens to these rows when that row goes")]
        case .checks, .options:
            return [mark, ListColumn(id: "name", title: "Name", width: 180, tip: "The check's name"),
                    ListColumn(id: "clause", title: "Condition", width: 380, tip: "What every row must satisfy, as SQL"),
                    ListColumn(id: "enforced", title: "Enforced", width: 70, tip: "MySQL can keep a check without enforcing it")]
        }
    }

    func configureList() {
        if list.dataSource == nil {
            list.dataSource = self
            list.delegate = self
            list.allowsMultipleSelection = true
            list.usesAlternatingRowBackgroundColors = true
            list.style = .plain
            list.rowHeight = 24
            list.intercellSpacing = NSSize(width: 6, height: 2)
            list.registerForDraggedTypes([.editorRow])
            list.setDraggingSourceOperationMask(.move, forLocal: true)
            list.draggingDestinationFeedbackStyle = .gap
            list.target = self
            list.doubleAction = #selector(listDoubleClicked(_:))
            list.setAccessibilityIdentifier("tableEditor.list")
            let menu = NSMenu()
            menu.add([Commands.addRow, Commands.duplicateRow, Commands.deleteRows])
            list.menu = menu
        }
        for column in list.tableColumns { list.removeTableColumn(column) }
        for spec in listColumns(section) {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = min(spec.width, 40)
            column.headerToolTip = spec.tip
            list.addTableColumn(column)
        }
        reloadList()
    }

    func reloadList() {
        list.reloadData()
        updateButtons()
    }

    /// MariaDB's column checks, listed after the table's own (their rows edit the column's CHECK).
    var columnCheckRows: [Int] { design.columns.indices.filter { design.columns[$0].check != nil } }

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch section {
        case .columns: return design.columns.count
        case .indexes: return design.indexes.count
        case .foreignKeys: return design.foreignKeys.count
        case .checks: return design.checks.count + columnCheckRows.count
        case .options: return 0
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    @objc func listDoubleClicked(_ sender: Any?) {
        guard list.clickedRow >= 0, list.clickedColumn >= 0 else { return }
        list.editColumn(list.clickedColumn, row: list.clickedRow, with: nil, select: true)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        switch rowState(row) {
        case .new: rowView.backgroundColor = .pendingInsert
        case .changed: rowView.backgroundColor = .pendingEdit
        case .same: break
        }
        return rowView
    }

    enum RowState { case new, changed, same }

    /// Whether the row is new, changed since the server's version, or as it was.
    func rowState(_ row: Int) -> RowState {
        func state<T: Equatable>(_ original: String?, _ item: T, _ old: [T], _ name: (T) -> String) -> RowState {
            guard let original else { return .new }
            return old.first { name($0) == original } == item ? .same : .changed
        }
        let before = self.before ?? TableDesign(name: "")
        switch section {
        case .columns where row < design.columns.count:
            return state(design.columns[row].original, design.columns[row], before.columns, \.name)
        case .indexes where row < design.indexes.count:
            return state(design.indexes[row].original, design.indexes[row], before.indexes, \.name)
        case .foreignKeys where row < design.foreignKeys.count:
            return state(design.foreignKeys[row].original, design.foreignKeys[row], before.foreignKeys, \.name)
        case .checks where row < design.checks.count:
            return state(design.checks[row].original, design.checks[row], before.checks, \.name)
        case .checks:
            let column = design.columns[columnCheckRows[row - design.checks.count]]
            return before.columns.first { $0.name == column.original }?.check == column.check ? .same : .changed
        default:
            return .same
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let cell = makeCell(id, row: row)
        cell.identifier = NSUserInterfaceItemIdentifier(id)
        return cell
    }
}
