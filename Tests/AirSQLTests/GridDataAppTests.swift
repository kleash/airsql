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
    /// The labels' queries, kept apart.
    var labels: [String] = []
    var rows: [[String?]] = [["1", "7", "EU", "100", "12.50", nil], ["2", nil, "US", "101", "99.00", "1"],
                             ["3", "9", "EU", "102", "0.10", nil]]
    var changed: (String) -> UInt64 = { _ in 1 }
    /// The server's error for a statement, if it refuses it.
    var refuse: (String) -> Error? = { _ in nil }
    /// INSERT's insert ID, and the row a read-back SELECT (… WHERE `id` = that ID) finds.
    var insertID: UInt64 = 0
    var readBack: [String?]?
    /// What reading edited rows back by key (… WHERE `id` IN (…)) finds.
    var edited: [[String?]]?
    /// What a foreign key's drop-down finds in customers: id and email.
    var customers: [[String?]] = [["7", "ann@example.com"], ["9", "cy@example.org"]]
    var sqlMode = "STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"

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

    /// Holds a statement until Cancel stops it; the statements Cancel was told to stop.
    var hold: (String) -> Bool = { _ in false }
    var held: CheckedContinuation<Void, Never>?
    var cancelled: [String] = []

    func cancel(statement: String?) async throws -> CancelResult {
        cancelled.append(statement ?? "")
        held?.resume()
        held = nil
        return .cancelled
    }

    func query(_ sql: String, rowCap: Int) async throws -> [StatementResult] {
        if hold(sql) {
            await withCheckedContinuation { held = $0 }
            throw AirSQLError(.other, "Query execution was interrupted")
        }
        func result(_ columns: [ResultStore.Column], _ values: [[String?]]) -> [StatementResult] {
            let store = ResultStore(columns: columns)
            for row in values { _ = store.append(row.map { $0.map { Array($0.utf8) } }) }
            return [StatementResult(rows: store, affectedRows: 0, insertID: 0, warnings: 0, info: nil, duration: 0)]
        }
        // The session's sql_mode and time zone (not about the table: left out of `statements`).
        if sql.hasPrefix("SELECT @@SESSION.sql_mode") {
            return result([.init(name: "m", type: MYSQL_TYPE_VAR_STRING), .init(name: "z", type: MYSQL_TYPE_VAR_STRING)],
                          [[sqlMode, "SYSTEM"]])
        }
        // Foreign keys' labels as their cells are drawn (SELECT key, label … WHERE key IN …): in `labels`.
        if let select = sql.range(of: "SELECT "), let from = sql.range(of: " FROM "), select.lowerBound == sql.startIndex {
            let names = sql[select.upperBound..<from.lowerBound].components(separatedBy: ", ")
            if names.count == 2, sql.contains(" WHERE \(names[0]) IN (") {
                labels.append(sql)
                let found = sql.contains("`customers`") ? customers : []
                return result([.init(name: "id", type: MYSQL_TYPE_LONG), .init(name: "label", type: MYSQL_TYPE_VAR_STRING)], found)
            }
        }
        statements.append(sql)
        if sql.hasPrefix("SELECT DISTINCT") {
            return result([.init(name: "v", type: MYSQL_TYPE_STRING)], [["EU"], ["US"]])
        }
        if sql.contains(" GROUP BY ") {
            return result([.init(name: "v", type: MYSQL_TYPE_STRING), .init(name: "n", type: MYSQL_TYPE_LONGLONG)], [["EU", "2"], ["US", "1"]])
        }
        if sql.hasPrefix("SELECT TABLE_ROWS") || sql.hasPrefix("SELECT COUNT(*)") {
            return result([.init(name: "n", type: MYSQL_TYPE_LONGLONG)], [[String(rows.count)]])
        }
        if sql.contains(" FROM `airsql_fixture`.`customers`"), !columns.contains(where: { $0.name == "email" }) {
            return result([.init(name: "id", type: MYSQL_TYPE_LONG), .init(name: "email", type: MYSQL_TYPE_VAR_STRING)], customers)
        }
        if let readBack, sql.hasPrefix("SELECT"), sql.hasSuffix("WHERE `id` = \(insertID)") { return result(columns, [readBack]) }
        if let edited, sql.hasPrefix("SELECT"), sql.contains(" WHERE `id` IN (") { return result(columns, edited) }
        if sql.hasPrefix("SELECT") { return result(columns, rows) }
        if let error = refuse(sql) { throw error }
        let affected = ["START TRANSACTION", "COMMIT", "ROLLBACK"].contains(sql) ? 0 : changed(sql)
        return [StatementResult(rows: nil, affectedRows: affected, insertID: sql.hasPrefix("INSERT") ? insertID : 0, warnings: 0,
                                info: nil, duration: 0)]
    }

    func stream(_ sql: String, batchRows: Int, batch: @escaping (ResultStore) throws -> Void) async throws {
        statements.append(sql)
    }
}

extension AppTests {
    @MainActor @Suite struct GridDataAppTests {
        /// A window with a table tab on `table` of the recorded fixture, its rows from a fake session.
        static func tab(_ table: String = "orders", session: FakeTableSession = FakeTableSession(), size: NSSize = MainWindowController.defaultSize,
                        readOnly: Bool = false) async throws -> (MainWindowController, AgentServer, TableDataController) {
            var connection = SavedConnection(name: "Local", host: "127.0.0.1", user: "app")
            connection.readOnly = readOnly
            let (main, harness) = appWindow(testModel([connection]), size: size)
            return (main, harness, try await open(table, in: main, connection: connection, session: session))
        }

        /// A table tab in `main` on `connection`, its rows from `session`, once they are shown.
        static func open(_ table: String = "orders", in main: MainWindowController, connection: SavedConnection,
                         session: FakeTableSession = FakeTableSession()) async throws -> TableDataController {
            let context = try await recordedEditorContext(connection)
            let controller = TableDataController(model: main.model, context: context, database: "airsql_fixture", table: table)
            controller.openSession = { session }
            main.select(main.open(controller, title: table, connection: connection.id))
            main.window?.layoutIfNeeded()
            await ready { controller.loading != nil || (controller.source == nil && controller.problem == nil) }
            return controller
        }

        @Test func showsTheRowsAndSaysWhereFilteringRuns() async throws {
            let session = FakeTableSession()
            let (main, _, tab) = try await Self.tab(session: session)
            // The grid fills the tab under its bars, the value panel open or not.
            let height = tab.viewer.frame.height
            #expect(height > 400)
            tab.viewer.toggleValuePanel(nil)
            main.window?.layoutIfNeeded()
            #expect(tab.viewer.frame.height == height && tab.viewer.valuePanel?.frame.height == height,
                    "\(height) → \(tab.viewer.frame.height), panel \(tab.viewer.valuePanel?.frame.height ?? 0)")
            tab.grid.selection.select(GridPosition(row: 1, column: 2))
            tab.viewer.showRecordView(nil)
            main.window?.layoutIfNeeded()
            #expect(tab.viewer.frame.height == height && tab.grid.rowCount == 6 && tab.grid.visibleRect.height > 300)
            tab.viewer.backToGrid(nil)
            tab.viewer.toggleValuePanel(nil)
            #expect(tab.grid.rowCount == 3 && tab.source?.cell(1, 2) == .text("US"))
            #expect(tab.bar.scope.text == "On server · all rows" && tab.viewer.status.rows.stringValue.hasPrefix("3 rows"))
            #expect(session.statements.first?.hasSuffix("FROM `airsql_fixture`.`orders` ORDER BY `id` ASC LIMIT 1000") == true)
            #expect(tab.notice.isHidden && !tab.isEdited && main.selectedTab?.title == "orders")
            // The bar's ? opens the Data Grid page of the help.
            #expect(find(NSButton.self, id: "help", in: tab.bar)?.identifier?.rawValue == "help:" + HelpPage.tableData.rawValue)

            tab.applyFilter("WHERE region = 'EU'")
            await ready { tab.loading != nil }
            #expect(session.statements.last?.contains(" WHERE (region = 'EU'\n) ORDER BY `id` ASC") == true)
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
            #expect(session.statements.contains("UPDATE `airsql_fixture`.`orders` SET `total` = 5 WHERE `id` = 1 AND `total` <=> 12.50"))
            #expect(session.statements.contains("COMMIT"))
            await ready { tab.loading != nil }
            #expect(tab.source?.changes.isEmpty == true && tab.notice.isHidden && !tab.isEdited)
            _ = main
        }

        @Test func applyWithEveryRowLoadedReadsBackOnlyTheEditedRows() async throws {
            let session = FakeTableSession()
            session.edited = [["2", nil, "EU", "101", "99.00", "1"]]
            let (_, _, tab) = try await Self.tab(session: session)
            tab.source?.set(.text("eu"), row: 1, column: 2)
            tab.grid.selection.selectRow(2)
            tab.deleteRows(nil)
            tab.applyChanges(nil)
            await ready { tab.loading != nil }
            #expect(session.statements.suffix(2) == ["COMMIT", "SELECT `id`, `customer_id`, `region`, `number`, `total`, `parent_id` "
                                                      + "FROM `airsql_fixture`.`orders` WHERE `id` IN (2)"])
            // The server's value (its collation kept the case it likes) shows, the deleted row is gone, nothing reloaded.
            #expect(tab.grid.rowCount == 2 && tab.source?.cell(1, 2) == .text("EU") && tab.viewer.status.rows.stringValue.hasPrefix("2 rows"))
            #expect(!tab.bar.busy && tab.source?.changes.isEmpty == true)
            // Refresh loads them all again.
            var sent = session.statements.count
            tab.refresh(nil)
            await ready { tab.loading != nil }
            #expect(tab.grid.rowCount == 3 && session.statements[sent...].contains { $0.hasSuffix("ORDER BY `id` ASC LIMIT 1000") })
            // Changing a key loads the rows again.
            tab.source?.set(.text("20"), row: 0, column: 0)
            sent = session.statements.count
            tab.applyChanges(nil)
            await ready { tab.loading != nil }
            #expect(session.statements[sent...].last?.hasSuffix("ORDER BY `id` ASC LIMIT 1000") == true)
        }

        @Test func aMismatchRollsBackAndPointsAtTheRow() async throws {
            let session = FakeTableSession()
            session.changed = { $0.contains("WHERE `id` = 2") ? 0 : 1 }
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

        @Test func figuresAndChartsSayTheyCoverTheLoadedRows() async throws {
            let (_, _, tab) = try await Self.tab()
            let viewer = tab.viewer, source = try #require(tab.source)
            viewer.grid.selection.selectColumn(4)
            viewer.status.update()
            #expect(!viewer.status.figure.title.contains("loaded") && viewer.chartCoverage == nil)
            // A Load All that stopped: a batch came, and the end of the stream didn't.
            source.append(ResultStore(columns: []), requested: nil)
            viewer.status.update()
            #expect(viewer.status.figure.title.hasPrefix("Sum of loaded rows "))
            #expect(viewer.chartCoverage == "Covers the first \(source.rowCount) rows loaded, not the whole table")
            viewer.grid.selection.select(GridPosition(row: 0, column: 4))
            viewer.status.update()
            #expect(!viewer.status.figure.title.contains("loaded"))
        }

        @Test func aServerErrorNamingAColumnPointsAtTheCell() async throws {
            let session = FakeTableSession()
            session.refuse = { sql in
                sql.contains("WHERE `id` = 2") ? ErrorMapping.map(code: 1406, message: "Data too long for column 'region' at row 1") : nil
            }
            let (main, harness, tab) = try await Self.tab(session: session)
            tab.source?.set(.text("5"), row: 0, column: 4)
            tab.source?.set(.text("EU"), row: 1, column: 2)
            tab.changesDidChange()
            tab.grid.selection.select(GridPosition(row: 0, column: 0))
            tab.applyChanges(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(session.statements.last == "ROLLBACK" && main.window?.attachedSheet != nil)
            #expect(tab.grid.selection.cursor == GridPosition(row: 1, column: 2) && !tab.grid.selection.containsRow(1))
            _ = await call(harness, "press", ["title": "OK"])
            // A value its column refuses before anything runs points at its cell too.
            tab.source?.set(.text("x"), row: 0, column: 4)
            tab.changesDidChange()
            let sent = session.statements.count
            tab.applyChanges(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(session.statements.count == sent && tab.grid.selection.cursor == GridPosition(row: 0, column: 4))
            _ = await call(harness, "press", ["title": "OK"])
        }

        @Test func stoppingAnApplyLeavesCommitAlone() async throws {
            let session = FakeTableSession()
            let stop = ApplyStop()
            stop.session = session
            try stop.starting("START TRANSACTION")
            try stop.starting("COMMIT")
            stop.stop()  // COMMIT is running: nothing is sent, and only ROLLBACK may follow
            #expect(throws: AirSQLError.self) { try stop.starting("UPDATE t SET a = 1") }
            try stop.starting("ROLLBACK")
            await Task.yield()
            #expect(session.cancelled.isEmpty)
            let second = ApplyStop()
            second.session = session
            try second.starting("UPDATE t SET a = 1")
            second.stop()
            #expect(await eventually { session.cancelled == ["UPDATE t SET a = 1"] })
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
            #expect(sql.contains("UPDATE `airsql_fixture`.`orders` SET `customer_id` = NULL WHERE `id` = 1 AND `customer_id` <=> 7;"))
            #expect(sql.contains("INSERT INTO `airsql_fixture`.`orders` (`region`, `number`, `total`) VALUES ('EU', 7, 1);"))
            #expect(shownText("preview.heading", in: main.window?.attachedSheet) == "Apply 2 changes to airsql_fixture.orders?")
            _ = await call(harness, "press", ["title": "Cancel"])
            #expect(tab.source?.changes.rowCount == 2)
        }

        @Test func anAgentsApplyWaitsForThePersonInThePreview() async throws {
            let session = FakeTableSession()
            let (main, harness, tab) = try await Self.tab(session: session)
            tab.source?.set(.text("x"), row: 0, column: 2)
            tab.changesDidChange()
            // An agent pressing Apply gets the preview, whatever Settings ▸ Safety says about previews: the person
            // approves the whole change there once.
            AgentGate.$agent.withValue("test agent") { tab.applyChanges(nil) }
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(shownText("preview.heading", in: main.window?.attachedSheet) == "Apply 1 change to airsql_fixture.orders?")
            #expect(!session.statements.contains("START TRANSACTION"))
            _ = await call(harness, "press", ["title": "Decline"])
            #expect(tab.source?.changes.rowCount == 1)
        }

        @Test func copyAsBecomesTheCopyFormat() async throws {
            let (_, _, tab) = try await Self.tab()
            tab.grid.selection.select(GridPosition(row: 0, column: 0))
            tab.grid.selection.select(GridPosition(row: 1, column: 2), extend: true)
            tab.viewer.copy(nil)
            #expect(NSPasteboard.general.string(forType: .string) == "1\t7\tEU\n2\tNULL\tUS\n")
            let item = NSMenuItem()
            item.representedObject = CopyFormat.jsonLines.rawValue
            tab.viewer.copyAs(item)
            tab.viewer.copy(nil)
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
                    + "ORDER BY COUNT(*) DESC, `region` LIMIT 1000")
            _ = await eventually(timeout: 10) { await call(harness, "press", ["title": "US  (1)"]).error == nil }
            _ = await call(harness, "press", ["id": "values.ok"])
            #expect(main.window?.attachedSheet == nil && tab.bar.filterText == "`region` IN ('EU')")
            await ready { tab.loading != nil }
            #expect(session.statements.last?.contains(" WHERE (`region` IN ('EU')\n) ORDER BY") == true)
        }

        /// Data ▸ Quick Filter has each operator of a cell's menu, and Type a Value…; Sort by Columns… sorts by several.
        @Test func quickFiltersFromTheMenuBarATypedValueAndASortByColumns() async throws {
            let session = FakeTableSession()
            let (main, harness, tab) = try await Self.tab(session: session)
            let window = try #require(main.window)
            window.makeFirstResponder(tab.grid)
            tab.grid.selection.select(GridPosition(row: 0, column: 2))
            #expect(await call(harness, "menu", ["path": "Data > Quick Filter > Contains Selection"]).error == nil)
            #expect(tab.bar.filterText == "`region` LIKE '%EU%'")
            await ready { tab.loading != nil }
            tab.applyFilter("")
            await ready { tab.loading != nil }
            // IN takes every value selected in the column; it waits for several.
            let into = Commands.filterIn.item()
            #expect(!tab.validateMenuItem(into) && into.toolTip == "Select several values of this column first")
            tab.grid.selection.select(GridPosition(row: 1, column: 2), extend: true)
            #expect(tab.validateMenuItem(into))
            #expect(await call(harness, "menu", ["path": "Data > Quick Filter > In Selected Values"]).error == nil)
            #expect(tab.bar.filterText == "`region` IN ('EU', 'US')")
            await ready { tab.loading != nil }

            // A value typed in, added to the filter there is.
            tab.grid.selection.select(GridPosition(row: 1, column: 2))
            #expect(await call(harness, "menu", ["path": "Data > Quick Filter > Type a Value…"]).error == nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(await call(harness, "set", ["id": "quickFilter.operator", "value": "Not equal to (<>)"]).error == nil)
            #expect(await call(harness, "set", ["id": "quickFilter.value", "value": "U'S"]).error == nil)
            #expect(await call(harness, "set", ["id": "quickFilter.add", "value": true]).error == nil)
            #expect(await call(harness, "press", ["title": "Filter", "in": "sheet"]).error == nil)
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            #expect(tab.bar.filterText == "(`region` IN ('EU', 'US')) AND `region` <> 'U\\'S'")
            await ready { tab.loading != nil }

            // Two columns, the second one descending.
            #expect(await call(harness, "menu", ["path": "Data > Sort > Sort by Columns…"]).error == nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(await call(harness, "set", ["id": "sort.column.0", "value": "region"]).error == nil)
            #expect(await call(harness, "press", ["id": "sort.add"]).error == nil)
            #expect(await call(harness, "set", ["id": "sort.direction.1", "value": "Descending"]).error == nil)
            #expect(await call(harness, "press", ["id": "sort.up.1"]).error == nil)
            #expect(await call(harness, "press", ["id": "sort.ok"]).error == nil)
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            await ready { tab.loading != nil }
            #expect(session.statements.last?.contains("ORDER BY `id` DESC, `region` ASC LIMIT") == true, "\(session.statements.last ?? "")")
            #expect(tab.grid.sortOrder.map(\.column) == [0, 2] && tab.settings.sort.count == 2)

            // Add to Sort keeps those and goes after them; a column already in the sort can't be added again.
            tab.grid.selection.select(GridPosition(row: 1, column: 1))
            #expect(await call(harness, "menu", ["path": "Data > Sort > Add to Sort"]).error == nil)
            await ready { tab.loading != nil }
            #expect(tab.grid.sortOrder.map(\.column) == [0, 2, 1])
            #expect(session.statements.last?.contains("ORDER BY `id` DESC, `region` ASC, `") == true, "\(session.statements.last ?? "")")
            #expect(await call(harness, "menu", ["path": "Data > Sort > Add to Sort"]).error != nil)
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
            // One ⌘Z takes back every value Replace All changed, and every row Duplicate Row added.
            tab.undo(nil)
            #expect(tab.source?.changes.isEmpty == true)
            tab.grid.selection.selectRow(0)
            tab.grid.selection.selectRow(2, extend: true)
            tab.duplicateRow(nil)
            #expect(tab.source?.changes.state.inserts.count == 3)
            tab.undo(nil)
            #expect(tab.source?.changes.isEmpty == true)
        }

        /// The first pending change opens the notice over the rows: the new row must still show once it has.
        @Test func aDuplicatedRowShowsAndLeavesItsAutoIncrementToTheServer() async throws {
            let session = FakeTableSession()
            session.rows = (1...60).map { [String($0), "7", "EU", String(100 + $0), "1.00", nil] }
            let (main, _, tab) = try await Self.tab(session: session, size: NSSize(width: 900, height: 500))
            tab.grid.selection.selectRow(0)
            tab.duplicateRow(nil)
            main.window?.layoutIfNeeded()
            let copy = tab.grid.rowCount - 1
            #expect(tab.grid.selection.cursor?.row == copy)
            #expect(tab.grid.visibleRect.contains(tab.grid.rowRect(copy).intersection(NSRect(x: 0, y: 0, width: 1, height: 1e6))),
                    "\(tab.grid.visibleRect) \(tab.grid.rowRect(copy))")
            #expect(tab.source?.cell(copy, 0) == .placeholder("auto") && tab.source?.cell(copy, 2) == .text("EU"))
        }

        /// The table a single click shows in the preview tab, the focus still in the tree.
        static func preview(_ table: String = "orders", in main: MainWindowController, connection: SavedConnection,
                            session: FakeTableSession = FakeTableSession()) async throws -> TableDataController {
            let context = try await recordedEditorContext(connection)
            let controller = TableDataController(model: main.model, context: context, database: "airsql_fixture", table: table)
            controller.openSession = { session }
            main.preview(controller, title: table, connection: connection.id)
            main.window?.layoutIfNeeded()
            await ready { controller.loading != nil || (controller.source == nil && controller.problem == nil) }
            main.window?.makeFirstResponder(main.sidebar.outline)
            return controller
        }

        @Test func thePreviewTabTakesTheTableTabsCommands() async throws {
            let connection = SavedConnection(name: "Local", host: "127.0.0.1", user: "app")
            let (main, _) = appWindow(testModel([connection]))
            let tab = try await Self.preview(in: main, connection: connection)
            // AppKit's walk for a menu item (NSApp.keyWindow stays nil in the tests).
            func target(_ action: Selector) -> AnyObject? {
                var responder = main.window?.firstResponder
                while let next = responder {
                    if next.responds(to: action) { return next }
                    if let found = next.supplementalTarget(forAction: action, sender: nil) as AnyObject? { return found }
                    responder = next.nextResponder
                }
                return nil
            }
            for command in [Commands.save, Commands.cancelQuery, Commands.find, Commands.filter, Commands.searchAllColumns, Commands.addRow, Commands.columnList,
                            Commands.transpose, Commands.loadMore] {
                #expect(target(command.action) === tab, "\(command.title): \(String(describing: target(command.action)))")
            }
            let transpose = Commands.transpose.item()
            #expect(tab.validateMenuItem(transpose))
            tab.toolbar.validate()
            let button = try #require(tab.toolbar.button(Commands.transpose))
            button.performClick(nil)
            #expect(tab.viewer.transposed)
            #expect(button.image != nil)
            let menu = tab.viewer.dataGrid(tab.grid, menuFor: .row(0))
            #expect(menu?.items.contains { $0.action == Commands.transpose.action } == true)
        }

        @Test func anotherTableClickedKeepsThePreviewsPendingChanges() async throws {
            let connection = SavedConnection(name: "Local", host: "127.0.0.1", user: "app")
            let (main, _) = appWindow(testModel([connection]))
            let tab = try await Self.preview(in: main, connection: connection)
            tab.keep(.text("US"), row: 0, column: 2)
            #expect(main.tabBar.buttons.first?.toolTip?.contains("(unsaved)") == true, "the tab's dot")
            let other = try await Self.preview("customers", in: main, connection: connection, session: .customers())
            #expect(main.tabs.count == 2 && main.tabs.first?.shown === tab && main.selectedTab?.shown === other)
            #expect(main.unfinishedWork().contains { $0.hasPrefix("orders on Local: 1 pending change") })
            let context = try await recordedEditorContext(connection)
            #expect(main.openTableData("orders", database: "airsql_fixture", context: context) === main.tabs.first, "not a second tab on it")
            tab.revertAllChanges(nil)
            _ = try await Self.preview("customers", in: main, connection: connection, session: .customers())
            #expect(main.tabs.count == 2, "with nothing pending it is a preview again")
        }

        @Test func cancelStopsTheTabsReadsAloneAndSaysSo() async throws {
            let session = FakeTableSession()
            let (main, _, tab) = try await Self.tab(session: session)
            let cancel = Commands.cancelQuery.item()
            #expect(!tab.validateMenuItem(cancel) && cancel.toolTip == "Nothing is running in this tab")
            // Count Exactly stops without a word; the rows stay and the tab can read again.
            session.hold = { $0.hasPrefix("SELECT COUNT(*)") }
            tab.countRows(nil)
            #expect(await eventually(timeout: 5) { session.held != nil })
            #expect(tab.validateMenuItem(cancel) && main.model.activity.running.map(\.title) == ["Counting the rows of orders"])
            tab.cancelQuery(nil)
            #expect(await eventually(timeout: 5) { tab.loading == nil })
            #expect(session.cancelled == [tab.source?.countSQL] && tab.problem == nil && main.model.activity.running.isEmpty)
            // A new filter's page, stopped from Activity: the tab says the rows aren't those asked for, and Refresh brings them.
            session.hold = { $0.contains("WHERE") }
            tab.applyFilter("region = 'EU'")
            #expect(await eventually(timeout: 5) { session.held != nil })
            main.model.activity.cancelAll()
            #expect(await eventually(timeout: 5) { tab.loading == nil })
            #expect(tab.problem?.hasPrefix("Cancelled") == true && tab.grid.rowCount == 3)
            session.hold = { _ in false }
            tab.refresh(nil)
            #expect(await eventually(timeout: 5) { tab.problem == nil })
            // Closing the tab stops what it was reading.
            session.hold = { $0.hasPrefix("SELECT COUNT(*)") }
            tab.countRows(nil)
            #expect(await eventually(timeout: 5) { session.held != nil })
            tab.shouldClose { _ in }
            #expect(await eventually(timeout: 5) { tab.loading == nil })
        }

        @Test func anEmptyTableOrFilterSaysSoAndOffersTheNextStep() async throws {
            let session = FakeTableSession()
            session.rows = []
            let (_, _, tab) = try await Self.tab(session: session)
            #expect(!tab.emptyNote.isHidden && tab.emptyNote.text.stringValue == "orders has no rows.")
            #expect(tab.emptyNote.clear.isHidden && !tab.emptyNote.add.isHidden)
            tab.applyFilter("region = 'XX'")
            #expect(await eventually(timeout: 5) { tab.loading == nil && !tab.emptyNote.clear.isHidden })
            #expect(tab.emptyNote.text.stringValue == "No rows match the filter or search.")
            tab.emptyNote.clear.performClick(nil)
            #expect(await eventually(timeout: 5) { tab.loading == nil && tab.emptyNote.clear.isHidden })
            tab.viewer.present(.text)
            #expect(tab.emptyNote.isHidden)  // the note follows View As
            tab.viewer.present(.table)
            #expect(!tab.emptyNote.isHidden)
            tab.emptyNote.add.performClick(nil)
            #expect(tab.emptyNote.isHidden && tab.grid.rowCount == 1)
            let (_, _, readOnly) = try await Self.tab(session: session, readOnly: true)
            #expect(!readOnly.emptyNote.isHidden && readOnly.emptyNote.add.isHidden)
        }

        /// ⌫ on rows selected by their numbers marks them, as ⌘⌫ does; ⌘X copies the cells and clears them, pending.
        @Test func deleteKeyMarksRowsAndCutClearsCells() async throws {
            let (main, _, tab) = try await Self.tab()
            let source = try #require(tab.source)
            main.window?.makeFirstResponder(tab.grid)  // ⌫ only reaches the grid when it has the focus
            tab.grid.selection.selectRow(0)
            tab.grid.deleteBackward(nil)
            #expect(source.changes.isDeleted(try #require(source.rowKey(0))))
            tab.undo(nil)
            #expect(source.changes.isEmpty)

            let nullable = try #require(source.table.columns.firstIndex { $0.nullable })
            let shown = try #require(tab.grid.columnOrder.firstIndex(of: nullable))
            tab.grid.selection.select(GridPosition(row: 0, column: shown))
            let copies = NSPasteboard.general.changeCount
            tab.cut(nil)
            #expect(NSPasteboard.general.changeCount > copies && source.value(0, nullable) == nil)
        }

        /// ⌘Z undoes text being typed, not the grid's changes: the tab stands aside for the window's undo manager.
        @Test func commandZUndoesTypingInTheTabsFields() async throws {
            let (main, _, tab) = try await Self.tab()
            let window = try #require(main.window)
            tab.keep(.text("US"), row: 0, column: 2)
            window.makeFirstResponder(tab.grid)
            #expect(tab.responds(to: Commands.undo.action))
            window.makeFirstResponder(tab.bar.whereField)
            #expect(!tab.responds(to: Commands.undo.action) && !tab.responds(to: Commands.redo.action))
            #expect(!tab.responds(to: Commands.deleteRows.action), "⌘⌫ reaches the text")
            tab.bar.whereField.insertText("region", replacementRange: NSRange(location: 0, length: 0))
            #expect(window.undoManager?.canUndo == true)
            window.undoManager?.undo()
            #expect(tab.bar.whereField.text.isEmpty && tab.source?.changes.isEmpty == false, "the edit stays pending")
            window.makeFirstResponder(tab.bar.searchField)
            #expect(!tab.responds(to: Commands.undo.action))
            window.makeFirstResponder(tab.grid)
            #expect(tab.responds(to: Commands.undo.action))
        }

        @Test func aColumnsFunnelFiltersByItsValuesAndCanWidenAgain() async throws {
            let session = FakeTableSession()
            let (main, harness, tab) = try await Self.tab(session: session)
            let window = try #require(main.window)
            tab.applyFilter("number > 1")
            await ready { tab.loading != nil }
            func open() async throws -> NSTableView {
                tab.dataGrid(tab.grid, filterValuesOf: 2, at: NSRect(x: 10, y: 0, width: 16, height: 20))
                #expect(await call(harness, "wait", ["until": "popover", "timeout": 5]).error == nil)
                let content = try #require(harness.popovers(of: window).last?.contentView)
                let list = try #require(find(NSTableView.self, id: "values.list", in: content))
                #expect(await eventually(timeout: 5) { list.numberOfRows == 2 })
                return list
            }
            func box(_ list: NSTableView, _ row: Int) -> NSButton? { list.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSButton }
            let list = try await open()
            #expect(session.statements.last?.contains("WHERE (number > 1") == true)
            box(list, 1)?.performClick(nil)
            #expect(await call(harness, "press", ["id": "values.ok"]).error == nil)
            await ready { tab.loading != nil }
            #expect(tab.bar.filterText == "(number > 1) AND `region` IN ('EU')" && tab.grid.filteredColumns == [2, 3])
            // Open again: the column's own choice comes ticked, and doesn't narrow the list or the next choice.
            let again = try await open()
            #expect(session.statements.last?.contains("IN (") == false)
            #expect(box(again, 0)?.state == .on && box(again, 1)?.state == .off)
            #expect(await call(harness, "press", ["id": "values.all"]).error == nil)
            #expect(await call(harness, "press", ["id": "values.ok"]).error == nil)
            await ready { tab.loading != nil }
            #expect(tab.bar.filterText == "number > 1" && tab.grid.filteredColumns == [3])
        }

        /// At 900 pt the condition was squeezed in beside the search and wrapped to eight lines.
        @Test func aNarrowBarGivesTheConditionARowOfItsOwn() async throws {
            let (main, _, tab) = try await Self.tab(size: NSSize(width: 900, height: 600))
            tab.bar.filterText = "region = 'EU' AND total > 100 AND customer_id IN (1, 2, 3)"
            main.window?.layoutIfNeeded()
            let box = tab.bar.whereField.box
            #expect(tab.bar.frame.width < 860 && box.frame.width > 400, "\(tab.bar.frame.width) \(box.frame.width)")
            #expect(box.window != nil && tab.bar.frame.height < 80, "\(tab.bar.frame.height)")
            main.window?.setContentSize(NSSize(width: 1600, height: 600))
            main.window?.layoutIfNeeded()
            main.window?.layoutIfNeeded()
            #expect(abs(box.convert(box.bounds, to: tab.bar).midY - tab.bar.searchField.convert(tab.bar.searchField.bounds, to: tab.bar).midY) < 2)
            #expect(tab.bar.frame.height < 45, "\(tab.bar.frame.height)")
        }

        /// AppKit tries only File ▸ Save for ⌘S, so it must act on a table tab's and an edited result's changes.
        @Test func commandSAppliesATablesChanges() async throws {
            let session = FakeTableSession()
            let (main, harness, tab) = try await Self.tab(session: session)
            main.window?.makeFirstResponder(tab.grid)
            let save = Commands.save.item()
            #expect(!tab.validateMenuItem(save) && save.toolTip == "No changes are pending")
            tab.grid.selection.select(GridPosition(row: 0, column: 2))
            tab.keep(.text("US"), row: 0, column: 2)
            #expect(tab.validateMenuItem(save))
            #expect(await call(harness, "key", ["combo": "cmd+s"]).error == nil)
            #expect(await eventually(timeout: 5) { tab.source?.changes.isEmpty == true })
            #expect(session.statements.contains { $0.hasPrefix("UPDATE") })
        }

        @Test func whereBarSuggestsColumnsOperatorsAndValuesAsYouType() async throws {
            let session = FakeTableSession()
            let (main, _, tab) = try await Self.tab(session: session)
            let field = tab.bar.whereField
            main.window?.makeFirstResponder(field)
            func labels() -> [String] { field.suggestedItems.map(\.label) }
            field.insertText("reg", replacementRange: field.selectedRange())
            #expect(labels() == ["region"])
            field.doCommand(by: #selector(NSResponder.insertTab(_:)))
            #expect(field.text == "region " && labels().contains("IS NULL"), "the operators come next")
            field.insertText("= ", replacementRange: field.selectedRange())
            #expect(await eventually(timeout: 5) { labels() == ["EU", "US"] }, "the values, read off the main thread")
            #expect(session.statements.last?.hasPrefix("SELECT DISTINCT `region` FROM (SELECT `region` FROM ") == true)
            field.doCommand(by: #selector(NSResponder.moveDown(_:)))
            field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            #expect(field.text == "region = 'US'" && labels().isEmpty && tab.bar.filterText == field.text)
            #expect(session.statements.last?.contains("WHERE") == false, "Return chose the value: the filter hasn't run")
            // With nothing chosen, Return applies the condition as it always has.
            field.insertText(" a", replacementRange: field.selectedRange())
            #expect(labels() == ["AND"])
            field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            #expect(await eventually(timeout: 5) { session.statements.contains { $0.contains("WHERE") } })
        }

        /// A console result filters, searches and sorts its own rows, as a table tab's loaded rows, with no query.
        @Test func consoleResultsFilterSearchAndSortTheirRows() async throws {
            let (main, harness) = appWindow(testModel(Fixtures.shop))
            let viewer = try #require(resultViewer(main))
            let result = try #require(viewer.superview as? ResultGridView)
            let window = try #require(main.window)
            #expect(await consoleTookTheFocus(main))
            window.makeFirstResponder(viewer.grid)
            // The bar shows only while a filter or a search is on; the results bar's ? opens the Data Grid page.
            #expect(result.filterBar.isHidden && result.filterBar.scope.text == "Local · all rows")
            let console = try #require(main.selectedTab?.content as? ConsoleViewController)
            #expect(!console.results.help.isHidden && console.results.help.identifier?.rawValue == "help:" + HelpPage.dataGrid.rawValue)
            viewer.grid.selection.select(GridPosition(row: 1, column: 3))
            #expect(await call(harness, "menu", ["path": "Data > Quick Filter > Greater Than Selection"]).error == nil)
            #expect(viewer.grid.rowCount == 1 && result.rows.value(0, 3) == "318" && !result.filterBar.isHidden)
            #expect(result.filterBar.scope.text == "Local · 1 of 5 rows" && result.filterBar.conditionsText.stringValue == "`orders` > 317")
            window.makeFirstResponder(viewer.grid)
            // A value typed in, added: no row has both.
            viewer.grid.selection.select(GridPosition(row: 0, column: 1))
            #expect(await call(harness, "menu", ["path": "Data > Quick Filter > Type a Value…"]).error == nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(await call(harness, "set", ["id": "quickFilter.value", "value": "Ama Mensah"]).error == nil)
            #expect(await call(harness, "set", ["id": "quickFilter.add", "value": true]).error == nil)
            #expect(await call(harness, "press", ["title": "Filter", "in": "sheet"]).error == nil)
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            #expect(viewer.grid.rowCount == 0 && result.conditions.count == 2)

            // The search keeps the rows holding its text, tinted, and the sort orders them.
            result.clearFilter(nil)
            #expect(viewer.grid.rowCount == 5 && result.filterBar.isHidden)
            #expect(await call(harness, "menu", ["path": "Data > Search All Columns"]).error == nil)
            #expect(!result.filterBar.isHidden && result.filterBar.searchField.currentEditor() != nil)
            result.filterBar.searchField.stringValue = "or"
            result.reorder()
            let found = (0..<viewer.grid.rowCount).map { result.rows.value($0, 1) ?? "" }
            #expect(found == ["Harbor Supply Co.", "Nordlicht GmbH", "Lucía Ortega", "Kestrel Outdoor"] && viewer.highlight?(0, 1) == true)
            result.dataGrid(viewer.grid, sortBy: 1, adding: false)
            #expect((0..<viewer.grid.rowCount).map { result.rows.value($0, 1) ?? "" } == found.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
            #expect(result.filterBar.scope.text == "Local · 4 of 5 rows")
            viewer.grid.selection.select(GridPosition(row: 0, column: 0))
            result.addToSort(nil)
            #expect(viewer.grid.sortOrder.map(\.column) == [1, 0])

            // Filter by Values counts the rows shown.
            result.clearFilter(nil)
            result.clearSort(nil)
            viewer.grid.selection.select(GridPosition(row: 0, column: 1))
            result.filterByValues(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await eventually(timeout: 10) { await call(harness, "press", ["title": "Ama Mensah  (1)"]).error == nil }
            _ = await call(harness, "press", ["id": "values.ok"])
            #expect(window.attachedSheet == nil && viewer.grid.rowCount == 4 && !(0..<4).contains { result.rows.value($0, 1) == "Ama Mensah" })
        }

        /// A filter from Record View goes back to the grid, filtered: Record View's row number would be another row's now,
        /// or past the rows (it read past them, which ended the app).
        @Test func recordViewLeavesWhenAFilterRemovesItsRow() async throws {
            let (main, harness) = appWindow(testModel(Fixtures.shop))
            let viewer = try #require(resultViewer(main))
            let result = try #require(viewer.superview as? ResultGridView)
            #expect(await consoleTookTheFocus(main))
            main.window?.makeFirstResponder(viewer.grid)
            viewer.grid.selection.select(GridPosition(row: 1, column: 1))
            viewer.showRecordView(nil)
            #expect(await call(harness, "menu", ["path": "Data > Quick Filter > Not Equal to Selection"]).error == nil)
            #expect(viewer.record == nil && viewer.grid.source is ReorderedSource && result.rows.rowCount == 4)
            viewer.grid.selection.select(GridPosition(row: 3, column: 1))
            viewer.showRecordView(nil)
            #expect(viewer.record == 3 && viewer.recordLabel.stringValue == "Row 4 of 4")
            #expect(await call(harness, "menu", ["path": "Data > Quick Filter > Equal to Selection"]).error == nil)
            #expect(viewer.record == nil && viewer.grid.rowCount == 1 && viewer.grid.source is ReorderedSource)
        }

        /// F2 edits the focused cell, as in HeidiSQL; in a console result, which can't be edited, it shows the value panel.
        @Test func f2EditsTheCellOrShowsItsValue() async throws {
            let (main, harness, tab) = try await Self.tab()
            let window = try #require(main.window)
            window.makeFirstResponder(tab.grid)
            tab.grid.selection.select(GridPosition(row: 1, column: 2))
            #expect(await call(harness, "key", ["combo": "f2"]).error == nil)
            #expect(tab.grid.editor != nil && tab.grid.editor?.position == GridPosition(row: 1, column: 2))
            tab.grid.endEditing(commit: false)
            let viewer = try #require(resultViewer(main))
            #expect(await consoleTookTheFocus(main))  // else it could take it back from the grid, and F2 would rename the tab
            window.makeFirstResponder(viewer.grid)
            viewer.grid.selection.select(GridPosition(row: 0, column: 1))
            #expect(await call(harness, "key", ["combo": "f2"]).error == nil)
            #expect(viewer.grid.editor == nil && viewer.valuePanel != nil)
        }

        /// The condition is coloured as SQL, grows a line at a time up to eight (then scrolls), and Return applies it.
        @Test func whereBarColoursItsSQLAndGrowsToEightLines() async throws {
            let session = FakeTableSession()
            let (main, _, tab) = try await Self.tab(session: session)
            let field = tab.bar.whereField
            main.window?.makeFirstResponder(field)
            field.insertText("region IN ('EU')", replacementRange: field.selectedRange())
            let storage = try #require(field.textStorage)
            #expect(storage.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor == .sqlKeyword)
            #expect(storage.attribute(.foregroundColor, at: 11, effectiveRange: nil) as? NSColor == .sqlString)
            main.window?.layoutIfNeeded()
            let one = field.box.frame.height
            field.insertNewlineIgnoringFieldEditor(nil)
            field.insertText("OR total > 100", replacementRange: field.selectedRange())
            main.window?.layoutIfNeeded()
            let two = field.box.frame.height
            #expect(two > one + 10 && field.text == "region IN ('EU')\nOR total > 100")
            for _ in 0..<12 { field.insertNewlineIgnoringFieldEditor(nil) }
            main.window?.layoutIfNeeded()
            #expect(field.box.frame.height < one * 9 && field.box.frame.height > two * 3, "\(one) \(two) \(field.box.frame.height)")
            // Return applies it; the bar shrinks back with it.
            field.text = "region = 'EU'"
            main.window?.layoutIfNeeded()
            #expect(field.box.frame.height == one)
            field.insertNewline(nil)
            await ready { tab.loading != nil }
            #expect(session.statements.last?.contains(" WHERE (region = 'EU'\n) ORDER BY") == true)
        }

        @Test func consoleResultsCopyInTheGridsFormat() async throws {
            let view = ResultGridView(store: ConsoleFixtures.customers(rows: 2), nullText: "NULL", fontSize: 12)
            view.viewer.copy(nil)  // nothing selected: every row, in TSV
            #expect(NSPasteboard.general.string(forType: .string)
                    == "10482\tHarbor Supply Co.\tcustomer0@mail.example\t318\t184220.50\n"
                    + "10475\tNordlicht GmbH\tcustomer1@mail.example\t317\t183889.25\n")
            view.grid.selection.select(GridPosition(row: 1, column: 0))
            view.grid.selection.select(GridPosition(row: 1, column: 1), extend: true)
            let item = NSMenuItem()
            item.representedObject = CopyFormat.insert.rawValue
            view.viewer.copyAs(item)
            #expect(NSPasteboard.general.string(forType: .string) == "INSERT INTO `table` (`id`, `name`) VALUES (10475, 'Nordlicht GmbH');\n")
            view.viewer.copyWithHeaders(nil)
            #expect(NSPasteboard.general.string(forType: .string)?.hasPrefix("INSERT INTO") == true)
            GridCopy.format = .tsv
            // The headers sort the rows here: by spent, smallest first, then back.
            view.dataGrid(view.grid, sortBy: 4, adding: false)
            #expect(view.grid.sortOrder == [DataGridView.Sort(column: 4, ascending: true)] && view.rows.cell(0, 0) == .text("10475"))
            view.dataGrid(view.grid, sortBy: 4, adding: false)
            view.dataGrid(view.grid, sortBy: 4, adding: false)
            #expect(view.grid.sortOrder.isEmpty && view.rows.cell(0, 0) == .text("10482"))
            let menu = try #require(view.viewer.dataGrid(view.grid, menuFor: .cells))
            #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title)
                    == ["Copy", "Copy with Headers", "Copy As", "Quick Filter", "Clear Filter", "Export Rows…", "Copy Result to Table…", "Value Panel", "Record View", "Transpose",
                        "Column Summary…", "Chart", "Open URL", "Compare Cells", "Display As"])
        }

        @Test func readOnlyConnectionsRefuseEditsAndLongValuesOpenInTheValuePanel() async throws {
            let (_, _, readOnly) = try await Self.tab(readOnly: true)
            #expect(readOnly.notice.text.stringValue.hasPrefix("Read-only. This connection is read-only"))
            #expect(!readOnly.dataGrid(readOnly.grid, canEditRow: 0, column: 2))
            let item = Commands.addRow.item()
            #expect(!readOnly.validateMenuItem(item) && item.toolTip?.hasPrefix("This connection is read-only") == true)
            let session = FakeTableSession()
            session.rows[0][2] = String(repeating: "x", count: 1_200)
            let (_, _, tab) = try await Self.tab(session: session)
            // A value longer than a cell shows is edited in the value panel.
            tab.grid.beginEditing(at: GridPosition(row: 0, column: 2))
            #expect(tab.grid.editor == nil && tab.viewer.valuePanel?.keep != nil && tab.viewer.valuePanel?.text.isEditable == true)
            tab.viewer.toggleValuePanel(nil)
            tab.grid.selection.select(GridPosition(row: 0, column: 2))
            tab.setCellNull(nil)  // region is NOT NULL: refused, with a beep
            #expect(tab.source?.mark(0, 2) == GridMark.none)
            tab.setCellDefault(nil)  // the whole value is replaced, so that's fine
            #expect(tab.source?.cell(0, 2) == .placeholder("default"))
            tab.revertAllChanges(nil)
        }

        @Test func aReadOnlyConnectionSendsOnlyFiltersThatProvablyRead() async throws {
            let session = FakeTableSession()
            let (main, _, tab) = try await Self.tab(session: session, readOnly: true)
            let sent = session.statements.count
            // A condition calling a function the read-only check doesn't know is refused before it is sent; the rows stay.
            tab.applyFilter("region = 'EU' OR SLEEP(5) = 0")
            #expect(session.statements.count == sent && tab.source?.filter == "" && tab.grid.rowCount == 3)
            #expect(tab.notice.text.stringValue.contains("is read-only, so nothing ran. SLEEP() isn't on the list"))
            #expect(tab.bar.scope.text == "On server · all rows")
            // The tab's other statements keep the filter that ran.
            tab.countRows(nil)
            await ready { tab.loading != nil }
            #expect(session.statements.last == "SELECT COUNT(*) FROM `airsql_fixture`.`orders`")
            // A plain condition runs, a subquery too.
            tab.applyFilter("region = 'EU' AND customer_id IN (SELECT id FROM customers)")
            await ready { tab.loading != nil }
            #expect(session.statements.last?.contains(" WHERE (region = 'EU' AND customer_id IN (SELECT id FROM customers)\n)") == true)
            #expect(tab.notice.text.stringValue.hasPrefix("Read-only. This connection is read-only"))

            // A refused filter a tab opens with stays in the bar, unused, and no rows load until it changes.
            let connection = try #require(main.model.data.connections.first)
            let opened = TableDataController(model: main.model, context: try await recordedEditorContext(connection),
                                             database: "airsql_fixture", table: "orders", filter: "id IN (SELECT GET_LOCK('x', 1))")
            let quiet = FakeTableSession()
            opened.openSession = { quiet }
            main.select(main.open(opened, title: "orders", connection: connection.id))
            await ready { opened.loading != nil || (opened.source == nil && opened.problem == nil) }
            #expect(quiet.statements.isEmpty && opened.source?.filter == "" && opened.bar.filterText.contains("GET_LOCK"))
            #expect(opened.notice.text.stringValue.contains("GET_LOCK() isn't on the list")
                    && opened.bar.scope.text == "On server · all rows")
            opened.applyFilter("")
            await ready { opened.loading != nil }
            #expect(opened.grid.rowCount == 3 && opened.problem == nil)
        }

        /// The tab takes `info` as a Refresh does, and waits with the new rows in and the read after them (the estimate) held.
        func refresh(_ tab: TableDataController, _ session: FakeTableSession, to info: SchemaTable) async {
            session.hold = { $0.hasPrefix("SELECT TABLE_ROWS") }
            tab.adopt(info)
            tab.reloadRows()
            await ready { session.held == nil }
        }

        @Test func aColumnGoneFromTheTableIsAskedForByNothing() async throws {
            let session = FakeTableSession()
            let (_, _, tab) = try await Self.tab(session: session)
            let old = try #require(tab.source)
            tab.grid.selection.select(GridPosition(row: 0, column: 5))
            _ = tab.grid.cellSuffix?(0, 5)  // the labels' keys, by the old columns
            var info = old.table
            info.columns.removeLast()
            session.columns.removeLast()
            session.rows = session.rows.map { Array($0.dropLast()) }
            await refresh(tab, session, to: info)
            // The new rows are in and the grid has yet to show them: what its drawing and the menus reach mustn't trap.
            #expect(tab.source !== old && tab.source?.loadedRows == 3 && tab.source?.columns.count == 5)
            #expect(tab.viewer.source == nil && tab.viewer.focusedCell == nil)
            #expect(tab.grid.cellSuffix?(0, 5) == nil && !tab.filtersOnCutValue)
            _ = tab.validateMenuItem(Commands.loadFullCell.item())
            _ = try await session.cancel(statement: nil)
            await ready { tab.loading != nil }
            #expect(tab.viewer.source === tab.source && tab.grid.columnCount == 5)
        }

        @Test func aSearchFollowsTheTableToItsNewColumns() async throws {
            let session = FakeTableSession()
            let (_, _, tab) = try await Self.tab(session: session)
            let old = try #require(tab.source)
            tab.search("EU", loadedOnly: true)
            var info = old.table
            info.columns.append(info.columns[2])
            info.columns[6].name = "added"
            session.columns.append(.init(name: "added", type: MYSQL_TYPE_STRING))
            session.rows = session.rows.map { $0 + ["EU"] }
            await refresh(tab, session, to: info)
            _ = try await session.cancel(statement: nil)
            await ready { tab.loading != nil }
            // The tint, as a cell of the new column draws: it reads the new source, and the search goes on.
            #expect(tab.viewer.source === tab.source && tab.grid.columnCount == 7)
            #expect(tab.viewer.highlight?(0, 6) == true && tab.source?.localFilter != nil)
        }

        @Test func aPageOnItsWayKeepsItsColumns() async throws {
            let session = FakeTableSession()
            let (_, _, tab) = try await Self.tab(session: session)
            let old = try #require(tab.source)
            session.hold = { $0.hasPrefix("SELECT `id`") }
            tab.loadMore(nil)
            await ready { session.held == nil }
            tab.refresh(nil)  // no: the source can't change under a page on its way
            #expect(tab.source === old && tab.viewer.source === old)
            _ = try await session.cancel(statement: nil)
            await ready { tab.loading != nil }
            #expect(tab.source === old && tab.viewer.source === old)
        }

        @Test func viewsAreReadOnlyAndSayWhy() async throws {
            let (_, _, tab) = try await Self.tab("customer_emails", session: .emails())
            #expect(!tab.notice.isHidden && tab.notice.text.stringValue.hasPrefix("Read-only. A view has no key to address its rows"))
            #expect(tab.source?.canEdit(0, 0) == false)
            let item = Commands.addRow.item()
            #expect(!tab.validateMenuItem(item) && item.toolTip?.hasPrefix("A view has no key") == true)
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
            #expect(again.source?.cell(0, 2) == .text("ZZ") && again.notice.text.stringValue.hasPrefix("Kept from before: "))
            again.revertAllChanges(nil)
            PendingChangesStore.shared.flush()
        }

        /// At the window's smallest the bar's search and condition narrow, and so do Find and Replace's fields, then its
        /// count (whole in its tooltip): the tab doesn't widen the window.
        @Test func theTableTabKeepsTheWindowAtItsMinimumSize() async throws {
            let (main, _, tab) = try await Self.tab(size: MainWindowController.minimumSize)
            main.window?.layoutIfNeeded()
            #expect(main.window?.frame.width == MainWindowController.minimumSize.width)
            #expect(tab.bar.whereField.box.frame.width >= 80 && tab.bar.searchField.frame.width >= 150,
                    "\(tab.bar.whereField.box.frame.width), \(tab.bar.searchField.frame.width)")
            for replacing in [false, true] {
                tab.findBar.show(replacing: replacing)
                for count in ["", "12,345 of 67,890", "Not a valid regular expression"] {
                    tab.findBar.setCount(count)
                    main.window?.layoutIfNeeded()
                    #expect(main.window?.frame.width == MainWindowController.minimumSize.width, "replacing: \(replacing), “\(count)”")
                }
                #expect(tab.findBar.findField.frame.width >= 100 && tab.findBar.count.toolTip == "Not a valid regular expression")
            }
            tab.findBar.close(nil)
        }

        @Test func theStatusBarKeepsTheRowsAndPagingLinksAtEveryWidth() async throws {
            let session = FakeTableSession()
            // A full page: more rows to load, so Count Exactly, Load More and Load All show.
            session.rows = (1...1_000).map { [String($0), "7", "EU", "100", "\($0).25", nil] }
            let (main, _, tab) = try await Self.tab(session: session, size: NSSize(width: 1800, height: 720))
            let model = main.model, id = model.data.connections[0].id
            model.data.connections[0].host = "warehouse-primary.analytics.internal.example.com"
            model.states[id] = .connected(server: "MariaDB 11.8.3-MariaDB-ubu2404-log")
            let status = tab.viewer.status, bar = main.statusBar
            status.rows.stringValue = "1,000 of about 2,348,245 rows"
            tab.grid.selection.select(GridPosition(row: 2, column: 4))
            tab.grid.selection.select(GridPosition(row: 40, column: 4), extend: true)
            status.update()
            // On the bar, whole and not overlapping another item.
            func shown(_ views: [NSView]) -> Bool {
                views.allSatisfy { view in
                    guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return false }
                    return bar.bounds.contains(view.convert(view.bounds, to: bar).insetBy(dx: 1, dy: 1))
                }
            }
            let kept = [status.rows, tab.countLink, tab.moreLink, tab.allLink], selection = [status.position, status.figure]
            // The default window, the smallest and a wide one, then back: the figure, then the position, step out for
            // room and come back with it; the rows and the links always stay.
            for agent in [nil, "Claude Code · reading the schema"] {
                model.agentStatus = agent
                main.refresh()
                for width in [1224.0, 900, 1800, 900, 1224] {
                    main.window?.setFrame(NSRect(origin: NSPoint(x: -20000, y: -20000), size: NSSize(width: width, height: 720)), display: false)
                    main.window?.layoutIfNeeded()
                    let place = "\(Int(width)) pt\(agent == nil ? "" : " with the agents' chip")"
                    #expect(shown(kept), "\(place)")
                    if width == 1800 || width == 1224 && agent == nil { #expect(shown(selection), "\(place)") }
                    let items = (kept + selection + [bar.route, bar.server, bar.agent, bar.sqlLog]).filter { shown([$0]) }
                        .map { $0.convert($0.bounds, to: bar) }.sorted { $0.minX < $1.minX }
                    #expect(zip(items, items.dropFirst()).allSatisfy { $0.maxX <= $1.minX + 0.5 }, "\(place): \(items)")
                }
            }
            main.window?.orderOut(nil)
        }
    }
}

extension AppTests.ScreenshotTests {
    /// The table tab: rows with pending changes and a filter, the Apply preview, the smallest window with the find bar,
    /// and a read-only view.
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
            let (main, harness, tab) = try await AppTests.GridDataAppTests.tab(session: session, size: NSSize(width: 1180, height: 720))
            main.window?.appearance = NSAppearance(named: appearance)
            main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
            main.window?.orderFront(nil)
            tab.applyFilter("region IN ('EU', 'US') AND total > 100")
            await ready { tab.loading != nil }
            tab.source?.set(.text("1999.90"), row: 1, column: 4)
            tab.source?.set(.text("UK"), row: 3, column: 2)  // region is char(2)
            tab.source?.changes.delete([["2400965"]])
            tab.source?.changes.addRow(["region": .text("EU"), "number": .text("9100"), "total": .text("42.00")])
            tab.changesDidChange()
            tab.grid.selection.select(GridPosition(row: 1, column: 4))
            main.window?.makeFirstResponder(tab.grid)
            main.window?.displayIfNeeded()
            try await save(harness, "table-data-\(suffix)")

            // Sort by Columns… with two columns, and Type a Value….
            tab.sortColumns(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await call(harness, "set", ["id": "sort.column.0", "value": "region"])
            _ = await call(harness, "press", ["id": "sort.add"])
            _ = await call(harness, "set", ["id": "sort.direction.1", "value": "Descending"])
            try await save(harness, "table-data-sort-\(suffix)", target: "sheet")
            _ = await call(harness, "press", ["id": "sort.cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            tab.grid.selection.select(GridPosition(row: 1, column: 4))
            tab.quickFilterPrompt(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await call(harness, "set", ["id": "quickFilter.operator", "value": "Greater than (>)"])
            try await save(harness, "table-data-type-a-value-\(suffix)", target: "sheet")
            _ = await call(harness, "press", ["title": "Cancel", "in": "sheet"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            tab.previewChanges(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            try await save(harness, "table-data-preview-\(suffix)", target: "sheet")
            _ = await call(harness, "press", ["title": "Cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            tab.revertAllChanges(nil)
            // A console result filtered and searched in its own bar.
            if let viewer = resultViewer(main), let result = viewer.superview as? ResultGridView {
                viewer.grid.selection.select(GridPosition(row: 1, column: 3))
                result.quickFilter(Commands.filterGreater.item())
                result.filterBar.searchField.stringValue = "Harbor"
                result.reorder()
                main.window?.makeFirstResponder(viewer.grid)
                main.window?.displayIfNeeded()
                try await save(harness, "console-result-filter-\(suffix)")
            }
            main.window?.orderOut(nil)

            // The smallest window, with the find bar.
            let (small, smallHarness, smallTab) = try await AppTests.GridDataAppTests.tab(session: session, size: MainWindowController.minimumSize)
            small.window?.appearance = NSAppearance(named: appearance)
            small.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
            small.window?.orderFront(nil)
            smallTab.source?.set(.text("APAC"), row: 3, column: 2)
            smallTab.changesDidChange()
            // A long condition wraps: the bar grows a line at a time, up to eight.
            smallTab.bar.filterText = "region IN ('EU', 'US') AND total > 100 AND created_at >= NOW() - INTERVAL 90 DAY -- this quarter"
            smallTab.performTextFinderAction(nil)
            smallTab.findBar.findField.stringValue = "EU"
            smallTab.findChanged()
            small.window?.displayIfNeeded()
            try await save(smallHarness, "table-data-small-\(suffix)")
            smallTab.revertAllChanges(nil)
            small.window?.orderOut(nil)

            let (viewMain, viewHarness, _) = try await AppTests.GridDataAppTests.tab("customer_emails", session: .emails(),
                                                                            size: NSSize(width: 1180, height: 520))
            viewMain.window?.appearance = NSAppearance(named: appearance)
            viewMain.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
            viewMain.window?.orderFront(nil)
            viewMain.window?.displayIfNeeded()
            try await save(viewHarness, "table-data-read-only-\(suffix)")
            viewMain.window?.orderOut(nil)

            // A read-only connection refusing a filter, in the smallest window: the notice says why.
            let (locked, lockedHarness, lockedTab) = try await AppTests.GridDataAppTests.tab(
                session: session, size: MainWindowController.minimumSize, readOnly: true)
            locked.window?.appearance = NSAppearance(named: appearance)
            locked.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
            locked.window?.orderFront(nil)
            lockedTab.applyFilter("region = 'EU' OR SLEEP(5) = 0")
            locked.window?.displayIfNeeded()
            try await save(lockedHarness, "table-data-read-only-filter-\(suffix)")
            locked.window?.orderOut(nil)
        }
    }
}

extension AppTests.HelpTests {
    /// Every control of the table tab, its find bar, notices and sheets has a tooltip, and so does every item of its
    /// menus.
    @Test func everyControlOfTheTableTabSaysWhatItDoes() async throws {
        let session = FakeTableSession()
        let (main, harness, tab) = try await AppTests.GridDataAppTests.tab(session: session)
        let window = try #require(main.window)
        tab.source?.set(.text("x"), row: 0, column: 2)
        tab.changesDidChange()
        let replace = NSMenuItem()
        replace.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        tab.performTextFinderAction(replace)
        var missing = unexplained([window], where: "table tab")
        tab.grid.selection.select(GridPosition(row: 0, column: 1))
        for target in [DataGridView.Target.cells, .column(1), .row(0)] {
            if let menu = tab.viewer.dataGrid(tab.grid, menuFor: target) { missing += unexplained(menu, path: ["\(target)"]) }
        }
        tab.exportRows(nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        missing += unexplained([try #require(window.attachedSheet)], where: "Export Rows")
        _ = await call(harness, "press", ["id": "export.cancel"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        tab.filterByValues(nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        _ = await eventually(timeout: 10) { session.statements.contains { $0.contains(" GROUP BY ") } }
        missing += unexplained([try #require(window.attachedSheet)], where: "Filter by Values")
        _ = await call(harness, "press", ["id": "values.cancel"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        tab.sortColumns(nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        _ = await call(harness, "press", ["id": "sort.add"])
        missing += unexplained([try #require(window.attachedSheet)], where: "Sort by Columns")
        _ = await call(harness, "press", ["id": "sort.cancel"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        tab.grid.selection.select(GridPosition(row: 0, column: 2))
        tab.quickFilterPrompt(nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        missing += unexplained([try #require(window.attachedSheet)], where: "Type a Value")
        _ = await call(harness, "press", ["title": "Cancel", "in": "sheet"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        tab.revertAllChanges(nil)
        // A console result's filter bar, and its menus.
        let viewer = try #require(resultViewer(main))
        let result = try #require(viewer.superview as? ResultGridView)
        viewer.grid.selection.select(GridPosition(row: 0, column: 1))
        result.quickFilterEquals(nil)
        missing += unexplained([window], where: "console result")
        for target in [DataGridView.Target.cells, .column(1), .row(0)] {
            if let menu = viewer.dataGrid(viewer.grid, menuFor: target) { missing += unexplained(menu, path: ["result \(target)"]) }
        }
        #expect(missing.isEmpty, "\(missing)")
    }
}

extension AppTests.LayoutTests {
    /// The table tab's polish (plan §2.13): its bars and notices with long text, the find bar, and its sheets, in light
    /// and dark, at the window's smallest and default size.
    @Test func tableTabIsTidyInLightAndDarkAtEverySize() async throws {
        var problems: [String] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for size in [MainWindowController.minimumSize, MainWindowController.defaultSize] {
                let place = "\(appearance == .aqua ? "light" : "dark") \(Int(size.width))×\(Int(size.height))"
                let session = FakeTableSession()
                session.rows[0][2] = String(repeating: "A very long region name ", count: 20)
                let (main, harness, tab) = try await AppTests.GridDataAppTests.tab(session: session, size: size)
                let window = try #require(main.window)
                func check(_ what: String, _ in: NSWindow? = nil) {
                    let target = `in` ?? window
                    target.appearance = NSAppearance(named: appearance)
                    target.contentView?.layoutSubtreeIfNeeded()
                    // The window's own layout, which widens it if the tab needs more room: the step stays at its size.
                    window.layoutIfNeeded()
                    if window.frame.width != size.width { problems.append("\(place) \(what): the window is \(Int(window.frame.width)) wide") }
                    if let content = target.contentView { problems += layoutProblems(content, where: "\(place) \(what)") }
                }
                check("table tab")
                tab.applyFilter("region = 'EU' AND " + String(repeating: "total > 100 AND ", count: 20) + "1")
                await ready { tab.loading != nil }
                for row in 0..<3 { tab.source?.set(.text("x"), row: row, column: 2) }
                tab.source?.changes.addRow()
                tab.changesDidChange()
                check("pending changes")
                tab.problem = "The rows didn't load: " + String(repeating: "You have an error in your SQL syntax; ", count: 6)
                tab.updateBars()
                check("a problem")
                tab.problem = nil
                tab.performTextFinderAction(nil)
                let replace = NSMenuItem()
                replace.tag = NSTextFinder.Action.showReplaceInterface.rawValue
                tab.performTextFinderAction(replace)
                tab.findBar.findField.stringValue = "EU"
                tab.findChanged()
                check("find and replace")
                tab.exportRows(nil)
                _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
                check("Export Rows", window.attachedSheet)
                _ = await call(harness, "press", ["id": "export.cancel"])
                _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
                tab.grid.selection.select(GridPosition(row: 0, column: 2))
                tab.filterByValues(nil)
                _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
                _ = await eventually(timeout: 10) { session.statements.contains { $0.contains(" GROUP BY ") } }
                check("Filter by Values", window.attachedSheet)
                _ = await call(harness, "press", ["id": "values.cancel"])
                _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
                tab.sortColumns(nil)
                _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
                for _ in 0..<3 { _ = await call(harness, "press", ["id": "sort.add"]) }
                check("Sort by Columns", window.attachedSheet)
                _ = await call(harness, "press", ["id": "sort.cancel"])
                _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
                tab.quickFilterPrompt(nil)
                _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
                check("Type a Value", window.attachedSheet)
                _ = await call(harness, "press", ["title": "Cancel", "in": "sheet"])
                _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
                // A console result filtered by long conditions, in the same window.
                if let viewer = resultViewer(main), let result = viewer.superview as? ResultGridView {
                    for column in 1...4 {
                        viewer.grid.selection.select(GridPosition(row: 0, column: column))
                        result.filter(column, by: GridCondition(result.source.columns[column], .notEquals, [String(repeating: "long ", count: 12)]),
                                      adding: true)
                    }
                    check("console result's filter bar")
                }
                tab.revertAllChanges(nil)
                let (viewMain, _, _) = try await AppTests.GridDataAppTests.tab("customer_emails", session: .emails(), size: size)
                viewMain.window?.appearance = NSAppearance(named: appearance)
                viewMain.window?.contentView?.layoutSubtreeIfNeeded()
                if let content = viewMain.window?.contentView { problems += layoutProblems(content, where: "\(place) read-only view") }
                window.orderOut(nil)
                viewMain.window?.orderOut(nil)
            }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }
}
