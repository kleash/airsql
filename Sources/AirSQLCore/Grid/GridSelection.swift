/// A cell by its row and its column as the grid shows it (the grid's display order, not the source's).
public struct GridPosition: Hashable, Sendable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// What is selected in a grid (grid-spec §2): blocks of cells, whole rows, whole columns or everything, plus the
/// focused cell (the cursor) and the anchor that ⇧ extends from. Clicks and keys change it; the grid draws it.
public struct GridSelection: Equatable, Sendable {
    public enum Area: Equatable, Sendable {
        case cells(rows: ClosedRange<Int>, columns: ClosedRange<Int>)
        case rows(ClosedRange<Int>)
        case columns(ClosedRange<Int>)
        case all

        public func contains(_ position: GridPosition) -> Bool {
            switch self {
            case .cells(let rows, let columns): return rows.contains(position.row) && columns.contains(position.column)
            case .rows(let rows): return rows.contains(position.row)
            case .columns(let columns): return columns.contains(position.column)
            case .all: return true
            }
        }
    }

    /// The ways a key moves the cursor.
    public enum Move: Sendable {
        case up, down, left, right, pageUp, pageDown, firstRow, lastRow, firstColumn, lastColumn
        /// Tab and ⇧Tab: the next or previous cell, wrapping to the next or previous row.
        case next, previous
    }

    public private(set) var areas: [Area] = []
    public private(set) var cursor: GridPosition?
    public private(set) var anchor: GridPosition?

    public init() {}

    public var isEmpty: Bool { areas.isEmpty }

    public func contains(_ position: GridPosition) -> Bool { areas.contains { $0.contains(position) } }

    /// Whether the whole row is selected (its row number shows it).
    public func containsRow(_ row: Int) -> Bool {
        areas.contains { area in
            if case .rows(let rows) = area { return rows.contains(row) }
            return area == .all
        }
    }

    /// Whether the whole column is selected (its header shows it).
    public func containsColumn(_ column: Int) -> Bool {
        areas.contains { area in
            if case .columns(let columns) = area { return columns.contains(column) }
            return area == .all
        }
    }

    /// A click on a cell: selects it; with ⇧ (`extend`) the block from the anchor to it; with ⌘ (`add`) adds it, or
    /// takes it away again when it was selected on its own.
    public mutating func select(_ position: GridPosition, extend: Bool = false, add: Bool = false) {
        let area = Area.cells(rows: position.row...position.row, columns: position.column...position.column)
        if extend, let anchor {
            replaceLast(.cells(rows: span(anchor.row, position.row), columns: span(anchor.column, position.column)))
            cursor = position
            return
        }
        if add, let index = areas.firstIndex(of: area) {
            areas.remove(at: index)
        } else {
            areas = add ? areas + [area] : [area]
        }
        cursor = position
        anchor = position
    }

    /// A click on a row number: the whole row, extended or added as with cells.
    public mutating func selectRow(_ row: Int, extend: Bool = false, add: Bool = false) {
        let position = GridPosition(row: row, column: cursor?.column ?? 0)
        let area = Area.rows(row...row)
        if extend, let anchor {
            replaceLast(.rows(span(anchor.row, row)))
        } else if add, let index = areas.firstIndex(of: area) {
            areas.remove(at: index)
            anchor = position
        } else {
            areas = add ? areas + [area] : [area]
            anchor = position
        }
        cursor = position
    }

    /// A click on a column header: the whole column, extended or added as with cells.
    public mutating func selectColumn(_ column: Int, extend: Bool = false, add: Bool = false) {
        let position = GridPosition(row: cursor?.row ?? 0, column: column)
        let area = Area.columns(column...column)
        if extend, let anchor {
            replaceLast(.columns(span(anchor.column, column)))
        } else if add, let index = areas.firstIndex(of: area) {
            areas.remove(at: index)
            anchor = position
        } else {
            areas = add ? areas + [area] : [area]
            anchor = position
        }
        cursor = position
    }

    /// ⌘A.
    public mutating func selectAll() {
        areas = [.all]
        if cursor == nil { cursor = GridPosition(row: 0, column: 0) }
        anchor = anchor ?? cursor
    }

    public mutating func clear() {
        self = GridSelection()
    }

    /// A key: moves the cursor in a grid of `rows` × `columns` (`page` rows to a page) and selects its cell; with ⇧
    /// (`extend`) selects the block, rows or columns from the anchor to it instead.
    public mutating func move(_ move: Move, extend: Bool = false, rows: Int, columns: Int, page: Int) {
        guard rows > 0, columns > 0 else { return clear() }
        let from = cursor ?? GridPosition(row: 0, column: 0)
        var to = from
        switch move {
        case .up: to.row -= 1
        case .down: to.row += 1
        case .left: to.column -= 1
        case .right: to.column += 1
        case .pageUp: to.row -= max(1, page)
        case .pageDown: to.row += max(1, page)
        case .firstRow: to.row = 0
        case .lastRow: to.row = rows - 1
        case .firstColumn: to.column = 0
        case .lastColumn: to.column = columns - 1
        case .next:
            if to.column < columns - 1 { to.column += 1 } else if to.row < rows - 1 { to = GridPosition(row: to.row + 1, column: 0) }
        case .previous:
            if to.column > 0 { to.column -= 1 } else if to.row > 0 { to = GridPosition(row: to.row - 1, column: columns - 1) }
        }
        to = GridPosition(row: min(max(0, to.row), rows - 1), column: min(max(0, to.column), columns - 1))
        guard extend, let anchor else { return select(to) }
        switch areas.last {
        case .rows: replaceLast(.rows(span(anchor.row, to.row)))
        case .columns: replaceLast(.columns(span(anchor.column, to.column)))
        default: replaceLast(.cells(rows: span(anchor.row, to.row), columns: span(anchor.column, to.column)))
        }
        cursor = to
    }

    /// Keeps the selection inside a grid that now has `rows` × `columns` (after a reload).
    public mutating func clamp(rows: Int, columns: Int) {
        guard rows > 0, columns > 0, let cursor else { return clear() }
        func fit(_ range: ClosedRange<Int>, _ count: Int) -> ClosedRange<Int>? {
            range.lowerBound < count ? range.lowerBound...min(range.upperBound, count - 1) : nil
        }
        areas = areas.compactMap { area in
            switch area {
            case .cells(let r, let c): return fit(r, rows).flatMap { r in fit(c, columns).map { .cells(rows: r, columns: $0) } }
            case .rows(let r): return fit(r, rows).map { .rows($0) }
            case .columns(let c): return fit(c, columns).map { .columns($0) }
            case .all: return .all
            }
        }
        let fitted = GridPosition(row: min(cursor.row, rows - 1), column: min(cursor.column, columns - 1))
        self.cursor = fitted
        if let anchor { self.anchor = GridPosition(row: min(anchor.row, rows - 1), column: min(anchor.column, columns - 1)) }
        if areas.isEmpty { areas = [.cells(rows: fitted.row...fitted.row, columns: fitted.column...fitted.column)] }
    }

    private mutating func replaceLast(_ area: Area) {
        if areas.isEmpty { areas = [area] } else { areas[areas.count - 1] = area }
    }

    private func span(_ a: Int, _ b: Int) -> ClosedRange<Int> { min(a, b)...max(a, b) }
}
