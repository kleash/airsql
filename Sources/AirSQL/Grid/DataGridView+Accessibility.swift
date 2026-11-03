import AirSQLCore
import AppKit

// The grid as an accessibility table (plan §2.5, R15): total row and column counts, row and cell elements made only for
// what is on screen (and kept while they are), focus and selection notifications, and editing through a cell's value.
// VoiceOver and the agent snapshot read and act on it.
extension DataGridView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .table }
    override func accessibilityLabel() -> String? { super.accessibilityLabel() ?? "Data" }
    override func accessibilityRowCount() -> Int { rowCount }
    override func accessibilityColumnCount() -> Int { columnCount }

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = accessibilityVisibleRows() ?? []
        if let editor { children.append(editor) }
        return children
    }

    override func accessibilityRows() -> [Any]? { accessibilityVisibleRows() }

    override func accessibilityVisibleRows() -> [Any]? {
        rows(in: visibleRect).map(rowElement)
    }

    override func accessibilitySelectedRows() -> [Any]? {
        rows(in: visibleRect).filter(selection.containsRow).map(rowElement)
    }

    override func accessibilityColumnHeaderUIElements() -> [Any]? {
        columns(in: visibleRect).map(headerElement)
    }

    override func accessibilityVisibleCells() -> [Any]? { shownCells { _ in true } }

    override func accessibilitySelectedCells() -> [Any]? { shownCells(selection.contains) }

    private func shownCells(_ include: (GridPosition) -> Bool) -> [Any] {
        var cells: [Any] = []
        let columns = columns(in: visibleRect)
        for row in rows(in: visibleRect) {
            for column in columns where include(GridPosition(row: row, column: column)) {
                cells.append(cellElement(GridPosition(row: row, column: column)))
            }
        }
        return cells
    }

    override func accessibilityCell(forColumn column: Int, row: Int) -> Any? {
        guard row >= 0, row < rowCount, column >= 0, column < columnCount else { return nil }
        return cellElement(GridPosition(row: row, column: column))
    }

    override var accessibilityFocusedUIElement: Any? {
        if let editor { return editor }
        return selection.cursor.map(cellElement) ?? self
    }

    func rowElement(_ row: Int) -> GridRowElement {
        if let element = accessibilityElements.rows[row] { return element }
        let element = GridRowElement(grid: self, row: row)
        accessibilityElements.rows[row] = element
        return element
    }

    func cellElement(_ position: GridPosition) -> GridCellElement {
        if let element = accessibilityElements.cells[position] { return element }
        accessibilityElements.trim(keeping: rows(in: visibleRect))
        let element = GridCellElement(grid: self, position: position)
        accessibilityElements.cells[position] = element
        return element
    }

    func headerElement(_ column: Int) -> GridHeaderElement {
        if let element = accessibilityElements.headers[column] { return element }
        let element = GridHeaderElement(grid: self, column: column)
        accessibilityElements.headers[column] = element
        return element
    }

    /// Tells VoiceOver: the selection changed, and the focused cell when it moved.
    func selectionDidChange(from old: GridSelection) {
        NSAccessibility.post(element: self, notification: .selectedCellsChanged)
        if selection.areas.contains(where: { if case .rows = $0 { return true }; return false }) {
            NSAccessibility.post(element: self, notification: .selectedRowsChanged)
        }
        if let cursor = selection.cursor, cursor != old.cursor, window?.firstResponder === self {
            NSAccessibility.post(element: cellElement(cursor), notification: .focusedUIElementChanged)
        }
    }
}

/// The accessibility elements made so far, by row, cell and header; forgotten on reload and when far off screen.
struct GridAccessibilityElements {
    var rows: [Int: GridRowElement] = [:]
    var cells: [GridPosition: GridCellElement] = [:]
    var headers: [Int: GridHeaderElement] = [:]

    mutating func removeAll() {
        self = GridAccessibilityElements()
    }

    /// Keeps at most a few screens of elements: those of the rows on screen.
    mutating func trim(keeping visible: Range<Int>) {
        guard cells.count > 4_000 || rows.count > 1_000 else { return }
        cells = cells.filter { visible.contains($0.key.row) }
        rows = rows.filter { visible.contains($0.key) }
    }
}

final class GridRowElement: NSAccessibilityElement {
    unowned let grid: DataGridView
    let row: Int

    init(grid: DataGridView, row: Int) {
        self.grid = grid
        self.row = row
        super.init()
        setAccessibilityRole(.row)
        setAccessibilityParent(grid)
    }

    override func accessibilityIndex() -> Int { row }
    override func accessibilityLabel() -> String? { "Row \(row + 1)" }
    override func isAccessibilitySelected() -> Bool { grid.selection.containsRow(row) }

    override func accessibilityChildren() -> [Any]? {
        grid.columns(in: grid.visibleRect).map { grid.cellElement(GridPosition(row: row, column: $0)) }
    }

    override func accessibilityFrame() -> NSRect {
        NSAccessibility.screenRect(fromView: grid, rect: grid.rowRect(row))
    }
}

final class GridCellElement: NSAccessibilityElement {
    unowned let grid: DataGridView
    let position: GridPosition

    init(grid: DataGridView, position: GridPosition) {
        self.grid = grid
        self.position = position
        super.init()
        setAccessibilityRole(.cell)
    }

    private var column: Int? { position.column < grid.columnCount ? grid.columnOrder[position.column] : nil }

    override func accessibilityParent() -> Any? { grid.rowElement(position.row) }
    override func accessibilityRowIndexRange() -> NSRange { NSRange(location: position.row, length: 1) }
    override func accessibilityColumnIndexRange() -> NSRange { NSRange(location: position.column, length: 1) }
    override func isAccessibilitySelected() -> Bool { grid.selection.contains(position) }
    override func isAccessibilityFocused() -> Bool { grid.selection.cursor == position && grid.editor == nil }

    override func accessibilityLabel() -> String? {
        guard let column, let source = grid.source, column < source.columns.count else { return nil }
        return source.columns[column].name
    }

    /// The value as text, the NULL text for NULL, "Loading" for a page still on its way.
    override func accessibilityValue() -> Any? {
        guard let column, let source = grid.source, position.row < source.rowCount else { return nil }
        switch source.cell(position.row, column) {
        case .text(let text): return text
        case .null: return grid.nullText
        case .loading: return "Loading"
        }
    }

    override func accessibilityFrame() -> NSRect {
        guard position.column < grid.columnCount else { return .zero }
        return NSAccessibility.screenRect(fromView: grid, rect: grid.shownRect(position))
    }

    /// Editable where the delegate allows editing in place: a new value is a pending change, as in the editor.
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(NSAccessibilityElement.setAccessibilityValue(_:)) { return grid.canEdit(position) }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    override func setAccessibilityValue(_ value: Any?) {
        guard let text = value as? String, grid.canEdit(position) else { return }
        grid.commit(text, at: position)
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        guard focused else { return }
        grid.window?.makeFirstResponder(grid)
        grid.selection.select(position)
        grid.reveal(grid.cellRect(position))
    }
}

/// A column's header, as a button: pressing it selects the column, as a click does.
final class GridHeaderElement: NSAccessibilityElement {
    unowned let grid: DataGridView
    let column: Int

    init(grid: DataGridView, column: Int) {
        self.grid = grid
        self.column = column
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityParent(grid)
    }

    override func accessibilityIndex() -> Int { column }

    override func accessibilityLabel() -> String? {
        guard column < grid.columnCount, let source = grid.source else { return nil }
        return source.columns[grid.columnOrder[column]].name
    }

    override func accessibilityHelp() -> String? { "Select the column; its sort control sorts by it" }
    override func isAccessibilitySelected() -> Bool { grid.selection.containsColumn(column) }

    override func accessibilityFrame() -> NSRect {
        guard column < grid.columnCount else { return .zero }
        let (left, right) = grid.header.edges(column)
        return NSAccessibility.screenRect(fromView: grid.header, rect: NSRect(x: left, y: 0, width: right - left, height: grid.header.bounds.height))
    }

    override func accessibilityPerformPress() -> Bool {
        guard column < grid.columnCount else { return false }
        grid.selection.selectColumn(column)
        return true
    }
}
