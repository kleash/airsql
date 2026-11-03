import Foundation

/// Rows turned into columns (Transpose, ⌥⌘T, and Record View's one row): the column names down the left, then a column
/// per row of the source. `base(_:_:)` says which source cell a cell shows, so edits can go back to it.
public final class TransposedSource: GridSource {
    public let base: GridSource
    /// The source's columns, in the order shown (hidden ones left out): the rows here.
    public let order: [Int]
    /// The source's rows shown as columns; nil for the first `limit` of them, as many as there are now.
    public let rows: [Int]?
    public private(set) var columns: [GridColumn] = []
    /// The most rows Transpose turns into columns: more would be too wide to read (and to measure).
    public static let limit = 1_000

    public init(_ base: GridSource, order: [Int], rows: [Int]? = nil) {
        self.base = base
        self.order = order
        self.rows = rows
        refresh()
    }

    /// The source's row count changed (a page arrived): one column per row again.
    public func refresh() {
        let shown = rows ?? Array(0..<min(base.rowCount, Self.limit))
        columns = [GridColumn(name: "Column", type: "name")]
            + shown.map { GridColumn(name: rows?.count == 1 ? "Value" : "\($0 + 1)", type: rows?.count == 1 ? "row \($0 + 1)" : "row") }
    }

    public var rowCount: Int { order.count }

    /// The source's row and column a cell shows; nil for the names on the left.
    public func base(_ row: Int, _ column: Int) -> (row: Int, column: Int)? {
        guard column > 0, order.indices.contains(row) else { return nil }
        return (rows?[column - 1] ?? column - 1, order[row])
    }

    private func sourceRow(_ column: Int) -> Int { rows?[column - 1] ?? column - 1 }

    public func cell(_ row: Int, _ column: Int) -> GridCell {
        column == 0 ? .text(base.columns[order[row]].name) : base.cell(sourceRow(column), order[row])
    }

    public func value(_ row: Int, _ column: Int) -> String? {
        column == 0 ? base.columns[order[row]].name : base.value(sourceRow(column), order[row])
    }

    public func mark(_ row: Int, _ column: Int) -> GridMark {
        column == 0 ? .none : base.mark(sourceRow(column), order[row])
    }

    public func prefetch(_ rows: Range<Int>) {}
}
