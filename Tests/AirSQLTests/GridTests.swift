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

    @Test @MainActor func pagesLoadAfterPrefetch() async {
        let source = FakeGridSource(rows: 1_000, columns: 5, pageSize: 100)
        #expect(source.cell(250, 1) == .loading)
        let loaded = await withCheckedContinuation { continuation in
            source.onLoad = { continuation.resume(returning: $0) }
            source.prefetch(210..<260)
        }
        #expect(loaded == 200..<300)
        #expect(source.cell(250, 1) != .loading)
        #expect(source.cell(300, 1) == .loading)
    }
}
