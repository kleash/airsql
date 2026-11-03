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
            let (_, harness, tab) = try await Tab.tab("customers", session: session)
            tab.grid.selection.select(GridPosition(row: 0, column: 8))
            let items = tab.insertValueItems()
            #expect(items.map(\.title).starts(with: ["DEFAULT", "NOW()", "UTC_TIMESTAMP()"]))
            tab.insertCellValue(items[1])
            #expect(tab.source?.cell(0, 8) == .placeholder("ƒ NOW()") && tab.source?.mark(0, 8) == .edited)
            tab.addRow(nil)
            let new = 2
            #expect(tab.source?.cell(new, 0) == .placeholder("auto") && tab.source?.cell(new, 8) == .placeholder("default"))
            #expect(tab.source?.cell(new, 15) == .placeholder("generated") && tab.source?.cell(new, 3) == .null)
            // The value panel says what the server puts there, not NULL.
            tab.viewer.toggleValuePanel(nil)
            tab.grid.selection.select(GridPosition(row: new, column: 0))
            #expect(tab.viewer.valuePanel?.footer.stringValue == "auto · the server sets it when you apply")
            tab.grid.selection.select(GridPosition(row: new, column: 3))
            #expect(tab.viewer.valuePanel?.footer.stringValue == "NULL")
            tab.viewer.toggleValuePanel(nil)
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
            // Edited again, it is read again after the next Apply; deleted, it goes.
            session.readBack?[1] = "cy@example.com"
            tab.keep(.text("cy@example.com"), row: 2, column: 1)
            tab.applyChanges(nil)
            _ = await eventually(timeout: 10) {
                try? await Task.sleep(nanoseconds: 20_000_000)
                return tab.loading == nil && tab.source?.changes.isEmpty == true
            }
            #expect(session.statements.contains("UPDATE `airsql_fixture`.`customers` SET `email` = 'cy@example.com' WHERE `id` = 42"))
            #expect(tab.source?.saved.count == 1 && tab.source?.cell(2, 1) == .text("cy@example.com") && tab.source?.mark(2, 1) == GridMark.none)
            tab.grid.selection.selectRow(2)
            tab.deleteRows(nil)
            tab.applyChanges(nil)
            // Deleting a customer sets orders' customer_id to NULL: the preview says so first.
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await call(harness, "press", ["title": "Apply"])
            _ = await eventually(timeout: 10) {
                try? await Task.sleep(nanoseconds: 20_000_000)
                return tab.loading == nil && tab.source?.changes.isEmpty == true
            }
            #expect(tab.source?.saved.isEmpty == true && tab.grid.rowCount == 2, "\(session.statements.suffix(6))")
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
            // Not being edited (the JSON tree shows), formatting keeps the value at once.
            tab.viewer.toggleValuePanel(nil)
            tab.viewer.toggleValuePanel(nil)
            let fresh = try #require(tab.viewer.valuePanel)
            #expect(fresh.mode == .json)
            fresh.formatJSON(nil)
            #expect(fresh.mode == .text && !fresh.edited && tab.source?.cell(0, 10) == .text("{\n  \"theme\": \"dark\"\n}"))
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
            #expect(session.statements.contains("SELECT `id`, `email` FROM `airsql_fixture`.`customers` ORDER BY `email` LIMIT 100"))
            lookup.table.selectRowIndexes([1], byExtendingSelection: false)
            lookup.choose(nil)
            #expect(tab.source?.cell(0, 1) == .text("9") && tab.source?.mark(0, 1) == .edited)
            // Typing searches the label or the key on the server.
            lookup.run("cy", after: 0)
            await ready { session.statements.last?.contains("LIKE") != true }
            #expect(session.statements.last?.contains("WHERE `email` LIKE '%cy%' ESCAPE '!' ORDER BY `email`") == true)
            tab.revertAllChanges(nil)
        }

        @Test func foreignKeysShowTheirRowsLabelAndVirtualOnesLeadToRows() async throws {
            let session = FakeTableSession()
            let (main, harness, tab) = try await Tab.tab(session: session)
            // customer_id's cells ask for their labels as they're drawn: one query for the values on screen (and one for
            // parent_id's, which refers to orders).
            tab.grid.needsDisplay = true
            tab.grid.displayIfNeeded()
            _ = (tab.label(0, 1), tab.label(2, 1))
            await ready { tab.readingLabels != nil || tab.loading != nil }
            #expect(tab.label(0, 1) == "ann@example.com" && tab.label(2, 1) == "cy@example.org")
            #expect(tab.label(1, 1) == nil && tab.label(0, 2) == nil)
            #expect(session.labels.filter { $0.hasPrefix("SELECT `id`, `email` FROM `airsql_fixture`.`customers` WHERE `id` IN (") }.count == 1,
                    "\(session.labels)")
            tab.grid.needsDisplay = true
            tab.grid.displayIfNeeded()

            // number becomes a virtual foreign key to a table's key: a drop-down and Related Rows follow it.
            let column = 3, store = TableViewSettingsStore.shared
            tab.grid.selection.select(GridPosition(row: 0, column: column))
            #expect(tab.foreignKey(column) == nil && tab.keyState(of: Commands.removeVirtualKey.action).0 == false)
            tab.addVirtualKey(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            let sheet = try #require(main.window?.attachedSheet)
            let popup = try #require(find(NSPopUpButton.self, id: "virtualKey.table", in: sheet.contentView!))
            popup.selectItem(withTitle: "customers (id)")
            _ = await call(harness, "press", ["title": "Add"])
            let key = try #require(tab.foreignKey(column))
            #expect(key.referencedTable == "customers" && key.referencedColumns == ["id"] && key.name == "virtual number")
            #expect(store.virtualKeys(connection: tab.context.connection.id)["airsql_fixture"]?["orders"] == [key])
            #expect(tab.keyState(of: Commands.removeVirtualKey.action).0 && tab.keyState(of: Commands.addVirtualKey.action).0)
            tab.removeVirtualKey(nil)
            #expect(tab.foreignKey(column) == nil && tab.settings.virtualKeys.isEmpty)

            // Use as Label on a column picks what the keys referring to the table show (its first text column until then).
            #expect(tab.isLabel(2))
            tab.grid.selection.select(GridPosition(row: 0, column: 4))
            tab.useAsLabel(nil)
            #expect(tab.isLabel(4) && !tab.isLabel(2))
            #expect(store.settings(connection: tab.context.connection.id, database: "airsql_fixture", table: "orders").labelColumn == "total")
            tab.useAsLabel(nil)
            #expect(!tab.isLabel(4) && tab.isLabel(2))
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

extension AppTests.ScreenshotTests {
    /// Grid editing: Insert Value's ƒ NOW() and a new row's placeholders, the value panel formatting JSON, an editor
    /// saying why it refuses a value, a SET's checklist and a foreign key's drop-down.
    @Test func gridEditing() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let (main, harness, tab) = try await AppTests.GridDataAppTests.tab("customers", session: .customers(),
                                                                             size: NSSize(width: 1180, height: 720))
            main.window?.appearance = NSAppearance(named: appearance)
            onScreen(main.window)
            tab.grid.selection.select(GridPosition(row: 0, column: 8))
            tab.insertCellValue(tab.insertValueItems()[1])
            tab.grid.selection.select(GridPosition(row: 1, column: 6))
            tab.grid.insertText("12.5")
            tab.grid.endEditing(commit: true)
            tab.addRow(nil)
            tab.viewer.toggleValuePanel(nil)
            tab.grid.selection.select(GridPosition(row: 0, column: 10))
            tab.viewer.valuePanel?.formatJSON(nil)
            main.window?.displayIfNeeded()
            try await save(harness, "grid-edit-\(suffix)")
            tab.viewer.valuePanel?.putBack(nil)
            tab.viewer.toggleValuePanel(nil)

            tab.grid.selection.select(GridPosition(row: 0, column: 6))
            main.window?.makeFirstResponder(tab.grid)
            tab.grid.insertText("12.345")
            tab.grid.endEditing(commit: true)
            main.window?.displayIfNeeded()
            try await save(harness, "grid-edit-problem-\(suffix)")
            tab.grid.endEditing(commit: false)

            tab.grid.beginEditing(at: GridPosition(row: 0, column: 5))
            try await save(harness, "grid-edit-set-\(suffix)")
            tab.checklist?.cancel(nil)
            tab.revertAllChanges(nil)
            main.window?.orderOut(nil)

            let (orders, ordersHarness, ordersTab) = try await AppTests.GridDataAppTests.tab(size: NSSize(width: 1180, height: 720))
            orders.window?.appearance = NSAppearance(named: appearance)
            onScreen(orders.window)
            ordersTab.grid.beginEditing(at: GridPosition(row: 0, column: 1))
            await ready { ordersTab.lookup?.rows.isEmpty == true }
            try await save(ordersHarness, "grid-edit-lookup-\(suffix)")
            ordersTab.lookup?.popover.close()
            orders.window?.orderOut(nil)
        }
    }
}

extension AppTests.HelpTests {
    /// The editors' popovers and the value panel's actions say what each control does.
    @Test func everyGridEditorSaysWhatItDoes() async throws {
        let (main, _, tab) = try await AppTests.GridDataAppTests.tab("customers", session: .customers())
        tab.viewer.toggleValuePanel(nil)
        tab.grid.selection.select(GridPosition(row: 0, column: 10))
        var missing = unexplained(try #require(tab.viewer.valuePanel?.actions.menu), path: ["value panel"])
        missing += unexplained([try #require(main.window)], where: "value panel")
        main.window?.orderFront(nil)
        tab.grid.beginEditing(at: GridPosition(row: 0, column: 5))
        missing += unexplained([try #require(tab.checklist?.popover.contentViewController?.view.window)], where: "SET checklist")
        tab.checklist?.cancel(nil)
        missing += unexplained(tab.pickList(["new", "active"], row: 0, column: 4), path: ["ENUM"])
        missing += unexplained(MainMenu.submenu("Insert Value", tab.insertValueItems()).submenu!, path: ["Insert Value"])
        main.window?.orderOut(nil)
        let (orders, _, ordersTab) = try await AppTests.GridDataAppTests.tab()
        orders.window?.orderFront(nil)
        ordersTab.grid.beginEditing(at: GridPosition(row: 0, column: 1))
        await ready { ordersTab.lookup?.rows.isEmpty == true }
        missing += unexplained([try #require(ordersTab.lookup?.popover.contentViewController?.view.window)], where: "lookup")
        ordersTab.lookup?.popover.close()
        orders.window?.orderOut(nil)
        #expect(missing.isEmpty, "\(missing)")
    }
}

extension AppTests.LayoutTests {
    /// The editors' popovers fit their text, in light and dark.
    @Test func gridEditorsAreTidy() async throws {
        var problems: [String] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let (main, _, tab) = try await AppTests.GridDataAppTests.tab("customers", session: .customers())
            main.window?.appearance = NSAppearance(named: appearance)
            main.window?.orderFront(nil)
            tab.grid.beginEditing(at: GridPosition(row: 0, column: 5))
            let checklist = try #require(tab.checklist?.popover.contentViewController?.view)
            checklist.layoutSubtreeIfNeeded()
            problems += layoutProblems(checklist, where: "\(appearance) SET checklist")
            tab.checklist?.cancel(nil)
            tab.grid.selection.select(GridPosition(row: 0, column: 6))
            tab.grid.insertText("12.345")
            tab.grid.endEditing(commit: true)
            tab.viewer.toggleValuePanel(nil)
            main.window?.contentView?.layoutSubtreeIfNeeded()
            problems += layoutProblems(try #require(tab.viewer.valuePanel), where: "\(appearance) value panel")
            tab.grid.endEditing(commit: false)
            main.window?.orderOut(nil)
        }
        #expect(problems.isEmpty, "\(problems)")
    }
}
