import AirSQLCore
import AppKit

/// A result tab's rows in the data grid (plan §2.5's embedding API: a `ResultSetSource` over the statement's
/// `ResultStore`, or a `DiffSource` for a compared result), in a `GridViewer` (the status bar's figures, the value panel,
/// Record View, the grids' copy formats, columns kept per query). The headers' sort controls sort the rows here (⌥ adds
/// a column), asking first above 100,000 rows; the filter bar's conditions and search filter them here too
/// (`ResultFilterBar`); Export Rows… saves them. A console's result of a SELECT is a `ResultEditSource`, editable when
/// its tables' keys are in it (`ResultGridView+Editing`); the rest are read-only.
@MainActor
final class ResultGridView: NSView, DataGridViewDelegate {
    let viewer: GridViewer
    var grid: DataGridView { viewer.grid }
    let source: GridSource
    /// The rows in the order shown.
    let rows: ReorderedSource
    /// The table the rows come from, for the SQL formats and the export's name.
    private let table: (database: String?, name: String)
    /// The bar over the rows, and its conditions on the source's columns (ANDed).
    let filterBar = ResultFilterBar()
    let findBar = TableFindBar()
    /// Over the grid when there are no rows to show.
    let emptyNote = TableEmptyNote()
    /// Whether the find bar's Filter Rows was hiding rows at the last change.
    var findFiltered = false
    var conditions: [(column: Int, condition: GridCondition)] = []
    /// Editing a console result: the connection it was run on (nil: not connected), the app (for Settings ▸ Safety),
    /// whether the console has a transaction open, and the data session's sql_mode and time zone once read.
    var editingContext: EditorContext?
    /// The data session, where Apply runs (the tests give their own); set by `prepareEditing` when nil.
    var openSession: (() async throws -> TableSession)?
    weak var model: AppModel?
    var transactionOpen: () -> Bool = { false }
    var editContext: EditContext?
    var checklist: SetChecklist?
    var lookup: ForeignKeyLookup?
    /// The pending changes' bar over the rows, and "Editable" or "Read-only" in the status bar.
    let notice = TableDataNotice()
    let editState = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor)

    /// `viewKey`: where its columns are kept (the statement, on its connection).
    /// `transposed`: shown on its side (a result with one row).
    /// `editable`: a console's result, whose cells may be edited (`prepareEditing`).
    convenience init(store: ResultStore, nullText: String, fontSize: CGFloat, viewKey: GridViewer.ViewKey? = nil,
                     transposed: Bool = false, editable: Bool = false) {
        self.init(source: editable ? ResultEditSource(store) : ResultSetSource(store), table: Self.table(of: store.columns),
                  nullText: nullText, fontSize: fontSize, viewKey: viewKey, transposed: transposed)
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
        viewer.filterByValue = { [weak self] column, value in
            guard let self else { return }
            self.filter(column, by: GridCondition(self.source.columns[column], .equals, [value]), adding: true)
        }
        grid.setAccessibilityLabel("Result rows")
        emptyNote.add.isHidden = true
        emptyNote.clear.target = self
        emptyNote.place(in: viewer.body)
        viewer.didPresent = { [weak self] in self?.updateEmptyNote() }
        updateEmptyNote()
        filterBar.owner = self
        filterBar.show([], shown: source.rowCount, of: source.rowCount)
        // The filter bar shows while a filter or a search is on (⇧⌘E opens it), and an edited result's notice while its
        // changes wait; hidden, they take no room.
        findBar.owner = self
        viewer.findBar = findBar
        let bars = NSStackView(views: [filterBar, findBar, notice])
        bars.orientation = .vertical
        bars.spacing = 0
        bars.translatesAutoresizingMaskIntoConstraints = false
        for bar in [filterBar, findBar, notice] as [NSView] { bar.widthAnchor.constraint(equalTo: bars.widthAnchor).isActive = true }
        filterBar.isHidden = true
        notice.owner = self
        addSubview(bars)
        addSubview(viewer)
        viewer.translatesAutoresizingMaskIntoConstraints = false
        var top = topAnchor
        if let legend {
            let line = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
            line.attributedStringValue = legend.text
            line.toolTip = legend.tip
            line.setAccessibilityIdentifier("grid.legend")
            addSubview(line)
            NSLayoutConstraint.activate([
                line.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.unit),
                line.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.unit),
            ])
            top = line.bottomAnchor
        }
        if source is ResultEditSource {
            editState.setAccessibilityIdentifier("result.editState")
            editState.isHidden = true
            viewer.status.insertView(editState, at: 0, in: .trailing)
        }
        NSLayoutConstraint.activate([
            bars.topAnchor.constraint(equalTo: top, constant: legend == nil ? 0 : 5),
            bars.leadingAnchor.constraint(equalTo: leadingAnchor), bars.trailingAnchor.constraint(equalTo: trailingAnchor),
            viewer.topAnchor.constraint(equalTo: bars.bottomAnchor),
            viewer.leadingAnchor.constraint(equalTo: leadingAnchor), viewer.trailingAnchor.constraint(equalTo: trailingAnchor),
            viewer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func dataGrid(_ grid: DataGridView, menuFor target: DataGridView.Target) -> NSMenu? {
        let menu = NSMenu(title: "Result")
        let editable = edits?.editing?.isEditable == true
        switch target {
        case .column:
            menu.add([Commands.sortAscending, Commands.sortDescending, Commands.addToSort, Commands.sortColumns, Commands.clearSort, nil,
                      Commands.filterByValues, Commands.clearFilter])
        case .cells:
            menu.addItem(quickFilterItem())
            menu.add([Commands.clearFilter, nil])
            if editable {
                menu.add([Commands.cut, Commands.paste, Commands.setNull, Commands.setDefault])
                let values = insertValueItems()
                if !values.isEmpty { menu.addItem(MainMenu.submenu("Insert Value", values)) }
                if let column = viewer.focusedCell?.column, foreignKey(column) != nil { menu.add([Commands.chooseReferencedRow]) }
                menu.add([nil] + (edits?.canDelete == true ? [Commands.deleteRows] : []) + [Commands.revert, nil,
                         Commands.previewChanges, Commands.apply, nil])
            }
            menu.add([Commands.exportRows])
        case .row:
            if editable { menu.add((edits?.canDelete == true ? [Commands.deleteRows] : []) + [Commands.revert, nil]) }
            menu.add([Commands.exportRows])
        }
        for item in menu.items + menu.items.compactMap(\.submenu).flatMap(\.items) where item.target == nil { item.target = self }
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
        let sort = { [self] in sortRows(keys) }
        guard source.rowCount > 100_000, let window else { return sort() }
        let alert = NSAlert()
        alert.messageText = "Sort \(source.rowCount.formatted()) rows here?"
        alert.informativeText = "Sorting this many rows takes a moment. An ORDER BY in the query sorts them on the server."
        alert.addButton(withTitle: "Sort").toolTip = "Sort the result's rows on this Mac"
        alert.addButton(withTitle: "Cancel").toolTip = "Leave the rows as they are"
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { sort() }
        }
    }

    /// Shows the rows sorted by `keys` (none: as they came), filtered as they are.
    func sortRows(_ keys: [DataGridView.Sort]) {
        viewer.backToGrid(nil)  // the sort is the grid's own: Record View and Transpose keep it aside
        grid.sortOrder = keys
        reorder()
    }

    /// Export Rows… (and the result tab's Export Result…): the selected rows or every row of the result.
    @objc func exportRows(_ sender: Any?) {
        guard let window else { return }
        let rows = rows, order = viewer.shownColumns, selected = viewer.selectedRows(), table = table
        func values(_ row: Int) -> [String?] { order.map { rows.value(row, $0) } }
        let request = ExportRowsRequest(
            title: table.name == "table" ? "result" : table.name, columns: order.map { source.columns[$0] }, database: table.database,
            table: table.name, noBackslashEscapes: viewer.noBackslashEscapes, hiddenColumns: source.columns.count - order.count, selectedCount: selected.count, selected: { selected.map(values) },
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
        let tip = text.string + "\nRows only in \(names.first) are green; rows only in \(names.second) are red and struck through; "
            + "cells that differ are amber: hold the pointer over one to see both values. Rows are matched on \(key)."
        return (text, tip)
    }
}
