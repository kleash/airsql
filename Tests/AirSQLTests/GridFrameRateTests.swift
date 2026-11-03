import AppKit
import QuartzCore
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// Scrolls a grid at a steady speed on each frame of the display and measures each frame, as the spike's experiment did:
/// the main thread's work (scroll, lay out and draw), the time from the display link's tick to the frame committed,
/// frames committed after their deadline, and display refreshes skipped.
@MainActor
final class FrameMeter: NSObject {
    struct Result: CustomStringConvertible {
        var frames = 0, skipped = 0, late = 0, cellsPerFrame = 0.0
        var drawP50 = 0.0, drawP95 = 0.0, drawMax = 0.0, p50 = 0.0, p95 = 0.0, max = 0.0
        var description: String {
            String(format: "frames %d, skipped refreshes %d, late commits %d; main-thread work p50 %.2f ms p95 %.2f ms max %.2f ms; "
                   + "tick to commit p50 %.2f ms p95 %.2f ms max %.2f ms; %.0f cells drawn a frame",
                   frames, skipped, late, drawP50, drawP95, drawMax, p50, p95, max, cellsPerFrame)
        }
    }

    private let grid: DataGridView
    private let speed: CGFloat, duration: Double, horizontal: Bool
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0, last: CFTimeInterval = 0, warmup = 12
    private var gaps: [CFTimeInterval] = [], works: [CFTimeInterval] = [], draws: [CFTimeInterval] = [], late = 0, cells = 0
    private var finish: ((Result) -> Void)?

    init(grid: DataGridView, speed: CGFloat, duration: Double = 3, horizontal: Bool = false) {
        self.grid = grid
        self.speed = speed
        self.duration = duration
        self.horizontal = horizontal
    }

    @available(macOS 14, *)
    func run() async -> Result {
        await withCheckedContinuation { continuation in
            finish = { continuation.resume(returning: $0) }
            let link = grid.displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    private func scroll(to offset: CGFloat) {
        let clip = grid.scrollView.contentView, insets = clip.contentInsets
        let point = horizontal ? NSPoint(x: min(offset, grid.bounds.width - clip.bounds.width) - insets.left, y: clip.bounds.minY)
            : NSPoint(x: clip.bounds.minX, y: min(offset, grid.bounds.height - clip.bounds.height) - insets.top)
        clip.scroll(to: point)
        grid.scrollView.reflectScrolledClipView(clip)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if warmup > 0 {
            warmup -= 1
            start = link.timestamp
            last = link.timestamp
            scroll(to: 0)
            grid.window?.displayIfNeeded()
            return
        }
        gaps.append(link.timestamp - last)
        last = link.timestamp
        let elapsed = link.timestamp - start
        let before = grid.drawnCells
        scroll(to: CGFloat(elapsed) * speed)
        grid.window?.displayIfNeeded()
        draws.append(CACurrentMediaTime() - now)
        CATransaction.flush()
        cells += grid.drawnCells - before
        let done = CACurrentMediaTime()
        works.append(done - now)
        if done > link.targetTimestamp { late += 1 }
        guard elapsed > duration else { return }
        link.invalidate()
        let frame = 1.0 / 120, sorted = works.sorted(), drawn = draws.sorted()
        func percentile(_ values: [Double], _ q: Double) -> Double { values[min(values.count - 1, Int(Double(values.count) * q))] * 1000 }
        finish?(Result(frames: works.count, skipped: gaps.filter { $0 > 1.5 * frame }.reduce(0) { $0 + Int(($1 / frame).rounded()) - 1 },
                       late: late, cellsPerFrame: Double(cells) / Double(works.count),
                       drawP50: percentile(drawn, 0.5), drawP95: percentile(drawn, 0.95), drawMax: (drawn.last ?? 0) * 1000,
                       p50: percentile(sorted, 0.5), p95: percentile(sorted, 0.95), max: (sorted.last ?? 0) * 1000))
        finish = nil
    }
}

extension AppTests {
    /// On this Mac's display only (grid-spec §8): the grid at full screen, scrolled at 2,400 and 7,000 points a second.
    @MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["AIRSQL_GRID_FPS"] == "1")) struct GridFrameRateTests {
        @Test func gridScrollsAtTheDisplaysRate() async throws {
            guard #available(macOS 14, *), let screen = NSScreen.main else { return }
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            print("GRID FPS display: \(Int(screen.frame.width))×\(Int(screen.frame.height)) pt, "
                  + "up to \(screen.maximumFramesPerSecond) Hz")
            let runs: [(String, GridSource, CGFloat, Bool)] = [
                ("1,000,000 × 50 down", FakeGridSource.large(), 2_400, false),
                ("1,000,000 × 50 down", FakeGridSource.large(), 7_000, false),
                ("10,000 × 300 down", FakeGridSource.wide(), 2_400, false),
                ("10,000 × 300 across", FakeGridSource.wide(), 2_400, true),
            ]
            for (name, source, speed, horizontal) in runs {
                let (main, _, content) = AppTests().gridWindow(source, size: screen.visibleFrame.size)
                main.window?.setFrame(screen.visibleFrame, display: true)
                main.window?.makeKeyAndOrderFront(nil)
                main.window?.displayIfNeeded()
                let result = await FrameMeter(grid: content.grid, speed: speed, horizontal: horizontal).run()
                print("GRID FPS \(name) at \(Int(speed)) pt/s, grid \(Int(content.grid.shownRect.width))×\(Int(content.grid.shownRect.height)) pt: \(result)")
                // The main thread's part of each frame fits in a refresh (the commit's wait belongs to the window server).
                #expect(result.drawP95 < 1000.0 / Double(screen.maximumFramesPerSecond), "\(name): \(result)")
                main.window?.orderOut(nil)
            }
            // The first screen of a 10,000,000-row table, from the source arriving to the frame committed.
            let (main, _, content) = AppTests().gridWindow(FakeGridSource(rows: 1, columns: 50), size: screen.visibleFrame.size)
            main.window?.setFrame(screen.visibleFrame, display: true)
            main.window?.orderFront(nil)
            main.window?.displayIfNeeded()
            let start = CACurrentMediaTime()
            content.grid.source = FakeGridSource(rows: 10_000_000, columns: 50)
            main.window?.displayIfNeeded()
            CATransaction.flush()
            let first = (CACurrentMediaTime() - start) * 1000
            print(String(format: "GRID FPS first screen of 10,000,000 × 50: %.1f ms", first))
            #expect(first < 300)
            main.window?.orderOut(nil)
        }
    }
}
