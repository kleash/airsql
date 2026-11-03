import AppKit
import CMariaDB
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// Counts what the viewer reads from its source, so the performance checks are numbers, not timings (grid-spec §8:
/// no timing on shared runners).
final class CountingSource: GridSource {
    let base: GridSource
    private(set) var values = 0
    private(set) var cells = 0

    init(_ base: GridSource) { self.base = base }

    var columns: [GridColumn] { base.columns }
    var rowCount: Int { base.rowCount }
    func cell(_ row: Int, _ column: Int) -> GridCell {
        cells += 1
        return base.cell(row, column)
    }
    func value(_ row: Int, _ column: Int) -> String? {
        values += 1
        return base.value(row, column)
    }
}

/// Lane L2's tools stay proportional to what is shown or selected, never to the rows held, on the grid's size target
/// (1,000,000 rows × 50 columns).
extension AppTests {
    @Test func figuresReadOnlyTheSelectedCellsAndNoneOfAHugeSelection() async throws {
        let source = CountingSource(FakeGridSource.large())
        let (_, _, content) = viewerWindow(source)
        let grid = content.viewer.grid, status = content.viewer.status
        grid.selection.select(GridPosition(row: 10, column: 1))
        let before = source.values
        grid.selection.select(GridPosition(row: 1_009, column: 1), extend: true)
        #expect(source.values - before == 1_000)
        // Everything: too many cells to add up, and none of them read.
        let all = source.values
        grid.selection.selectAll()
        #expect(source.values == all && status.figure.title == "Too many cells to add up")
        #expect(status.position.stringValue.hasSuffix("50,000,000 cells"))
    }

    @Test func transposeAndViewsStayWithinTheirLimits() async throws {
        let source = CountingSource(FakeGridSource.large())
        let (_, _, content) = viewerWindow(source)
        let viewer = content.viewer
        viewer.transposeGrid(nil)
        #expect(viewer.grid.columnCount == TransposedSource.limit + 1 && viewer.recordLabel.stringValue.contains("first 1,000"))
        viewer.transposeGrid(nil)
        let read = source.values
        viewer.present(.text)
        #expect(source.values - read == GridViewer.presentedLimit * 50)
        viewer.present(.table)
        // Drawing a screen of the grid reads a few screens of cells at most (its tiles reach past it), whatever the
        // row count.
        let drawn = source.cells
        viewer.grid.window?.displayIfNeeded()
        CATransaction.flush()
        let visible = viewer.grid.rows(in: viewer.grid.visibleRect).count * viewer.grid.columns(in: viewer.grid.visibleRect).count
        print("GRID cells read for a screen: \(source.cells - drawn) (\(visible) shown)")
        #expect(source.cells - drawn > 0 && source.cells - drawn <= visible * 6)
    }

    @Test func pagedTableFindsRowsAcrossAThousandPages() {
        let column = ResultStore.Column(name: "id", type: MYSQL_TYPE_LONG)
        func page(_ start: Int, _ count: Int) -> ResultStore {
            let store = ResultStore(columns: [column])
            for value in start..<start + count { store.append([Array(String(value).utf8)]) }
            return store
        }
        var table = SchemaTable(name: "t", kind: .table)
        table.columns = [cachedColumn("id", "int")]
        let source = TableDataSource(database: "d", table: table)
        for index in 0..<1_000 { source.append(page(index * 100, 100), requested: 100) }
        source.append(page(100_000, 7), requested: 100)
        #expect(source.rowCount == 100_007 && !source.hasMore)
        for row in [0, 99, 100, 54_321, 99_999, 100_006] { #expect(source.cell(row, 0) == .text(String(row))) }
    }
}
