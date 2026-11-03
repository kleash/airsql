import AirSQLCore
import AppKit

/// A data grid with what helps read it (lane L2, grid-spec §3): the status bar's position, selection size and
/// aggregate, and columns that open as they were left (widths, order, hidden ones: `TableViewSettings`, per table or
/// per query). The screen that shows it (a table tab, a console result) is its `host`: the grid's edits, sorting and
/// the first items of its menus stay the host's.
@MainActor
final class GridViewer: NSView, DataGridViewDelegate, NSMenuItemValidation {
    /// Where a grid's columns are remembered: a table, or a query (its text as `table`).
    struct ViewKey: Equatable {
        var connection: UUID
        var database: String
        var table: String
    }

    let grid: DataGridView
    /// The status bar's part for this grid (the host's `statusAccessory`).
    let status = GridStatusView()
    weak var host: DataGridViewDelegate?
    /// Where the columns are kept; nil: nowhere.
    var viewKey: ViewKey?
    private var settings = TableViewSettings()
    /// The grid (or what View As shows) on the left, the value panel on the right when it is open.
    private let split = NSSplitView()
    /// The record bar (Record View only) over the body, which holds the grid or what View As shows.
    private let content = NSStackView()
    let body = NSView()
    private(set) var valuePanel: GridValuePanel?
    private let recordBar = NSStackView()
    let recordLabel = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor)

    init(source: GridSource?) {
        grid = DataGridView(source: source)
        super.init(frame: .zero)
        grid.delegate = self
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(content)
        addSubview(split)
        split.pin(to: self)
        content.orientation = .vertical
        content.spacing = 0
        content.setViews([recordBar, body], in: .top)
        body.addSubview(grid.containerView)
        grid.containerView.pin(to: body)
        let previous = GridStatusView.link("‹ Previous", id: "record.previous", tip: Commands.previousRecord.tip,
                                           action: Commands.previousRecord.action)
        let next = GridStatusView.link("Next ›", id: "record.next", tip: Commands.nextRecord.tip, action: Commands.nextRecord.action)
        let close = GridStatusView.link("Back to the Grid", id: "record.close", tip: "Show the rows as a grid again", action: nil)
        close.target = self
        close.action = #selector(backToGrid(_:))
        recordBar.setViews([previous, recordLabel, next], in: .leading)
        recordBar.setViews([close], in: .trailing)
        recordBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        recordBar.isHidden = true
        for part in [recordBar, body] { part.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        status.viewer = self
        status.update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The host's rows; the grid shows them, or them transposed.
    private(set) var source: GridSource?
    /// Transpose (⌥⌘T) or Record View (⌥⌘R, the row shown) is on: the grid shows a `TransposedSource`.
    private(set) var transposed = false
    private(set) var record: Int?
    /// The grid's columns as they were before Transpose or Record View, to put back after.
    private var layout: (order: [Int], widths: [CGFloat])?
    /// Display As, by the source's column.
    private(set) var displays: [Int: GridDisplay] = [:]
    /// Heatmaps by the source's column, and whether equal values are tinted (`GridViewer+Colours`).
    var heat: [Int: HeatScale] = [:]
    var highlightsEqual = false
    /// Where Column Summary is worked out for a table (on the server, by its tab); nil: from the rows in memory.
    var serverSummary: ((_ column: Int, _ done: @escaping (Result<ColumnSummary, Error>) -> Void) -> Void)?
    /// The summary shown last (tests read it).
    private(set) weak var summaryShown: GridSummaryView?
    /// View As or Chart (`GridViewer+Views`): what the body shows, and the view shown in place of the grid.
    var presentation = Presentation.table
    var presented: NSView?
    /// The source as the grid shows it untransposed: with its display types.
    private(set) var displayed: GridSource?

    /// Shows `source` with the columns as they were left under `viewKey`; `transposed` turns it on its side.
    func show(_ source: GridSource?, transposed: Bool = false) {
        if presentation != .table { present(.table) }
        self.source = source
        record = nil
        self.transposed = false
        layout = nil
        if let source, let viewKey {
            settings = TableViewSettingsStore.shared.settings(connection: viewKey.connection, database: viewKey.database,
                                                              table: viewKey.table)
            displays = Dictionary(source.columns.indices.compactMap { index in
                settings.displayTypes[source.columns[index].name].flatMap(GridDisplay.init(rawValue:)).map { (index, $0) }
            }, uniquingKeysWith: { first, _ in first })
        } else {
            displays = [:]
        }
        displayed = source.map(display)
        heat = [:]
        updateTint()
        grid.source = displayed
        restoreColumns()
        if transposed { transposeGrid(nil) }
        updateRecordBar()
        status.update()
        updateValuePanel()
    }

    /// `source` with the display types, when there are any.
    private func display(_ source: GridSource) -> GridSource {
        displays.isEmpty ? source : DisplaySource(source, displays: displays, bytes: { [weak source] row, column in
            (source as? GridBytes)?.bytes(row, column)
        })
    }

    /// Shows the grid's source again in another form (display types, back from Transpose), keeping the columns'
    /// order and widths, the selection and where it is scrolled.
    private func replaceShown(_ shown: GridSource?) {
        let order = grid.columnOrder, widths = grid.columnWidths, selection = grid.selection
        let origin = grid.scrollView.contentView.bounds.origin
        grid.source = shown
        guard let shown, widths.count == shown.columns.count else { return }
        grid.columnWidths = widths
        grid.columnOrder = order
        grid.selection = selection
        grid.scrollView.contentView.scroll(to: origin)
        grid.scrollView.reflectScrolledClipView(grid.scrollView.contentView)
    }

    /// Display As ▸ (a menu item's tag is the `GridDisplay`'s index): the selected columns, or the focused cell's.
    @objc func displayAs(_ sender: Any?) {
        guard let source, let item = sender as? NSMenuItem, GridDisplay.allCases.indices.contains(item.tag) else { return }
        if transposed || record != nil { transposeGrid(nil) }
        let chosen = GridDisplay.allCases[item.tag]
        for column in focusedColumns where GridDisplay.choices(for: source.columns[column]).contains(chosen) {
            displays[column] = chosen == .standard ? nil : chosen
        }
        displayed = display(source)
        replaceShown(displayed)
        saveColumns()
        updateValuePanel()
    }

    /// The source columns the column commands act on: the selected ones, else the focused cell's.
    var focusedColumns: [Int] {
        let selected = (0..<grid.columnCount).filter { grid.selection.containsColumn($0) }
        return (selected.isEmpty ? grid.selection.cursor.map { [$0.column] } ?? [] : selected).map(grid.sourceColumn)
    }

    /// Display As ▸, as in the Data menu: the ways the focused column's kind can be shown are on.
    static func displayMenu() -> NSMenuItem {
        MainMenu.submenu("Display As", GridDisplay.allCases.enumerated().map { index, display in
            let item = Commands.displayAs.item()
            item.title = display.title
            item.tag = index
            return item
        })
    }

    /// The host's rows or columns changed (a page arrived): shows them again.
    func reloadData() {
        (grid.source as? TransposedSource)?.refresh()
        rescaleHeat()
        if presentation != .table { present(presentation) }
        grid.reloadData()
        updateRecordBar()
        status.update()
        updateValuePanel()
    }

    // MARK: Transpose and Record View

    /// Transpose (⌥⌘T): rows become columns, the column names down the left; again to turn back.
    @objc func transposeGrid(_ sender: Any?) {
        guard let source else { return }
        if presentation != .table { present(.table) }
        if transposed || record != nil {
            let focus = (grid.source as? TransposedSource).flatMap { shown in grid.selection.cursor.flatMap { shown.base($0.row, grid.sourceColumn($0.column)) } }
            transposed = false
            record = nil
            grid.source = displayed
            if let layout, layout.widths.count == source.columns.count {
                grid.columnWidths = layout.widths
                grid.columnOrder = layout.order
            }
            layout = nil
            if let focus, let column = grid.columnOrder.firstIndex(of: focus.column) { focusCell(GridPosition(row: focus.row, column: column)) }
        } else {
            let cursor = grid.selection.cursor
            transposed = true
            layout = (grid.columnOrder, grid.columnWidths)
            grid.source = TransposedSource(displayed ?? source, order: grid.columnOrder)
            if let cursor { focusCell(GridPosition(row: cursor.column, column: cursor.row + 1)) }
        }
        updateRecordBar()
        status.update()
        updateValuePanel()
    }

    /// Record View (⌥⌘R): the focused row as a form, one line per column; ⌥↑ ⌥↓ show the row before or after.
    @objc func showRecordView(_ sender: Any?) {
        if presentation != .table { present(.table) }
        if record != nil { return transposeGrid(nil) }
        guard let source, source.rowCount > 0 else { return NSSound.beep() }
        if transposed { transposeGrid(nil) }
        showRecord(grid.selection.cursor?.row ?? 0, field: grid.selection.cursor?.column ?? 0)
    }

    private func showRecord(_ row: Int, field: Int) {
        guard let source else { return }
        if layout == nil { layout = (grid.columnOrder, grid.columnWidths) }
        let order = layout?.order ?? grid.columnOrder
        record = row
        grid.source = TransposedSource(displayed ?? source, order: order, rows: [row])
        focusCell(GridPosition(row: min(field, max(0, order.count - 1)), column: 1))
        updateRecordBar()
        status.update()
        updateValuePanel()
    }

    /// The record bar's Back to the Grid: out of Record View or Transpose.
    @objc func backToGrid(_ sender: Any?) {
        if transposed || record != nil { transposeGrid(nil) }
    }

    /// The row before or after in Record View.
    @objc func showPreviousRecord(_ sender: Any?) { stepRecord(-1) }
    @objc func showNextRecord(_ sender: Any?) { stepRecord(1) }

    private func stepRecord(_ step: Int) {
        guard let record, let source else { return }
        let next = record + step
        guard next >= 0, next < source.rowCount else { return NSSound.beep() }
        showRecord(next, field: grid.selection.cursor?.row ?? 0)
    }

    /// The record bar shows in Record View, with the row's number, and over a transposed grid that leaves rows out.
    private func updateRecordBar() {
        let rows = source?.rowCount ?? 0, cut = transposed && rows > TransposedSource.limit
        recordBar.isHidden = record == nil && !cut
        for view in recordBar.views(in: .leading) where view !== recordLabel { view.isHidden = record == nil }
        if let record {
            recordLabel.stringValue = "Row \((record + 1).formatted()) of \(rows.formatted())"
        } else if cut {
            recordLabel.stringValue = "Transposed: the first \(TransposedSource.limit.formatted()) of \(rows.formatted()) rows"
        }
    }

    private func focusCell(_ position: GridPosition) {
        guard position.row < grid.rowCount, position.column < grid.columnCount else { return }
        grid.selection.select(position)
        grid.reveal(grid.cellRect(position))
    }

    // MARK: Value panel

    /// Value Panel (⇧↩): the focused cell's whole value beside the grid.
    @objc func toggleValuePanel(_ sender: Any?) {
        if let valuePanel {
            valuePanel.removeFromSuperview()
            self.valuePanel = nil
        } else {
            let panel = GridValuePanel()
            split.addArrangedSubview(panel)
            split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
            split.layoutSubtreeIfNeeded()
            split.setPosition(max(240, split.bounds.width - 320), ofDividerAt: 0)
            valuePanel = panel
            updateValuePanel()
        }
    }

    private func updateValuePanel() {
        guard let valuePanel else { return }
        guard let source, let cursor = grid.selection.cursor, cursor.row < grid.rowCount, cursor.column < grid.columnCount else {
            return valuePanel.show(column: nil, value: nil, bytes: nil)
        }
        let column = grid.sourceColumn(cursor.column)
        valuePanel.show(column: source.columns[column], value: source.value(cursor.row, column),
                        bytes: (source as? GridBytes)?.bytes(cursor.row, column))
    }

    // MARK: Columns kept

    /// The order, widths and hidden columns kept under `viewKey`, by name; columns it doesn't know keep their place
    /// at the end.
    func restoreColumns() {
        guard let source, viewKey != nil, !transposed, record == nil, grid.columnWidths.count == source.columns.count else { return }
        let names = source.columns.map(\.name)
        var widths = grid.columnWidths
        for (index, name) in names.enumerated() {
            if let width = settings.widths[name] { widths[index] = CGFloat(max(40, width)) }
        }
        grid.columnWidths = widths
        let rank = Dictionary(settings.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        grid.columnOrder = names.indices.filter { !settings.hiddenColumns.contains(names[$0]) }
            .sorted { (rank[names[$0]] ?? Int.max, $0) < (rank[names[$1]] ?? Int.max, $1) }
    }

    /// Keeps the columns' order, widths and hidden ones under `viewKey`.
    func saveColumns() {
        guard let source, let viewKey, !transposed, record == nil, grid.columnWidths.count == source.columns.count else { return }
        let names = source.columns.map(\.name)
        let shown = grid.columnOrder.map { names[$0] }, hidden = names.filter { !shown.contains($0) }
        // Hidden columns keep their place: after the column they followed before.
        let old = settings.order.isEmpty ? names : settings.order
        var order = shown
        for name in hidden {
            let before = old.prefix { $0 != name }.last { order.contains($0) }
            order.insert(name, at: before.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        }
        settings.order = order
        settings.hiddenColumns = hidden
        settings.displayTypes = Dictionary(displays.map { (names[$0.key], $0.value.rawValue) }, uniquingKeysWith: { first, _ in first })
        settings.widths = Dictionary(names.indices.map { (names[$0], Double(grid.columnWidths[$0])) },
                                     uniquingKeysWith: { first, _ in first })
        TableViewSettingsStore.shared.set(settings, connection: viewKey.connection, database: viewKey.database,
                                          table: viewKey.table)
    }

    /// Shows or hides source columns (the column list, Hide Column), keeping the rest in their order.
    func setHidden(_ hidden: Bool, columns: [Int]) {
        guard let source else { return }
        if transposed || record != nil { transposeGrid(nil) }
        var order = grid.columnOrder
        if hidden {
            order.removeAll { columns.contains($0) }
            guard !order.isEmpty else { return NSSound.beep() }  // one column stays
        } else {
            let rank = Dictionary(settings.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            for column in columns where !order.contains(column) {
                // Back where it was: before the first shown column that came after it.
                let place = rank[source.columns[column].name] ?? Int.max
                let index = order.firstIndex { (rank[source.columns[$0].name] ?? Int.max, $0) > (place, column) } ?? order.count
                order.insert(column, at: index)
            }
        }
        grid.selection.clear()
        grid.columnOrder = order
        saveColumns()
        status.update()
    }

    // MARK: Commands (they reach the viewer while its grid has the focus)

    /// Go to Row… (⌘L): a row number, or column:row.
    @objc func goToRow(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, let source else { return }
        let names = grid.columnOrder.map { source.columns[$0].name }
        let cursor = grid.selection.cursor
        askText("Go to Row", message: "Type a row number from 1 to \(grid.rowCount.formatted()), or column:row (the column's name or number)",
                placeholder: "120 or \(names.first ?? "id"):120", action: "Go", id: "goToRow.text", on: window) { [weak self] text in
            guard let self else { return }
            guard let target = GridGoTo(text), target.row < grid.rowCount, target.column == nil || target.columnIndex(in: names) != nil else {
                return NSSound.beep()
            }
            let position = GridPosition(row: target.row, column: target.columnIndex(in: names) ?? cursor?.column ?? 0)
            grid.selection.select(position)
            grid.reveal(grid.cellRect(position))
            window.makeFirstResponder(grid)
        }
    }

    /// Column List… (⌘J): find a column, jump to it, show or hide columns.
    @objc func showColumnList(_ sender: Any?) {
        guard source != nil, window != nil else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = GridColumnList(viewer: self)
        let container = grid.containerView!
        // Under the header's right end (the container is flipped).
        popover.show(relativeTo: NSRect(x: container.bounds.maxX - 60, y: 0, width: 40, height: grid.header.frame.height),
                     of: container, preferredEdge: .maxY)
    }

    /// Column Summary…: the focused column's distinct values, NULLs, smallest and largest, and most frequent values.
    @objc func showColumnSummary(_ sender: Any?) {
        if presentation != .table { present(.table) }
        if transposed || record != nil { transposeGrid(nil) }
        guard let source, let column = focusedColumns.first, window != nil else { return NSSound.beep() }
        let origin = serverSummary == nil ? "From the \(source.rowCount.formatted()) rows loaded" : "From the server, within the filter"
        let content = GridSummaryView(column: source.columns[column].name, origin: origin, nullText: grid.nullText)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        let display = grid.columnOrder.firstIndex(of: column) ?? 0
        grid.reveal(grid.cellRect(GridPosition(row: grid.selection.cursor?.row ?? 0, column: display)))
        let (left, right) = grid.header.edges(display), header = grid.header.bounds
        let start = min(max(header.minX, left), header.maxX - 20)
        popover.show(relativeTo: NSRect(x: start, y: 0, width: max(20, min(right, header.maxX) - start), height: header.height),
                     of: grid.header, preferredEdge: .maxY)
        summaryShown = content
        if let serverSummary {
            serverSummary(column) { [weak content] result in content?.show(result) }
        } else {
            content.show(.success(ColumnSummary(values: (0..<source.rowCount).map { source.value($0, column) })))
        }
    }

    @objc func zoomIn(_ sender: Any?) { grid.fontSize = min(28, grid.fontSize + 1) }
    @objc func zoomOut(_ sender: Any?) { grid.fontSize = max(9, grid.fontSize - 1) }
    @objc func zoomReset(_ sender: Any?) {
        grid.fontSize = CGFloat((NSApp.delegate as? AppDelegate)?.model?.data.settings.gridFontSize ?? 12)
    }

    /// Copy Selection Summary (⇧⌘C): every figure for the selected cells, one per line.
    @objc func copySummary(_ sender: Any?) {
        guard let aggregate = status.aggregate else { return NSSound.beep() }
        let lines = GridAggregate.Kind.allCases.compactMap { kind in aggregate.copyText(kind).map { "\(kind.title)\t\($0)" } }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// Hide Column: the selected columns, or the focused cell's.
    @objc func hideColumn(_ sender: Any?) {
        setHidden(true, columns: focusedColumns)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copySummary(_:)):
            item.explain(enabled: status.aggregate != nil, reason: "Select some cells first")
            return status.aggregate != nil
        case #selector(goToRow(_:)): return grid.rowCount > 0
        case #selector(showColumnSummary(_:)):
            item.explain(enabled: !focusedColumns.isEmpty, reason: "Select a column first")
            return !focusedColumns.isEmpty
        case #selector(showColumnList(_:)): return source != nil
        case #selector(viewAs(_:)):
            item.state = item.tag == presentation.rawValue ? .on : .off
            return source != nil
        case #selector(showChart(_:)):
            item.state = presentation == .chart ? .on : .off
            return source != nil
        case #selector(toggleHeatmap(_:)):
            let all = grid.selection.areas.contains(.all)
            let columns = ((all ? source.map { Array($0.columns.indices) } : nil) ?? focusedColumns)
                .filter { source?.columns[$0].kind == .number }
            item.state = !columns.isEmpty && columns.allSatisfy({ heat[$0] != nil }) ? .on : .off
            item.explain(enabled: !columns.isEmpty, reason: "Select a number column first")
            return !columns.isEmpty
        case #selector(highlightEqualValues(_:)):
            item.state = highlightsEqual ? .on : .off
            return source != nil
        case #selector(displayAs(_:)):
            let display = GridDisplay.allCases.indices.contains(item.tag) ? GridDisplay.allCases[item.tag] : .standard
            let columns = focusedColumns.compactMap { source?.columns[$0] }
            let enabled = !columns.isEmpty && columns.allSatisfy { GridDisplay.choices(for: $0).contains(display) }
            item.state = enabled && focusedColumns.allSatisfy({ (displays[$0] ?? .standard) == display }) ? .on : .off
            item.explain(enabled: enabled, reason: columns.isEmpty ? "Select a column first" : "Not for this column's type")
            return enabled
        case #selector(toggleValuePanel(_:)):
            item.state = valuePanel == nil ? .off : .on
            return true
        case #selector(transposeGrid(_:)):
            item.state = transposed ? .on : .off
            return source != nil
        case #selector(showPreviousRecord(_:)), #selector(showNextRecord(_:)):
            let step = item.action == #selector(showNextRecord(_:)) ? 1 : -1
            let enabled = record.map { (0..<(source?.rowCount ?? 0)).contains($0 + step) } ?? false
            item.explain(enabled: enabled, reason: record == nil ? "Open Record View first (⌥⌘R)" : "There is no row \(step > 0 ? "after" : "before") this one")
            return enabled
        case #selector(showRecordView(_:)):
            item.state = record != nil ? .on : .off
            item.explain(enabled: (source?.rowCount ?? 0) > 0, reason: "There are no rows to show")
            return (source?.rowCount ?? 0) > 0
        case #selector(hideColumn(_:)):
            let enabled = grid.columnCount > 1 && grid.selection.cursor != nil
            item.explain(enabled: enabled, reason: grid.columnCount > 1 ? "Select a column first" : "One column stays shown")
            return enabled
        default: return true
        }
    }

    // MARK: DataGridViewDelegate

    func dataGridSelectionDidChange(_ grid: DataGridView) {
        status.update()
        updateValuePanel()
        if highlightsEqual { grid.needsDisplay = true }
        host?.dataGridSelectionDidChange(grid)
    }

    func dataGrid(_ grid: DataGridView, canEditRow row: Int, column: Int) -> Bool {
        host?.dataGrid(grid, canEditRow: row, column: column) ?? false
    }

    func dataGrid(_ grid: DataGridView, didEditRow row: Int, column: Int, text: String) {
        host?.dataGrid(grid, didEditRow: row, column: column, text: text)
        status.update()
    }

    /// The host's items (Copy…), then the viewer's for what was clicked.
    func dataGrid(_ grid: DataGridView, menuFor target: DataGridView.Target) -> NSMenu? {
        let menu = host?.dataGrid(grid, menuFor: target) ?? NSMenu(title: "Grid")
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        switch target {
        case .cells: menu.add([Commands.valuePanel, Commands.recordView, Commands.columnSummary])
        case .row: menu.add([Commands.recordView, Commands.valuePanel])
        case .column: menu.add([Commands.columnSummary, Commands.hideColumn, Commands.columnList, Commands.heatmap])
        }
        if !transposed, record == nil { menu.addItem(Self.displayMenu()) }
        return menu
    }

    func dataGrid(_ grid: DataGridView, sortBy column: Int, adding: Bool) {
        host?.dataGrid(grid, sortBy: column, adding: adding)
    }

    /// A double click on a row's number: Record View of that row.
    func dataGrid(_ grid: DataGridView, openRecord row: Int) {
        guard !transposed, record == nil else { return }
        grid.selection.select(GridPosition(row: row, column: grid.selection.cursor?.column ?? 0))
        showRecordView(nil)
    }

    /// A double click on a cell that can't be edited opens the value panel.
    func dataGridOpenValue(_ grid: DataGridView) {
        if valuePanel == nil { toggleValuePanel(nil) }
    }

    func dataGridColumnsDidChange(_ grid: DataGridView) {
        saveColumns()
        host?.dataGridColumnsDidChange(grid)
    }
}

/// A source that keeps the bytes the server sent: the value panel's hex and image.
protocol GridBytes {
    func bytes(_ row: Int, _ column: Int) -> [UInt8]?
}

extension TableDataSource: GridBytes {}

extension ResultSetSource: GridBytes {
    func bytes(_ row: Int, _ column: Int) -> [UInt8]? { store.bytes(row, column) }
}
