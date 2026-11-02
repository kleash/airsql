// The data grid (plan §2.5, docs/dev/grid-spec.md): a document view as tall and wide as all its cells, in an
// NSScrollView, that draws only the cells in the rect AppKit asks for, with Core Text. The spike measured this at about
// 2.5 ms a frame for 1,000,000 × 50 at full screen on a 120 Hz display, so there is no line cache. The column header
// and the row numbers are the scroll view's rulers, so they scroll with it; one editor overlay edits a cell in place.
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
    /// The menu for a right click on the selected cells, a column's header or a row's number (selected first).
    func dataGrid(_ grid: DataGridView, menuFor target: DataGridView.Target) -> NSMenu?
    /// The sort control in a column's header was clicked; with ⌥ `adding` the column to the sort.
    func dataGrid(_ grid: DataGridView, sortBy column: Int, adding: Bool)
    /// A double click on a row's number: Record View.
    func dataGrid(_ grid: DataGridView, openRecord row: Int)
    /// Columns were resized, auto-fitted or moved: remember `columnWidths` and `columnOrder`.
    func dataGridColumnsDidChange(_ grid: DataGridView)
}

extension DataGridViewDelegate {
    func dataGridSelectionDidChange(_ grid: DataGridView) {}
    func dataGrid(_ grid: DataGridView, canEditRow row: Int, column: Int) -> Bool { false }
    func dataGrid(_ grid: DataGridView, didEditRow row: Int, column: Int, text: String) {}
    func dataGrid(_ grid: DataGridView, menuFor target: DataGridView.Target) -> NSMenu? { nil }
    func dataGrid(_ grid: DataGridView, sortBy column: Int, adding: Bool) {}
    func dataGrid(_ grid: DataGridView, openRecord row: Int) {}
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
    /// The scroll view to add to a screen: the grid is its document view, the header and row numbers its rulers.
    let scrollView: NSScrollView = GridScrollView()
    private(set) var header: GridHeaderView!
    private(set) var rowNumbers: GridRowNumberView!

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
    var fontSize: CGFloat = 12 {
        didSet {
            styles = GridStyles(fontSize: fontSize)
            rowHeight = styles.rowHeight
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
        header = GridHeaderView(grid: self)
        rowNumbers = GridRowNumberView(grid: self)
        scrollView.hasHorizontalRuler = true
        scrollView.hasVerticalRuler = true
        scrollView.horizontalRulerView = header
        scrollView.verticalRulerView = rowNumbers
        scrollView.rulersVisible = true
        setAccessibilityIdentifier("grid")
        self.source = source
        sourceDidChange()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func sourceDidChange() {
        endEditing(commit: false)
        columnOrder = Array(0..<(source?.columns.count ?? 0))
        columnWidths = []
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
        if columnWidths.count != source.columns.count { columnWidths = (0..<source.columns.count).map(measure) }
        columnOrder = columnOrder.filter { $0 < source.columns.count }
        if !selection.isEmpty { selection.clamp(rows: rowCount, columns: columnCount) }
        accessibilityElements.removeAll()
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

    /// The rows a rect crosses.
    func rows(in rect: NSRect) -> Range<Int> {
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

    func position(at point: NSPoint) -> GridPosition? {
        guard point.y >= 0, let column = column(atX: point.x) else { return nil }
        let row = Int(point.y / rowHeight)
        return row < rowCount ? GridPosition(row: row, column: column) : nil
    }

    /// The part of the grid on screen that the header and the row numbers leave uncovered (since macOS 26 the scroll
    /// view lays its rulers over the cells, with the clip view's insets making room at the start).
    var shownRect: NSRect {
        let clip = scrollView.contentView, insets = clip.contentInsets, area = clip.bounds
        return NSRect(x: area.minX + insets.left, y: area.minY + insets.top, width: area.width - insets.left - insets.right,
                      height: area.height - insets.top - insets.bottom).intersection(bounds)
    }

    /// Rows of a page: what fits on screen.
    var rowsPerPage: Int { max(1, Int(shownRect.height / rowHeight) - 1) }

    /// Scrolls to the first row and column, clear of the header and row numbers.
    func scrollToStart() {
        scrollView.tile()
        let insets = scrollView.contentView.contentInsets
        scrollView.contentView.scroll(to: NSPoint(x: -insets.left, y: -insets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Scrolls just enough to show `rect` (a cell) clear of the header and row numbers.
    func reveal(_ rect: NSRect) {
        let shown = shownRect, clip = scrollView.contentView
        guard !shown.isEmpty else { return }
        var origin = clip.bounds.origin
        if rect.minX < shown.minX { origin.x -= shown.minX - rect.minX } else if rect.maxX > shown.maxX {
            origin.x += min(rect.maxX - shown.maxX, rect.minX - shown.minX)
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
        if frame.size != size { setFrameSize(size) }
    }

    /// A column's width from its header and its first rows: 60 to 230 points, except that a key column is never cut.
    private func measure(_ column: Int) -> CGFloat {
        guard let source else { return 100 }
        let info = source.columns[column]
        var width = header.width(for: info)
        let sample = Array(0..<min(source.rowCount, 200)) + (source.rowCount > 200 ? [source.rowCount - 1] : [])
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

    /// Redraws what a selection covers on screen.
    private func invalidate(_ selection: GridSelection) {
        let visible = visibleRect
        guard !visible.isEmpty, columnCount > 0 else { return }
        var dirty = NSRect.zero
        for area in selection.areas {
            let rect: NSRect
            switch area {
            case .cells(let rows, let columns):
                rect = cellRect(GridPosition(row: rows.lowerBound, column: columns.lowerBound))
                    .union(cellRect(GridPosition(row: rows.upperBound, column: columns.upperBound)))
            case .rows(let rows):
                rect = rowRect(rows.lowerBound).union(rowRect(rows.upperBound))
            case .columns(let columns):
                rect = columnRect(columns.lowerBound).union(columnRect(columns.upperBound))
            case .all:
                rect = visible
            }
            dirty = dirty.union(rect.intersection(visible))
        }
        if let cursor = selection.cursor, cursor.row < rowCount, cursor.column < columnCount {
            dirty = dirty.union(cellRect(cursor).intersection(visible))
        }
        if !dirty.isEmpty { setNeedsDisplay(dirty) }
        header.needsDisplay = true
        rowNumbers.needsDisplay = true
    }
}

/// The grid's scroll view: when the room for the rulers changes (the row numbers widen as rows arrive, or the view
/// gets its size), a grid shown from its start stays at its start rather than slipping under the rulers.
private final class GridScrollView: NSScrollView {
    override func tile() {
        let clip = contentView, before = clip.contentInsets, origin = clip.bounds.origin
        let atStart = origin.x <= 0.5 - before.left && origin.y <= 0.5 - before.top
        super.tile()
        let after = clip.contentInsets
        guard atStart, after.left != before.left || after.top != before.top else { return }
        clip.scroll(to: NSPoint(x: -after.left, y: -after.top))
        reflectScrolledClipView(clip)
    }
}
