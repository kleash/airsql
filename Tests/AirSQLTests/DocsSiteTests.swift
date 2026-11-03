import Foundation
import Testing
@testable import AirSQL

// AirSQL Help (docs/, the GitHub Pages site) agrees with the app: the shortcuts page is the commands table's.
@MainActor
struct DocsSiteTests {
    /// docs/shortcuts.md lists every command that has a shortcut, in `Commands.all`'s order, hidden ones (F9) too.
    @Test func theShortcutsPageListsEveryShortcut() throws {
        let page = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/shortcuts.md"),
            encoding: .utf8)
        let rows = Commands.all.filter { !$0.key.isEmpty }.map { "| \($0.title) | \($0.shortcut) |" }
        let table = (["| Command | Shortcut |", "|---|---|"] + rows).joined(separator: "\n") + "\n"
        #expect(page.contains(table), "docs/shortcuts.md's table should be the commands table's:\n\(table)")
    }
}
