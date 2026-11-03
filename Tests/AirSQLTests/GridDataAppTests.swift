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

    static let columns: [ResultStore.Column] = [
        .init(name: "id", type: MYSQL_TYPE_LONGLONG), .init(name: "customer_id", type: MYSQL_TYPE_LONG),
        .init(name: "region", type: MYSQL_TYPE_STRING), .init(name: "number", type: MYSQL_TYPE_LONG),
        .init(name: "total", type: MYSQL_TYPE_NEWDECIMAL), .init(name: "parent_id", type: MYSQL_TYPE_LONGLONG),
    ]

    func query(_ sql: String, rowCap: Int) async throws -> [StatementResult] {
        statements.append(sql)
        func result(_ columns: [ResultStore.Column], _ values: [[String?]]) -> [StatementResult] {
            let store = ResultStore(columns: columns)
            for row in values { _ = store.append(row.map { $0.map { Array($0.utf8) } }) }
            return [StatementResult(rows: store, affectedRows: 0, insertID: 0, warnings: 0, info: nil, duration: 0)]
        }
        if sql.hasPrefix("SELECT TABLE_ROWS") || sql.hasPrefix("SELECT COUNT(*)") {
            return result([.init(name: "n", type: MYSQL_TYPE_LONGLONG)], [[String(rows.count)]])
        }
        if sql.hasPrefix("SELECT") { return result(Self.columns, rows) }
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

        @Test func viewsAreReadOnlyAndSayWhy() async throws {
            let (_, _, tab) = try await Self.tab("customer_emails")
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
