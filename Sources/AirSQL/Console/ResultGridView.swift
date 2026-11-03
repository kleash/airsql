import AirSQLCore
import AppKit

/// A result tab's rows in the data grid (plan §2.5's embedding API: a `ResultSetSource` over the statement's
/// `ResultStore`), read-only. ⌘C copies the selected cells (all of them when none are selected) in the grids' copy
/// format (`GridCopy`: TSV until Copy As chooses another), ⌥⌘C with the column names first; Export Rows… saves them.
/// The headers' sort controls sort the rows here (⌥ adds a column), asking first above 100,000 rows.
@MainActor
final class ResultGridView: NSView, DataGridViewDelegate {
    let grid: DataGridView
    let source: ResultSetSource
    /// The rows in the order shown.
    let rows: ReorderedSource

    init(store: ResultStore, nullText: String, fontSize: CGFloat) {
        source = ResultSetSource(store)
        rows = ReorderedSource(source)
        grid = DataGridView(source: rows)
        super.init(frame: .zero)
        grid.nullText = nullText
        grid.fontSize = fontSize
        grid.delegate = self
        grid.setAccessibilityLabel("Result rows")
        addSubview(grid.containerView)
        grid.containerView.pin(to: self)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func dataGrid(_ grid: DataGridView, menuFor target: DataGridView.Target) -> NSMenu? {
        let menu = NSMenu(title: "Result")
        menu.add([Commands.copy, Commands.copyWithHeaders])
        menu.addItem(GridCopy.copyAsItem())
        menu.add([nil, Commands.exportRows])
        for item in menu.items + (menu.items[2].submenu?.items ?? []) where item.action != nil { item.target = self }
        return menu
    }

    /// The table the rows come from, for the SQL formats: the one every column names, else "table".
    private var table: (database: String?, name: String) {
        let columns = source.store.columns
        guard let first = columns.first, !first.originalTable.isEmpty,
              columns.allSatisfy({ $0.originalTable == first.originalTable && $0.database == first.database }) else {
            return (nil, "table")
        }
        return (first.database.isEmpty ? nil : first.database, first.originalTable)
    }

    /// A shown row's value, whole.
    private var value: (Int, Int) -> String? {
        { [source, rows] in source.value(rows.baseRow($0), $1) }
    }

    private func copyRows(_ format: CopyFormat, headers: Bool) {
        if grid.selection.isEmpty, grid.selection.cursor == nil { grid.selectAll(nil) }
        GridCopy.copy(grid, format: format, headers: headers, value: value, database: table.database, table: table.name)
    }

    /// Ascending, descending, then off; with ⌥ the column joins the sort.
    func dataGrid(_ grid: DataGridView, sortBy column: Int, adding: Bool) {
        var keys = grid.sortOrder
        if let index = keys.firstIndex(where: { $0.column == column }) {
            if keys[index].ascending { keys[index].ascending = false } else { keys.remove(at: index) }
            if !adding { keys = keys.filter { $0.column == column } }
        } else {
            keys = (adding ? keys : []) + [DataGridView.Sort(column: column, ascending: true)]
        }
        let sort = { [self] in
            rows.order = keys.isEmpty ? nil : GridSorting.sorted(Array(0..<source.rowCount), by: keys.map { ($0.column, $0.ascending) },
                                                                 columns: source.columns) { source.value($0, $1) }
            grid.sortOrder = keys
            grid.needsDisplay = true
        }
        guard source.rowCount > 100_000, let window else { return sort() }
        let alert = NSAlert()
        alert.messageText = "Sort \(source.rowCount.formatted()) rows here?"
        alert.informativeText = "Sorting this many rows takes a moment. An ORDER BY in the query sorts them on the server."
        alert.addButton(withTitle: "Sort")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { sort() }
        }
    }

    @objc func copy(_ sender: Any?) { copyRows(GridCopy.format, headers: false) }
    @objc func copyWithHeaders(_ sender: Any?) { copyRows(GridCopy.format, headers: true) }

    @objc func copyAs(_ sender: Any?) {
        guard let format = GridCopy.format(of: sender) else { return }
        GridCopy.format = format
        copyRows(format, headers: false)
    }

    /// Export Rows…: the selected rows or every row of the result.
    @objc func exportRows(_ sender: Any?) {
        guard let window else { return }
        let source = source, order = grid.columnOrder, selected = GridCopy.covered(grid).rows, table = table, value = value
        let request = ExportRowsRequest(
            title: table.name == "table" ? "result" : table.name, columns: order.map { source.columns[$0] }, database: table.database,
            table: table.name, selectedCount: selected.count, selected: { selected.map { row in order.map { value(row, $0) } } },
            loadedCount: source.rowCount, loaded: { (0..<source.rowCount).map { row in order.map { value(row, $0) } } },
            all: nil)
        ExportRowsSheet.show(request, activity: ActivityCenter.shared, on: window)
    }
}
