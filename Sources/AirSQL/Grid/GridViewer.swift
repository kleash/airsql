import AirSQLCore
import AppKit

/// A data grid with what helps read it (lane L2, grid-spec §3): the status bar's position, selection size and
/// aggregate, and columns that open as they were left (widths, order, hidden ones: `TableViewSettings`, per table or
/// per query). The screen that shows it (a table tab, a console result) is its `host`: the grid's edits, sorting and
/// the first items of its menus stay the host's.
@MainActor
final class GridViewer: NSView, DataGridViewDelegate {
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
    let content = NSView()
    private(set) var valuePanel: GridValuePanel?

    init(source: GridSource?) {
        grid = DataGridView(source: source)
        super.init(frame: .zero)
        grid.delegate = self
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(content)
        addSubview(split)
        split.pin(to: self)
        content.addSubview(grid.containerView)
        grid.containerView.pin(to: content)
        status.viewer = self
        status.update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var source: GridSource? { grid.source }

    /// Shows `source` with the columns as they were left under `viewKey`.
    func show(_ source: GridSource?) {
        grid.source = source
        restoreColumns()
        status.update()
        updateValuePanel()
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
        guard let source, let viewKey, grid.columnWidths.count == source.columns.count else { return }
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
        guard let source, let viewKey, grid.columnWidths.count == source.columns.count else { return }
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
