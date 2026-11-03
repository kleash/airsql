import AppKit
import CMariaDB
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// The data session of the table tab's tests: `orders` rows from memory, every statement recorded, and the rows each
/// write changes (1 unless `changed` says otherwise).
final class FakeTableSession: TableSession {
    var noBackslashEscapes = false
    var statements: [String] = []
    var rows: [[String?]] = [["1", "7", "EU", "100", "12.50", nil], ["2", nil, "US", "101", "99.00", "1"],
                             ["3", "9", "EU", "102", "0.10", nil]]
    var changed: (String) -> UInt64 = { _ in 1 }

    var columns: [ResultStore.Column] = [
        .init(name: "id", type: MYSQL_TYPE_LONGLONG), .init(name: "customer_id", type: MYSQL_TYPE_LONG),
        .init(name: "region", type: MYSQL_TYPE_STRING), .init(name: "number", type: MYSQL_TYPE_LONG),
        .init(name: "total", type: MYSQL_TYPE_NEWDECIMAL), .init(name: "parent_id", type: MYSQL_TYPE_LONGLONG),
    ]

    /// The view customer_emails's rows instead.
    static func emails() -> FakeTableSession {
        let session = FakeTableSession()
        session.columns = [.init(name: "id", type: MYSQL_TYPE_LONG), .init(name: "email", type: MYSQL_TYPE_VAR_STRING)]
        session.rows = [["1", "ann@example.com"], ["2", nil], ["3", "cy@example.org"]]
        return session
    }

    func query(_ sql: String, rowCap: Int) async throws -> [StatementResult] {
        statements.append(sql)
        func result(_ columns: [ResultStore.Column], _ values: [[String?]]) -> [StatementResult] {
            let store = ResultStore(columns: columns)
            for row in values { _ = store.append(row.map { $0.map { Array($0.utf8) } }) }
            return [StatementResult(rows: store, affectedRows: 0, insertID: 0, warnings: 0, info: nil, duration: 0)]
        }
        if sql.contains(" GROUP BY ") {
            return result([.init(name: "v", type: MYSQL_TYPE_STRING), .init(name: "n", type: MYSQL_TYPE_LONGLONG)], [["EU", "2"], ["US", "1"]])
        }
        if sql.hasPrefix("SELECT TABLE_ROWS") || sql.hasPrefix("SELECT COUNT(*)") {
            return result([.init(name: "n", type: MYSQL_TYPE_LONGLONG)], [[String(rows.count)]])
        }
        if sql.hasPrefix("SELECT") { return result(columns, rows) }
        let affected = ["START TRANSACTION", "COMMIT", "ROLLBACK"].contains(sql) ? 0 : changed(sql)
        return [StatementResult(rows: nil, affectedRows: affected, insertID: 0, warnings: 0, info: nil, duration: 0)]
    }

    func stream(_ sql: String, batchRows: Int, batch: @escaping (ResultStore) throws -> Void) async throws {
        statements.append(sql)
    }
}

extension AppTests {
    @MainActor @Suite struct GridDataAppTests {
        /// A window with a table tab on `table` of the recorded fixture, its rows from a fake session.
        static func tab(_ table: String = "orders", session: FakeTableSession = FakeTableSession(), size: NSSize = MainWindowController.defaultSize)
            async throws -> (MainWindowController, AgentServer, TableDataController) {
            let connection = SavedConnection(name: "Local", host: "127.0.0.1", user: "app")
            let model = testModel([connection])
            let (main, harness) = appWindow(model, size: size)
            let context = try await recordedEditorContext(connection)
            let controller = TableDataController(model: model, context: context, database: "airsql_fixture", table: table)
            controller.openSession = { session }
            main.select(main.open(controller, title: table, connection: connection.id))
            main.window?.layoutIfNeeded()
            await ready { controller.loading != nil || (controller.source == nil && controller.problem == nil) }
            return (main, harness, controller)
        }

        @Test func showsTheRowsAndSaysWhereFilteringRuns() async throws {
            let session = FakeTableSession()
            let (main, _, tab) = try await Self.tab(session: session)
            #expect(tab.grid.rowCount == 3 && tab.source?.cell(1, 2) == .text("US"))
            #expect(tab.bar.scope.text == "On server · all rows" && tab.status.rows.stringValue == "3 rows")
            #expect(session.statements.first?.hasSuffix("FROM `airsql_fixture`.`orders` ORDER BY `id` ASC LIMIT 1000") == true)
            #expect(tab.notice.isHidden && !tab.isEdited && main.selectedTab?.title == "orders")

            tab.applyFilter("WHERE region = 'EU'")
            await ready { tab.loading != nil }
            #expect(session.statements.last?.contains(" WHERE region = 'EU' ORDER BY `id` ASC") == true)
            #expect(tab.bar.scope.text == "On server · filtered" && tab.settings.recentFilters == ["region = 'EU'"])

            // Searching the loaded rows only filters here, without a query.
            let sent = session.statements.count
            tab.bar.searchField.stringValue = "us"
            tab.search("us", loadedOnly: true)
            #expect(session.statements.count == sent && tab.grid.rowCount == 1)
            #expect(tab.bar.scope.text == "Local · 1 of 3 loaded rows")
        }

        @Test func editsWaitForApplyWhichRunsThemInOneTransaction() async throws {
            let session = FakeTableSession()
            let (main, _, tab) = try await Self.tab(session: session)
            // Typing over two selected cells sets both (multi-cell edit).
            tab.grid.selection.select(GridPosition(row: 0, column: 4))
            tab.grid.selection.select(GridPosition(row: 1, column: 4), extend: true)
            tab.grid.insertText("5")
            tab.grid.endEditing(commit: true)
            #expect(tab.source?.mark(0, 4) == .edited && tab.source?.mark(1, 4) == .edited && tab.source?.cell(1, 4) == .text("5"))
            #expect(!tab.notice.isHidden && tab.notice.text.stringValue.hasPrefix("2 pending changes: 2 edited rows"))
            #expect(tab.isEdited)
            tab.grid.selection.selectRow(2)
            tab.deleteRows(nil)
            #expect(tab.source?.mark(2, 0) == .deleted)
            // A Production-like preview isn't asked for here, but deleting shows the SQL first only with a warning: none.
            tab.applyChanges(nil)
            await ready { tab.loading != nil }
            #expect(session.statements.suffix(6).first == "START TRANSACTION")
            #expect(session.statements.contains("DELETE FROM `airsql_fixture`.`orders` WHERE `id` IN (3)"))
            #expect(session.statements.contains("UPDATE `airsql_fixture`.`orders` SET `total` = 5 WHERE `id` = 1"))
            #expect(session.statements.contains("COMMIT"))
            await ready { tab.loading != nil }
            #expect(tab.source?.changes.isEmpty == true && tab.notice.isHidden && !tab.isEdited)
            _ = main
        }

        @Test func aMismatchRollsBackAndPointsAtTheRow() async throws {
            let session = FakeTableSession()
            session.changed = { $0.hasSuffix("`id` = 2") ? 0 : 1 }
            let (main, harness, tab) = try await Self.tab(session: session)
            tab.source?.set(.text("x"), row: 0, column: 2)
            tab.source?.set(.text("y"), row: 1, column: 2)
            tab.changesDidChange()
            tab.applyChanges(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(session.statements.last == "ROLLBACK")
            #expect(main.window?.attachedSheet != nil)
            #expect(tab.grid.selection.containsRow(1) && tab.source?.changes.rowCount == 2)
            _ = await call(harness, "press", ["title": "OK"])
        }

        @Test func previewShowsTheSQLAndWarnsBeforeApply() async throws {
            let (main, harness, tab) = try await Self.tab()
            tab.source?.set(.null, row: 0, column: 1)
            tab.source?.changes.addRow(["region": .text("EU"), "number": .text("7"), "total": .text("1")])
            tab.changesDidChange()
            #expect(tab.grid.rowCount == 4 && tab.source?.mark(3, 0) == .inserted)
            tab.previewChanges(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            let sql = shownText("preview.sql", in: main.window?.attachedSheet) ?? ""
            #expect(sql.contains("UPDATE `airsql_fixture`.`orders` SET `customer_id` = NULL WHERE `id` = 1;"))
            #expect(sql.contains("INSERT INTO `airsql_fixture`.`orders` (`region`, `number`, `total`) VALUES ('EU', 7, 1);"))
            #expect(shownText("preview.heading", in: main.window?.attachedSheet) == "Apply 2 changes to airsql_fixture.orders?")
            _ = await call(harness, "press", ["title": "Cancel"])
            #expect(tab.source?.changes.rowCount == 2)
        }

        @Test func copyAsBecomesTheCopyFormat() async throws {
            let (_, _, tab) = try await Self.tab()
            tab.grid.selection.select(GridPosition(row: 0, column: 0))
            tab.grid.selection.select(GridPosition(row: 1, column: 2), extend: true)
            tab.copy(nil)
            #expect(NSPasteboard.general.string(forType: .string) == "1\t7\tEU\n2\tNULL\tUS\n")
            let item = NSMenuItem()
            item.representedObject = CopyFormat.jsonLines.rawValue
            tab.copyAs(item)
            tab.copy(nil)
            #expect(NSPasteboard.general.string(forType: .string)
                    == "{\"id\": 1, \"customer_id\": 7, \"region\": \"EU\"}\n{\"id\": 2, \"customer_id\": null, \"region\": \"US\"}\n")
            GridCopy.format = .tsv
        }

        @Test func exportsRowsToTheClipboardOrAFile() async throws {
            let (main, harness, tab) = try await Self.tab()
            tab.exportRows(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(main.window?.attachedSheet?.title == "Export Rows of orders")
            _ = await call(harness, "press", ["id": "export.copy"])
            #expect(NSPasteboard.general.string(forType: .string)?.hasPrefix(
                "id,customer_id,region,number,total,parent_id\n1,7,EU,100,12.50,NULL\n2,NULL,US,101,99.00,1\n") == true)
            #expect(main.window?.attachedSheet == nil)
            // Excel and text files are written as the rows come.
            let folder = URL(fileURLWithPath: try scratch())
            let columns = try #require(tab.source?.columns)
            for (format, name) in [(CopyFormat?.none, "rows.xlsx"), (CopyFormat?.some(.insert), "rows.sql")] {
                let output = try ExportOutput(url: folder.appendingPathComponent(name), format: format, columns: columns,
                                              database: "airsql_fixture", table: "orders", options: CopyOptions(headers: true))
                try output.write([["1", nil, "EU", "1", "2.50", nil]])
                try output.write([["2", "3", "US", "2", "1", nil]])
                try output.finish()
            }
            let sql = try String(contentsOf: folder.appendingPathComponent("rows.sql"), encoding: .utf8)
            #expect(sql.components(separatedBy: "\n").filter { $0.hasPrefix("INSERT INTO `airsql_fixture`.`orders`") }.count == 2)
            let size = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("rows.xlsx").path)[.size] as? Int
            #expect((size ?? 0) > 500)
        }

        @Test func filterByTickingValuesCountedOnTheServer() async throws {
            let session = FakeTableSession()
            let (main, harness, tab) = try await Self.tab(session: session)
            tab.grid.selection.select(GridPosition(row: 0, column: 2))
            tab.filterByValues(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await eventually(timeout: 10) { session.statements.contains { $0.contains(" GROUP BY ") } }
            #expect(session.statements.last == "SELECT `region`, COUNT(*) FROM `airsql_fixture`.`orders` GROUP BY `region` "
                    + "ORDER BY COUNT(*) DESC LIMIT 1000")
            _ = await eventually(timeout: 10) { await call(harness, "press", ["title": "US  (1)"]).error == nil }
            _ = await call(harness, "press", ["id": "values.ok"])
            #expect(main.window?.attachedSheet == nil && tab.bar.filterText == "`region` IN ('EU')")
            await ready { tab.loading != nil }
            #expect(session.statements.last?.contains(" WHERE `region` IN ('EU') ORDER BY") == true)
        }

        @Test func findAndReplaceInTheLoadedRows() async throws {
            let (_, _, tab) = try await Self.tab()
            let replace = NSMenuItem()
            replace.tag = NSTextFinder.Action.showReplaceInterface.rawValue
            tab.performTextFinderAction(replace)
            #expect(!tab.findBar.isHidden && !tab.findBar.replaceField.isHidden)
            tab.findBar.findField.stringValue = "eu"
            tab.findChanged()
            #expect(tab.findBar.count.stringValue == "2 matching")
            tab.findMatch(forward: true)
            #expect(tab.grid.selection.cursor == GridPosition(row: 0, column: 2) && tab.findBar.count.stringValue == "1 of 2")
            tab.findMatch(forward: true)
            #expect(tab.grid.selection.cursor == GridPosition(row: 2, column: 2))
            // Filter Rows hides the loaded rows without a match.
            tab.findBar.options.item(at: 4)?.state = .on
            tab.findChanged()
            #expect(tab.grid.rowCount == 2 && tab.bar.scope.text == "Local · 2 of 3 loaded rows")
            tab.findBar.replaceField.stringValue = "Europe"
            tab.replaceMatch(all: true)
            #expect(tab.source?.cell(0, 2) == .text("Europe") && tab.source?.mark(1, 2) == .edited)
            #expect(tab.findBar.count.stringValue == "Replaced 2 values" && tab.source?.changes.rowCount == 2)
            tab.findBar.close(nil)
            #expect(tab.findBar.isHidden && tab.grid.rowCount == 3)
        }

        @Test func viewsAreReadOnlyAndSayWhy() async throws {
            let (_, _, tab) = try await Self.tab("customer_emails", session: .emails())
            #expect(!tab.notice.isHidden && tab.notice.text.stringValue.hasPrefix("Read-only. Views are read-only"))
            #expect(tab.source?.canEdit(0, 0) == false)
            let item = Commands.addRow.item()
            #expect(!tab.validateMenuItem(item) && item.toolTip?.hasPrefix("Views are read-only") == true)
        }

        @Test func pendingChangesComeBackAfterACrash() async throws {
            let session = FakeTableSession()
            let (main, _, tab) = try await Self.tab(session: session)
            tab.source?.set(.text("ZZ"), row: 0, column: 2)
            tab.changesDidChange()
            PendingChangesStore.shared.flush()
            // A new tab on the same table, as after a relaunch.
            let again = TableDataController(model: tab.model, context: tab.context, database: "airsql_fixture", table: "orders")
            again.openSession = { session }
            main.select(main.open(again, title: "orders", connection: tab.context.connection.id))
            await ready { again.loading != nil || again.source == nil }
            #expect(again.source?.cell(0, 2) == .text("ZZ") && again.notice.text.stringValue.hasPrefix("Left from before AirSQL quit"))
            again.revertAllChanges(nil)
            PendingChangesStore.shared.flush()
        }
    }
}

extension AppTests {
    /// Light and dark pictures of the table tab (AIRSQL_SCREENSHOTS=1, into build/screenshots): rows with pending
    /// changes and a filter, the Apply preview, and a read-only view.
    @MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["AIRSQL_SCREENSHOTS"] == "1")) struct GridDataScreenshotTests {
        @Test func tableTab() async throws {
            let session = FakeTableSession()
            let regions = ["EU", "US", "APAC", "EU", "US"]
            session.rows = (1...28).map { (id: Int) -> [String?] in
                let customer: String? = id % 4 == 0 ? nil : String(1_000 + id * 7)
                let parent: String? = id % 6 == 0 ? String(2_400_960 + id - 1) : nil
                let total = String(format: "%.2f", Double(id * 1_337 % 5_000) / 3)
                return [String(2_400_960 + id), customer, regions[id % 5], String(9_000 + id), total, parent]
            }
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let (main, harness, tab) = try await GridDataAppTests.tab(session: session, size: NSSize(width: 1180, height: 720))
                main.window?.appearance = NSAppearance(named: appearance)
                main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
                main.window?.orderFront(nil)
                tab.bar.filterText = "total > 100"
                tab.applyFilter("total > 100")
                await ready { tab.loading != nil }
                tab.source?.set(.text("1999.90"), row: 1, column: 4)
                tab.source?.set(.text("APAC"), row: 3, column: 2)
                tab.source?.changes.delete([["2400965"]])
                tab.source?.changes.addRow(["region": .text("EU"), "number": .text("9100"), "total": .text("42.00")])
                tab.changesDidChange()
                tab.grid.selection.select(GridPosition(row: 1, column: 4))
                main.window?.makeFirstResponder(tab.grid)
                main.window?.displayIfNeeded()
                try await save(harness, "table-data-\(suffix)")

                tab.previewChanges(nil)
                _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
                try await save(harness, "table-data-preview-\(suffix)", target: "sheet")
                _ = await call(harness, "press", ["title": "Cancel"])
                tab.revertAllChanges(nil)
                main.window?.orderOut(nil)

                let (viewMain, viewHarness, _) = try await GridDataAppTests.tab("customer_emails", session: .emails(),
                                                                                size: NSSize(width: 1180, height: 520))
                viewMain.window?.appearance = NSAppearance(named: appearance)
                viewMain.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
                viewMain.window?.orderFront(nil)
                viewMain.window?.displayIfNeeded()
                try await save(viewHarness, "table-data-read-only-\(suffix)")
                viewMain.window?.orderOut(nil)
            }
        }

        func save(_ harness: AgentServer, _ name: String, target: String = "main") async throws {
            let reply = await call(harness, "screenshot", ["target": target, "scale": 2])
            let image = try #require(reply.image, "\(name): \(reply.error ?? "")")
            let png = try #require(image.representation(using: .png, properties: [:]))
            try png.write(to: AppTests.ScreenshotTests.folder.appendingPathComponent(name + ".png"))
        }
    }
}
