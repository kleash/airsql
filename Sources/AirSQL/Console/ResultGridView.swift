import AirSQLCore
import AppKit

/// A result tab's rows in the data grid (plan §2.5's embedding API: a `ResultSetSource` over the statement's
/// `ResultStore`), read-only. ⌘C copies the selected cells (all of them when none are selected) in the grids' copy
/// format (`GridCopy`: TSV until Copy As chooses another), ⌥⌘C with the column names first; Export Rows… saves them.
@MainActor
final class ResultGridView: NSView, DataGridViewDelegate {
    let grid: DataGridView
    let source: ResultSetSource

    init(store: ResultStore, nullText: String, fontSize: CGFloat) {
        source = ResultSetSource(store)
        grid = DataGridView(source: source)
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
              columns.allSatisfy({ $0.originalTable == first.originalTable && $0.database == first.database }) else { return (nil, "table") }
        return (first.database.isEmpty ? nil : first.database, first.originalTable)
    }

    private func copyRows(_ format: CopyFormat, headers: Bool) {
        if grid.selection.isEmpty, grid.selection.cursor == nil { grid.selectAll(nil) }
        let source = source
        GridCopy.copy(grid, format: format, headers: headers, value: { source.value($0, $1) }, database: table.database, table: table.name)
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
        let source = source, order = grid.columnOrder, rows = GridCopy.covered(grid).rows, table = table
        let request = ExportRowsRequest(
            title: table.name == "table" ? "result" : table.name, columns: order.map { source.columns[$0] }, database: table.database,
            table: table.name, selectedCount: rows.count, selected: { rows.map { row in order.map { source.value(row, $0) } } },
            loadedCount: source.rowCount, loaded: { (0..<source.rowCount).map { row in order.map { source.value(row, $0) } } },
            all: nil)
        ExportRowsSheet.show(request, activity: ActivityCenter.shared, on: window)
    }
}
