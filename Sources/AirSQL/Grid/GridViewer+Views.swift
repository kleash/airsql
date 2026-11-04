import AirSQLCore
import AppKit

/// View As ▸ Table, Text or Tree, and Chart (grid-spec §3): the rows shown another way in place of the grid. Text and
/// Tree show the first 10,000 rows, the columns as the grid has them (order, hidden ones; Tree with the display types).
/// Text is what copying them all would give: the copy format (Edit ▸ Copy As), with the column names.
extension GridViewer {
    enum Presentation: Int {
        case table, text, tree, chart
    }

    /// The most rows Text, Tree and Chart show.
    static let presentedLimit = 10_000

    /// View As ▸ (the item's tag: 0 Table, 1 Text, 2 Tree).
    @objc func viewAs(_ sender: Any?) {
        present(Presentation(rawValue: (sender as? NSMenuItem)?.tag ?? 0) ?? .table)
    }

    /// Chart: the rows as a chart; again for the table.
    @objc func showChart(_ sender: Any?) {
        present(presentation == .chart ? .table : .chart)
    }

    /// Shows the rows as `next`, in place of what the body shows now.
    func present(_ next: Presentation) {
        guard source != nil else { return }
        if next != .table, transposed || record != nil { transposeGrid(nil) }
        presented?.removeFromSuperview()
        presented = nil
        presentation = next
        grid.containerView.isHidden = next != .table
        let view: NSView
        switch next {
        case .table:
            window?.makeFirstResponder(grid)
            return
        case .text:
            guard let source else { return }
            let rows = Array(0..<min(source.rowCount, Self.presentedLimit))
            let scroll = NSTextView.scrollableTextView()
            let text = scroll.documentView as! NSTextView
            text.isEditable = false
            let font = NSFont.monospacedSystemFont(ofSize: grid.fontSize, weight: .regular)
            text.font = font
            // Tabs (TSV) every eight characters, past the default stops too. Long rows wrap, so only what shows is laid out: a
            // text as wide as its longest row is laid out whole first (10,000 rows of it took CI's Mac 40 minutes).
            let tabs = NSMutableParagraphStyle()
            tabs.tabStops = []
            tabs.defaultTabInterval = 8 * ("0" as NSString).size(withAttributes: [.font: font]).width
            text.defaultParagraphStyle = tabs
            text.textContainerInset = NSSize(width: 8, height: 8)
            text.string = GridCopy.text(source, rows: rows, columns: grid.columnOrder, format: GridCopy.format, headers: true,
                                        nullText: grid.nullText, database: copyTable.database, table: copyTable.name, noBackslashEscapes: noBackslashEscapes) + note(rows.count)
            text.setAccessibilityIdentifier("grid.text")
            view = scroll
        case .tree:
            let (columns, rows) = presentedRows()
            let tree = JSONTreeView()
            tree.openLevels = 1
            tree.tree = JSONNode.rows(columns, rows)
            tree.outline.setAccessibilityIdentifier("grid.tree")
            view = tree
        case .chart:
            view = GridChartView(viewer: self)
        }
        body.addSubview(view)
        view.pin(to: body)
        presented = view
        window?.makeFirstResponder(view is NSScrollView ? (view as! NSScrollView).documentView : view)
    }

    /// What the rows shown are short of: "Showing the first 10,000 rows".
    private func note(_ shown: Int) -> String {
        guard let source, source.rowCount > shown else { return "" }
        return "\n\nShowing the first \(shown.formatted()) of \(source.rowCount.formatted()) rows loaded."
    }

    /// What a chart of the rows shown leaves out: rows past `presentedLimit`, and rows the table tab hasn't loaded.
    var chartCoverage: String? {
        guard let source else { return nil }
        let shown = min(source.rowCount, Self.presentedLimit).formatted()
        if (source as? TableDataSource)?.hasMore == true { return "Covers the first \(shown) rows loaded, not the whole table" }
        return source.rowCount > Self.presentedLimit ? "Covers the first \(shown) of \(source.rowCount.formatted()) rows" : nil
    }

    /// The first rows (at most `presentedLimit`) by the columns on screen, as the grid shows them; nil for NULL.
    func presentedRows() -> (columns: [GridColumn], rows: [[String?]]) {
        guard let shown = displayed ?? source else { return ([], []) }
        let order = grid.columnOrder
        let rows = (0..<min(shown.rowCount, Self.presentedLimit)).map { row in
            order.map { column -> String? in
                switch shown.cell(row, column) {
                case .text(let text): return text
                case .null, .placeholder: return nil
                case .loading: return "…"
                }
            }
        }
        return (order.map { shown.columns[$0] }, rows)
    }

    /// The numbers of a column in the rows shown (charts): nil where a value isn't one.
    func numbers(_ column: Int) -> [Double?] {
        guard let source else { return [] }
        return (0..<min(source.rowCount, Self.presentedLimit)).map { source.value($0, column).flatMap(Double.init) }
    }
}
