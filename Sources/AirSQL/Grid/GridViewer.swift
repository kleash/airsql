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
        let close = GridStatusView.link("Back to the Grid", id: "record.close", tip: "Show every row again (⌥⌘R)",
                                        action: Commands.recordView.action)
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

    /// Shows `source` with the columns as they were left under `viewKey`; `transposed` turns it on its side.
    func show(_ source: GridSource?, transposed: Bool = false) {
        self.source = source
        record = nil
        self.transposed = false
        grid.source = source
        restoreColumns()
        if transposed { transposeGrid(nil) }
        updateRecordBar()
        status.update()
        updateValuePanel()
    }

    /// The host's rows or columns changed (a page arrived): shows them again.
    func reloadData() {
        (grid.source as? TransposedSource)?.refresh()
        grid.reloadData()
        updateRecordBar()
        status.update()
        updateValuePanel()
    }

    // MARK: Transpose and Record View

    /// Transpose (⌥⌘T): rows become columns, the column names down the left; again to turn back.
    @objc func transposeGrid(_ sender: Any?) {
        guard let source else { return }
        if transposed || record != nil {
            let focus = (grid.source as? TransposedSource).flatMap { shown in grid.selection.cursor.flatMap { shown.base($0.row, grid.sourceColumn($0.column)) } }
            transposed = false
            record = nil
            grid.source = source
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
            grid.source = TransposedSource(source, order: grid.columnOrder)
            if let cursor { focusCell(GridPosition(row: cursor.column, column: cursor.row + 1)) }
        }
        updateRecordBar()
        status.update()
        updateValuePanel()
    }

    /// Record View (⌥⌘R): the focused row as a form, one line per column; ⌥↑ ⌥↓ show the row before or after.
    @objc func showRecordView(_ sender: Any?) {
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
        grid.source = TransposedSource(source, order: order, rows: [row])
        focusCell(GridPosition(row: min(field, max(0, order.count - 1)), column: 1))
        updateRecordBar()
        status.update()
        updateValuePanel()
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

    /// The record bar shows in Record View, with the row's number.
    private func updateRecordBar() {
        recordBar.isHidden = record == nil
        if let record, let source { recordLabel.stringValue = "Row \((record + 1).formatted()) of \(source.rowCount.formatted())" }
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
        guard let source, let viewKey, grid.source === source, grid.columnWidths.count == source.columns.count else { return }
        settings = TableViewSettingsStore.shared.settings(connection: viewKey.connection, database: viewKey.database,
                                                          table: viewKey.table)
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
        guard let source, let viewKey, grid.source === source, grid.columnWidths.count == source.columns.count else { return }
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
        let shown = Array(0..<grid.columnCount).filter { grid.selection.containsColumn($0) }
        let columns = shown.isEmpty ? grid.selection.cursor.map { [$0.column] } ?? [] : shown
        setHidden(true, columns: columns.map(grid.sourceColumn))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copySummary(_:)):
            item.explain(enabled: status.aggregate != nil, reason: "Select some cells first")
            return status.aggregate != nil
        case #selector(goToRow(_:)): return grid.rowCount > 0
        case #selector(showColumnList(_:)): return source != nil
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
        host?.dataGridSelectionDidChange(grid)
    }

    func dataGrid(_ grid: DataGridView, canEditRow row: Int, column: Int) -> Bool {
        host?.dataGrid(grid, canEditRow: row, column: column) ?? false
    }

    func dataGrid(_ grid: DataGridView, didEditRow row: Int, column: Int, text: String) {
        host?.dataGrid(grid, didEditRow: row, column: column, text: text)
        status.update()
    }

    func dataGrid(_ grid: DataGridView, menuFor target: DataGridView.Target) -> NSMenu? {
        host?.dataGrid(grid, menuFor: target)
    }

    func dataGrid(_ grid: DataGridView, sortBy column: Int, adding: Bool) {
        host?.dataGrid(grid, sortBy: column, adding: adding)
    }

    func dataGrid(_ grid: DataGridView, openRecord row: Int) {
        host?.dataGrid(grid, openRecord: row)
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
