import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

// The navigator in the app on the lab's servers (AIRSQL_LAB=1): names first on the 5,000-table server, and the table
// commands end to end through their dialogs and the SQL preview, the tree following each change.
extension AppTests {
    @MainActor @Suite(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh")) struct NavigatorAppLabTests {
        /// A saved connection for `server`, attached to its real sessions as connecting would.
        private func connected(_ server: Lab.Server) async throws -> (AppModel, MainWindowController, AgentServer, OpenConnection) {
            let saved = SavedConnection(name: "Lab \(server.name)", host: "127.0.0.1", port: server.port, user: Lab.airsql.user)
            let model = testModel([saved])
            let (main, harness) = appWindow(model)
            let connection = Connection(options: DBLab.options(server), log: DBLab.log)
            try await connection.connect()
            let open = model.attach(connection, to: saved.id) { !["information_schema", "performance_schema", "sys"].contains($0) }
            _ = await eventually(timeout: 60) { open.snapshot.server != nil && open.loading.isEmpty }
            return (model, main, harness, open)
        }

        @Test func aServerWithFiveThousandTablesLoadsNamesFirstAndDetailsWhenOpened() async throws {
            let (model, main, harness, open) = try await connected(Lab.many)
            defer { model.detach(open.id) }
            #expect(open.snapshot.tableCount > 3_000 && !open.snapshot.detailsUpfront)
            let many = try #require(open.snapshot.database("many_tables"))
            #expect(many.tables.count >= Lab.manyTables && !many.detailsLoaded)
            let tables = try #require(main.sidebar.treeNodes[.category(open.id, "many_tables", .table)])
            #expect(tables.children.count >= Lab.manyTables)
            // Opening the database loads its columns (its row spins meanwhile).
            main.sidebar.outline.expandItem(main.sidebar.treeNodes[.database(open.id, "many_tables")])
            #expect(open.loading.contains(.details("many_tables")))
            #expect(await eventually(timeout: 120) { open.snapshot.database("many_tables")?.detailsLoaded == true })
            #expect(open.snapshot.database("many_tables")?.table("t0001")?.columns.isEmpty == false)
            // A click shows the database view, which reads the sizes of its 5,000 tables.
            let row = try #require(treeRow(main, .database(open.id, "many_tables")))
            _ = await call(harness, "click", ["x": row.point.0, "y": row.point.1])
            let view = try #require((main.selectedTab?.content as? PreviewContent)?.shown as? DatabaseViewController)
            #expect(await eventually(timeout: 120) { open.snapshot.database("many_tables")?.statistics != nil && open.loading.isEmpty })
            view.reload()
            #expect(view.rows.count >= Lab.manyTables)
        }

        @Test(arguments: NavigatorLabTests.servers)
        func tableCommandsRunAfterThePreviewAndTheTreeFollows(_ server: Lab.Server) async throws {
            let setup = DBConnection(options: DBLab.options(server), role: .tools, log: DBLab.log)
            try await setup.connect()
            let db = "lane_l5a_nav_app"
            _ = try await setup.query("DROP DATABASE IF EXISTS " + SQLQuote.identifier(db))
            let (model, main, harness, open) = try await connected(server)
            defer { model.detach(open.id) }
            let id = open.id
            func sheet(_ text: String) async -> Bool { await call(harness, "wait", ["until": "sheet", "text": text, "timeout": 15]).error == nil }
            func context(_ kind: SidebarNode.Kind, _ command: String) async throws {
                let row = try #require(treeRow(main, kind), "\(kind) isn't in the tree")
                _ = await call(harness, "click", ["x": row.point.0, "y": row.point.1])
                _ = await call(harness, "click", ["x": row.point.0, "y": row.point.1, "button": "right"])
                let chosen = await call(harness, "menu", ["path": "context > " + command])
                #expect(chosen.error == nil, "\(command): \(chosen.error ?? "")")
            }

            // New Database: a name, the server's character set and collation.
            let connectionRow = try #require(sidebarRow(main, "Lab \(server.name)"))
            _ = await call(harness, "click", ["x": connectionRow.0, "y": connectionRow.1])
            #expect(await call(harness, "menu", ["path": "Database > New Database…"]).error == nil)
            #expect(await sheet("New database"))
            #expect(await call(harness, "set", ["id": "newDatabase.name", "value": db, "in": "sheet"]).error == nil)
            _ = await call(harness, "press", ["title": "Create", "in": "sheet"])
            #expect(await eventually(timeout: 20) { main.sidebar.treeNodes[.database(id, db)] != nil })

            _ = try await setup.query("CREATE TABLE \(SQLQuote.identifier(db, "orders")) (id INT PRIMARY KEY, note TEXT)")
            _ = try await setup.query("INSERT INTO \(SQLQuote.identifier(db, "orders")) VALUES (1, 'a'), (2, 'b')")
            open.refresh([.table(database: db, name: "orders")])
            let orders = SidebarNode.Kind.object(id, DatabaseObject(.table, db, "orders"))
            #expect(await eventually(timeout: 20) { main.sidebar.treeNodes[orders] != nil })

            // Copy Table with a condition.
            try await context(orders, "Copy Table…")
            #expect(await sheet("Copy orders"))
            _ = await call(harness, "set", ["id": "copyTable.where", "value": "id = 2", "in": "sheet"])
            _ = await call(harness, "press", ["title": "Next…", "in": "sheet"])
            #expect(await sheet("INSERT INTO `lane_l5a_nav_app`.`orders_copy`"))
            _ = await call(harness, "press", ["id": "preview.run", "in": "sheet"])
            let copy = SidebarNode.Kind.object(id, DatabaseObject(.table, db, "orders_copy"))
            #expect(await eventually(timeout: 20) { main.sidebar.treeNodes[copy] != nil })
            #expect(try await setup.rows("SELECT COUNT(*) FROM \(SQLQuote.identifier(db, "orders_copy"))").first?.first == "1")

            // Rename, then Truncate, then Drop: each through the SQL preview.
            try await context(copy, "Rename…")
            #expect(await sheet("Rename orders_copy"))
            _ = await call(harness, "set", ["id": "rename.name", "value": "kept", "in": "sheet"])
            _ = await call(harness, "press", ["title": "Next…", "in": "sheet"])
            #expect(await sheet("RENAME TABLE"))
            _ = await call(harness, "press", ["id": "preview.run", "in": "sheet"])
            let kept = SidebarNode.Kind.object(id, DatabaseObject(.table, db, "kept"))
            #expect(await eventually(timeout: 20) { main.sidebar.treeNodes[kept] != nil && main.sidebar.treeNodes[copy] == nil })
            try await context(orders, "Truncate…")
            #expect(await sheet("TRUNCATE TABLE `lane_l5a_nav_app`.`orders`"))
            _ = await call(harness, "press", ["id": "preview.run", "in": "sheet"])
            #expect(await eventually(timeout: 20) {
                (try? await setup.rows("SELECT COUNT(*) FROM \(SQLQuote.identifier(db, "orders"))").first?.first) == "0"
            })
            try await context(kept, "Drop…")
            #expect(await sheet("DROP TABLE `lane_l5a_nav_app`.`kept`"))
            _ = await call(harness, "press", ["id": "preview.run", "in": "sheet"])
            #expect(await eventually(timeout: 20) { main.sidebar.treeNodes[kept] == nil })

            // Dropping the database needs its name typed.
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            try await context(.database(id, db), "Drop…")
            #expect(await sheet("DROP DATABASE `lane_l5a_nav_app`"))
            _ = await call(harness, "set", ["id": "preview.confirm", "value": db, "in": "sheet"])
            _ = await call(harness, "press", ["id": "preview.run", "in": "sheet"])
            #expect(await eventually(timeout: 20) { main.sidebar.treeNodes[.database(id, db)] == nil })
            await setup.close()
        }
    }
}
