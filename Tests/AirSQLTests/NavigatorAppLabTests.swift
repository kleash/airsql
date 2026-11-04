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

        /// The current database and the Tx pop-up on a real session: a database chosen in the toolbar is USEd before the
        /// console's next statement, a USE typed there moves the navigator's bold one, an isolation level chosen in the
        /// Tx pop-up is the session's, and Run… writes the CALL with the parameters the server lists.
        @Test func theConsoleRunsInTheCurrentDatabaseAndRunWritesTheCall() async throws {
            let setup = DBConnection(options: DBLab.options(Lab.mariadb118), role: .tools, log: DBLab.log)
            try await setup.connect()
            let (a, b) = ("lane_fix_int_a", "lane_fix_int_b")
            for sql in ["DROP DATABASE IF EXISTS \(a)", "DROP DATABASE IF EXISTS \(b)", "CREATE DATABASE \(a)", "CREATE DATABASE \(b)",
                        "CREATE PROCEDURE \(a).twice(IN p_in INT, OUT p_out INT) SET p_out = p_in * 2"] {
                _ = try await setup.query(sql)
            }
            let (model, main, harness, open) = try await connected(Lab.mariadb118)
            ConsoleViewController.openConnection = { model.openConnection($0)?.connection }
            defer {
                ConsoleViewController.openConnection = { _ in nil }
                ConsoleViewController.shared[open.id] = nil
                model.detach(open.id)
            }
            model.states[open.id] = .connected(server: "MariaDB 11.8")
            main.sidebar.select([open.id])
            main.refresh()
            let popup = main.toolbarController.databasePopup
            popup.menu?.performActionForItem(at: popup.indexOfItem(withTitle: b))
            #expect(open.currentDatabase == b)
            let console = try #require(main.openConsole(text: "SELECT DATABASE();", title: nil, connection: open.id).content
                                       as? ConsoleViewController)
            func run(_ text: String) async {
                console.editor.setText(text)
                console.editor.setSelectedRange(NSRange(location: 0, length: 0))
                console.runStatement(nil)
                _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            }
            await run("SELECT DATABASE();")
            #expect(console.lastOutcome?.results.first?.rows?.string(0, 0) == b, "\(console.messagesView.messages.map(\.text))")
            #expect(console.messagesView.messages.contains { $0.statement == "USE `\(b)`" })
            await run("USE \(a);")
            #expect(open.currentDatabase == a && popup.titleOfSelectedItem == a)

            // The Tx pop-up: an isolation level, as choosing it sends it.
            let tx = main.toolbarController.transactionPopup
            tx.selectItem(withTitle: "Read Committed")
            NSApp.sendAction(Commands.isolation.action, to: harness.target(for: Commands.isolation.action, explicit: nil, in: main.window),
                             from: tx)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            await run("SELECT @@SESSION.transaction_isolation;")
            #expect(console.lastOutcome?.results.first?.rows?.string(0, 0) == "READ-COMMITTED")
            // Opened, the pop-up ticks it (its items are checked by the console, as the menu bar's are).
            let level = try #require(tx.item(withTitle: "Read Committed"))
            #expect((harness.target(for: level.action!, explicit: nil, in: main.window) as? NSMenuItemValidation)?
                .validateMenuItem(level) == true)
            #expect(level.state == .on && tx.titleOfSelectedItem == "Auto-commit")

            // Run…: the procedure's CALL, its parameters as the server lists them.
            let routine = try #require(treeRow(main, .object(open.id, DatabaseObject(.procedure, a, "twice"))))
            _ = await call(harness, "click", ["x": routine.point.0, "y": routine.point.1, "button": "right"])
            #expect(await call(harness, "menu", ["path": "context > Run…"]).error == nil)
            #expect(await eventually(timeout: 10) { (main.selectedTab?.content as? ConsoleViewController) !== console })
            let routineConsole = try #require(main.selectedTab?.content as? ConsoleViewController)
            #expect(routineConsole.text == "CALL `\(a)`.`twice`(? /* p_in int(11) */, @`p_out`);\nSELECT @`p_out`;\n")
            for database in [a, b] { _ = try await setup.query("DROP DATABASE " + database) }
            await setup.close()
        }
    }
}
