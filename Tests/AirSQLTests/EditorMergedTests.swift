import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// Where the editor's lanes meet: problems against edits, marks against edits, the completion list against pastes,
/// Windows line ends against the line commands, and Format SQL off the main thread.
extension AppTests {
    @MainActor @Suite struct EditorMergedTests {
        private func editor(_ text: String) async throws -> SQLEditorView {
            let (main, _, console) = try await ConsoleAppTests.console()
            let editor = try #require(console.editor)
            main.window?.makeFirstResponder(editor)
            editor.setText(text)
            return editor
        }

        @Test func aFixWaitsForTheTextToBeReadAgain() async throws {
            let editor = try await editor("SELECT 1 FROM t WHERE a = NULL")
            let fix = SQLFix("Change", .edit([SQLEdit(range: 0..<6, text: "X")]))
            editor.check()
            #expect(await eventually(timeout: 5) { !editor.problemsOutOfDate })
            editor.runProblem = SQLProblem(range: 0..<6, message: "m", severity: .error, fixes: [fix])
            let analysis = SQLAnalysis(editor.string, snapshot: nil, database: nil)
            #expect(editor.contextActions(at: 3, in: analysis).contains { $0.title == "Change" })
            editor.replace(NSRange(location: 0, length: 0), with: "  ")
            editor.runProblem = SQLProblem(range: 0..<6, message: "m", severity: .error, fixes: [fix])
            #expect(!editor.contextActions(at: 3, in: analysis).contains { $0.title == "Change" }, "its range is of the old text")
            editor.goToProblem(SQLProblem(range: 900..<901, message: "m", severity: .error))  // past the end: no crash
        }

        @Test func lineCommandsKeepWindowsLineEnds() async throws {
            let editor = try await editor("a\r\nb\r\nc")
            editor.setSelectedRange(NSRange(location: 3, length: 0))
            editor.moveLineUp(nil)
            #expect(editor.string == "b\r\na\r\nc")
            editor.setText("a\r\nb\r\nc")
            editor.setSelectedRange(NSRange(location: 6, length: 0))
            editor.moveLineUp(nil)
            #expect(editor.string == "a\r\nc\r\nb", "the last line takes the break it needs")
            editor.setText("a\r\nb")
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.duplicateLine(nil)
            #expect(editor.string == "a\r\na\r\nb")
            editor.setText("b\r\na\r\n")
            editor.setSelectedRange(NSRange(location: 0, length: 6))
            editor.sortLines(nil)
            #expect(editor.string == "a\r\nb\r\n")
            editor.setText("a\r\nb\r\nc")
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.joinLines(nil)
            #expect(editor.string == "a b\r\nc")
        }

        @Test func marksGoWithoutLeavingTint() async throws {
            let editor = try await editor("SELECT aa, aa")
            let layout = try #require(editor.layoutManager)
            layout.addTemporaryAttribute(.backgroundColor, value: NSColor.red, forCharacterRange: NSRange(location: 11, length: 2))
            editor.usageMarks = [NSRange(location: 11, length: 2)]
            editor.replace(NSRange(location: 0, length: 0), with: "-")
            for place in 0..<(editor.string as NSString).length {
                #expect(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: place, effectiveRange: nil) == nil, "at \(place)")
            }
        }

        @Test func aPasteClosesTheCompletionList() async throws {
            let editor = try await editor("SELECT ab")
            editor.setSelectedRange(NSRange(location: 9, length: 0))
            editor.completions = { _, _ in (7..<9, [CompletionItem(kind: .column, text: "abc", label: "abc", detail: "")]) }
            editor.updateCompletion(force: true)
            #expect(editor.completionPopup?.isShown == true)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("x", forType: .string)
            editor.paste(nil)
            #expect(editor.completionPopup?.isShown == false)
        }

        @Test func completionWaitsForAskingInALongStatement() async throws {
            let long = "INSERT INTO t VALUES (" + String(repeating: "1,", count: SQLEditorView.longStatement) + "1)"
            let editor = try await editor(long + ";\nSELECT 1")
            editor.setSelectedRange(NSRange(location: 30, length: 0))
            #expect(!editor.completesWhileTyping)
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            #expect(editor.completesWhileTyping)
        }

        @Test func formatRunsAwayFromTheKeysAndKeepsEdits() async throws {
            let (main, _, console) = try await ConsoleAppTests.console()
            let editor = try #require(console.editor)
            main.window?.makeFirstResponder(editor)
            editor.setText("select 1 from t")
            console.formatSQL(nil)
            #expect(editor.isFormatting && editor.string == "select 1 from t", "not on this turn of the main thread")
            #expect(await eventually(timeout: 5) { editor.string == "SELECT 1\nFROM t" && !editor.isFormatting })
            // Text typed meanwhile wins.
            editor.setText("select 2 from t")
            console.formatSQL(nil)
            editor.insertText(" ", replacementRange: NSRange(location: 15, length: 0))
            #expect(await eventually(timeout: 5) { !editor.isFormatting })
            #expect(editor.string == "select 2 from t ")
        }
    }
}
