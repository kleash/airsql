import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// The SQL editor's code insight, through the harness: underlines by severity, Option-Return's fixes, the Code menu.
extension AppTests {
    @MainActor @Suite struct InsightAppTests {
        /// An editor on `text`, read with the test schema.
        func editor(_ text: String) async throws -> SQLEditorView {
            let (_, _, console) = try await ConsoleAppTests.console()
            let editor = try #require(console.editor)
            let context = (snapshot: Optional(InspectionTests.snapshot()), database: Optional("shop"), changed: Set<String>())
            editor.nameContext = { context }
            editor.setText(text)
            editor.check()
            #expect(await eventually(timeout: 10) { editor.insight?.text == text })
            return editor
        }

        @Test func severitiesLookDifferent() async throws {
            let editor = try await editor("DELETE FROM nosuch; SELECT id FROM orders ORDER BY id ASC")
            let layout = try #require(editor.layoutManager)
            func colour(_ index: Int) -> NSColor? { layout.temporaryAttribute(.underlineColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor }
            #expect(colour(1) == .statusWarning)
            #expect(colour(14) == .statusBad)
            #expect(colour(54) == .tertiaryLabelColor)
            #expect(colour(9) == nil)
        }

        @Test func aFixIsOneUndo() async throws {
            let text = "SELECT totl FROM orders"
            let editor = try await editor(text)
            let analysis = try #require(editor.insight)
            let fix = try #require(editor.contextActions(at: 8, in: analysis).first { $0.title == "Change to “total”" })
            editor.apply(fix)
            #expect(editor.string == "SELECT total FROM orders")
            editor.undo(nil)
            #expect(editor.string == text)
        }

        @Test func severalEditsAreOneUndoToo() async throws {
            let text = "SELECT o.id FROM orders o WHERE o.total > 1"
            let editor = try await editor(text)
            #expect(editor.rename(at: 7, to: "x", in: try #require(editor.insight)) == nil)
            #expect(editor.string == "SELECT x.id FROM orders x WHERE x.total > 1")
            editor.undo(nil)
            #expect(editor.string == text)
        }

        @Test func goesToADeclaration() async throws {
            let editor = try await editor("SELECT o.id FROM orders o")
            editor.setSelectedRange(NSRange(location: 7, length: 0))
            editor.goToDeclaration(nil)
            #expect(await eventually(timeout: 5) { editor.selectedRange() == NSRange(location: 24, length: 1) })
        }

        @Test func aTableGoesToTheConsole() async throws {
            let editor = try await editor("SELECT 1 FROM orders")
            var opened: SQLSymbol?
            editor.insightHooks.openObject = { opened = $0 }
            editor.setSelectedRange(NSRange(location: 15, length: 0))
            editor.goToDeclaration(nil)
            #expect(await eventually(timeout: 5) { opened?.name == "orders" })
        }

        @Test func usagesAreTinted() async throws {
            let editor = try await editor("SELECT o.id FROM orders o WHERE o.id = 1")
            editor.setSelectedRange(NSRange(location: 7, length: 0))
            editor.markUsages()
            #expect(editor.usageMarks.count == 3)
            editor.setSelectedRange(NSRange(location: 39, length: 0))
            editor.markUsages()
            #expect(editor.usageMarks.isEmpty)
        }

        @Test func blockWordsPairUp() async throws {
            let text = "DELIMITER $$\nCREATE PROCEDURE p() BEGIN IF 1 THEN SELECT CASE WHEN 1 THEN 2 END; END IF; END$$"
            let editor = try await editor(text)
            editor.setSelectedRange(NSRange(location: (text as NSString).range(of: "BEGIN").location + 1, length: 0))
            editor.markUsages()
            #expect(editor.usageMarks.map(\.length) == [5, 3] && NSMaxRange(editor.usageMarks[1]) == (text as NSString).range(of: "$$", options: .backwards).location)
            editor.setSelectedRange(NSRange(location: (text as NSString).range(of: "END IF").location + 1, length: 0))
            editor.markUsages()
            #expect(editor.usageMarks.map(\.length) == [2, 6])
        }

        @Test func notesSayWhatsAtTheCaret() async throws {
            let editor = try await editor("SELECT id FROM orders; SELECT LEFT('a', 1) FROM orders WHERE total = NULL")
            editor.setSelectedRange(NSRange(location: 16, length: 0))
            editor.quickDocumentation(nil)
            #expect(await eventually(timeout: 5) { editor.shownNote.hasPrefix("orders\nTable in shop") })
            editor.setSelectedRange(NSRange(location: 40, length: 0))
            editor.parameterInfo(nil)
            #expect(await eventually(timeout: 5) { editor.shownNote == "LEFT\ntext, length" })
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.nextProblem(nil)
            #expect(editor.selectedRange().location == 67 && editor.shownNote.contains("IS NULL"))
            editor.showProblem(nil)
            #expect(editor.shownNote.contains("IS NULL"))
            editor.notePopover?.close()
        }

        @Test func previewsWithoutChangingTheText() async throws {
            let text = "UPDATE orders SET total = 1 WHERE id = 2"
            let editor = try await editor(text)
            var sql: String?
            editor.insightHooks.previewRows = { sql = $0 }
            editor.previewAffectedRows(nil)
            #expect(await eventually(timeout: 5) { sql?.hasPrefix("SELECT 1 AS `new total`, orders.* FROM orders") == true })
            #expect(editor.string == text)
        }

        @Test func aReadOnlyConnectionMarksWrites() async throws {
            let editor = try await editor("SELECT 1")
            editor.insightHooks.isReadOnly = { true }
            editor.setText("DELETE FROM orders WHERE id = 1")
            editor.check()
            #expect(await eventually(timeout: 5) { editor.problems.contains { $0.code == "readOnlyWrite" } })
        }

        @Test func aSettingTurnsACheckOff() async throws {
            let editor = try await editor("SELECT 1")
            editor.insightHooks.disabledInspections = { ["noWhere"] }
            editor.setText("DELETE FROM orders")
            editor.check()
            #expect(await eventually(timeout: 5) { editor.insight?.text == "DELETE FROM orders" })
            #expect(editor.problems.isEmpty)
        }

        @Test func theStripeMarksProblems() async throws {
            let editor = try await editor("SELECT 1\nFROM nosuch")
            let stripe = try #require(editor.problemStripe)
            #expect(!stripe.isHidden && stripe.toolTip?.hasPrefix("1 error, 0 warnings") == true)
        }

        @Test func theCodeMenuIsThere() throws {
            let titles = MainMenu.build().items.first { $0.title == "Query" }?.submenu?.items.first { $0.title == "Code" }?.submenu?.items.map(\.title)
            #expect(titles?.contains("Fixes and Actions…") == true && titles?.contains("Preview Rows to Change") == true)
        }
    }
}
