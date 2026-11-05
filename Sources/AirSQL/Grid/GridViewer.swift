import AirSQLCore
import AppKit

/// A data grid with what helps read it (grid-spec §3, §6): the status bar's position, selection size and aggregate,
/// the value panel, Record View, Transpose, Display As, heatmaps, View As and charts, Column Summary, copying in every
/// format, and columns that open as they were left (widths, order, hidden ones: `TableViewSettings`, per table or per
/// query). The screen that shows it (the table tab, a console result) is its `host`: the grid's edits, sorting and the
/// host's menu items stay the host's, in the host's own rows and columns even while Transpose or Record View is on.
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
    /// The table the rows come from, for the SQL copy formats (INSERT, UPDATE…).
    var copyTable: (database: String?, name: String) = (nil, "table")
    /// The session's NO_BACKSLASH_ESCAPES, for the strings of what's copied as SQL.
    var noBackslashEscapes = false
    /// ⌘C with nothing selected copies every row (a console result) rather than nothing.
    var copiesEverything = false
    /// The host's own highlight (find matches), by the host's row and column: tinted over the cells.
    var highlight: ((_ row: Int, _ column: Int) -> Bool)? { didSet { updateTint() } }
    /// Filters the host's rows by a column's value (Column Summary's values); nil: the values can't be clicked.
    var filterByValue: ((_ column: Int, _ value: String?) -> Void)?
    /// Keeps a value edited in the value panel as the host's cell's pending value (nil: the panel only shows values).
    var keepValue: ((_ row: Int, _ column: Int, _ text: String) -> Void)?
    /// Whether the host's cell holds only the start of its value, and reads the host's `rows` whole in `columns` before
    /// what must have them (nil: a host's cells are always whole).
    var isCut: ((_ row: Int, _ column: Int) -> Bool)?
    var readWhole: ((_ rows: [Int], _ columns: [Int], _ then: @escaping () -> Void) -> Void)?
    /// Columns were hidden or shown.
    var hiddenColumnsDidChange: (() -> Void)?
    /// Why the host's cell can't be edited, said when it is double-clicked; nil: nothing to say.
    var whyReadOnly: ((_ row: Int, _ column: Int) -> String?)?
    /// Where the columns are kept; nil: nowhere.
    var viewKey: ViewKey?
    private var settings = TableViewSettings()
    /// The grid (or what View As shows) on the left, the value panel on the right when it is open.
    private let split = NSSplitView()
    /// The record bar (Record View only) over the body, which holds the grid or what View As shows.
    private let content = NSStackView()
    let body = NSView()
    private(set) var valuePanel: GridValuePanel?
    /// The width it last had, in any tab.
    private static var valuePanelWidth: CGFloat = 320
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
        previous.target = self
        next.target = self
        let close = GridStatusView.link("Back to the Grid", id: "record.close", tip: "Show the rows as a grid again", action: nil)
        close.target = self
        close.action = #selector(backToGrid(_:))
        recordBar.setViews([previous, recordLabel, next], in: .leading)
        recordBar.setViews([close], in: .trailing)
        recordBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        recordBar.setHuggingPriority(.defaultHigh, for: .vertical)
        grid.scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(stretchRecordValues),
                                               name: NSView.frameDidChangeNotification, object: grid.scrollView)
        let barGround = SurfaceView(.bar)
        recordBar.addSubview(barGround, positioned: .below, relativeTo: nil)
        barGround.pin(to: recordBar)
        recordBar.isHidden = true
        for part in [recordBar, body] { part.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        status.viewer = self
        status.update()
        NotificationCenter.default.addObserver(self, selector: #selector(gridSettingsChanged(_:)), name: .gridSettingsDidChange,
                                               object: nil)
        if let settings = (NSApp.delegate as? AppDelegate)?.model?.data.settings { applyLook(settings) }
    }

    /// Settings ▸ Grid's font and date format.
    private func applyLook(_ settings: AppSettings) {
        if grid.fontFamily != settings.gridFontFamily { grid.fontFamily = settings.gridFontFamily }
        GridDisplay.pattern = settings.gridDatePattern.isEmpty ? AppSettings().gridDatePattern : settings.gridDatePattern
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Record View's values get the width the names leave, when it opens (once the grid is laid out) and as it grows.
    @objc private func stretchRecordValues() {
        guard record != nil, grid.columnWidths.count == 2 else { return }
        let room = floor(grid.scrollView.contentSize.width - grid.columnWidths[0])
        if room > grid.columnWidths[1] { grid.columnWidths[1] = room }
    }

    /// Settings ▸ Grid changed: its NULL text, and its text size unless this grid is zoomed (⌘+ or ⌘−).
    @objc private func gridSettingsChanged(_ notification: Notification) {
        guard let settings = (notification.object as? AppModel)?.data.settings,
              let old = notification.userInfo?["old"] as? AppSettings else { return }
        grid.nullText = settings.nullText
        applyLook(settings)
        if grid.fontSize == CGFloat(old.gridFontSize) { grid.fontSize = CGFloat(settings.gridFontSize) }
    }

    /// The host's rows; the grid shows them, or them transposed.
    private(set) var source: GridSource?
    /// Transpose (⌥⌘T) or Record View (⌥⌘R, the row shown) is on: the grid shows a `TransposedSource`.
    private(set) var transposed = false
    private(set) var record: Int?
    /// The grid's columns and sort as they were before Transpose or Record View, to put back after.
    private var layout: (order: [Int], widths: [CGFloat], sort: [DataGridView.Sort], frozen: Int)?
    /// The host's sort, by its columns: the grid's, or the one kept aside while Transpose or Record View is on.
    var sortOrder: [DataGridView.Sort] { layout?.sort ?? grid.sortOrder }
    /// Display As and its Time Zone, by the source's column.
    private(set) var displays: [Int: GridDisplay] = [:]
    private(set) var zones: [Int: GridZone] = [:]
    /// Heatmaps by the source's column, and whether equal values are tinted (`GridViewer+Colours`).
    var heat: [Int: HeatScale] = [:]
    var highlightsEqual = false
    /// Where Column Summary is worked out for a table (on the server, by its tab); nil: from the rows in memory.
    var serverSummary: ((_ column: Int, _ done: @escaping (Result<ColumnSummary, Error>) -> Void) -> Void)?
    /// The summary shown last (tests read it).
    private(set) weak var summaryShown: GridSummaryView?
    /// View As or Chart (`GridViewer+Views`): what the body shows, and the view shown in place of the grid.
    var presentation = Presentation.table
    /// The host's row of actions, kept up to date with the status bar.
    weak var toolbar: GridToolbar?
    /// The host's find bar, for Esc.
    weak var findBar: TableFindBar?
    /// Called when View As changes what the body shows.
    var didPresent: (() -> Void)?
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
            zones = Dictionary(source.columns.indices.compactMap { index in
                settings.displayZones[source.columns[index].name].flatMap(GridZone.init(rawValue:)).map { (index, $0) }
            }, uniquingKeysWith: { first, _ in first })
        } else {
            displays = [:]
            zones = [:]
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
        displays.isEmpty && zones.isEmpty ? source : DisplaySource(source, displays: displays, zones: zones, bytes: { [weak source] row, column in
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
        displayChanged()
    }

    /// Display As ▸ Time Zone ▸ (the item's tag is the `GridZone`'s index): the selected DATETIME and TIMESTAMP columns.
    @objc func displayTimeZone(_ sender: Any?) {
        guard let source, let item = sender as? NSMenuItem, GridZone.allCases.indices.contains(item.tag) else { return }
        if transposed || record != nil { transposeGrid(nil) }
        let chosen = GridZone.allCases[item.tag]
        for column in focusedColumns where GridZone.applies(to: source.columns[column]) {
            zones[column] = chosen == .stored ? nil : chosen
        }
        displayChanged()
    }

    private func displayChanged() {
        guard let source else { return }
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

    /// Display As ▸, as in the Data menu: the ways the focused column's kind can be shown are on, in groups (numbers,
    /// dates, bytes), with Decimal Places and Time Zone in submenus.
    static func displayMenu() -> NSMenuItem {
        func item(_ display: GridDisplay) -> NSMenuItem {
            let item = Commands.displayAs.item()
            item.title = display.title
            item.tag = GridDisplay.allCases.firstIndex(of: display) ?? 0
            return item
        }
        let decimals = MainMenu.submenu("Decimal Places", [GridDisplay.decimals0, .decimals1, .decimals2, .decimals3, .decimals4].map(item))
        let zones = MainMenu.submenu("Time Zone", GridZone.allCases.enumerated().map { index, zone in
            let item = Commands.displayZone.item()
            item.title = zone.title
            item.tag = index
            return item
        })
        return MainMenu.submenu("Display As", [item(.standard), .separator(), item(.grouped), decimals, item(.unixTime), item(.unixMillis),
                                               .separator(), item(.dateShort), item(.dateMedium), item(.dateLong), item(.datePattern), zones, .separator(),
                                               item(.detected), item(.uuid), item(.uuidSwapped), item(.hex), item(.text), item(.wkt)])
    }

    /// The host's rows or columns changed (a page arrived): shows them again.
    func reloadData() {
        // Record View's row is gone (a filter or an Apply left fewer rows): back to the grid rather than read past the end.
        if let record, record >= source?.rowCount ?? 0 { backToGrid(nil) }
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
                grid.sortOrder = layout.sort
                grid.frozenColumns = layout.frozen
            }
            layout = nil
            if let focus, let column = grid.columnOrder.firstIndex(of: focus.column) { focusCell(GridPosition(row: focus.row, column: column)) }
        } else {
            let cursor = grid.selection.cursor
            transposed = true
            layout = (grid.columnOrder, grid.columnWidths, grid.sortOrder, grid.frozenColumns)
            grid.sortOrder = []
            grid.frozenColumns = 0
            grid.source = TransposedSource(displayed ?? source, order: grid.columnOrder)
            if let cursor { focusCell(GridPosition(row: cursor.column, column: cursor.row + 1)) }
        }
        updateRecordBar()
        status.update()
        updateValuePanel()
    }

    /// Record View (⌥⌘R): the focused row as a form, one line per column; Previous and Next show the rows around it.
    @objc func showRecordView(_ sender: Any?) {
        if presentation != .table { present(.table) }
        if record != nil { return transposeGrid(nil) }
        guard let source, source.rowCount > 0 else { return NSSound.beep() }
        if transposed { transposeGrid(nil) }
        showRecord(grid.selection.cursor?.row ?? 0, field: grid.selection.cursor?.column ?? 0)
    }

    private func showRecord(_ row: Int, field: Int) {
        guard let source else { return }
        if layout == nil {
            layout = (grid.columnOrder, grid.columnWidths, grid.sortOrder, grid.frozenColumns)
            grid.sortOrder = []
            grid.frozenColumns = 0
        }
        let order = layout?.order ?? grid.columnOrder
        record = row
        grid.source = TransposedSource(displayed ?? source, order: order, rows: [row])
        DispatchQueue.main.async { [weak self] in self?.stretchRecordValues() }
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
            Self.valuePanelWidth = valuePanel.frame.width
            valuePanel.removeFromSuperview()
            self.valuePanel = nil
        } else {
            let panel = GridValuePanel()
            split.addArrangedSubview(panel)
            split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
            split.layoutSubtreeIfNeeded()
            split.setPosition(max(240, split.bounds.width - Self.valuePanelWidth), ofDividerAt: 0)
            valuePanel = panel
            updateValuePanel()
        }
        status.update()
    }

    /// The panel shows the focused cell, editable where the host lets it be edited (`keepValue`); text being edited
    /// there stays until it is kept or put back.
    private func updateValuePanel() {
        guard let valuePanel, !valuePanel.edited else { return }
        // The host's cell, also in Transpose and Record View (the names down their left show nothing).
        guard let source, let (row, column) = focusedCell else {
            valuePanel.keep = nil
            return valuePanel.show(column: nil, value: nil, bytes: nil)
        }
        let cut = isCut?(row, column) == true
        if !cut, let keepValue, host?.dataGrid(grid, canEditRow: row, column: column) == true {
            valuePanel.keep = { [weak self] text in
                guard let self else { return nil }
                if let refusal = host?.dataGrid(grid, check: text, row: row, column: column) { return refusal }
                keepValue(row, column, text)
                return nil
            }
        } else {
            valuePanel.keep = nil
        }
        var placeholder: String?
        if case .placeholder(let words) = source.cell(row, column) { placeholder = words }
        valuePanel.show(column: source.columns[column], value: placeholder == nil ? source.value(row, column) : nil,
                        bytes: (source as? GridBytes)?.bytes(row, column), placeholder: placeholder,
                        loadFull: cut ? { [weak self] in self?.readWhole?([row], [column]) {} } : nil)
    }

    /// Edits the focused cell's value in the value panel, opening it first (a long or multi-line value).
    func editInValuePanel() {
        if valuePanel == nil { toggleValuePanel(nil) }
        valuePanel?.beginEditing()
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
        grid.frozenColumns = min(settings.frozenColumns, grid.columnCount)
    }

    /// Keeps the columns' order, widths and hidden ones under `viewKey`.
    func saveColumns() {
        guard let source, let viewKey, !transposed, record == nil, grid.columnWidths.count == source.columns.count else { return }
        // Read again first: the host keeps its own part there (a table's filter and sort).
        settings = TableViewSettingsStore.shared.settings(connection: viewKey.connection, database: viewKey.database,
                                                          table: viewKey.table)
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
        settings.frozenColumns = grid.frozenColumns
        settings.displayTypes = Dictionary(displays.map { (names[$0.key], $0.value.rawValue) }, uniquingKeysWith: { first, _ in first })
        settings.displayZones = Dictionary(zones.map { (names[$0.key], $0.value.rawValue) }, uniquingKeysWith: { first, _ in first })
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
        hiddenColumnsDidChange?()
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
        if let filterByValue {
            // A value clicked narrows the rows to it.
            content.choose = { [weak popover] value in
                popover?.close()
                filterByValue(column, value)
            }
        }
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

    /// Freeze: keeps the columns up to the focused one in view while the grid scrolls across; on the last frozen column,
    /// unfreezes them.
    @objc func freezeColumns(_ sender: Any?) {
        guard let column = grid.selection.cursor?.column, !transposed, record == nil else { return NSSound.beep() }
        grid.frozenColumns = grid.frozenColumns == column + 1 ? 0 : column + 1
        saveColumns()
    }

    /// Hide Other Columns: only the selected columns, or the focused cell's, stay.
    @objc func hideOtherColumns(_ sender: Any?) {
        if transposed || record != nil { transposeGrid(nil) }
        let kept = Set(focusedColumns)
        setHidden(true, columns: grid.columnOrder.filter { !kept.contains($0) })
    }

    /// Puts the columns back as they come: every one shown, in order, at its natural width, as stored.
    func resetColumns() {
        guard let source else { return }
        backToGrid(nil)
        if presentation != .table { present(.table) }
        displays = [:]
        zones = [:]
        heat = [:]
        updateTint()
        displayed = display(source)
        grid.frozenColumns = 0
        grid.source = displayed
        saveColumns()
        status.update()
        hiddenColumnsDidChange?()
    }

    /// Open URL: the focused cell's web address in the browser.
    @objc func openCellURL(_ sender: Any?) {
        guard let url = focusedURL else { return NSSound.beep() }
        NSWorkspace.shared.open(url)
    }

    private var focusedURL: URL? {
        guard let cell = focusedCell, let text = source?.value(cell.row, cell.column) else { return nil }
        return GridLink.url(text)
    }

    /// Compare Cells: two selected cells' values, line by line, in a tab. Cut values read whole first.
    @objc func compareCells(_ sender: Any?) {
        let cells = selectedCells(limit: 3)
        guard cells.count == 2, source != nil, let main = window?.windowController as? MainWindowController else { return NSSound.beep() }
        let show = { [self] in
            guard let source else { return }
            let (first, second) = (source.value(cells[0].row, cells[0].column), source.value(cells[1].row, cells[1].column))
            let name = { (cell: (row: Int, column: Int)) in "\(source.columns[cell.column].name), row \((cell.row + 1).formatted())" }
            main.open(TextContent(title: "Compare Cells", caption: "− \(name(cells[0]))   + \(name(cells[1]))",
                                  text: GridLink.lineDifference(first ?? grid.nullText, second ?? grid.nullText)),
                      title: "Compare Cells", connection: nil)
        }
        if let readWhole { readWhole(cells.map(\.row), cells.map(\.column), show) } else { show() }
    }

    /// Hide Column: the selected columns, or the focused cell's.
    @objc func hideColumn(_ sender: Any?) {
        if transposed || record != nil { transposeGrid(nil) }
        setHidden(true, columns: focusedColumns)
    }

    // MARK: Copy (grid-spec §6): one way for every grid, in the formats of GridCopy

    /// What copying reads: the host's rows (their stored values, whatever Display As shows), or the cells Transpose and
    /// Record View show.
    private var copied: GridSource? { transposed || record != nil ? grid.source : source }

    @objc func copy(_ sender: Any?) { copySelection(GridCopy.format, headers: false) }
    @objc func copyWithHeaders(_ sender: Any?) { copySelection(GridCopy.format, headers: true) }

    @objc func copyAs(_ sender: Any?) {
        guard let format = GridCopy.format(of: sender) else { return }
        GridCopy.format = format
        copySelection(format, headers: false)
    }

    @objc func copyColumnNames(_ sender: Any?) {
        guard let copied else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(GridCopy.covered(grid).columns.map { copied.columns[$0].name }.joined(separator: "\t"),
                                       forType: .string)
    }

    private func copySelection(_ format: CopyFormat, headers: Bool) {
        if copiesEverything, grid.selection.isEmpty, grid.selection.cursor == nil { grid.selectAll(nil) }
        guard copied != nil else { return NSSound.beep() }
        let copy = { [self] in
            guard let copied else { return }
            GridCopy.copy(grid, source: copied, format: format, headers: headers, database: copyTable.database, table: copyTable.name,
                          noBackslashEscapes: noBackslashEscapes)
        }
        if let readWhole { readWhole(selectedRows(), shownColumns, copy) } else { copy() }
    }

    // MARK: The host's cells

    /// The host's cell a cell of the grid shows (row, source column): itself, or, in Transpose and Record View, the one
    /// it stands for (nil for the column names down the left).
    func hostCell(_ row: Int, _ column: Int) -> (row: Int, column: Int)? {
        guard let shown = grid.source as? TransposedSource else { return (row, column) }
        return shown.base(row, column)
    }

    /// The host's cell under the cursor.
    var focusedCell: (row: Int, column: Int)? {
        guard let cursor = grid.selection.cursor, cursor.row < grid.rowCount, cursor.column < grid.columnCount else { return nil }
        return hostCell(cursor.row, grid.sourceColumn(cursor.column))
    }

    /// The host's column of the focused cell, or of the first selected header (not while the rows are on their side).
    var focusedColumn: Int? {
        if let cell = focusedCell { return cell.column }
        guard !transposed, record == nil else { return nil }
        for case .columns(let columns) in grid.selection.areas where columns.lowerBound < grid.columnCount {
            return grid.sourceColumn(columns.lowerBound)
        }
        return nil
    }

    /// The host's cells the selection covers (the focused one when nothing is selected), for its commands: at most
    /// `limit`.
    func selectedCells(limit: Int = .max) -> [(row: Int, column: Int)] {
        let (rows, columns) = GridCopy.covered(grid)
        let selection = grid.selection
        var cells: [(row: Int, column: Int)] = []
        for row in rows {
            for column in columns {
                guard let display = grid.columnOrder.firstIndex(of: column),
                      selection.isEmpty || selection.contains(GridPosition(row: row, column: display)),
                      let cell = hostCell(row, column) else { continue }
                cells.append(cell)
                if cells.count == limit { return cells }
            }
        }
        return cells
    }

    /// The host's columns in the order shown, hidden ones left out (in Transpose and Record View: as they were before).
    var shownColumns: [Int] { transposed || record != nil ? layout?.order ?? [] : grid.columnOrder }

    /// The host's rows the selection covers.
    func selectedRows() -> [Int] {
        guard grid.source is TransposedSource else { return GridCopy.covered(grid).rows }
        return Array(Set(selectedCells().map(\.row))).sorted()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(copyWithHeaders(_:)), #selector(copyAs(_:)), #selector(copyColumnNames(_:)):
            if item.action == #selector(copyAs(_:)) { item.state = GridCopy.format(of: item) == GridCopy.format ? .on : .off }
            let enabled = grid.rowCount > 0 && (copiesEverything || !GridCopy.covered(grid).rows.isEmpty)
            item.explain(enabled: enabled, reason: grid.rowCount == 0 ? "There are no rows to copy" : "Select cells first")
            return enabled
        case #selector(copySummary(_:)):
            item.explain(enabled: status.aggregate != nil, reason: "Select some cells first")
            return status.aggregate != nil
        case #selector(goToRow(_:)):
            item.explain(enabled: grid.rowCount > 0, reason: "There are no rows to go to")
            return grid.rowCount > 0
        case #selector(showColumnSummary(_:)):
            item.explain(enabled: !focusedColumns.isEmpty, reason: "Select a column first")
            return !focusedColumns.isEmpty
        case #selector(showColumnList(_:)):
            item.explain(enabled: source != nil, reason: "Wait until the rows have loaded")
            return source != nil
        case #selector(viewAs(_:)):
            item.state = item.tag == presentation.rawValue ? .on : .off
            item.explain(enabled: source != nil, reason: "Wait until the rows have loaded")
            return source != nil
        case #selector(showChart(_:)):
            item.state = presentation == .chart ? .on : .off
            item.explain(enabled: source != nil, reason: "Wait until the rows have loaded")
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
            item.explain(enabled: source != nil, reason: "Wait until the rows have loaded")
            return source != nil
        case #selector(displayAs(_:)):
            let display = GridDisplay.allCases.indices.contains(item.tag) ? GridDisplay.allCases[item.tag] : .standard
            let columns = focusedColumns.compactMap { source?.columns[$0] }
            let enabled = !columns.isEmpty && columns.allSatisfy { GridDisplay.choices(for: $0).contains(display) }
            item.state = enabled && focusedColumns.allSatisfy({ (displays[$0] ?? .standard) == display }) ? .on : .off
            item.explain(enabled: enabled, reason: columns.isEmpty ? "Select a column first" : "Not for this column's type")
            return enabled
        case #selector(displayTimeZone(_:)):
            let zone = GridZone.allCases.indices.contains(item.tag) ? GridZone.allCases[item.tag] : .stored
            let columns = focusedColumns.compactMap { source?.columns[$0] }
            let enabled = !columns.isEmpty && columns.allSatisfy(GridZone.applies)
            item.state = enabled && focusedColumns.allSatisfy({ (zones[$0] ?? .stored) == zone }) ? .on : .off
            item.explain(enabled: enabled, reason: columns.isEmpty ? "Select a column first" : "Only for DATETIME and TIMESTAMP columns")
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
        case #selector(freezeColumns(_:)):
            let column = grid.selection.cursor?.column, enabled = column != nil && !transposed && record == nil
            item.state = column.map { $0 < grid.frozenColumns } == true ? .on : .off
            item.explain(enabled: enabled, reason: column == nil ? "Select a column first" : "Not while the rows are on their side")
            return enabled
        case #selector(hideOtherColumns(_:)):
            let enabled = !focusedColumns.isEmpty && Set(focusedColumns).count < grid.columnCount
            item.explain(enabled: enabled, reason: focusedColumns.isEmpty ? "Select a column first" : "No other columns are shown")
            return enabled
        case #selector(openCellURL(_:)):
            item.explain(enabled: focusedURL != nil, reason: "Select a cell holding a web address first")
            return focusedURL != nil
        case #selector(compareCells(_:)):
            let enabled = selectedCells(limit: 3).count == 2
            item.explain(enabled: enabled, reason: "Select two cells first")
            return enabled
        case #selector(hideColumn(_:)):
            let enabled = grid.columnCount > 1 && grid.selection.cursor != nil
            item.explain(enabled: enabled, reason: grid.columnCount > 1 ? "Select a column first" : "One column stays shown")
            return enabled
        default: return true
        }
    }

    // MARK: DataGridViewDelegate

    func dataGridReachedLastRow(_ grid: DataGridView) {
        if !(grid.source is TransposedSource) { host?.dataGridReachedLastRow(grid) }
    }

    func dataGridSelectionDidChange(_ grid: DataGridView) {
        status.update()
        updateValuePanel()
        if highlightsEqual { grid.needsDisplay = true }
        host?.dataGridSelectionDidChange(grid)
    }

    /// Edits go to the host in its own row and column: in Transpose and Record View, those of the cell edited.
    func dataGrid(_ grid: DataGridView, canEditRow row: Int, column: Int) -> Bool {
        guard let cell = hostCell(row, column) else { return false }
        return host?.dataGrid(grid, canEditRow: cell.row, column: cell.column) ?? false
    }

    func dataGrid(_ grid: DataGridView, didEditRow row: Int, column: Int, text: String) {
        guard let cell = hostCell(row, column) else { return }
        host?.dataGrid(grid, didEditRow: cell.row, column: cell.column, text: text)
        status.update()
    }

    func dataGrid(_ grid: DataGridView, edit row: Int, column: Int, typed: String?) -> Bool {
        guard let cell = hostCell(row, column) else { return false }
        return host?.dataGrid(grid, edit: cell.row, column: cell.column, typed: typed) ?? false
    }

    func dataGrid(_ grid: DataGridView, check text: String, row: Int, column: Int) -> String? {
        guard let cell = hostCell(row, column) else { return nil }
        return host?.dataGrid(grid, check: text, row: cell.row, column: cell.column)
    }

    func dataGrid(_ grid: DataGridView, step text: String, at offset: Int, by amount: Int, row: Int, column: Int)
        -> (text: String, part: NSRange)? {
        guard let cell = hostCell(row, column) else { return nil }
        return host?.dataGrid(grid, step: text, at: offset, by: amount, row: cell.row, column: cell.column)
    }

    /// Copy first, then the host's items, then the viewer's for what was clicked.
    func dataGrid(_ grid: DataGridView, menuFor target: DataGridView.Target) -> NSMenu? {
        let menu = NSMenu(title: "Grid")
        if case .column = target {
            menu.add([Commands.copyColumnName])
        } else {
            menu.add([Commands.copy, Commands.copyWithHeaders])
            menu.addItem(GridCopy.copyAsItem())
        }
        for item in menu.items + (menu.items.last?.submenu?.items ?? []) where item.action != nil { item.target = self }
        if let items = host?.dataGrid(grid, menuFor: target)?.items, !items.isEmpty {
            menu.addItem(.separator())
            for item in items {
                item.menu?.removeItem(item)
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        switch target {
        case .cells: menu.add([Commands.valuePanel, Commands.recordView, Commands.transpose, Commands.columnSummary, Commands.chart, nil,
                               Commands.openURL, Commands.compareCells])
        case .row: menu.add([Commands.recordView, Commands.transpose, Commands.valuePanel])
        case .column: menu.add([Commands.columnSummary, Commands.hideColumn, Commands.hideOtherColumns, Commands.freeze, Commands.columnList, Commands.heatmap,
                                Commands.chart])
        }
        if !transposed, record == nil { menu.addItem(Self.displayMenu()) }
        return menu
    }

    /// Esc steps back: it closes the find bar, leaves Record View and Transpose, then narrows the selection to the focused cell.
    override func cancelOperation(_ sender: Any?) {
        if let findBar, !findBar.isHidden {
            findBar.close(sender)
        } else if transposed || record != nil {
            backToGrid(sender)
        } else if let cursor = grid.selection.cursor {
            grid.selection.select(cursor)
        }
    }

    /// Sorting is the host's, by its own columns: not while the grid shows them on their side.
    func dataGrid(_ grid: DataGridView, sortBy column: Int, adding: Bool) {
        guard !transposed, record == nil else { return NSSound.beep() }
        host?.dataGrid(grid, sortBy: column, adding: adding)
    }

    func dataGridFiltersColumns(_ grid: DataGridView) -> Bool { !transposed && record == nil && host?.dataGridFiltersColumns(grid) == true }

    func dataGrid(_ grid: DataGridView, filterValuesOf column: Int, at rect: NSRect) {
        host?.dataGrid(grid, filterValuesOf: column, at: rect)
    }

    /// A double click on a row's number: Record View of that row.
    func dataGrid(_ grid: DataGridView, openRecord row: Int) {
        guard !transposed, record == nil else { return }
        grid.selection.select(GridPosition(row: row, column: grid.selection.cursor?.column ?? 0))
        showRecordView(nil)
    }

    /// A double click on a cell that can't be edited opens the value panel, and says why when the host knows.
    func dataGridOpenValue(_ grid: DataGridView) {
        if valuePanel == nil { toggleValuePanel(nil) }
        guard let cell = focusedCell, let cursor = grid.selection.cursor, let reason = whyReadOnly?(cell.row, cell.column) else { return }
        let text = label("Can't edit this cell: " + reason + ".", font: .systemFont(ofSize: 12), wraps: true)
        text.preferredMaxLayoutWidth = 320
        let stack = NSStackView(views: [text])
        stack.setAccessibilityIdentifier("grid.readOnlyReason")
        popover(around: stack, behavior: .transient).show(relativeTo: grid.cellRect(cursor), of: grid, preferredEdge: .maxY)
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

extension ReorderedSource: GridBytes {
    func bytes(_ row: Int, _ column: Int) -> [UInt8]? { (base as? GridBytes)?.bytes(baseRow(row), column) }
}

extension ResultSetSource: GridBytes {
    func bytes(_ row: Int, _ column: Int) -> [UInt8]? { store.bytes(row, column) }
}

/// A sheet asking for one line of text (Go to Row); `reply` gets it, trimmed, when `action` is pressed.
@MainActor
func askText(_ title: String, message: String, placeholder: String, value: String = "", action: String, id: String,
             on window: NSWindow, reply: @escaping (String) -> Void) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    let field = textField(value, placeholder: placeholder, id: id, tip: message)
    // NSAlert places its accessory by frame.
    field.translatesAutoresizingMaskIntoConstraints = true
    field.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
    alert.accessoryView = field
    alert.addButton(withTitle: action).toolTip = message
    alert.addButton(withTitle: "Cancel").toolTip = "Close without doing anything"
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { response in
        guard response == .alertFirstButtonReturn else { return }
        reply(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
