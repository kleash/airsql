import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// A console tab driven through the harness (plan §2.6): New Query, typing with colours, the editor's commands, and
/// what Run says without a connection. The lab test runs statements, Manual mode and closing with a transaction open.
extension AppTests {
    @MainActor @Suite struct ConsoleAppTests {
        /// A window with the shop's connections and a new console on Production.
        static func console(_ given: AppModel? = nil, on connection: UUID = Fixtures.production.id) async throws
            -> (MainWindowController, AgentServer, ConsoleViewController) {
            let model = given ?? testModel(Fixtures.shop)
            // Shown as connected, so New Query doesn't start a connect: the fixtures lead nowhere.
            if model.states[connection] == nil { model.states[connection] = .connected(server: "MariaDB 11.8.3") }
            let (main, harness) = appWindow(model)
            main.sidebar.select([connection])
            let reply = await call(harness, "menu", ["path": "File > New Query"])
            #expect(reply.error == nil, "\(reply.error ?? "")")
            let console = try #require(main.selectedTab?.content as? ConsoleViewController)
            return (main, harness, console)
        }

        @Test func newQueryStartsConnectingADisconnectedConnection() async throws {
            let closed = SavedConnection(name: "Closed port", host: "127.0.0.1", port: 1, user: "nobody")
            let model = testModel([closed])
            let (main, harness) = appWindow(model)
            main.sidebar.select([closed.id])
            #expect(await call(harness, "menu", ["path": "File > New Query"]).error == nil)
            // Connecting, or already failed (nothing listens on port 1): either way New Query started it.
            #expect(model.states[closed.id] != nil && main.selectedTab?.connectionID == closed.id, "\(String(describing: model.states[closed.id]))")
            model.connector.cancel(closed.id)
            if let sheet = main.window?.attachedSheet { main.window?.endSheet(sheet) }
        }

        @Test func newQueryOpensAConsoleOnTheSelectedConnection() async throws {
            let (main, _, console) = try await Self.console()
            #expect(main.selectedTab?.title == "Query 1" && console.connectionID == Fixtures.production.id)
            #expect(main.window?.firstResponder === console.editor)
            #expect(!console.isEdited && console.canRename && console.fileURL == nil)
            main.openConsole(text: "", title: nil, connection: Fixtures.production.id)
            #expect(main.selectedTab?.title == "Query 2")
        }

        /// Statements after which the navigator's tree reloads.
        @Test func schemaChangesAreToldApart() {
            #expect(ConsoleViewController.changesSchema("/* new */ create table t (id int)"))
            #expect(ConsoleViewController.changesSchema("DROP VIEW v") && ConsoleViewController.changesSchema("rename table a to b"))
            #expect(!ConsoleViewController.changesSchema("SELECT 'CREATE'") && !ConsoleViewController.changesSchema("INSERT INTO t VALUES (1)"))
        }

        @Test func typingColoursTheSQLAndTheEditorsCommandsChangeIt() async throws {
            let (main, harness, console) = try await Self.console()
            _ = await call(harness, "type", ["text": "select a, `from` from t where x = 'from' -- note"])
            let storage = try #require(console.editor.textStorage)
            func color(at text: String) -> NSColor? {
                storage.attribute(.foregroundColor, at: (storage.string as NSString).range(of: text).location, effectiveRange: nil) as? NSColor
            }
            #expect(color(at: "select") == .sqlKeyword && color(at: "'from'") == .sqlString && color(at: "-- note") == .sqlComment)
            #expect(color(at: "`from`") == .sqlIdentifier)
            #expect(console.isEdited && main.tabBar.buttons.first?.toolTip?.contains("(unsaved)") == true)

            #expect(await call(harness, "menu", ["path": "Query > Format SQL"]).error == nil)
            #expect(console.text == "SELECT a, `from`\nFROM t\nWHERE x = 'from' -- note")
            console.editor.selectAll(nil)
            #expect(await call(harness, "menu", ["path": "Edit > Comment Lines"]).error == nil)
            #expect(console.text == "-- SELECT a, `from`\n-- FROM t\n-- WHERE x = 'from' -- note")
            #expect(await call(harness, "menu", ["path": "Edit > Comment Lines"]).error == nil)
            #expect(console.text == "SELECT a, `from`\nFROM t\nWHERE x = 'from' -- note")
            #expect(await call(harness, "menu", ["path": "Edit > Shift Right"]).error == nil)
            #expect(console.text.hasPrefix("    SELECT") && console.text.contains("\n    FROM"))
            #expect(await call(harness, "menu", ["path": "Edit > Shift Left"]).error == nil)
            #expect(console.text.hasPrefix("SELECT"))
        }

        @Test func findAndReplaceWithARegularExpression() async throws {
            let (_, harness, console) = try await Self.console()
            _ = await call(harness, "type", ["text": "SELECT o1, o2 FROM t WHERE o3 = 'O4'"])
            #expect(await call(harness, "menu", ["path": "Edit > Find > Find and Replace…"]).error == nil)
            let find = try #require(console.findBar)
            #expect(!find.isHidden && console.view.window?.firstResponder === find.search.currentEditor())
            find.search.stringValue = "o(\\d)"
            find.update()
            #expect(find.matches()?.isEmpty == true, "plain text: there is no o(\\d)")
            find.regex.state = .on
            find.update()
            #expect(find.matches()?.count == 4, "any case by default")
            find.matchCase.state = .on
            find.update()
            #expect(find.matches()?.count == 3)
            find.replacement.stringValue = "col$1"
            find.update()
            _ = await call(harness, "press", ["id": "find.replaceAll"])
            #expect(console.text == "SELECT col1, col2 FROM t WHERE col3 = 'O4'")
            find.search.stringValue = "("
            find.update()
            #expect(find.matches() == nil, "not a regular expression")
            find.close(nil)
            #expect(find.isHidden && console.view.window?.firstResponder === console.editor)
        }

        @Test func theSQLLogShowsFiltersAndClearsTheLog() async throws {
            let folder = try scratch()
            let log = SQLLog(fileURL: URL(fileURLWithPath: folder + "/SQL.log"))
            log.statement("SELECT * FROM orders", context: "Shop main:1", noBackslashEscapes: false)
            log.statement("CREATE USER x IDENTIFIED BY 'secret'", context: "Shop main:2", noBackslashEscapes: false)
            let viewer = SQLLogWindowController.show(log)
            keptWindows.append(viewer)
            viewer.window?.setFrameOrigin(NSPoint(x: -22000, y: -22000))
            #expect(try await eventually(timeout: 5) { viewer.lines.count == 2 })
            #expect(viewer.lines.last?.contains("<secret>") == true && viewer.lines.last?.contains("'secret'") == false)
            log.statement("SELECT 2", context: "Shop main:3", noBackslashEscapes: false)
            viewer.refresh()
            #expect(try await eventually(timeout: 5) { viewer.lines.count == 3 }, "follows what is added")
            SQLLogWindowController.clear(log)
            #expect(try await eventually(timeout: 5) { !FileManager.default.fileExists(atPath: log.fileURL.path) })
            viewer.refresh()
            #expect(try await eventually(timeout: 5) { viewer.lines.isEmpty })
            viewer.close()
        }

        @Test func completionOffersJoinsAndColumnsFromTheSchemaCache() async throws {
            let (cache, _) = try await SchemaTests.loaded(SchemaFixtures.mariadb118)
            ConsoleViewController.schemaCache = { _ in cache }
            defer { ConsoleViewController.schemaCache = { _ in nil } }
            var saved = Fixtures.local
            saved.database = "airsql_fixture"
            let (_, harness, console) = try await Self.console(testModel([saved]), on: saved.id)
            _ = await call(harness, "type", ["text": "SELECT * FROM orders o JOIN "])
            console.editor.complete(nil)
            let popup = try #require(console.editor.completionPopup)
            #expect(popup.isShown && popup.selected?.text == "customers c ON c.id = o.customer_id")
            console.editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            #expect(!popup.isShown && console.text == "SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id")
            // Typing a dot after an alias lists its columns; ↓ and Tab choose and insert.
            console.editor.insertText(" WHERE c", replacementRange: console.editor.selectedRange())
            console.editor.insertText(".", replacementRange: console.editor.selectedRange())
            #expect(popup.isShown && popup.items.allSatisfy { $0.kind == .column })
            console.editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
            let second = try #require(popup.selected)
            console.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            #expect(console.text.hasSuffix("WHERE c." + second.text))
            // Not inside a string.
            console.editor.insertText(" = 'o", replacementRange: console.editor.selectedRange())
            #expect(!popup.isShown)
        }

        @Test func helpersFollowTheStatementAndInsert() async throws {
            let (cache, _) = try await SchemaTests.loaded(SchemaFixtures.mariadb118)
            ConsoleViewController.schemaCache = { _ in cache }
            defer { ConsoleViewController.schemaCache = { _ in nil } }
            var saved = Fixtures.local
            saved.database = "airsql_fixture"
            let (_, harness, console) = try await Self.console(testModel([saved]), on: saved.id)
            _ = await call(harness, "type", ["text": "SELECT  FROM orders o"])
            console.editor.setSelectedRange(NSRange(location: 7, length: 0))
            #expect(await call(harness, "menu", ["path": "View > Query Helpers"]).error == nil)
            #expect(console.helpersShown)
            let panel = console.helpers
            #expect(panel.table.numberOfRows > 2)
            #expect((panel.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)?.stringValue == "orders o")
            panel.table.selectRowIndexes([2], byExtendingSelection: false)
            panel.insertSelected(nil)
            #expect(console.text.hasPrefix("SELECT customer_id FROM") || console.text.hasPrefix("SELECT id FROM"), "\(console.text)")
            panel.choice.selectedSegment = 1
            panel.reload()
            #expect((panel.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)?.stringValue == "Aggregate")
            #expect(await call(harness, "menu", ["path": "View > Query Helpers"]).error == nil)
            #expect(!console.helpersShown)
        }

        @Test func filesOpenSaveAndTabsComeBackAfterRelaunch() async throws {
            let folder = try scratch()
            ConsoleDocuments.shared.fileURL = URL(fileURLWithPath: folder + "/Consoles.json")
            let file = URL(fileURLWithPath: folder + "/top customers.sql")
            try "SELECT 1;".write(to: file, atomically: true, encoding: .utf8)
            let (main, harness, untitled) = try await Self.console()
            _ = await call(harness, "type", ["text": "SELECT 'unsaved';"])
            main.openFiles([file])
            #expect(try await eventually(timeout: 5) { main.tabs.count == 2 })
            let opened = try #require(main.selectedTab?.content as? ConsoleViewController)
            #expect(main.selectedTab?.title == "top customers.sql" && opened.text == "SELECT 1;" && !opened.isEdited && !opened.canRename)
            _ = await call(harness, "type", ["text": "\nSELECT 2;"])
            #expect(opened.isEdited)
            opened.saveQuery(nil)
            #expect(try await eventually(timeout: 5) { !opened.isEdited })
            #expect(try String(contentsOf: file, encoding: .utf8) == "SELECT 1;\nSELECT 2;")
            main.openFiles([file])
            #expect(main.tabs.count == 2, "a file already open shows its tab")

            // Quit and launch again: both come back, in order, with their text and connection.
            _ = await call(harness, "type", ["text": "\n-- not saved yet"])
            ConsoleDocuments.shared.main = main
            ConsoleDocuments.shared.saveNow()
            let (relaunched, _) = appWindow(testModel(Fixtures.shop))
            ConsoleDocuments.shared.restore(into: relaunched)
            #expect(try await eventually(timeout: 5) { relaunched.tabs.count == 2 })
            let restored = relaunched.tabs.compactMap { $0.content as? ConsoleViewController }
            #expect(relaunched.tabs.map(\.title) == ["Query 1", "top customers.sql"])
            #expect(restored.first?.text == untitled.text && restored.first?.connectionID == Fixtures.production.id)
            #expect(restored.last?.text == "SELECT 1;\nSELECT 2;\n-- not saved yet" && restored.last?.isEdited == true)
            #expect(restored.last?.fileURL == file)
            ConsoleDocuments.shared.fileURL = ConsoleTabStore.fileURL
        }

        @Test func runSaysToConnectFirst() async throws {
            let (_, harness, console) = try await Self.console()
            _ = await call(harness, "type", ["text": "SELECT 1"])
            let run = await call(harness, "menu", ["path": "Query > Run Statement"])
            #expect(run.error?.contains("Connect first") == true, "\(run.error ?? "")")
            #expect(console.results.cancelButton.isHidden)
            let commit = await call(harness, "menu", ["path": "Query > Commit"])
            #expect(commit.error?.contains("No transaction is open") == true, "\(commit.error ?? "")")
        }

        /// Run All against MariaDB 11.8: a result tab per result set (named from the comment above), Messages, Manual
        /// mode's transaction in the badge, and closing the last console with the transaction open.
        @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
        func runsStatementsAndHoldsTheTransactionUntilAsked() async throws {
            let options = DBLab.options(DBLab.server("mariadb"), tls: DBLab.required)
            let connection = Connection(options: options, log: DBLab.log)
            try await connection.connect()
            let database = "lane_l4_console_app"
            let setup = try await connection.toolsSession()
            for sql in ["DROP DATABASE IF EXISTS \(database)", "CREATE DATABASE \(database)", "CREATE TABLE \(database).t (id INT PRIMARY KEY)"] {
                _ = try await setup.query(sql)
            }
            ConsoleViewController.openConnection = { $0 == Fixtures.production.id ? connection : nil }
            defer { ConsoleViewController.openConnection = { _ in nil } }
            let model = testModel(Fixtures.shop)
            model.states[Fixtures.production.id] = .connected(server: "MariaDB 11.8")
            let (main, harness, console) = try await Self.console(model)

            _ = await call(harness, "type", ["text": "-- Two numbers\nSELECT 1 AS one;\nSELECT 2 AS two, 3 AS three;"])
            #expect(await call(harness, "key", ["combo": "cmd+shift+return"]).error == nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(console.resultTabs.map(\.label) == ["Two numbers · 1 × 1", "Result 2 · 1 × 2"])
            #expect(console.messagesView.messages.map(\.level) == [.ok, .ok])
            #expect(console.messagesView.messages.first?.line == 2)

            #expect(await call(harness, "menu", ["path": "Query > Transaction Mode > Manual"]).error == nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(!console.autocommit)
            _ = await call(harness, "type", ["text": "\nINSERT INTO \(database).t VALUES (1), (2);"])
            #expect(await call(harness, "key", ["combo": "cmd+return"]).error == nil)
            // Production asks before any write from the console: the SQL preview sheet, then Run.
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(main.window?.attachedSheet?.title == "Run this statement on Production · shop?")
            #expect(await call(harness, "press", ["title": "Run"]).error == nil)
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(console.transactionBadge == "Transaction open · 2 changes", "\(console.messagesView.messages.map(\.text))")
            #expect(main.statusBar.transaction.value == "Transaction open · 2 changes")

            // Profile: the statement's result, then where the server spent its time.
            console.editor.setSelectedRange(NSRange(location: 20, length: 0))
            #expect(await call(harness, "menu", ["path": "Query > Profile"]).error == nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(console.resultTabs.last?.title == "Profile", "\(console.resultTabs.map(\.title))")

            // Explain: the plan in a tab of its own.
            #expect(await call(harness, "menu", ["path": "Query > Explain"]).error == nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(console.selectedResult?.title == "Plan")

            // Closing the connection's last console asks about the transaction, then about the unsaved text.
            main.closeTab(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(await call(harness, "press", ["title": "Roll Back"]).error == nil)
            _ = try await eventually(timeout: 10) { main.window?.attachedSheet?.title != "" && console.session?.inTransaction == false }
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(await call(harness, "press", ["title": "Don't Save"]).error == nil)
            #expect(try await eventually(timeout: 10) { main.tabs.isEmpty })
            let count = try await setup.query("SELECT COUNT(*) FROM \(database).t").first?.rows?.string(0, 0)
            #expect(count == "0", "rolled back")
            _ = try await setup.query("DROP DATABASE \(database)")
            await connection.disconnect()
        }
    }
}
