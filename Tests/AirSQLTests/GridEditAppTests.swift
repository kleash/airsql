import AppKit
import CMariaDB
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

extension FakeTableSession {
    /// The recorded customers table's rows: an ENUM, a SET, DECIMAL, BIT, TIMESTAMP, DATETIME(3), JSON, defaults and
    /// generated columns.
    static func customers() -> FakeTableSession {
        let session = FakeTableSession()
        let names = ["id", "email", "name", "note", "status", "flags", "balance", "bits", "created", "updated", "prefs", "path", "token",
                     "word", "secret", "email_domain", "name_upper"]
        session.columns = names.map { .init(name: $0, type: ["id", "secret"].contains($0) ? MYSQL_TYPE_LONG : MYSQL_TYPE_VAR_STRING) }
        session.rows = [
            ["1", "ann@example.com", "Ann", nil, "new", "a", "10.00", "101", "2026-11-03 10:00:00", "2026-11-03 10:00:00.000",
             "{\"theme\": \"dark\"}", nil, "6ccd780c-baba-1026-9564-5b8c656024db", "w", nil, "example.com", "ANN"],
            ["2", "bo@example.org", "Bo", "two\nlines", "active", nil, "0.50", "000", "2026-11-04 11:00:00", nil, nil, nil,
             "7ccd780c-baba-1026-9564-5b8c656024db", "x", nil, "example.org", "BO"],
        ]
        return session
    }
}

extension AppTests {
    /// Grid editing's second half (grid-spec §5): typed editors, Insert Value, placeholders, paste, the value panel,
    /// foreign key drop-downs, reading new rows back after Apply, and what Quit asks about.
    @MainActor @Suite struct GridEditAppTests {
        typealias Tab = GridDataAppTests

        @Test func editsAreCheckedByTypeAndTheEditorSaysWhy() async throws {
            let session = FakeTableSession.customers()
            let (_, _, tab) = try await Tab.tab("customers", session: session)
            #expect(tab.editContext?.sqlMode.contains("NO_ZERO_DATE") == true)
            // A DECIMAL(10,2) keeps two digits after the point: the editor stays open and says so.
            tab.grid.selection.select(GridPosition(row: 0, column: 6))
            tab.grid.insertText("12.345")
            #expect(!tab.grid.endEditing(commit: true) && tab.grid.editor != nil && tab.source?.mark(0, 6) == GridMark.none)
            tab.grid.editor?.stringValue = "12.34"
            #expect(tab.grid.endEditing(commit: true) && tab.source?.cell(0, 6) == .text("12.34"))
            // ↑ steps the part of a date under the cursor; Esc leaves the cell as it was.
            tab.grid.beginEditing(at: GridPosition(row: 0, column: 8))
            let editor = try #require(tab.grid.editor), field = try #require(editor.currentEditor() as? NSTextView)
            field.setSelectedRange(NSRange(location: 9, length: 0))
            #expect(editor.control(editor, textView: field, doCommandBy: #selector(NSResponder.moveUp(_:))))
            #expect(editor.stringValue == "2026-11-04 10:00:00" && field.selectedRange() == NSRange(location: 8, length: 2))
            tab.grid.endEditing(commit: false)
            #expect(tab.source?.mark(0, 8) == GridMark.none)
            // Typing over cells of several types gives each one what its column takes, as one step for undo.
            tab.grid.selection.select(GridPosition(row: 0, column: 2))
            tab.grid.selection.select(GridPosition(row: 1, column: 6), extend: true)
            tab.grid.insertText("7")
            #expect(tab.grid.endEditing(commit: true))
            #expect(tab.source?.cell(1, 2) == .text("7") && tab.source?.cell(1, 6) == .text("7") && tab.source?.cell(0, 4) == .text("new"))
            tab.undo(nil)
            #expect(tab.source?.cell(1, 2) == .text("Bo") && tab.source?.cell(0, 6) == .text("12.34"))
            tab.revertAllChanges(nil)
        }

        @Test func enumAndSetPickFromTheirMembers() async throws {
            let (_, _, tab) = try await Tab.tab("customers", session: .customers())
            let menu = tab.pickList(["new", "active", "gone"], row: 0, column: 4)
            #expect(menu.items.map(\.title) == ["new", "active", "gone"] && menu.items[0].state == .on)
            tab.grid.selection.select(GridPosition(row: 0, column: 4))
            tab.pickMember(menu.items[2])
            #expect(tab.source?.cell(0, 4) == .text("gone"))
            // SET: a checklist under the cell; Set keeps the ticked members in the column's order.
            tab.grid.selection.select(GridPosition(row: 0, column: 5))
            #expect(tab.dataGrid(tab.grid, edit: 0, column: 5, typed: nil) && tab.grid.editor == nil)
            let checklist = try #require(tab.checklist)
            #expect(checklist.boxes.map(\.title) == ["a", "b"] && checklist.boxes.map(\.state) == [.on, .off])
            checklist.boxes[1].state = .on
            checklist.keep(nil)
            #expect(tab.source?.cell(0, 5) == .text("a,b"))
            // Typing still edits as text, checked against the members.
            tab.grid.insertText("c")
            #expect(!tab.grid.endEditing(commit: true))
            tab.grid.endEditing(commit: false)
            tab.revertAllChanges(nil)
        }

        @Test func insertValueAndNewRowsShowWhatTheServerFillsIn() async throws {
            let session = FakeTableSession.customers()
            let (_, _, tab) = try await Tab.tab("customers", session: session)
            tab.grid.selection.select(GridPosition(row: 0, column: 8))
            let items = tab.insertValueItems()
            #expect(items.map(\.title).starts(with: ["DEFAULT", "NOW()", "UTC_TIMESTAMP()"]))
            tab.insertCellValue(items[1])
            #expect(tab.source?.cell(0, 8) == .placeholder("ƒ NOW()") && tab.source?.mark(0, 8) == .edited)
            tab.addRow(nil)
            let new = 2
            #expect(tab.source?.cell(new, 0) == .placeholder("auto") && tab.source?.cell(new, 8) == .placeholder("default"))
            #expect(tab.source?.cell(new, 15) == .placeholder("generated") && tab.source?.cell(new, 3) == .null)
            tab.grid.selection.select(GridPosition(row: new, column: 1))
            tab.grid.insertText("cy@example.net")
            #expect(tab.grid.endEditing(commit: true))
            // Apply reads the new row back by its AUTO_INCREMENT key: it stays where it was, with what the server put in.
            session.insertID = 42
            session.readBack = ["42", "cy@example.net", "it's", nil, "new", nil, "0.00", "101", "2026-11-05 09:00:00", nil, nil, nil,
                                "8ccd780c-baba-1026-9564-5b8c656024db", "NULL", nil, "example.net", "IT'S"]
            tab.applyChanges(nil)
            await ready { tab.loading != nil }
            #expect(session.statements.contains("UPDATE `airsql_fixture`.`customers` SET `created` = NOW() WHERE `id` = 1"))
            #expect(session.statements.contains("INSERT INTO `airsql_fixture`.`customers` (`email`) VALUES ('cy@example.net')"))
            #expect(session.statements.contains { $0.hasSuffix("FROM `airsql_fixture`.`customers` WHERE `id` = 42") })
            await ready { tab.loading != nil }
            #expect(tab.source?.changes.isEmpty == true && tab.source?.saved.count == 1 && tab.grid.rowCount == 3)
            #expect(tab.source?.cell(2, 0) == .text("42") && tab.source?.rowKey(2) == ["42"] && tab.source?.canEdit(2, 1) == true)
        }

        @Test func pasteFillsCellsFromTheFocusedOneAndAddsRows() async throws {
            let (_, _, tab) = try await Tab.tab("customers", session: .customers())
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("Cy\tnote one\nDee\tNULL\nEve\t", forType: .string)
            tab.grid.selection.select(GridPosition(row: 1, column: 2))
            tab.paste(nil)
            #expect(tab.source?.cell(1, 2) == .text("Cy") && tab.source?.cell(1, 3) == .text("note one"))
            #expect(tab.grid.rowCount == 4 && tab.source?.cell(2, 2) == .text("Dee") && tab.source?.cell(2, 3) == .null)
            #expect(tab.source?.cell(3, 3) == .text("") && tab.source?.cell(3, 0) == .placeholder("auto"))
            tab.undo(nil)
            #expect(tab.source?.changes.isEmpty == true && tab.grid.rowCount == 2)
            // One value over several selected cells fills them all.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("active", forType: .string)
            tab.grid.selection.select(GridPosition(row: 0, column: 4))
            tab.grid.selection.select(GridPosition(row: 1, column: 4), extend: true)
            tab.paste(nil)
            #expect(tab.source?.cell(0, 4) == .text("active") && tab.source?.mark(1, 4) == GridMark.none)
            tab.pasteAsNewRows(nil)
            #expect(tab.grid.rowCount == 3 && tab.source?.cell(2, 4) == .text("active"))
            tab.revertAllChanges(nil)
        }

        @Test func theValuePanelEditsTheFocusedCell() async throws {
            let (main, _, tab) = try await Tab.tab("customers", session: .customers())
            tab.viewer.toggleValuePanel(nil)
            let panel = try #require(tab.viewer.valuePanel)
            // A long or multi-line value opens there instead of in the cell.
            tab.grid.beginEditing(at: GridPosition(row: 1, column: 3))
            #expect(tab.grid.editor == nil && main.window?.firstResponder === panel.text && panel.text.isEditable)
            panel.text.string = "three\nlines\nnow"
            panel.textDidChange(Notification(name: NSText.didChangeNotification))
            panel.keepValue(nil)
            #expect(tab.source?.cell(1, 3) == .text("three\nlines\nnow") && !panel.edited)
            // A value its column refuses stays in the panel, which says why.
            tab.grid.selection.select(GridPosition(row: 0, column: 6))
            panel.text.string = "lots"
            panel.textDidChange(Notification(name: NSText.didChangeNotification))
            panel.keepValue(nil)
            #expect(panel.edited && panel.footer.stringValue.hasPrefix("decimal(10,2) holds numbers") && tab.source?.mark(0, 6) == GridMark.none)
            panel.putBack(nil)
            #expect(!panel.edited && panel.text.string == "10.00")
            // JSON is formatted and compacted in place.
            tab.grid.selection.select(GridPosition(row: 0, column: 10))
            panel.formatJSON(nil)
            #expect(panel.text.string == "{\n  \"theme\": \"dark\"\n}" && panel.edited)
            panel.compactJSON(nil)
            panel.keepValue(nil)
            #expect(tab.source?.cell(0, 10) == .text("{\"theme\":\"dark\"}"))
            tab.revertAllChanges(nil)
        }

        @Test func aForeignKeyPicksItsRowFromADropDown() async throws {
            let session = FakeTableSession()
            let (_, _, tab) = try await Tab.tab(session: session)
            tab.grid.selection.select(GridPosition(row: 0, column: 1))
            #expect(tab.dataGrid(tab.grid, edit: 0, column: 1, typed: nil))
            let lookup = try #require(tab.lookup)
            await ready { lookup.rows.isEmpty }
            #expect(lookup.rows.map(\.key) == [["7"], ["9"]] && lookup.rows.map(\.label) == ["ann@example.com", "cy@example.org"])
            // Ordered by the label, which an index starts with; never the whole table.
            #expect(session.statements.last == "SELECT `id`, `email` FROM `airsql_fixture`.`customers` ORDER BY `email` LIMIT 100")
            lookup.table.selectRowIndexes([1], byExtendingSelection: false)
            lookup.choose(nil)
            #expect(tab.source?.cell(0, 1) == .text("9") && tab.source?.mark(0, 1) == .edited)
            // Typing searches the label or the key on the server.
            lookup.run("cy", after: 0)
            await ready { session.statements.last?.contains("LIKE") != true }
            #expect(session.statements.last?.contains("WHERE `email` LIKE '%cy%' ESCAPE '!' ORDER BY `email`") == true)
            tab.revertAllChanges(nil)
        }

        @Test func quitListsPendingChangesFirst() async throws {
            let (main, _, tab) = try await Tab.tab(session: FakeTableSession())
            #expect(main.unfinishedWork().isEmpty)
            tab.grid.selection.select(GridPosition(row: 0, column: 2))
            tab.setCellDefault(nil)
            #expect(main.unfinishedWork() == ["orders on Local: 1 pending change, kept for the next time you open the table"])
            tab.revertAllChanges(nil)
        }
    }
}
