import AirSQLCore
import Foundation
import Testing

struct GridTests {
    @Test func largeFixtureIsAMillionRowsOfFiftyColumns() {
        let source = FakeGridSource.large()
        #expect(source.rowCount == 1_000_000)
        #expect(source.columns.count == 50)
        #expect(source.columns[0] == GridColumn(name: "id", type: "bigint unsigned", kind: .number, isKey: true))
        #expect(source.columns.dropFirst().allSatisfy { !$0.isKey })
        // Worked out from the position, so the same every time and at the far end too.
        #expect(source.cell(999_999, 0) == .text("1000000"))
        #expect(source.cell(123_456, 3) == source.cell(123_456, 3))
    }

    @Test func wideFixtureHasThreeHundredColumnsAndALongName() {
        let source = FakeGridSource.wide()
        #expect(source.columns.count == 300)
        #expect(source.columns.contains { $0.name.count == 60 })
        #expect(Set(source.columns.map(\.name)).count == 300)
    }

    @Test func nullAndEmptyStayDistinct() {
        let source = FakeGridSource.large()
        let cells = (0..<20).flatMap { r in (0..<10).map { source.cell(r, $0) } }
        #expect(cells.contains(.null))
        #expect(cells.contains(.text("")))
        #expect(GridCell.null.text == "" && GridCell.loading.text == "")
    }

    @Test func keyValuesAreWhole() {
        let source = FakeGridSource.large()
        for row in [0, 41, 999_999] {
            #expect(source.cell(row, 0) == .text(String(row + 1)))
        }
    }

    @Test func clicksSelectCellsBlocksRowsAndColumns() {
        var selection = GridSelection()
        selection.select(GridPosition(row: 2, column: 1))
        #expect(selection.contains(GridPosition(row: 2, column: 1)))
        #expect(!selection.contains(GridPosition(row: 2, column: 2)))
        selection.select(GridPosition(row: 4, column: 3), extend: true)  // ⇧-click: the block from the anchor
        #expect(selection.areas == [.cells(rows: 2...4, columns: 1...3)])
        #expect(selection.cursor == GridPosition(row: 4, column: 3) && selection.anchor == GridPosition(row: 2, column: 1))
        selection.select(GridPosition(row: 9, column: 0), add: true)  // ⌘-click adds, and takes away again
        #expect(selection.areas.count == 2)
        selection.select(GridPosition(row: 9, column: 0), add: true)
        #expect(selection.areas == [.cells(rows: 2...4, columns: 1...3)])

        selection.selectRow(5)
        selection.selectRow(7, extend: true)
        #expect(selection.containsRow(6) && !selection.containsRow(8))
        #expect(selection.contains(GridPosition(row: 6, column: 40)))
        selection.selectColumn(3)
        selection.selectColumn(1, extend: true)
        #expect(selection.containsColumn(2) && !selection.containsColumn(0) && !selection.containsRow(6))
        selection.selectAll()
        #expect(selection.containsRow(999) && selection.containsColumn(49))
    }

    @Test func keysMoveTheCursorAndShiftExtends() {
        var selection = GridSelection()
        func move(_ move: GridSelection.Move, extend: Bool = false) {
            selection.move(move, extend: extend, rows: 100, columns: 5, page: 20)
        }
        move(.down)  // nothing focused yet: starts at the first cell
        #expect(selection.cursor == GridPosition(row: 1, column: 0))
        move(.up); move(.up); move(.left)
        #expect(selection.cursor == GridPosition(row: 0, column: 0))  // stops at the edges
        move(.pageDown); move(.pageDown)
        #expect(selection.cursor?.row == 40)
        move(.lastColumn)
        move(.next)  // Tab at the end of a row wraps to the next one
        #expect(selection.cursor == GridPosition(row: 41, column: 0))
        move(.previous)
        #expect(selection.cursor == GridPosition(row: 40, column: 4))
        move(.left, extend: true); move(.down, extend: true)
        #expect(selection.areas == [.cells(rows: 40...41, columns: 3...4)])
        move(.lastRow)
        #expect(selection.areas == [.cells(rows: 99...99, columns: 3...3)])
        selection.selectRow(10)
        move(.down, extend: true)  // ⇧ on a row selection extends the rows
        #expect(selection.areas == [.rows(10...11)])
    }

    @Test func selectionGrowsAndShrinksFromTheFocusedCell() {
        var selection = GridSelection()
        selection.grow()  // nothing focused: nothing to grow
        #expect(selection.isEmpty)
        selection.select(GridPosition(row: 3, column: 2))
        selection.select(GridPosition(row: 5, column: 4), extend: true)
        let steps: [GridSelection.Area] = [.columns(4...4), .rows(5...5), .all]
        for step in steps {
            selection.grow()
            #expect(selection.areas == [step] && selection.cursor == GridPosition(row: 5, column: 4))
        }
        selection.grow()  // everything already
        #expect(selection.areas == [.all])
        for step in [GridSelection.Area.rows(5...5), .columns(4...4), .cells(rows: 5...5, columns: 4...4)] {
            selection.shrink()
            #expect(selection.areas == [step] && selection.cursor == GridPosition(row: 5, column: 4))
        }
        selection.shrink()  // one cell: stays
        #expect(selection.areas == [.cells(rows: 5...5, columns: 4...4)])
    }

    @Test func reloadKeepsTheSelectionInside() {
        var selection = GridSelection()
        selection.select(GridPosition(row: 50, column: 4))
        selection.select(GridPosition(row: 80, column: 6), extend: true)
        selection.clamp(rows: 60, columns: 5)
        #expect(selection.areas == [.cells(rows: 50...59, columns: 4...4)])
        #expect(selection.cursor == GridPosition(row: 59, column: 4))
        selection.clamp(rows: 0, columns: 5)
        #expect(selection.isEmpty && selection.cursor == nil)
    }
}
