import AppKit
import Darwin
import Testing
@testable import AirSQL
@testable import AirSQLCore

// grid-spec §8: the deterministic numbers CI checks (no timing on shared runners: counts, a ratio to a reference on the
// same machine, memory), and, on this Mac only, the frame rate of the real view (AIRSQL_GRID_FPS=1).
extension AppTests {
    /// Draws `rect` of the grid as AppKit would (off screen too) and returns how many cells that took.
    @discardableResult
    func drawCells(_ grid: DataGridView, _ rect: NSRect) -> Int {
        let before = grid.drawnCells
        if let bitmap = grid.bitmapImageRepForCachingDisplay(in: rect) { grid.cacheDisplay(in: rect, to: bitmap) }
        return grid.drawnCells - before
    }

    /// The process's memory as Activity Monitor counts it (its footprint).
    func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    func median(_ times: [Double]) -> Double { times.sorted()[times.count / 2] }

    @Test func gridDrawsOnlyWhatScrollsIntoView() {
        var counts: [Int: (step: Int, screen: Int)] = [:]
        for rows in [1_000_000, 2_000] {
            let (_, _, content) = gridWindow(FakeGridSource(rows: rows, columns: 50))
            let grid = content.grid, shown = grid.visibleRect
            drawCells(grid, shown)  // the first display also fills the view's layer
            // Three rows scroll into view below the screen.
            let step = drawCells(grid, NSRect(x: shown.minX, y: shown.maxY, width: shown.width, height: 3 * grid.rowHeight))
            counts[rows] = (step, drawCells(grid, shown))
        }
        let (_, _, wide) = gridWindow(FakeGridSource.wide())
        drawCells(wide.grid, wide.grid.visibleRect)
        let wideScreen = drawCells(wide.grid, wide.grid.visibleRect)
        let columns = wide.grid.columns(in: wide.grid.visibleRect).count, rows = wide.grid.rows(in: wide.grid.visibleRect).count
        print("GRID cells drawn: 3-row step \(counts[1_000_000]!.step) (1,000,000 rows) / \(counts[2_000]!.step) (2,000 rows); "
              + "a screen \(counts[1_000_000]!.screen) / \(counts[2_000]!.screen); a screen of 300 columns \(wideScreen) "
              + "(\(rows) rows × \(columns) columns)")
        // Proportional to the area shown, whatever the number of rows; never every column of a wide table.
        #expect(counts[1_000_000]! == counts[2_000]!)
        #expect(counts[1_000_000]!.step <= 4 * 50 && counts[1_000_000]!.step > 0)
        #expect(wideScreen == rows * columns && columns < 30)
    }

    /// A page (a screen of cells drawn from nothing) within 5× of drawing the same text with bare Core Text.
    @Test func gridPageBuildsWithinFiveTimesTheReference() {
        let (_, _, content) = gridWindow(FakeGridSource.large())
        let grid = content.grid, shown = grid.visibleRect
        let rows = grid.rows(in: shown), columns = grid.columns(in: shown)
        let source = FakeGridSource.large(), font = grid.styles.regular
        drawCells(grid, shown)  // warm up fonts and caches
        var page: [Double] = [], reference: [Double] = []
        let bitmap = grid.bitmapImageRepForCachingDisplay(in: shown)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        for _ in 0..<7 {
            var start = CACurrentMediaTime()
            grid.cacheDisplay(in: shown, to: bitmap)
            page.append(CACurrentMediaTime() - start)
            start = CACurrentMediaTime()
            for row in rows {
                for column in columns {
                    let text = GridStyles.text(source.cell(row, column), nullText: "NULL")
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                    context.textPosition = CGPoint(x: CGFloat(column) * 100, y: CGFloat(row) * 23)
                    CTLineDraw(line, context)
                }
            }
            reference.append(CACurrentMediaTime() - start)
        }
        let ratio = median(page) / median(reference)
        print(String(format: "GRID page of %d cells: %.2f ms; bare Core Text %.2f ms; ratio %.1f", rows.count * columns.count,
                     median(page) * 1000, median(reference) * 1000, ratio))
        #expect(ratio < 5)
    }

    /// Nothing is kept per row: a million-row grid scrolled from end to end holds a few megabytes.
    @Test func gridMemoryDoesNotGrowWithRows() {
        for (name, source) in [("1,000,000 × 50", FakeGridSource.large()), ("10,000 × 300", FakeGridSource.wide())] {
            let before = footprint()
            let (_, _, content) = gridWindow(source)
            let grid = content.grid
            for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let row = Int(Double(grid.rowCount - 1) * fraction)
                let rect = NSRect(x: 0, y: CGFloat(row) * grid.rowHeight, width: grid.visibleRect.width, height: grid.visibleRect.height)
                drawCells(grid, rect.intersection(grid.bounds))
                _ = grid.accessibilityCell(forColumn: 1, row: row)
            }
            let grown = footprint() - before
            print("GRID memory for \(name): \(grown >> 10) KB")
            #expect(grown < 64 << 20, "\(name): \(grown >> 20) MB")
        }
    }
}
