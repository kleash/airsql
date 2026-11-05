// The data grid (plan §2.5, docs/dev/grid-spec.md): a document view as tall and wide as all its cells, in an
// NSScrollView. Its cells show in tiles that Core Animation moves as it scrolls (GridTiles), each drawn with Core Text
// once, when it comes into view or its cells change. The column header and the row numbers follow its scrolling beside
// it (GridContainerView); one editor overlay edits a cell in place.
import AirSQLCore
import AppKit

/// What a grid's host decides; the grid itself never writes anything. Columns here are the source's indexes. Every
/// method has a default: a read-only grid with no menus.
@MainActor
protocol DataGridViewDelegate: AnyObject {
    /// The selection or the focused cell changed.
    func dataGridSelectionDidChange(_ grid: DataGridView)
    /// Whether the cell can be edited in place (default false: read-only).
    func dataGrid(_ grid: DataGridView, canEditRow row: Int, column: Int) -> Bool
    /// An edit was committed (Return, Tab, a click elsewhere): keep it as a pending change. Nothing is written here.
    func dataGrid(_ grid: DataGridView, didEditRow row: Int, column: Int, text: String)
    /// Editing is starting (Return, a double click, or typing `typed`): the host may edit the cell its own way (a
    /// pick-list, a checkbox, a larger editor) and return true, so the grid opens no text field (default false).
    func dataGrid(_ grid: DataGridView, edit row: Int, column: Int, typed: String?) -> Bool
    /// Why `text` can't be kept in the cell (the editor stays open and says so), nil when it can (default nil).
    func dataGrid(_ grid: DataGridView, check text: String, row: Int, column: Int) -> String?
    /// ↑ or ↓ in the editor: `text` with the part at `offset` stepped by `amount`, and the part to select; nil leaves
    /// the keys to the text field (default nil).
    func dataGrid(_ grid: DataGridView, step text: String, at offset: Int, by amount: Int, row: Int, column: Int)
        -> (text: String, part: NSRange)?
    /// The menu for a right click on the selected cells, a column's header or a row's number (selected first).
    func dataGrid(_ grid: DataGridView, menuFor target: DataGridView.Target) -> NSMenu?
    /// The sort control in a column's header was clicked, or the header double-clicked; with ⌥ or ⇧ `adding` the column to the sort.
    func dataGrid(_ grid: DataGridView, sortBy column: Int, adding: Bool)
    /// Whether the headers show a funnel for filtering a column by its values (default false), and it was clicked at
    /// `rect` of the header.
    func dataGridFiltersColumns(_ grid: DataGridView) -> Bool
    func dataGrid(_ grid: DataGridView, filterValuesOf column: Int, at rect: NSRect)
    /// Moving down reached the last row: the host may load more.
    func dataGridReachedLastRow(_ grid: DataGridView)
    /// A double click on a row's number: Record View.
    func dataGrid(_ grid: DataGridView, openRecord row: Int)
    /// A double click on a cell that can't be edited: show its whole value (default: a beep).
    func dataGridOpenValue(_ grid: DataGridView)
    /// Columns were resized, auto-fitted or moved: remember `columnWidths` and `columnOrder`.
    func dataGridColumnsDidChange(_ grid: DataGridView)
}

extension DataGridViewDelegate {
    func dataGridSelectionDidChange(_ grid: DataGridView) {}
    func dataGridReachedLastRow(_ grid: DataGridView) {}
    func dataGrid(_ grid: DataGridView, canEditRow row: Int, column: Int) -> Bool { false }
    func dataGrid(_ grid: DataGridView, didEditRow row: Int, column: Int, text: String) {}
    func dataGrid(_ grid: DataGridView, edit row: Int, column: Int, typed: String?) -> Bool { false }
    func dataGrid(_ grid: DataGridView, check text: String, row: Int, column: Int) -> String? { nil }
    func dataGrid(_ grid: DataGridView, step text: String, at offset: Int, by amount: Int, row: Int, column: Int)
        -> (text: String, part: NSRange)? { nil }
    func dataGrid(_ grid: DataGridView, menuFor target: DataGridView.Target) -> NSMenu? { nil }
    func dataGrid(_ grid: DataGridView, sortBy column: Int, adding: Bool) {}
    func dataGridFiltersColumns(_ grid: DataGridView) -> Bool { false }
    func dataGrid(_ grid: DataGridView, filterValuesOf column: Int, at rect: NSRect) {}
    func dataGrid(_ grid: DataGridView, openRecord row: Int) {}
    func dataGridOpenValue(_ grid: DataGridView) { NSSound.beep() }
    func dataGridColumnsDidChange(_ grid: DataGridView) {}
}

final class DataGridView: NSView {
    /// A column of the sort, in order: the header shows its arrow and position.
    struct Sort: Equatable {
        var column: Int
        var ascending: Bool
    }

    /// What a right click was on.
    enum Target: Equatable {
        case cells
        case column(Int)
        case row(Int)
    }

    weak var delegate: DataGridViewDelegate?
    /// The view to add to a screen: the scroll view with the cells, the header and the row numbers.
    private(set) var containerView: GridContainerView!
    /// The cells' scroll view (the grid is its document view), inside `containerView`.
    let scrollView = NSScrollView()
    private(set) var header: GridHeaderView!
    private(set) var rowNumbers: GridRowNumberView!
    /// What shows the cells: the grid itself draws nothing.
    private(set) var tiles: GridTiles!

    var source: GridSource? { didSet { sourceDidChange() } }

    /// The selection, in display columns (`columnOrder` maps them to the source's).
    var selection = GridSelection() {
        didSet {
            guard selection != oldValue else { return }
            invalidate(oldValue)
            invalidate(selection)
            delegate?.dataGridSelectionDidChange(self)
            selectionDidChange(from: oldValue)
        }
    }

    var sortOrder: [Sort] = [] { didSet { header.needsDisplay = true } }
    /// The source's columns in display order; hidden columns are left out.
    var columnOrder: [Int] = [] { didSet { layoutColumns() } }
    /// Widths by source column; empty until the first reload measures them.
    var columnWidths: [CGFloat] = [] { didSet { layoutColumns() } }
    var nullText = "NULL" { didSet { needsDisplay = true } }
    /// A colour over a cell's background (a heatmap, equal values), by row and source column; nil for none.
    var cellTint: ((Int, Int) -> NSColor?)? { didSet { needsDisplay = true } }
    /// Grey words after a cell's value (a foreign key's referenced label), by row and source column; nil for none.
    var cellSuffix: ((Int, Int) -> String?)?
    /// How many columns, from the first shown, stay in view while the grid scrolls across (Freeze).
    var frozenColumns = 0 {
        didSet {
            guard frozenColumns != oldValue else { return }
            tiles?.update()
            needsDisplay = true
            header?.needsDisplay = true
        }
    }
    /// Settings ▸ Grid's font family (empty: the system's) and the lines of a value each row shows.
    var fontFamily = "" { didSet { restyle() } }
    var rowLines = 1 { didSet { restyle() } }
    private func restyle() {
        styles = GridStyles(fontSize: fontSize, family: fontFamily, lines: rowLines)
        rowHeight = styles.rowHeight
        reloadData()
    }
    var fontSize: CGFloat = 12 {
        didSet {
            styles = GridStyles(fontSize: fontSize, family: fontFamily, lines: rowLines)
            rowHeight = styles.rowHeight
            // In step with the text, so values measured or sized by hand still fit as they did.
            columnWidths = columnWidths.map { ceil($0 * fontSize / oldValue) }
            reloadData()
        }
    }

    private(set) var styles = GridStyles(fontSize: 12)
    private(set) var rowHeight: CGFloat = 23
    /// Each display column's left edge, and the total width last.
    private(set) var offsets: [CGFloat] = [0]
    /// The editor overlay while a cell is edited.
    var editor: GridEditor?
    var isDragging = false
    /// The columns the filter names, whose headers keep their funnel on show.
    var filteredColumns: Set<Int> = [] { didSet { if filteredColumns != oldValue { header.needsDisplay = true } } }
    var hoveredCell: GridPosition?
    var accessibilityElements = GridAccessibilityElements()
    /// The cells drawn so far: the spike's measure that drawing follows the area shown, not the number of rows.
    var drawnCells = 0
    var rowCount: Int { source?.rowCount ?? 0 }
    var columnCount: Int { columnOrder.count }

    init(source: GridSource? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .content
        scrollView.documentView = self
        tiles = GridTiles(grid: self)
        addSubview(tiles)
        header = GridHeaderView(grid: self)
        rowNumbers = GridRowNumberView(grid: self)
        containerView = GridContainerView(grid: self)
        setAccessibilityIdentifier("grid")
        self.source = source
        sourceDidChange()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // The tiles draw what the grid is asked to draw.
    override var needsDisplay: Bool {
        didSet { if needsDisplay { tiles?.invalidateAll() } }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        tiles?.invalidate(invalidRect)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        tiles?.frame = bounds
        tiles?.update()
    }

    private func sourceDidChange() {
        endEditing(commit: false)
        columnOrder = Array(0..<(source?.columns.count ?? 0))
        columnWidths = []
        frozenColumns = 0
        selection.clear()
        reloadData()
        scrollToStart()
    }

    /// The columns or the row count changed: measures new columns, keeps the selection inside, redraws.
    func reloadData() {
        guard let source else {
            offsets = [0]
            updateSize()
            return
        }
        if columnWidths.count != source.columns.count {
            // New columns: all of them, in the source's order, measured again.
            columnOrder = Array(0..<source.columns.count)
            columnWidths = (0..<source.columns.count).map(measure)
        }
        if !selection.isEmpty { selection.clamp(rows: rowCount, columns: columnCount) }
        accessibilityElements.removeAll()
        header.updateThickness()
        rowNumbers.updateThickness()
        layoutColumns()
        needsDisplay = true
        header.needsDisplay = true
        rowNumbers.needsDisplay = true
    }

    /// Rows that changed or arrived: redraws them where they are on screen.
    func reloadRows(_ rows: Range<Int>) {
        let rect = NSRect(x: 0, y: CGFloat(rows.lowerBound) * rowHeight, width: bounds.width,
                          height: CGFloat(rows.count) * rowHeight).intersection(visibleRect)
        guard !rect.isEmpty else { return }
        setNeedsDisplay(rect)
        rowNumbers.needsDisplay = true
    }

    // MARK: Geometry

    func sourceColumn(_ displayColumn: Int) -> Int { columnOrder[displayColumn] }

    func rowRect(_ row: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(row) * rowHeight, width: offsets.last ?? 0, height: rowHeight)
    }

    func columnRect(_ column: Int) -> NSRect {
        NSRect(x: offsets[column], y: 0, width: offsets[column + 1] - offsets[column], height: CGFloat(rowCount) * rowHeight)
    }

    func cellRect(_ position: GridPosition) -> NSRect {
        NSRect(x: offsets[position.column], y: CGFloat(position.row) * rowHeight,
               width: offsets[position.column + 1] - offsets[position.column], height: rowHeight)
    }

    /// The rows a rect crosses (none for the null rect a dirty rect outside a view intersects to).
    func rows(in rect: NSRect) -> Range<Int> {
        guard !rect.isNull, !rect.isEmpty else { return 0..<0 }
        let first = max(0, Int(floor(rect.minY / rowHeight))), last = min(rowCount, Int(ceil(rect.maxY / rowHeight)))
        return first..<max(first, last)
    }

    /// The display columns a rect crosses (a binary search over the left edges, for wide tables).
    func columns(in rect: NSRect) -> Range<Int> {
        guard columnCount > 0 else { return 0..<0 }
        let first = column(atX: rect.minX) ?? (rect.minX < 0 ? 0 : columnCount)
        let last = column(atX: max(rect.minX, rect.maxX - 0.001)).map { $0 + 1 } ?? (rect.maxX <= 0 ? 0 : columnCount)
        return first..<max(first, last)
    }

    func column(atX x: CGFloat) -> Int? {
        guard columnCount > 0, x >= 0, x < offsets[columnCount] else { return nil }
        var low = 0, high = columnCount - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if offsets[middle] <= x { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The frozen columns' width (0 when none are), and how far right of their own place they show: over the cells,
    /// at the left of what is shown, once the grid has scrolled across.
    var frozenWidth: CGFloat { frozenColumns > 0 ? offsets[min(frozenColumns, columnCount)] : 0 }
    var frozenShift: CGFloat { frozenWidth > 0 ? max(0, visibleRect.minX) : 0 }

    /// Where a cell shows: a frozen column's cells at the left of what is shown.
    func shownRect(_ position: GridPosition) -> NSRect {
        position.column < frozenColumns ? cellRect(position).offsetBy(dx: frozenShift, dy: 0) : cellRect(position)
    }

    func position(at point: NSPoint) -> GridPosition? {
        let overFrozen = point.x >= frozenShift && point.x < frozenShift + frozenWidth
        guard point.y >= 0, let column = column(atX: overFrozen ? point.x - frozenShift : point.x) else { return nil }
        let row = Int(point.y / rowHeight)
        return row < rowCount ? GridPosition(row: row, column: column) : nil
    }

    /// Rows of a page: what fits on screen.
    var rowsPerPage: Int { max(1, Int(visibleRect.height / rowHeight) - 1) }

    /// Scrolls to the first row and column.
    func scrollToStart() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Scrolls just enough to show `rect` (a cell).
    func reveal(_ rect: NSRect) {
        var shown = visibleRect
        let clip = scrollView.contentView, frozen = frozenWidth
        guard !shown.isEmpty else { return }
        var origin = clip.bounds.origin
        // Frozen columns are always in view across; the cells they cover are not.
        shown.origin.x += frozen
        shown.size.width -= frozen
        if frozen == 0 || rect.maxX > frozen {
            if rect.minX < shown.minX { origin.x -= shown.minX - rect.minX } else if rect.maxX > shown.maxX {
                origin.x += min(rect.maxX - shown.maxX, rect.minX - shown.minX)
            }
        }
        if rect.minY < shown.minY { origin.y -= shown.minY - rect.minY } else if rect.maxY > shown.maxY {
            origin.y += rect.maxY - shown.maxY
        }
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func layoutColumns() {
        var x: CGFloat = 0
        offsets = [0]
        for column in columnOrder where column < columnWidths.count {
            x += columnWidths[column]
            offsets.append(x)
        }
        if offsets.count != columnOrder.count + 1 { offsets = Array(repeating: 0, count: columnOrder.count + 1) }
        updateSize()
        needsDisplay = true
        header?.needsDisplay = true
    }

    private func updateSize() {
        let size = NSSize(width: offsets.last ?? 0, height: CGFloat(rowCount) * rowHeight)
        if frame.size != size {
            setFrameSize(size)
        }
    }

    /// A column's width from its header, its first rows and its last: 60 to 230 points, except that a key column is never
    /// cut. A sample, so a new result shows at once.
    private func measure(_ column: Int) -> CGFloat {
        guard let source else { return 100 }
        let info = source.columns[column]
        var width = header.width(for: info)
        let sample = Array(0..<min(source.rowCount, 50)) + (source.rowCount > 50 ? [source.rowCount - 1] : [])
        for row in sample {
            width = max(width, styles.width(of: source.cell(row, column), in: info, nullText: nullText) + 2 * GridStyles.padding)
        }
        return ceil(info.isKey ? max(60, width) : min(230, max(60, width)))
    }

    /// Whether the delegate lets this cell be edited in place.
    func canEdit(_ position: GridPosition) -> Bool {
        position.row < rowCount && position.column < columnCount
            && delegate?.dataGrid(self, canEditRow: position.row, column: columnOrder[position.column]) == true
    }

    /// Hands an edit to the delegate (a pending change) and redraws the cell.
    func commit(_ text: String, at position: GridPosition) {
        guard position.row < rowCount, position.column < columnCount else { return }
        delegate?.dataGrid(self, didEditRow: position.row, column: columnOrder[position.column], text: text)
        setNeedsDisplay(cellRect(position))
    }

    /// Widens a key column whose value didn't fit (drawing found it): key values are never cut.
    func widenKeyColumn(_ column: Int, to width: CGFloat) {
        guard column < columnWidths.count, columnWidths[column] < width else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, column < columnWidths.count, columnWidths[column] < width else { return }
            columnWidths[column] = ceil(width)
        }
    }

    /// Auto-fit (a double click on a header's border): as wide as the column's header and its rows on screen.
    func autoFit(_ displayColumn: Int) {
        guard let source else { return }
        let column = columnOrder[displayColumn], info = source.columns[column]
        var width = header.width(for: info)
        for row in rows(in: visibleRect) {
            width = max(width, styles.width(of: source.cell(row, column), in: info, nullText: nullText) + 2 * GridStyles.padding)
        }
        columnWidths[column] = ceil(max(40, width))
        delegate?.dataGridColumnsDidChange(self)
    }

    /// Redraws what a selection covers on screen (an old selection may reach past columns a reload took away).
    private func invalidate(_ selection: GridSelection) {
        let visible = visibleRect
        guard !visible.isEmpty, columnCount > 0 else { return }
        func column(_ index: Int) -> NSRect { columnRect(min(index, columnCount - 1)) }
        var dirty = NSRect.zero
        for area in selection.areas {
            let rect: NSRect
            switch area {
            case .cells(let rows, let columns):
                rect = column(columns.lowerBound).union(column(columns.upperBound))
                    .intersection(rowRect(rows.lowerBound).union(rowRect(rows.upperBound)))
            case .rows(let rows):
                rect = rowRect(rows.lowerBound).union(rowRect(rows.upperBound))
            case .columns(let columns):
                rect = column(columns.lowerBound).union(column(columns.upperBound))
            case .all:
                rect = visible
            }
            dirty = dirty.union(rect.intersection(visible))
        }
        if let cursor = selection.cursor {
            dirty = dirty.union(column(cursor.column).intersection(rowRect(cursor.row)).intersection(visible))
        }
        if !dirty.isEmpty { setNeedsDisplay(dirty) }
        header.needsDisplay = true
        rowNumbers.needsDisplay = true
    }
}
