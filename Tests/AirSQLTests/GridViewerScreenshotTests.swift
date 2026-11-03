import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// FakeGridSource's columns with what a table's schema would add: keys, a foreign key, auto, a default, NULL allowed.
final class DescribedSource: GridSource {
    let base = FakeGridSource(rows: 2_000, columns: 10)
    let columns: [GridColumn]

    init() {
        var columns = base.columns
        columns[0].marks = [.primary, .autoIncrement]
        columns[0].type = "bigint unsigned"
        columns[1].marks = [.unique]
        columns[2].marks = [.indexed]
        columns[3].marks = [.hasDefault]
        columns[4].marks = [.nullable]
        columns[9].marks = [.foreign, .indexed]
        columns[4].comment = "What the customer wrote at checkout"
        self.columns = columns
    }

    var rowCount: Int { base.rowCount }
    func cell(_ row: Int, _ column: Int) -> GridCell { base.cell(row, column) }
}

extension AppTests.ScreenshotTests {
    /// The grid viewer's tools (the header's marks, the status bar's figure, the value panel, Record View, Transpose,
    /// Text and Chart), to compare with docs/dev/mockups.html.
    @Test func viewerTools() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let (main, harness) = appWindow(testModel(Fixtures.shop), size: NSSize(width: 1180, height: 720))
            main.model.states[Fixtures.production.id] = .connected(server: "MariaDB 11.8")
            let content = ViewerContent(DescribedSource())
            main.open(content, title: "orders", connection: Fixtures.production.id)
            content.viewer.status.rows.stringValue = "1,000 of ≈2,348,245 rows"
            let window = try #require(main.window)
            window.appearance = NSAppearance(named: appearance)
            window.setFrameOrigin(NSPoint(x: 40, y: 40))
            window.orderFront(nil)
            let viewer = content.viewer, grid = viewer.grid
            window.makeFirstResponder(grid)
            func save(_ name: String) async throws {
                window.layoutIfNeeded()
                window.displayIfNeeded()
                try await self.save(harness, "viewer-\(name)-\(suffix)")
            }
            grid.selection.select(GridPosition(row: 2, column: 2))
            grid.selection.select(GridPosition(row: 6, column: 2), extend: true)
            viewer.toggleHeatmap(nil)
            try await save("figures")
            grid.selection.select(GridPosition(row: 0, column: 7))
            viewer.toggleValuePanel(nil)
            try await save("value-panel")
            viewer.toggleValuePanel(nil)
            viewer.showRecordView(nil)
            try await save("record")
            viewer.transposeGrid(nil)
            viewer.transposeGrid(nil)
            try await save("transposed")
            viewer.transposeGrid(nil)
            viewer.present(.text)
            try await save("text")
            viewer.present(.chart)
            try await save("chart")
            if let chart = viewer.presented as? GridChartView, let png = chart.pngData() {
                try png.write(to: Self.folder.appendingPathComponent("viewer-chart-export-\(suffix).png"))
            }
            window.orderOut(nil)
        }
    }
}
