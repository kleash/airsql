import AppKit
import CMariaDB
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

extension AppTests {
    /// Editing a console's result (grid-spec §5): one table with its key, or an inner join with every table's key,
    /// through pending changes, the preview and Apply on the data session; the rest say why they're read-only.
    @MainActor @Suite struct GridEditResultAppTests {
        /// A console result of `sql` in a window, on the recorded fixture, its data session `session`, once its rules are
        /// worked out.
        static func result(_ sql: String, _ columns: [ResultStore.Column], rows: [[String?]], session: FakeTableSession,
                           readOnly: Bool = false) async throws -> (MainWindowController, AgentServer, ResultGridView) {
            var connection = SavedConnection(name: "Local", host: "127.0.0.1", user: "app")
            connection.readOnly = readOnly
            let (main, harness) = appWindow(testModel([connection]))
            let store = ResultStore(columns: columns)
            for row in rows { store.append(row.map { $0.map { Array($0.utf8) } }) }
            let view = ResultGridView(store: store, nullText: "NULL", fontSize: 12, editable: true)
            view.editingContext = try await recordedEditorContext(connection)
            view.model = main.model
            view.openSession = { session }
            main.window?.contentView = view
            main.window?.layoutIfNeeded()
            view.prepareEditing(sql: sql, database: "airsql_fixture", noBackslashEscapes: false)
            await ready { view.edits?.editing == nil }
            return (main, harness, view)
        }

        static func column(_ alias: String, _ table: String, _ name: String, _ type: enum_field_types = MYSQL_TYPE_VAR_STRING) -> ResultStore.Column {
            ResultStore.Column(name: name, originalName: table.isEmpty ? "" : name, table: alias, originalTable: table,
                               database: table.isEmpty ? "" : "airsql_fixture", type: type)
        }

        /// ENUM, dates, Set DEFAULT, Insert Value, Paste and foreign keys work as in a table tab.
        @Test func aResultsCellsEditByTheirType() async throws {
            let c = { Self.column("customers", "customers", $0, $1) }
            let (main, harness, view) = try await Self.result("SELECT id, balance, status, created, note FROM customers",
                                                        [c("id", MYSQL_TYPE_LONG), c("balance", MYSQL_TYPE_NEWDECIMAL), c("status", MYSQL_TYPE_VAR_STRING),
                                                         c("created", MYSQL_TYPE_TIMESTAMP), c("note", MYSQL_TYPE_VAR_STRING)],
                                                        rows: [["1", "2.00", "new", "2026-01-02 03:04:05", nil], ["2", "3.00", "active", "2026-01-02 03:04:05", "x"]],
                                                        session: FakeTableSession())
            let edits = try #require(view.edits), grid = view.grid
            // The real key reaches the viewer up the responder chain: Esc narrows the selection.
            main.window?.makeFirstResponder(grid)
            grid.selection.select(GridPosition(row: 0, column: 1))
            grid.selection.select(GridPosition(row: 1, column: 2), extend: true)
            _ = await call(harness, "key", ["combo": "escape"])
            #expect(!grid.selection.contains(GridPosition(row: 1, column: 1)) || !grid.selection.contains(GridPosition(row: 0, column: 1)))
            #expect(view.dataGrid(grid, step: "2026-01-02 03:04:05", at: 9, by: 1, row: 0, column: 3)?.text == "2026-01-03 03:04:05")

            grid.selection.select(GridPosition(row: 0, column: 2))
            let item = NSMenuItem()
            item.representedObject = "gone"
            view.pickMember(item)
            #expect(edits.value(0, 2) == "gone")
            view.setCellDefault(nil)
            #expect(edits.mark(0, 2) == .edited)

            grid.selection.select(GridPosition(row: 1, column: 3))
            #expect(!view.insertValueItems().isEmpty)

            let board = NSPasteboard.general
            board.clearContents()
            board.setString("5\tactive\n6\tnew\n7\tnew", forType: .string)  // the third row is past the result's last
            grid.selection.select(GridPosition(row: 0, column: 1))
            view.paste(nil)
            #expect(edits.value(0, 1) == "5" && edits.value(0, 2) == "active" && edits.value(1, 1) == "6" && edits.value(1, 2) == "new")
            board.clearContents()
            board.setString("not a number", forType: .string)
            view.paste(nil)
            #expect(edits.value(0, 1) == "5" && main.window?.attachedSheet != nil)
            main.window?.attachedSheet.map { main.window?.endSheet($0) }

            let o = { Self.column("orders", "orders", $0, $1) }
            let (_, _, orders) = try await Self.result("SELECT id, region, customer_id FROM orders",
                                                       [o("id", MYSQL_TYPE_LONGLONG), o("region", MYSQL_TYPE_VAR_STRING), o("customer_id", MYSQL_TYPE_LONG)],
                                                       rows: [["1", "EU", "2"]], session: FakeTableSession())
            orders.grid.selection.select(GridPosition(row: 0, column: 2))
            #expect(orders.foreignKey(2)?.columns == [2] && orders.dataGrid(orders.grid, edit: 0, column: 2, typed: nil) && orders.lookup != nil)
            orders.lookup?.popover.close()
            #expect(!orders.dataGrid(orders.grid, edit: 0, column: 2, typed: "7"))  // typing edits the key as text
        }

        @Test func aOneTableResultEditsAndAppliesLikeATable() async throws {
            let session = FakeTableSession()
            session.columns = [.init(name: "id", type: MYSQL_TYPE_LONG), .init(name: "email", type: MYSQL_TYPE_VAR_STRING),
                               .init(name: "name", type: MYSQL_TYPE_VAR_STRING)]
            session.edited = [["1", "ANN@EXAMPLE.NET", "Ann"]]
            let c = { Self.column("customers", "customers", $0, $1) }
            let (main, harness, view) = try await Self.result("SELECT id, email, NOW() AS at, name FROM customers",
                                                     [c("id", MYSQL_TYPE_LONG), c("email", MYSQL_TYPE_VAR_STRING), Self.column("", "", "at"),
                                                      c("name", MYSQL_TYPE_VAR_STRING)],
                                                     rows: [["1", "ann@example.com", "x", "Ann"], ["2", "bo@example.org", "y", "Bo"]],
                                                     session: session)
            #expect(view.editState.stringValue == "Editable" && !view.editState.isHidden && view.notice.isHidden)
            #expect(view.dataGrid(view.grid, canEditRow: 0, column: 1) && !view.dataGrid(view.grid, canEditRow: 0, column: 2))
            #expect(view.whyReadOnly(0, 2) == "Worked out by the query, not a column of a table")
            // A value its column refuses keeps the editor open, saying why.
            #expect(view.dataGrid(view.grid, check: "x", row: 0, column: 0) != nil)
            view.grid.selection.select(GridPosition(row: 0, column: 1))
            view.grid.insertText("ann@example.net")
            #expect(view.grid.endEditing(commit: true))
            view.grid.selection.selectRow(1)
            view.deleteRows(nil)
            #expect(view.source.mark(0, 1) == .edited && view.source.mark(1, 0) == .deleted && !view.notice.isHidden)
            #expect(view.notice.text.stringValue.hasPrefix("2 rows have pending changes"))
            let save = Commands.save.item()
            #expect(view.responds(to: save.action) && view.validateMenuItem(save))
            view.undo(nil)
            #expect(view.source.mark(1, 0) == GridMark.none)
            view.redo(nil)
            // Deleting customers also changes orders through their foreign key: the preview says so first.
            view.applyChanges(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(shownText("preview.heading", in: main.window?.attachedSheet) == "Apply 2 changes to customers?")
            _ = await call(harness, "press", ["title": "Apply"])
            await ready { view.edits?.isEmpty == false }
            #expect(session.statements == ["START TRANSACTION", "DELETE FROM `airsql_fixture`.`customers` WHERE `id` IN (2)",
                                           "UPDATE `airsql_fixture`.`customers` SET `email` = 'ann@example.net' WHERE `id` = 1 AND `email` <=> 'ann@example.com'", "COMMIT",
                                           "SELECT `id`, `email`, `name` FROM `airsql_fixture`.`customers` WHERE `id` IN (1)"])
            // What the server kept shows; the deleted row is gone.
            #expect(view.grid.rowCount == 1 && view.source.cell(0, 1) == .text("ANN@EXAMPLE.NET") && view.notice.isHidden)
            #expect(!view.responds(to: save.action))
        }

        @Test func aJoinShowsTheSQLFirstAndOtherResultsSayWhy() async throws {
            let session = FakeTableSession()
            let o = { Self.column("o", "orders", $0, MYSQL_TYPE_LONG) }, c = { Self.column("c", "customers", $0) }
            let (main, harness, view) = try await Self.result(
                "SELECT o.id, o.number, c.id, c.email FROM orders o JOIN customers c ON c.id = o.customer_id",
                [o("id"), o("number"), Self.column("c", "customers", "id", MYSQL_TYPE_LONG), c("email")],
                rows: [["1", "100", "7", "ann@example.com"], ["2", "101", "9", "cy@example.org"]], session: session)
            #expect(view.editState.toolTip?.contains("Apply shows the SQL first") == true)
            view.grid.selection.select(GridPosition(row: 1, column: 3))
            view.grid.insertText("cy@example.net")
            #expect(view.grid.endEditing(commit: true))
            view.applyChanges(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            let sql = shownText("preview.sql", in: main.window?.attachedSheet) ?? ""
            #expect(sql.contains("UPDATE `airsql_fixture`.`customers` SET `email` = 'cy@example.net' WHERE `id` = 9 AND `email` <=> 'cy@example.org';"))
            #expect(!session.statements.contains("START TRANSACTION"))
            _ = await call(harness, "press", ["title": "Cancel"])
            #expect(view.edits?.pendingRows == 1)

            // Grouped results can't be edited: the status bar and a double-click say why.
            let (_, _, grouped) = try await Self.result("SELECT customer_id, COUNT(*) FROM orders GROUP BY customer_id",
                                                        [o("customer_id"), Self.column("", "", "COUNT(*)")], rows: [["7", "2"]],
                                                        session: FakeTableSession())
            #expect(grouped.editState.stringValue == "Read-only" && grouped.editState.toolTip == "Grouped results are read-only: a row stands for many")
            #expect(!grouped.dataGrid(grouped.grid, canEditRow: 0, column: 0) && grouped.viewer.dataGrid(grouped.grid, menuFor: .cells)?
                .items.contains { $0.action == Commands.apply.action } == false)
            grouped.grid.selection.select(GridPosition(row: 0, column: 0))
            grouped.viewer.dataGridOpenValue(grouped.grid)
            #expect(grouped.viewer.valuePanel != nil)
        }

        @Test func editAsTableOpensInsertsAsNewRowsThatPreviewFirst() async throws {
            let model = testModel([Fixtures.local])
            let (main, harness) = appWindow(model)
            let connected = Editors.open
            defer { Editors.open = connected }
            let context = try await recordedEditorContext(Fixtures.local)
            Editors.open = { $1 == Fixtures.local.id ? (context.sessions, context.schema) : nil }
            let console = ConsoleViewController(model: model, connection: Fixtures.local.id,
                                                text: "SELECT 1;\nINSERT INTO airsql_fixture.orders (region, number, total) VALUES ('EU', 7, 1.5), ('US', 8, DEFAULT);")
            main.open(console, title: "Query 1", connection: Fixtures.local.id)
            console.editor.setSelectedRange(NSRange(location: 20, length: 0))  // in the INSERT
            console.editAsTable(nil)
            let tab = try #require(main.selectedTab?.content as? TableDataController)
            let session = FakeTableSession()
            tab.openSession = { session }
            await ready { tab.loading != nil || tab.source == nil }
            let inserts = tab.source?.changes.state.inserts ?? []
            #expect(inserts.map(\.values) == [["region": .text("EU"), "number": .text("7"), "total": .text("1.5")],
                                              ["region": .text("US"), "number": .text("8"), "total": .default]])
            #expect(tab.grid.rowCount == 5 && tab.grid.selection.cursor?.row == 3 && tab.isEdited)
            // Apply shows the SQL first; one undo takes both rows back.
            tab.applyChanges(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            let sql = shownText("preview.sql", in: main.window?.attachedSheet) ?? ""
            #expect(sql.contains("INSERT INTO `airsql_fixture`.`orders` (`region`, `number`, `total`) VALUES ('EU', 7, 1.5);"))
            _ = await call(harness, "press", ["title": "Cancel"])
            #expect(!session.statements.contains("START TRANSACTION"))
            tab.undo(nil)
            #expect(tab.source?.changes.isEmpty == true)
            // A statement that isn't an INSERT … VALUES says so.
            main.select(try #require(main.tabs.first { $0.content === console }))
            console.editor.setSelectedRange(NSRange(location: 2, length: 0))
            console.editAsTable(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(main.window?.attachedSheet != nil)
            _ = await call(harness, "press", ["title": "OK"])
        }

        @Test func aReadOnlyConnectionsResultSaysWhy() async throws {
            let c = { Self.column("customers", "customers", $0, MYSQL_TYPE_LONG) }
            let (_, _, view) = try await Self.result("SELECT id FROM customers", [c("id")], rows: [["1"]], session: FakeTableSession(),
                                                     readOnly: true)
            #expect(view.editState.stringValue == "Read-only" && view.editState.toolTip?.hasPrefix("This connection is read-only") == true)
            #expect(!view.dataGrid(view.grid, canEditRow: 0, column: 0) && view.whyReadOnly(0, 0)?.hasPrefix("This connection is read-only") == true)
        }

        /// Record View's row deleted by Apply: the grid again, with the rows left (it read past them), sorted as before.
        @Test func applyingTheDeleteOfRecordViewsRowShowsTheGrid() async throws {
            let session = FakeTableSession()
            session.columns = [.init(name: "id", type: MYSQL_TYPE_LONG), .init(name: "email", type: MYSQL_TYPE_VAR_STRING)]
            let c = { Self.column("customers", "customers", $0, $1) }
            let (_, harness, view) = try await Self.result("SELECT id, email FROM customers",
                                                           [c("id", MYSQL_TYPE_LONG), c("email", MYSQL_TYPE_VAR_STRING)],
                                                           rows: [["1", "a@example.com"], ["2", "b@example.org"], ["3", "c@example.net"]],
                                                           session: session)
            func deleteInRecordView(row: Int) async {
                view.grid.selection.select(GridPosition(row: row, column: 1))
                view.viewer.showRecordView(nil)
                #expect(view.viewer.record == row)
                view.deleteRows(nil)
                view.applyChanges(nil)
                _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
                _ = await call(harness, "press", ["title": "Apply"])
                await ready { view.edits?.isEmpty == false }
            }
            await deleteInRecordView(row: 2)
            #expect(session.statements.contains("DELETE FROM `airsql_fixture`.`customers` WHERE `id` IN (3)"))
            #expect(view.viewer.record == nil && view.grid.source === view.rows && view.grid.rowCount == 2)
            // Sorted, the rows' order is worked out again before the grid shows them.
            let descending = [DataGridView.Sort(column: 0, ascending: false)]
            view.sortRows(descending)
            await deleteInRecordView(row: 0)
            #expect(session.statements.contains("DELETE FROM `airsql_fixture`.`customers` WHERE `id` IN (2)"))
            #expect(view.viewer.record == nil && view.grid.sortOrder == descending && view.rows.order == [0] && view.grid.rowCount == 1)
        }

        /// A filter or a sort from Record View shows the grid, filtered and sorted, rather than another row (or a row
        /// past the end); the sort set before Record View stays.
        @Test func aFilterOrSortFromRecordViewShowsTheGrid() async throws {
            let (main, _) = appWindow(testModel())
            let store = ResultStore(columns: [ResultStore.Column(name: "id", type: MYSQL_TYPE_LONG),
                                              ResultStore.Column(name: "name", type: MYSQL_TYPE_VAR_STRING)])
            for row in 0..<5 { store.append([Array("\(row)".utf8), Array("n\(row % 2)".utf8)]) }
            let view = ResultGridView(store: store, nullText: "NULL", fontSize: 12)
            main.window?.contentView = view
            main.window?.layoutIfNeeded()
            view.grid.selection.select(GridPosition(row: 4, column: 1))
            view.viewer.showRecordView(nil)
            view.quickFilterEquals(nil)
            #expect(view.viewer.record == nil && view.rows.order == [0, 2, 4] && view.grid.rowCount == 3)
            view.clearFilter(nil)
            let descending = [DataGridView.Sort(column: 0, ascending: false)]
            view.sortRows(descending)
            view.grid.selection.select(GridPosition(row: 0, column: 1))
            view.viewer.showRecordView(nil)
            #expect(view.viewer.record == 0 && view.grid.source?.cell(0, 1) == .text("4"))
            view.quickFilterEquals(nil)
            #expect(view.viewer.record == nil && view.grid.sortOrder == descending && view.rows.order == [4, 2, 0])
            view.viewer.showRecordView(nil)
            view.sortAscending(nil)
            #expect(view.viewer.record == nil && view.grid.sortOrder == [DataGridView.Sort(column: 1, ascending: true)])
        }

        /// A result's edits not applied are never thrown away unasked (grid-spec rule 1): the next Run keeps its tab, as
        /// if pinned; Close Result, closing the console and Quit ask first.
        @Test func aResultsEditsStayUntilThePersonThrowsThemAway() async throws {
            let (main, harness, console) = try await AppTests.ConsoleAppTests.console()
            let c = { Self.column("customers", "customers", $0, $1) }
            let store = ResultStore(columns: [c("id", MYSQL_TYPE_LONG), c("email", MYSQL_TYPE_VAR_STRING)])
            for row in [["1", "ann@example.com"], ["2", "bo@example.org"]] { store.append(row.map { Array($0.utf8) }) }
            console.addResult(store, title: "Customers", summary: "", query: "SELECT id, email FROM customers")
            console.showResults()
            let tab = try #require(console.resultTabs.first)
            let view = try #require(tab.view as? ResultGridView)
            view.editingContext = try await recordedEditorContext(SavedConnection(name: "Local", host: "127.0.0.1", user: "app"))
            view.openSession = { FakeTableSession() }
            view.prepareEditing(sql: "SELECT id, email FROM customers", database: "airsql_fixture", noBackslashEscapes: false)
            await ready { view.edits?.editing == nil }
            view.keep(.text("ann@example.net"), row: 0, column: 1)
            #expect(view.edits?.pendingRows == 1)
            #expect(view.validateMenuItem(Commands.save.item()), "⌘S applies them while the rows have the keyboard")
            #expect(main.unfinishedWork().contains { $0.hasPrefix("Edits to 1 row in the results of") && $0.hasSuffix("thrown away") })
            console.dropUnpinnedResults()
            #expect(console.resultTabs.count == 1 && !tab.pinned)
            var closes: Bool?
            console.shouldClose { closes = $0 }
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(main.window?.attachedSheet != nil)
            _ = await call(harness, "press", ["title": "Cancel"])
            await ready { closes == nil }
            #expect(closes == false)
            console.selectResult(tab)
            console.closeResult(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await call(harness, "press", ["title": "Throw Away"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            #expect(console.resultTabs.isEmpty && main.unfinishedWork().isEmpty)
        }
    }
}

extension AppTests {
    /// Console results edited against the lab (MariaDB 11.4 and 11.8, MySQL 8.4), with the column details real servers
    /// send: a one-table result, an inner join (through the preview), and an outer join that stays read-only. Writes
    /// only in lane_r2_edit_<server>, dropped afterwards.
    @MainActor @Suite(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh")) struct GridEditResultAppLabTests {
        @Test(arguments: [Lab.mariadb114, Lab.mariadb118, Lab.mysql84])
        func consoleResultsEditOnTheServer(_ lab: Lab.Server) async throws {
            let database = "lane_r2_edit_\(lab.name)", quoted = SQLQuote.identifier(database)
            let connection = Connection(options: DBLab.options(lab), log: DBLab.log)
            defer { Task { await connection.disconnect() } }
            let admin = try await connection.session(.schema)
            for sql in ["DROP DATABASE IF EXISTS \(quoted)", "CREATE DATABASE \(quoted)",
                        "CREATE TABLE \(quoted).c (id INT PRIMARY KEY, email VARCHAR(40) NOT NULL)",
                        "CREATE TABLE \(quoted).o (id INT PRIMARY KEY, customer_id INT, note VARCHAR(20))",
                        "INSERT INTO \(quoted).c VALUES (7, 'ann@example.com'), (9, 'cy@example.org')",
                        "INSERT INTO \(quoted).o VALUES (1, 7, 'first'), (2, 9, NULL), (3, NULL, 'lost')"] {
                _ = try await admin.query(sql)
            }
            let schema = SchemaCache(source: admin, includes: { $0 == database })
            try await schema.load()
            let saved = SavedConnection(name: "Lab \(lab.name)", host: "127.0.0.1", user: "airsql")
            let model = testModel([saved])
            let (main, harness) = appWindow(model)
            let console = try await connection.session(.main)
            func result(_ sql: String) async throws -> ResultGridView {
                let store = try #require(try await console.query(sql).first?.rows)
                let view = ResultGridView(store: store, nullText: "NULL", fontSize: 12, editable: true)
                view.editingContext = EditorContext(connection: saved, sessions: connection, schema: schema)
                view.model = model
                main.window?.contentView = view
                view.prepareEditing(sql: sql, database: database, noBackslashEscapes: console.noBackslashEscapes)
                await ready { view.edits?.editing == nil || view.edits?.editing?.isEditable == true && view.editContext == nil }
                return view
            }
            func applied(_ view: ResultGridView) async {
                _ = await eventually(timeout: 30) {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    return view.edits?.isEmpty == true && !TableDataController.applying.contains(saved.id)
                }
            }
            func value(_ sql: String) async throws -> String? { try await admin.query(sql).first?.rows?.string(0, 0) }

            // One table: an edit and a NULL, applied at once, read back.
            let one = try await result("SELECT id, note FROM \(quoted).o ORDER BY id")
            #expect(one.editState.stringValue == "Editable", "\(lab.name): \(one.editState.toolTip ?? "")")
            one.keep(.text("it's \"new\""), row: 0, column: 1)
            one.keep(.null, row: 2, column: 1)
            one.applyChanges(nil)
            await applied(one)
            #expect(try await value("SELECT note FROM \(quoted).o WHERE id = 1") == "it's \"new\"", "\(lab.name)")
            #expect(try await value("SELECT COUNT(*) FROM \(quoted).o WHERE note IS NULL") == "2", "\(lab.name)")
            #expect(one.source.cell(0, 1) == .text("it's \"new\"") && one.source.cell(2, 1) == .null)

            // An inner join: both tables' edits, after the preview.
            let join = try await result("SELECT o.id, o.note, c.id AS cid, c.email FROM \(quoted).o JOIN \(quoted).c ON c.id = o.customer_id ORDER BY o.id")
            #expect(join.edits?.editing?.needsPreview == true, "\(lab.name): \(join.editState.toolTip ?? "")")
            join.keep(.text("second"), row: 1, column: 1)
            join.keep(.text("cy@example.net"), row: 1, column: 3)
            join.applyChanges(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await call(harness, "press", ["title": "Apply"])
            await applied(join)
            #expect(try await value("SELECT note FROM \(quoted).o WHERE id = 2") == "second", "\(lab.name)")
            #expect(try await value("SELECT email FROM \(quoted).c WHERE id = 9") == "cy@example.net", "\(lab.name)")

            // An outer join stays read-only, and says why.
            let outer = try await result("SELECT o.id, c.id, c.email FROM \(quoted).o LEFT JOIN \(quoted).c ON c.id = o.customer_id")
            #expect(outer.editState.stringValue == "Read-only" && outer.editState.toolTip?.hasPrefix("Outer joins are read-only") == true,
                    "\(lab.name)")
            main.window?.orderOut(nil)
            _ = try await admin.query("DROP DATABASE \(quoted)")
        }
    }
}

extension AppTests.HelpTests {
    /// An edited console result's bar and status say what they do, and its menu items why they're off.
    @Test func anEditedResultSaysWhatItsControlsDo() async throws {
        let c = { AppTests.GridEditResultAppTests.column("customers", "customers", $0, $1) }
        let (main, _, view) = try await AppTests.GridEditResultAppTests.result(
            "SELECT id, email FROM customers", [c("id", MYSQL_TYPE_LONG), c("email", MYSQL_TYPE_VAR_STRING)], rows: [["7", "a@x"]],
            session: FakeTableSession())
        view.keep(.text("b@x"), row: 0, column: 1)
        main.window?.orderFront(nil)
        var missing = unexplained([try #require(main.window)], where: "edited result")
        if view.editState.toolTip?.isEmpty != false { missing.append("result.editState") }
        missing += unexplained(try #require(view.viewer.dataGrid(view.grid, menuFor: .cells)), path: ["result cell"])
        main.window?.orderOut(nil)
        #expect(missing.isEmpty, "\(missing)")
    }
}

extension AppTests.HelpTests {
    /// The Add Virtual Foreign Key and Paste Format sheets say what each control does.
    @Test func theVirtualKeyAndPasteFormatSheetsSayWhatTheyDo() async throws {
        let (main, harness, tab) = try await AppTests.GridDataAppTests.tab()
        main.window?.orderFront(nil)
        var missing: [String] = []
        tab.grid.selection.select(GridPosition(row: 0, column: 3))
        tab.addVirtualKey(nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        missing += unexplained([try #require(main.window?.attachedSheet)], where: "virtual foreign key")
        _ = await call(harness, "press", ["title": "Cancel"])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("7", forType: .string)
        tab.pasteWithFormat(nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        missing += unexplained([try #require(main.window?.attachedSheet)], where: "paste format")
        _ = await call(harness, "press", ["title": "Cancel"])
        main.window?.orderOut(nil)
        #expect(missing.isEmpty, "\(missing)")
    }
}

extension AppTests.LayoutTests {
    /// An edited console result's bar fits its words and buttons, in light and dark.
    @Test func anEditedResultIsTidy() async throws {
        var problems: [String] = []
        let c = { AppTests.GridEditResultAppTests.column("customers", "customers", $0, $1) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let (main, _, view) = try await AppTests.GridEditResultAppTests.result(
                "SELECT id, email FROM customers", [c("id", MYSQL_TYPE_LONG), c("email", MYSQL_TYPE_VAR_STRING)], rows: [["7", "a@x"]],
                session: FakeTableSession())
            main.window?.appearance = NSAppearance(named: appearance)
            main.window?.orderFront(nil)
            view.keep(.text("b@x"), row: 0, column: 1)
            main.window?.contentView?.layoutSubtreeIfNeeded()
            problems += layoutProblems(view, where: "\(appearance) edited result")
            main.window?.orderOut(nil)
        }
        #expect(problems.isEmpty, "\(problems)")
    }
}

extension AppTests.ScreenshotTests {
    /// Grid editing, round 2: a console result being edited, foreign keys' labels, the virtual foreign key sheet and the
    /// Paste Format sheet, in light and dark.
    @Test func gridEditingRoundTwo() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let c = { AppTests.GridEditResultAppTests.column("customers", "customers", $0, $1) }
            let (resultWindow, resultHarness, result) = try await AppTests.GridEditResultAppTests.result(
                "SELECT id, email, name FROM customers", [c("id", MYSQL_TYPE_LONG), c("email", MYSQL_TYPE_VAR_STRING), c("name", MYSQL_TYPE_VAR_STRING)],
                rows: [["7", "ann@example.com", "Ann"], ["9", "cy@example.org", "Cy"], ["12", "di@example.net", "Di"]], session: FakeTableSession())
            resultWindow.window?.appearance = NSAppearance(named: appearance)
            resultWindow.window?.setContentSize(NSSize(width: 900, height: 420))
            onScreen(resultWindow.window)
            result.keep(.text("ann@example.net"), row: 0, column: 1)
            result.grid.selection.selectRow(2)
            result.deleteRows(nil)
            result.grid.selection.select(GridPosition(row: 1, column: 2))
            resultWindow.window?.displayIfNeeded()
            try await save(resultHarness, "result-edit-\(suffix)")
            resultWindow.window?.orderOut(nil)

            let (main, harness, tab) = try await AppTests.GridDataAppTests.tab(size: NSSize(width: 1180, height: 600))
            main.window?.appearance = NSAppearance(named: appearance)
            onScreen(main.window)
            tab.grid.columnWidths[1] = 220
            tab.grid.needsDisplay = true
            main.window?.displayIfNeeded()
            await ready { tab.readingLabels != nil || tab.loading != nil }
            tab.grid.selection.select(GridPosition(row: 0, column: 1))
            main.window?.displayIfNeeded()
            try await save(harness, "grid-labels-\(suffix)")
            tab.grid.selection.select(GridPosition(row: 0, column: 3))
            tab.addVirtualKey(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            try await save(harness, "grid-virtual-key-\(suffix)")
            _ = await call(harness, "press", ["title": "Cancel"])
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("1,234", forType: .string)
            tab.grid.selection.select(GridPosition(row: 0, column: 4))
            tab.paste(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            try await save(harness, "grid-paste-format-\(suffix)")
            _ = await call(harness, "press", ["title": "Cancel"])
            main.window?.orderOut(nil)
        }
    }
}
