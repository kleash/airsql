import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// A window that draws as the key window, so pictures show the grid as people use it (the tests' process is never the
/// active app, so its windows are never key).
final class KeyLookWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

// Light and dark pictures of the grid (both fixtures, a selection, the editor), for people and reviewers to compare with
// docs/dev/mockups.html. Only with AIRSQL_SCREENSHOTS=1: they go to build/screenshots.
extension AppTests {
    @MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["AIRSQL_SCREENSHOTS"] == "1")) struct GridScreenshotTests {
        private func save(_ harness: AgentServer, _ name: String, target: String = "main") async throws {
            let reply = await call(harness, "screenshot", ["target": target, "scale": 2])
            let image = try #require(reply.image, "\(name): \(reply.error ?? "")")
            let png = try #require(image.representation(using: .png, properties: [:]))
            try png.write(to: ScreenshotTests.folder.appendingPathComponent(name + ".png"))
        }

        private func show(_ window: NSWindow?, _ appearance: NSAppearance.Name) {
            window?.appearance = NSAppearance(named: appearance)
            window?.setFrameOrigin(NSPoint(x: 40, y: 40))
            window?.orderFront(nil)
            window?.displayIfNeeded()
        }

        /// The grid alone in a window that looks key, for the selection and the editor.
        private func focusedGrid(_ source: GridSource, _ appearance: NSAppearance.Name) -> (NSWindow, AgentServer, GridFixtureContent) {
            let window = KeyLookWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 560), styleMask: [.titled, .closable, .resizable],
                                       backing: .buffered, defer: false)
            window.title = "Grid"
            window.isReleasedWhenClosed = false
            let content = GridFixtureContent(source)
            window.contentViewController = content
            window.setContentSize(NSSize(width: 980, height: 560))
            let (_, harness) = appWindow(testModel(), windows: { [window] })
            show(window, appearance)
            window.makeFirstResponder(content.grid)
            return (window, harness, content)
        }

        @Test func grids() async throws {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                // Both fixtures in the main window.
                let (main, harness, _) = AppTests().gridWindow(FakeGridSource.large())
                show(main.window, appearance)
                try await save(harness, "grid-large-\(suffix)")
                main.window?.orderOut(nil)

                let (wide, wideHarness, wideContent) = AppTests().gridWindow(FakeGridSource.wide())
                wideContent.grid.sortOrder = [.init(column: 3, ascending: true), .init(column: 5, ascending: false)]
                show(wide.window, appearance)
                // Scrolled across to the column with the 60-character name, which the header shortens.
                let grid = wideContent.grid, clip = grid.scrollView.contentView
                clip.scroll(to: NSPoint(x: grid.offsets[4] - clip.contentInsets.left, y: clip.bounds.minY))
                grid.scrollView.reflectScrolledClipView(clip)
                wide.window?.displayIfNeeded()
                try await save(wideHarness, "grid-wide-\(suffix)")
                wide.window?.orderOut(nil)

                // A block of cells with the focused cell, a row added with ⌘, as the key window shows them.
                let (window, focusedHarness, content) = focusedGrid(FakeGridSource.large(), appearance)
                content.grid.selection.select(GridPosition(row: 2, column: 1))
                content.grid.selection.select(GridPosition(row: 5, column: 3), extend: true)
                content.grid.selection.selectRow(8, add: true)
                window.displayIfNeeded()
                try await save(focusedHarness, "grid-selection-\(suffix)", target: "window:Grid")

                // Pending changes (an edited cell, an added row, a deleted row) and rows still loading.
                let states = ChangingGridSource(rows: 40, columns: 6)
                states.loadingFrom = 7
                content.grid.source = states
                content.grid.selection.select(GridPosition(row: 5, column: 2))
                window.displayIfNeeded()
                try await save(focusedHarness, "grid-states-\(suffix)", target: "window:Grid")
                content.grid.source = FakeGridSource.large()

                // The editor over a cell, after typing.
                content.editable = true
                content.grid.selection.select(GridPosition(row: 4, column: 1))
                content.grid.beginEditing(at: GridPosition(row: 4, column: 1), text: "Customer 4 Barbara Liskov")
                window.displayIfNeeded()
                try await save(focusedHarness, "grid-editor-\(suffix)", target: "window:Grid")
                content.grid.endEditing(commit: false)
                window.orderOut(nil)
            }
        }
    }
}
