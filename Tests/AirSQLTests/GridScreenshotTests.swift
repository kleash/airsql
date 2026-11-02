import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

// Light and dark pictures of the grid (both fixtures, a selection, the editor), for people and reviewers to compare with
// docs/dev/mockups.html. Only with AIRSQL_SCREENSHOTS=1: they go to build/screenshots.
extension AppTests {
    @MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["AIRSQL_SCREENSHOTS"] == "1")) struct GridScreenshotTests {
        private func save(_ harness: AgentServer, _ name: String) async throws {
            let reply = await call(harness, "screenshot", ["target": "main", "scale": 2])
            let image = try #require(reply.image, "\(name): \(reply.error ?? "")")
            let png = try #require(image.representation(using: .png, properties: [:]))
            try png.write(to: ScreenshotTests.folder.appendingPathComponent(name + ".png"))
        }

        @Test func grids() async throws {
            // Active, so the grid's window can be key and its selection shows in the accent, as people see it.
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let (main, harness, content) = AppTests().gridWindow(FakeGridSource.large())
                main.window?.appearance = NSAppearance(named: appearance)
                main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
                main.window?.makeKeyAndOrderFront(nil)
                main.window?.makeFirstResponder(content.grid)
                content.grid.selection.select(GridPosition(row: 2, column: 1))
                content.grid.selection.select(GridPosition(row: 4, column: 3), extend: true)
                main.window?.displayIfNeeded()
                try await save(harness, "grid-large-\(suffix)")
                main.window?.orderOut(nil)

                let (wide, wideHarness, wideContent) = AppTests().gridWindow(FakeGridSource.wide())
                wide.window?.appearance = NSAppearance(named: appearance)
                wide.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
                wide.window?.makeKeyAndOrderFront(nil)
                wide.window?.makeFirstResponder(wideContent.grid)
                wideContent.grid.selection.selectColumn(2)
                wideContent.grid.sortOrder = [.init(column: 2, ascending: true), .init(column: 4, ascending: false)]
                wide.window?.displayIfNeeded()
                try await save(wideHarness, "grid-wide-\(suffix)")
                wide.window?.orderOut(nil)
            }
        }
    }
}
