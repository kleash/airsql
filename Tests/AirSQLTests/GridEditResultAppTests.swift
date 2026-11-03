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

        @Test func aOneTableResultEditsAndAppliesLikeATable() async throws {
            let session = FakeTableSession()
            session.columns = [.init(name: "id", type: MYSQL_TYPE_LONG), .init(name: "email", type: MYSQL_TYPE_VAR_STRING)]
            session.edited = [["1", "ANN@EXAMPLE.NET"]]
            let c = { Self.column("customers", "customers", $0, $1) }
            let (main, harness, view) = try await Self.result("SELECT id, email, NOW() AS at FROM customers",
                                                     [c("id", MYSQL_TYPE_LONG), c("email", MYSQL_TYPE_VAR_STRING), Self.column("", "", "at")],
                                                     rows: [["1", "ann@example.com", "x"], ["2", "bo@example.org", "y"]], session: session)
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
            #expect(view.responds(to: save.action) && !view.validateMenuItem(save))
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
                                           "UPDATE `airsql_fixture`.`customers` SET `email` = 'ann@example.net' WHERE `id` = 1", "COMMIT",
                                           "SELECT `id`, `email` FROM `airsql_fixture`.`customers` WHERE `id` IN (1)"])
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
            #expect(sql.contains("UPDATE `airsql_fixture`.`customers` SET `email` = 'cy@example.net' WHERE `id` = 9;"))
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

        @Test func aReadOnlyConnectionsResultSaysWhy() async throws {
            let c = { Self.column("customers", "customers", $0, MYSQL_TYPE_LONG) }
            let (_, _, view) = try await Self.result("SELECT id FROM customers", [c("id")], rows: [["1"]], session: FakeTableSession(),
                                                     readOnly: true)
            #expect(view.editState.stringValue == "Read-only" && view.editState.toolTip?.hasPrefix("This connection is read-only") == true)
            #expect(!view.dataGrid(view.grid, canEditRow: 0, column: 0) && view.whyReadOnly(0, 0)?.hasPrefix("This connection is read-only") == true)
        }
    }
}
