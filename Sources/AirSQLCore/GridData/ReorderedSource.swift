/// Another source's rows in another order: a console result sorted here, by its headers (grid-spec §4: results sort
/// locally). Nil `order`: the rows as they came.
public final class ReorderedSource: GridSource {
    public let base: GridSource
    public var order: [Int]?

    public init(_ base: GridSource) {
        self.base = base
    }

    /// The base's row shown at `row`.
    public func baseRow(_ row: Int) -> Int { order?[row] ?? row }

    public var columns: [GridColumn] { base.columns }
    public var rowCount: Int { order?.count ?? base.rowCount }
    public func cell(_ row: Int, _ column: Int) -> GridCell { base.cell(baseRow(row), column) }
    public func mark(_ row: Int, _ column: Int) -> GridMark { base.mark(baseRow(row), column) }
}
