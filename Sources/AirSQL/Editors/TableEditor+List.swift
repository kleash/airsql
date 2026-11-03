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
        } else if event.specialKey == .carriageReturn || event.specialKey == .enter, selectedRow >= 0, let action = doubleAction {
            NSApp.sendAction(action, to: target, from: self)  // Return edits the row, as a double-click does
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

/// The list's cells: a right-click on one opens the list's menu for its row, as on the row itself.
final class ListTextField: NSTextField {
    override func menu(for event: NSEvent) -> NSMenu? { enclosingList?.menu(for: event) }
}

final class ListCheckbox: NSButton {
    override func menu(for event: NSEvent) -> NSMenu? { enclosingList?.menu(for: event) }
}

final class ListPopUp: NSPopUpButton {
    override func menu(for event: NSEvent) -> NSMenu? { enclosingList?.menu(for: event) }
}

final class ListComboBox: NSComboBox {
    override func menu(for event: NSEvent) -> NSMenu? { enclosingList?.menu(for: event) }
}

extension NSView {
    /// The editor list this view is a cell of.
    var enclosingList: EditorList? {
        var view = superview
        while let current = view, !(current is EditorList) { view = current.superview }
        return view as? EditorList
    }
}

/// A column of a list section: its identifier, header, width and what its header's tooltip says. `minimum`: how narrow
/// it may get as the columns share the list's width; nil keeps it at its width (marks, checkboxes, short pop-ups).
struct ListColumn {
    let id: String
    let title: String
    let width: CGFloat
    var minimum: CGFloat?
    let tip: String
}

extension TableEditorController: NSTableViewDataSource, NSTableViewDelegate {
    /// The columns of each list section.
    func listColumns(_ section: Section) -> [ListColumn] {
        let mark = ListColumn(id: "mark", title: "#", width: 30, tip: "The row's place; + marks a new one, • a changed one")
        switch section {
        case .columns:
            return [mark, ListColumn(id: "name", title: "Name", width: 150, minimum: 100, tip: "The column's name"),
                    ListColumn(id: "type", title: "Type", width: 120, minimum: 100, tip: "The column's type, from those this server has"),
                    ListColumn(id: "length", title: "Length / values", width: 140, minimum: 100,
                               tip: "The length, the digits and decimals, or ENUM and SET values, as the type takes them"),
                    ListColumn(id: "unsigned", title: "Unsigned", width: 64, tip: "Numbers from zero up only"),
                    ListColumn(id: "null", title: "NULL", width: 44, tip: "The column may hold NULL"),
                    ListColumn(id: "default", title: "Default", width: 150, minimum: 80,
                               tip: "Empty for none, NULL, 'text', a number or an expression; a generated column's expression"),
                    ListColumn(id: "extra", title: "Extra", width: 190, minimum: 135,
                               tip: "Counts up by itself, follows updates, or is generated"),
                    ListColumn(id: "collation", title: "Collation", width: 170, minimum: 150,
                               tip: "How text is compared and sorted; empty for the table's"),
                    ListColumn(id: "comment", title: "Comment", width: 200, minimum: 70, tip: "A note kept with the column")]
        case .indexes:
            return [mark, ListColumn(id: "name", title: "Name", width: 170, minimum: 100, tip: "The index's name"),
                    ListColumn(id: "kind", title: "Kind", width: 110, tip: "Primary key, unique, plain, full-text or spatial"),
                    ListColumn(id: "columns", title: "Columns", width: 300, minimum: 150,
                               tip: "Its columns in order, separated by commas; name(10) indexes the first 10 characters, DESC sorts down"),
                    ListColumn(id: "comment", title: "Comment", width: 220, minimum: 80, tip: "A note kept with the index")]
        case .foreignKeys:
            return [mark, ListColumn(id: "name", title: "Name", width: 170, minimum: 100, tip: "The key's name"),
                    ListColumn(id: "columns", title: "Columns", width: 160, minimum: 100, tip: "This table's columns, separated by commas"),
                    ListColumn(id: "references", title: "References", width: 170, minimum: 110, tip: "The table they point at"),
                    ListColumn(id: "referencedColumns", title: "Its columns", width: 150, minimum: 100,
                               tip: "The columns there, in the same order, separated by commas"),
                    ListColumn(id: "onUpdate", title: "On update", width: 110, tip: "What happens to these rows when that key changes"),
                    ListColumn(id: "onDelete", title: "On delete", width: 110, tip: "What happens to these rows when that row goes")]
        case .checks, .options:
            return [mark, ListColumn(id: "name", title: "Name", width: 180, minimum: 100, tip: "The check's name"),
                    ListColumn(id: "clause", title: "Condition", width: 380, minimum: 200, tip: "What every row must satisfy, as SQL"),
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
            // The columns share the list's width down to their minimums, then it scrolls sideways.
            list.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
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
        // No rows while the columns change: the table view would ask the new section for the old rows' cells.
        emptied = true
        list.reloadData()
        for column in list.tableColumns { list.removeTableColumn(column) }
        for spec in listColumns(section) {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.minimum ?? spec.width
            column.resizingMask = spec.minimum == nil ? .userResizingMask : [.autoresizingMask, .userResizingMask]
            column.headerToolTip = spec.tip
            list.addTableColumn(column)
        }
        list.sizeToFit()
        emptied = false
        reloadList()
    }

    func reloadList() {
        list.reloadData()
        updateButtons()
    }

    /// MariaDB's column checks, listed after the table's own (their rows edit the column's CHECK).
    var columnCheckRows: [Int] { design.columns.indices.filter { design.columns[$0].check != nil } }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if emptied { return 0 }
        switch section {
        case .columns: return design.columns.count
        case .indexes: return design.indexes.count
        case .foreignKeys: return design.foreignKeys.count
        case .checks: return design.checks.count + columnCheckRows.count
        case .options: return 0
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    /// A double-click edits the cell (the row's name when no cell was clicked, as from the keyboard).
    @objc func listDoubleClicked(_ sender: Any?) {
        let row = list.clickedRow >= 0 ? list.clickedRow : list.selectedRow
        guard row >= 0, !isBusy else { return }
        let column = list.clickedColumn > 0 ? list.clickedColumn : 1
        list.editColumn(column, row: row, with: nil, select: true)
    }

    /// New rows tinted green, changed ones amber, as the grid marks pending inserts and edits (after the table view has
    /// given the row its alternating colour).
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        switch rowState(row) {
        case .new: rowView.backgroundColor = .pendingInsert
        case .changed: rowView.backgroundColor = .pendingEdit
        case .same: break
        }
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
            return state(design.indexes[row].original, design.indexes[row], before.indexes.map(design.renamingColumns(of:)), \.name)
        case .foreignKeys where row < design.foreignKeys.count:
            return state(design.foreignKeys[row].original, design.foreignKeys[row],
                         before.foreignKeys.map(design.renamingColumns(of:)), \.name)
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
        let control = makeCell(id, row: row)
        control.identifier = NSUserInterfaceItemIdentifier(id)
        // Every cell says what it holds (a text cell its whole text, when it has one).
        if control.toolTip == nil { control.toolTip = tableColumn?.headerToolTip }
        // A checkbox has no title of its own: VoiceOver reads its column's.
        if let box = control as? NSButton, box.title.isEmpty { box.setAccessibilityLabel(tableColumn?.title) }
        // In the middle of its row, across the column.
        let cell = NSView()
        control.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: cell.leadingAnchor), control.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
