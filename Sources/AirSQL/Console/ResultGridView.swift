import AirSQLCore
import AppKit

/// A result tab's rows in the data grid (plan §2.5's embedding API: a `ResultSetSource` over the statement's
/// `ResultStore`), read-only, in a `GridViewer` (the status bar's figures, columns kept per query). ⌘C copies the
/// selected cells (all of them when none are selected) as tab-separated text with the column names first; the grid
/// lanes bring the other formats.
@MainActor
final class ResultGridView: NSView, DataGridViewDelegate {
    let viewer: GridViewer
    var grid: DataGridView { viewer.grid }
    let source: ResultSetSource

    /// `viewKey`: where its columns are kept (the statement, on its connection).
    /// `transposed`: shown on its side (a result with one row).
    init(store: ResultStore, nullText: String, fontSize: CGFloat, viewKey: GridViewer.ViewKey? = nil, transposed: Bool = false) {
        source = ResultSetSource(store)
        viewer = GridViewer(source: nil)
        super.init(frame: .zero)
        viewer.grid.nullText = nullText
        viewer.grid.fontSize = fontSize
        viewer.host = self
        viewer.viewKey = viewKey
        viewer.show(source, transposed: transposed)
        grid.setAccessibilityLabel("Result rows")
        addSubview(viewer)
        viewer.pin(to: self)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func dataGrid(_ grid: DataGridView, menuFor target: DataGridView.Target) -> NSMenu? {
        let menu = NSMenu(title: "Result")
        let copy = Commands.copy.item()
        copy.target = self
        menu.addItem(copy)
        return menu
    }

    @objc func copy(_ sender: Any?) {
        let selection = grid.selection
        let order = grid.columnOrder
        let rows = (0..<source.rowCount).filter { row in selection.isEmpty || order.indices.contains { selection.contains(GridPosition(row: row, column: $0)) } }
        let shown = order.indices.filter { column in selection.isEmpty || rows.contains { selection.contains(GridPosition(row: $0, column: column)) } }
        var lines = [shown.map { source.columns[order[$0]].name }.joined(separator: "\t")]
        for row in rows {
            lines.append(shown.map { column -> String in
                guard selection.isEmpty || selection.contains(GridPosition(row: row, column: column)) else { return "" }
                return source.value(row, order[column]) ?? grid.nullText
            }.joined(separator: "\t"))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
