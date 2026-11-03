import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

// The editors in the app on MySQL 8.4 and MariaDB 11.4 (AIRSQL_LAB=1): a table changed and a view created and replaced,
// each through the SQL preview sheet and a tools session, then read back from the server.
extension AppTests {
    @MainActor @Suite(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh")) struct EditorsAppLabTests {
        static let database = "lane_l5b_editors_app"

        /// A lab server as the editors' connection: its sessions, and a schema cache reading through the schema session.
        func labContext(_ lab: Lab.Server) async throws -> EditorContext {
            let connection = Connection(options: DBLab.options(lab), log: DBLab.log)
            let schemaSession = try await connection.session(.schema)
            let database = Self.database
            for sql in ["DROP DATABASE IF EXISTS " + SQLQuote.identifier(database), "CREATE DATABASE " + SQLQuote.identifier(database),
                        "CREATE TABLE " + SQLQuote.identifier(database, "items") + " (id INT PRIMARY KEY, name VARCHAR(20))"] {
                _ = try await schemaSession.query(sql)
            }
            let schema = SchemaCache(source: schemaSession, includes: { $0 == database })
            try await schema.load()
            return EditorContext(connection: Fixtures.local, sessions: connection, schema: schema)
        }

        /// Presses the sheet's button and waits until `busy` is over.
        func approve(_ harness: AgentServer, _ title: String, until busy: @escaping () -> Bool) async {
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await call(harness, "press", ["title": title])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            _ = await eventually(timeout: 30) {
                try? await Task.sleep(nanoseconds: 50_000_000)
                return !busy()
            }
        }

        @Test(arguments: EditorsLabTests.servers)
        func changesATableAndMakesAViewThroughThePreviewSheet(_ lab: Lab.Server) async throws {
            let context = try await labContext(lab)
            defer { Task { await context.sessions.disconnect() } }
            let model = testModel([Fixtures.local])
            let (main, harness) = appWindow(model)

            main.openTableEditor("items", database: Self.database, context: context)
            let editor = try #require(main.selectedTab?.content as? TableEditorController)
            await ready { editor.isBusy || !editor.overlay.isHidden }
            #expect(editor.design.columns.map(\.name) == ["id", "name"], "\(lab)")
            editor.update { table in
                table.renameColumn(at: 1, to: "title")
                var price = ColumnDesign(name: "price", type: TypeSpec(name: "decimal", length: "8,2"))
                price.defaultValue = .value("0.00")
                price.nullable = false
                table.columns.append(price)
                table.indexes.append(IndexDesign(name: "by_title", kind: .index, parts: [.init(column: "title")]))
            }
            _ = await call(harness, "press", ["id": "tableEditor.apply"])
            await approve(harness, "Apply") { editor.isBusy }
            #expect(!editor.isEdited && editor.sqlText.string.hasPrefix("-- No changes yet"), "\(lab): \(editor.sqlText.string)")
            let table = try #require(context.schema.snapshot.table(Self.database, "items"))
            #expect(table.columns.map(\.name) == ["id", "title", "price"] && table.indexes.contains { $0.name == "by_title" }, "\(lab)")

            main.openObjectEditor(.view, name: nil, database: Self.database, context: context)
            let view = try #require(main.selectedTab?.content as? ObjectEditorController)
            await ready { view.isBusy || !view.overlay.isHidden }
            view.code.string = "CREATE VIEW `cheap` AS SELECT id, title FROM items WHERE price < 10"
            view.textDidChange(Notification(name: NSText.didChangeNotification))
            _ = await call(harness, "press", ["id": "objectEditor.apply"])
            await approve(harness, "Create") { view.isBusy }
            #expect(view.name == "cheap" && main.selectedTab?.title == "cheap · view", "\(lab)")
            view.code.string = view.code.string.replacingOccurrences(of: "10", with: "20")
            view.textDidChange(Notification(name: NSText.didChangeNotification))
            _ = await call(harness, "press", ["id": "objectEditor.apply"])
            await approve(harness, "Apply") { view.isBusy }
            #expect(view.definition?.code.contains("20") == true && !view.isEdited, "\(lab): \(view.definition?.code ?? "")")

            _ = try await context.sessions.session(.schema).query("DROP DATABASE " + SQLQuote.identifier(Self.database))
        }
    }
}
