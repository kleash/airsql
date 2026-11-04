import AirSQLCore
import AppKit

/// Column List… (⌘J, grid-spec §2): every column of the grid with a box that shows or hides it, narrowed by what is
/// typed in its search field. Return or a double-click jumps to the column; Space or a click on its box shows or hides
/// it; Show All brings every hidden column back.
@MainActor
final class GridColumnList: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private weak var viewer: GridViewer?
    private let search = NSSearchField()
    let table = ContentTable()
    private let footer = label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    /// Source columns matching the search, in the grid's order (shown ones first, then hidden ones).
    private(set) var rows: [Int] = []

    init(viewer: GridViewer) {
        self.viewer = viewer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        search.placeholderString = "Find a column"
        search.toolTip = "Type part of a column's name; Return jumps to the first match"
        search.delegate = self
        search.setAccessibilityIdentifier("columnList.search")
        search.translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: .init("column"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(jump(_:))
        table.target = self
        table.setAccessibilityIdentifier("columnList.table")
        table.setAccessibilityLabel("Columns")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let showAll = button("Show All", id: "columnList.showAll", tip: "Show every hidden column again", target: self,
                             action: #selector(showAll(_:)))
        showAll.controlSize = .small
        let stack = NSStackView(views: [search, scroll, NSStackView(views: [footer, NSView(), showAll])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = .all(10)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true }
        NSLayoutConstraint.activate([stack.widthAnchor.constraint(equalToConstant: 300), scroll.heightAnchor.constraint(equalToConstant: 280)])
        view = stack
        reloadRows()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(search)
    }

    private func reloadRows() {
        guard let viewer, let source = viewer.source else { return }
        let shown = viewer.grid.columnOrder
        let all = shown + source.columns.indices.filter { !shown.contains($0) }
        let text = search.stringValue.trimmingCharacters(in: .whitespaces)
        rows = all.filter { text.isEmpty || source.columns[$0].name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        table.reloadData()
        if !rows.isEmpty, table.selectedRow < 0 { table.selectRowIndexes([0], byExtendingSelection: false) }
        footer.stringValue = rows.isEmpty ? "No column has “\(text)” in its name: clear the search to see them all"
            : "\(shown.count) of \(source.columns.count) columns shown"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let viewer, let source = viewer.source, rows.indices.contains(row) else { return nil }
        let info = source.columns[rows[row]]
        let box = checkbox("", id: "columnList.\(info.name)", tip: "Show or hide \(info.name) (Space)",
                           on: viewer.grid.columnOrder.contains(rows[row]), target: self, action: #selector(toggle(_:)))
        box.tag = rows[row]
        box.setAccessibilityLabel(info.name)
        let name = label(info.name, truncates: true)
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = info.name
        let type = label(info.type, font: .systemFont(ofSize: 11), color: .quietText)
        let cell = NSStackView(views: [box, name, NSView(), type])
        cell.spacing = 6
        cell.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 6)
        return cell
    }

    @objc private func toggle(_ sender: NSButton) {
        viewer?.setHidden(sender.state == .off, columns: [sender.tag])
        reloadRows()
    }

    /// Space in the list: shows or hides the selected columns.
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { toggleSelected() } else if event.keyCode == 36 || event.keyCode == 76 {
            jump(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    func toggleSelected() {
        guard let viewer else { return }
        let picked = table.selectedRowIndexes.map { rows[$0] }
        guard !picked.isEmpty else { return }
        let hide = picked.contains { viewer.grid.columnOrder.contains($0) }
        viewer.setHidden(hide, columns: picked)
        let selected = table.selectedRowIndexes
        reloadRows()
        table.selectRowIndexes(selected, byExtendingSelection: false)
    }

    /// Selects the column in the grid (showing it first when hidden) and scrolls to it.
    @objc func jump(_ sender: Any?) {
        guard let viewer, table.selectedRow >= 0, rows.indices.contains(table.selectedRow) else { return }
        let column = rows[table.selectedRow]
        if !viewer.grid.columnOrder.contains(column) { viewer.setHidden(false, columns: [column]) }
        guard let index = viewer.grid.columnOrder.firstIndex(of: column) else { return }
        viewer.grid.selection.selectColumn(index)
        let row = viewer.grid.visibleRect.minY / max(1, viewer.grid.rowHeight)
        viewer.grid.reveal(viewer.grid.cellRect(GridPosition(row: min(Int(row), max(0, viewer.grid.rowCount - 1)), column: index)))
        dismiss(nil)
        viewer.window?.makeFirstResponder(viewer.grid)
    }

    @objc private func showAll(_ sender: Any?) {
        guard let viewer, let source = viewer.source else { return }
        viewer.setHidden(false, columns: Array(source.columns.indices))
        reloadRows()
    }

    // MARK: Search field

    func controlTextDidChange(_ notification: Notification) {
        reloadRows()
        if !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let step = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let next = min(max(0, table.selectedRow + step), rows.count - 1)
            if next >= 0 {
                table.selectRowIndexes([next], byExtendingSelection: false)
                table.scrollRowToVisible(next)
            }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            jump(nil)
            return true
        default:
            return false
        }
    }
}
