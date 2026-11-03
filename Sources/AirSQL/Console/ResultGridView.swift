import AirSQLCore
import AppKit

/// A result tab's rows in the data grid (plan §2.5's embedding API: a `ResultSetSource` over the statement's
/// `ResultStore`, or a `DiffSource` for a compared result), read-only, in a `GridViewer` (the status bar's figures, the
/// value panel, Record View, the grids' copy formats, columns kept per query). The headers' sort controls sort the rows
/// here (⌥ adds a column), asking first above 100,000 rows; Export Rows… saves them.
@MainActor
final class ResultGridView: NSView, DataGridViewDelegate {
    let viewer: GridViewer
    var grid: DataGridView { viewer.grid }
    let source: GridSource
    /// The rows in the order shown.
    let rows: ReorderedSource
    /// The table the rows come from, for the SQL formats and the export's name.
    private let table: (database: String?, name: String)

    /// `viewKey`: where its columns are kept (the statement, on its connection).
    /// `transposed`: shown on its side (a result with one row).
    convenience init(store: ResultStore, nullText: String, fontSize: CGFloat, viewKey: GridViewer.ViewKey? = nil,
                     transposed: Bool = false) {
        self.init(source: ResultSetSource(store), table: Self.table(of: store.columns), nullText: nullText, fontSize: fontSize,
                  viewKey: viewKey, transposed: transposed)
    }

    /// `legend`: a line above the rows saying what their colours mean (a diff's), and its tooltip.
    init(source: GridSource, table: (database: String?, name: String), legend: (text: NSAttributedString, tip: String)? = nil, nullText: String,
         fontSize: CGFloat, viewKey: GridViewer.ViewKey? = nil, transposed: Bool = false) {
        self.source = source
        self.table = table
        rows = ReorderedSource(source)
        viewer = GridViewer(source: nil)
        super.init(frame: .zero)
        viewer.grid.nullText = nullText
        viewer.grid.fontSize = fontSize
        viewer.host = self
        viewer.viewKey = viewKey
        viewer.copyTable = table
        // ⌘C with nothing selected copies the whole result.
        viewer.copiesEverything = true
        viewer.show(rows, transposed: transposed)
        grid.setAccessibilityLabel("Result rows")
        addSubview(viewer)
        guard let legend else {
            viewer.pin(to: self)
            return
        }
        let line = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
        line.attributedStringValue = legend.text
        line.toolTip = legend.tip
        line.setAccessibilityIdentifier("grid.legend")
        addSubview(line)
        viewer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.unit),
            line.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.unit),
            viewer.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 5),
            viewer.leadingAnchor.constraint(equalTo: leadingAnchor), viewer.trailingAnchor.constraint(equalTo: trailingAnchor),
            viewer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func dataGrid(_ grid: DataGridView, menuFor target: DataGridView.Target) -> NSMenu? {
        if case .column = target { return nil }
        let menu = NSMenu(title: "Result")
        menu.add([Commands.exportRows])
        menu.items.forEach { $0.target = self }
        return menu
    }

    /// The table a result's rows come from, for the SQL formats: the one every column names, else "table".
    static func table(of columns: [ResultStore.Column]) -> (database: String?, name: String) {
        guard let first = columns.first, !first.originalTable.isEmpty,
              columns.allSatisfy({ $0.originalTable == first.originalTable && $0.database == first.database }) else {
            return (nil, "table")
        }
        return (first.database.isEmpty ? nil : first.database, first.originalTable)
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
            viewer.reloadData()
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

    /// Export Rows… (and the result tab's Export Result…): the selected rows or every row of the result.
    @objc func exportRows(_ sender: Any?) {
        guard let window else { return }
        let rows = rows, order = viewer.shownColumns, selected = viewer.selectedRows(), table = table
        func values(_ row: Int) -> [String?] { order.map { rows.value(row, $0) } }
        let request = ExportRowsRequest(
            title: table.name == "table" ? "result" : table.name, columns: order.map { source.columns[$0] }, database: table.database,
            table: table.name, selectedCount: selected.count, selected: { selected.map(values) },
            loadedCount: rows.rowCount, loaded: { (0..<rows.rowCount).map(values) }, all: nil)
        ExportRowsSheet.show(request, activity: ActivityCenter.shared, on: window)
    }
}

extension DiffSource: GridBytes {}

extension DiffSource {
    /// What the colours mean, with the counts ("● 3 only in Production  ● 2 only in Staging  ● 12 changed"), and the
    /// same in words.
    var legend: (text: NSAttributedString, tip: String) {
        let text = NSMutableAttributedString(), font = NSFont.systemFont(ofSize: 11.5)
        let parts = [(data.missing.count, "only in \(names.first)", NSColor.pendingInsertLine),
                     (data.extra.count, "only in \(names.second)", NSColor.pendingDeleteLine), (data.changed.count, "changed", NSColor.pendingEditLine)]
        for (index, (count, words, colour)) in parts.enumerated() {
            text.append(NSAttributedString(string: (index == 0 ? "" : "    ") + "● ", attributes: [.font: font, .foregroundColor: colour]))
            text.append(NSAttributedString(string: "\(count.formatted()) \(words)",
                                           attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let key = data.key.isEmpty ? "every column" : data.key.joined(separator: ", ")
        let tip = "Rows only in \(names.first) are green; rows only in \(names.second) are red and struck through; cells that "
            + "differ are amber: hold the pointer over one to see both values. Rows are matched on \(key)."
        return (text, tip)
    }
}
