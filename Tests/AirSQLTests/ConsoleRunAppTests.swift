import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// Running in a query tab: the connection a tab takes, the marks at the statements' ends, the notice of a long run, a
/// result run again.
extension AppTests {
    @MainActor @Suite struct ConsoleRunAppTests {
        /// A tab with no connection works on the one the window shows, with nothing to choose.
        @Test func aTabWithNoConnectionTakesTheWindows() async throws {
            let model = testModel(Fixtures.shop)
            let (main, harness) = appWindow(model)
            let tab = main.openConsole(text: "SELECT 1", title: nil, connection: nil)
            let console = try #require(tab.content as? ConsoleViewController)
            #expect(console.connectionID == nil)
            main.sidebar.select([Fixtures.production.id])
            _ = await call(harness, "wait", ["until": "idle", "timeout": 5])
            #expect(console.connectionID == Fixtures.production.id && tab.connectionID == Fixtures.production.id)
            #expect(main.selectedTab === tab, "it stays on show")
        }

        @Test func marksFollowTheTextAndGoWithTheirStatement() async throws {
            let (_, _, console) = try await ConsoleAppTests.console()
            console.editor.setText("SELECT 1;\nSELECT 2;\n")
            console.runMarks.add(NSRange(location: 0, length: 9), failed: false, time: "1 ms")
            console.runMarks.add(NSRange(location: 10, length: 9), failed: true, time: "2 ms")
            console.editor.insertText("-- ", replacementRange: NSRange(location: 0, length: 0))
            #expect(console.runMarks.marks.map(\.range.location) == [3, 13])
            console.editor.insertText("0", replacementRange: NSRange(location: 10, length: 1))
            #expect(console.runMarks.marks.map(\.range.location) == [13], "the edited statement's mark goes")
            console.editor.setText("")
            #expect(console.runMarks.marks.isEmpty)
        }

        @Test func onlyALongRunWhileAwayTellsThePerson() {
            #expect(LongQueryNotice.shouldTell(after: 10, appActive: false))
            #expect(!LongQueryNotice.shouldTell(after: 9.9, appActive: false))
            #expect(!LongQueryNotice.shouldTell(after: 600, appActive: true))
        }

        /// A lab console on Production's id, and the connection under it.
        static func labConsole() async throws -> (MainWindowController, AgentServer, ConsoleViewController, Connection) {
            let connection = Connection(options: DBLab.options(Lab.mariadb114, tls: DBLab.required), log: DBLab.log)
            try await connection.connect()
            ConsoleViewController.openConnection = { $0 == Fixtures.production.id ? connection : nil }
            let model = testModel(Fixtures.shop)
            model.states[Fixtures.production.id] = .connected(server: "MariaDB")
            let (main, harness, console) = try await ConsoleAppTests.console(model)
            return (main, harness, console, connection)
        }

        /// Run marks the statements; Run Result Again puts new rows in the tab's place, under its name.
        @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
        func aResultRunsAgainInItsPlace() async throws {
            let (_, harness, console, connection) = try await Self.labConsole()
            defer { ConsoleViewController.openConnection = { _ in nil } }
            console.editor.setText("SELECT RAND() AS r;\nSELECT 2;\nSELECT nope;")
            #expect(await call(harness, "key", ["combo": "cmd+shift+return"]).error == nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(console.runMarks.marks.map(\.failed) == [false, false, true], "\(console.messagesView.messages.map(\.text))")
            let first = try #require(console.resultTabs.first)
            first.title = "Mine"
            first.pinned = true
            console.selectResult(first)
            let before = first.content.store?.string(0, 0)
            #expect(await call(harness, "menu", ["path": "Query > Run Result Again"]).error == nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(console.resultTabs.count == 2)
            let again = try #require(console.resultTabs.first)
            #expect(again !== first && again.title == "Mine" && again.pinned && console.selectedResult === again)
            #expect(again.content.store?.string(0, 0) != before)
            await connection.disconnect()
        }

        /// Two tabs of one connection: a long statement in one doesn't hold up the other; each has its own transaction,
        /// database and session, Cancel stops only its own statement, and Quit lists both transactions.
        @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
        func eachTabRunsOnItsOwnSession() async throws {
            let (main, harness, first, connection) = try await Self.labConsole()
            defer { ConsoleViewController.openConnection = { _ in nil } }
            let setup = try await connection.toolsSession()
            let database = "lane_run_sessions"
            for sql in ["DROP DATABASE IF EXISTS \(database)", "CREATE DATABASE \(database)", "CREATE TABLE \(database).t (id INT PRIMARY KEY)"] {
                _ = try await setup.query(sql)
            }
            func idle() async { _ = await call(harness, "wait", ["until": "idle", "timeout": 20]) }
            func run(_ console: ConsoleViewController, _ sql: String) async {
                console.editor.setText(sql)
                console.editor.setSelectedRange(NSRange(location: 0, length: 0))
                console.runStatement(nil)
                if main.window?.attachedSheet != nil { _ = await call(harness, "press", ["title": "Run"]) }
            }
            await run(first, "USE fixture;")
            await idle()
            let tab = main.openConsole(text: "", title: nil, connection: Fixtures.production.id)
            let second = try #require(tab.content as? ConsoleViewController)
            await run(second, "USE \(database);")
            await idle()
            #expect(first.database == "fixture" && second.database == database)
            #expect(first.session !== second.session && first.session != nil && second.session != nil)
            let (one, two) = (first.session?.server?.threadID, second.session?.server?.threadID)
            #expect(one != two)

            // The first tab's long statement: the second runs while it does, and its Cancel touches only the first.
            await run(first, "SELECT SLEEP(30);")
            #expect(await eventually(timeout: 5) { first.session?.isBusy == true })
            #expect(first.running != nil)
            await run(second, "SELECT DATABASE();")
            #expect(await eventually(timeout: 5) { second.running == nil })
            #expect(second.lastOutcome?.results.first?.rows?.string(0, 0) == database)
            #expect(first.running != nil, "still running")
            first.cancelQuery(nil)
            #expect(await eventually(timeout: 10) { first.running == nil })

            // A transaction in each: Commit in one leaves the other's.
            second.setTransactionMode(Self.manualItem())
            await idle()
            await run(second, "INSERT INTO t VALUES (1);")
            await idle()
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 5])
            await idle()
            #expect(second.session?.inTransaction == true, "\(second.messagesView.messages.map(\.text))")
            #expect(first.session?.inTransaction == false && first.transactionBadge == nil)
            main.select(try #require(main.tabs.first { $0.content === first }))
            first.setTransactionMode(Self.manualItem())
            await idle()
            await run(first, "INSERT INTO \(database).t VALUES (2);")
            await idle()
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 5])
            await idle()
            let lines = main.unfinishedWork()
            #expect(lines.filter { $0.hasPrefix("A transaction in") }.count == 2, "\(lines)")
            first.rollback(nil)
            await idle()
            #expect(first.session?.inTransaction == false && second.session?.inTransaction == true)
            let seen = try await setup.query("SELECT COUNT(*) FROM \(database).t").first?.rows?.string(0, 0)
            #expect(seen == "0", "neither committed")

            // Closing the tab asks about its own transaction though another tab of the connection stays, then ends its session.
            let session = try #require(second.session)
            main.close(tab)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(await call(harness, "press", ["title": "Roll Back"]).error == nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(await call(harness, "press", ["title": "Don't Save"]).error == nil)
            #expect(await eventually(timeout: 10) { !session.isConnected })
            #expect(ConsoleViewController.shared[second.documentID] == nil)
            _ = try await setup.query("DROP DATABASE \(database)")
            await connection.disconnect()
        }

        static func manualItem() -> NSMenuItem {
            let item = NSMenuItem()
            item.tag = 1
            return item
        }

        /// A read-only connection's tab sessions are read-only on the server too, and a session lost to the server is
        /// reported, with nothing run, before a Run opens another.
        @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
        func aTabsSessionKeepsReadOnlyAndIsNeverSilentlyReplaced() async throws {
            var options = DBLab.options(Lab.mariadb114, tls: DBLab.required)
            options.readOnly = true
            let connection = Connection(options: options, log: DBLab.log)
            try await connection.connect()
            ConsoleViewController.openConnection = { $0 == Fixtures.production.id ? connection : nil }
            defer { ConsoleViewController.openConnection = { _ in nil } }
            let model = testModel(Fixtures.shop)
            var saved = Fixtures.production
            saved.readOnly = true
            model.save(saved)
            model.states[Fixtures.production.id] = .connected(server: "MariaDB")
            let (_, harness, console) = try await ConsoleAppTests.console(model)
            func run(_ sql: String) async {
                console.editor.setText(sql)
                console.editor.setSelectedRange(NSRange(location: 0, length: 0))
                console.runStatement(nil)
                _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            }
            console.editor.setText("SELECT 1;")
            console.explainAnalyze(nil)
            #expect(console.messagesView.messages.last?.level == .error && console.resultTabs.isEmpty, "refused, even a SELECT: it runs")
            await run("SELECT @@transaction_read_only;")
            #expect(console.lastOutcome?.results.first?.rows?.string(0, 0) == "1", "\(console.messagesView.messages.map(\.text))")
            let session = try #require(console.session)
            #expect(session.role == .query)

            let killer = try await connection.toolsSession()
            let thread = try #require(session.server?.threadID)
            _ = try await killer.query("KILL \(thread)")
            try? await session.ping()
            #expect(session.wasLost)
            await run("SELECT 1;")
            #expect(console.messagesView.messages.last?.text.contains("session was lost") == true)
            await run("SELECT 2;")
            #expect(console.lastOutcome?.results.first?.rows?.string(0, 0) == "2", "\(console.messagesView.messages.map(\.text))")
            #expect(console.session !== session)
            await connection.disconnect()
        }

        /// A connection set to share one session: its tabs are on the main session, with one transaction, as before.
        @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
        func aSharedSessionStaysAnOptionAndNewSessionsStartAsTheConnectionSays() async throws {
            let (main, harness, first, connection) = try await Self.labConsole()
            defer { ConsoleViewController.openConnection = { _ in nil } }
            var saved = try #require(first.connection)
            saved.sharedQuerySession = true
            saved.startsManual = true
            saved.startIsolation = .readCommitted
            first.model.save(saved)
            func run(_ console: ConsoleViewController, _ sql: String) async {
                console.editor.setText(sql)
                console.editor.setSelectedRange(NSRange(location: 0, length: 0))
                console.runStatement(nil)
                _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            }
            await run(first, "SELECT @@autocommit, @@transaction_isolation;")
            let rows = try #require(first.lastOutcome?.results.first?.rows)
            #expect(rows.string(0, 0) == "0" && rows.string(0, 1) == "READ-COMMITTED", "\(first.messagesView.messages.map(\.text))")
            #expect(first.shared.isolation == .readCommitted && !first.autocommit)
            let second = try #require(main.openConsole(text: "", title: nil, connection: Fixtures.production.id).content as? ConsoleViewController)
            await run(second, "SELECT 1;")
            let shared = try await connection.session(.main)
            #expect(first.session === shared && second.session === shared)
            await connection.disconnect()
            ConsoleViewController.shared[Fixtures.production.id] = nil
        }

        /// Explain Analyze: the plan with real figures in its tab; a write asks first even where writes don't, and a
        /// read-only connection refuses it whatever the statement.
        @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
        func explainAnalyzeRunsAndAsksAsARunDoes() async throws {
            let (main, harness, console, connection) = try await Self.labConsole()
            defer { ConsoleViewController.openConnection = { _ in nil } }
            console.editor.setText("SELECT COUNT(*) FROM fixture.customers;")
            #expect(await call(harness, "menu", ["path": "Query > Explain Analyze"]).error == nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            let tab = try #require(console.resultTabs.last)
            #expect(tab.title == "Plan (Analyzed)", "\(console.messagesView.messages.map(\.text))")
            let plan = try #require(tab.view as? PlanView)
            let operations = try #require(plan.operations?.outline)
            #expect(operations.numberOfRows > 0 && operations.tableColumns.contains { $0.title == "Actual Rows" })

            console.editor.setText("UPDATE fixture.customers SET id = id WHERE id = -1;")
            console.explainAnalyze(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(main.window?.attachedSheet != nil, "it really runs: a write asks")
            #expect(await call(harness, "press", ["title": "Cancel"]).error == nil)
            await connection.disconnect()
        }

        /// Parameters are asked for, filled in, and the read-only check sees the final SQL; Run from Cursor and Run Subquery
        /// send what they say.
        @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
        func parametersAreAskedForAndRunTheWayTheCursorSays() async throws {
            let (main, harness, console, connection) = try await Self.labConsole()
            defer { ConsoleViewController.openConnection = { _ in nil } }
            console.parameterValues = [":a": "7", "?1": "it's"]
            console.editor.setText("SELECT :a, ?, ':a', :a;")
            console.editor.setSelectedRange(NSRange(location: 0, length: 0))
            console.runStatement(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(main.window?.attachedSheet != nil)
            #expect(await call(harness, "press", ["title": "Run"]).error == nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            let rows = try #require(console.lastOutcome?.results.first?.rows, "\(console.messagesView.messages.map(\.text))")
            #expect((0..<4).map { rows.string(0, $0) } == ["7", "it's", ":a", "7"])

            console.editor.setText("SELECT 1;\nSELECT 2;\nSELECT (SELECT 3 + 0) AS four, 4;")
            console.editor.setSelectedRange(NSRange(location: 10, length: 0))
            console.runFromCaret(nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(console.resultTabs.count == 2)
            console.editor.setSelectedRange(NSRange(location: 30, length: 0))
            console.runSubquery(nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(console.lastOutcome?.statement.sql == "SELECT 3 + 0")
            await connection.disconnect()
        }

        /// Manual Commit in a table tab: Apply stays uncommitted and the tab reads its own changes; others don't see them;
        /// Quit lists it, Roll Back undoes it, Commit writes it, and closing asks.
        @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
        func aTableTabHoldsItsChangesInAManualTransaction() async throws {
            let connection = Connection(options: DBLab.options(Lab.mariadb114, tls: DBLab.required), log: DBLab.log)
            try await connection.connect()
            defer { Task { await connection.disconnect() } }
            let database = "lane_run_manual"
            let admin = try await connection.session(.schema)
            for sql in ["DROP DATABASE IF EXISTS \(database)", "CREATE DATABASE \(database)",
                        "CREATE TABLE \(database).t (id INT PRIMARY KEY, name VARCHAR(20))", "INSERT INTO \(database).t VALUES (1, 'a')"] {
                _ = try await admin.query(sql)
            }
            let schema = SchemaCache(source: admin, includes: { $0 == database })
            try await schema.load()
            let saved = SavedConnection(name: "Lab", host: "127.0.0.1", user: "airsql")
            let model = testModel([saved])
            let (main, harness) = appWindow(model)
            let tab = TableDataController(model: model, context: EditorContext(connection: saved, sessions: connection, schema: schema),
                                          database: database, table: "t")
            main.select(main.open(tab, title: "t", connection: saved.id))
            func ready() async { _ = await eventually(timeout: 20) { try? await Task.sleep(nanoseconds: 50_000_000); return tab.source != nil && tab.loading == nil } }
            await ready()
            func outside() async throws -> String? { try await admin.query("SELECT name FROM \(database).t WHERE id = 1").first?.rows?.string(0, 0) }

            tab.setTransactionMode(Self.manualItem())
            #expect(await eventually(timeout: 10) { tab.transactionSession != nil })
            await ready()
            let source = try #require(tab.source)
            tab.keep(.text("b"), row: 0, column: 1)
            tab.applyChanges(nil)
            #expect(await eventually(timeout: 20) { try? await Task.sleep(nanoseconds: 50_000_000); return source.changes.isEmpty && tab.loading == nil })
            #expect(tab.inTransaction && tab.transactionBadge == "Transaction open")
            #expect(await eventually(timeout: 10) { source.value(0, 1) == "b" }, "the tab reads its own change")
            #expect(try await outside() == "a", "not committed")
            #expect(main.unfinishedWork().contains { $0.hasPrefix("A transaction in “t”") })

            tab.rollback(nil)
            await ready()
            #expect(await eventually(timeout: 10) { !tab.inTransaction })
            #expect(try await outside() == "a")

            tab.keep(.text("c"), row: 0, column: 1)
            tab.applyChanges(nil)
            #expect(await eventually(timeout: 20) { try? await Task.sleep(nanoseconds: 50_000_000); return source.changes.isEmpty && tab.loading == nil })
            main.close(try #require(main.tabs.first))
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(await call(harness, "press", ["title": "Commit"]).error == nil)
            #expect(await eventually(timeout: 10) { main.tabs.isEmpty })
            #expect(try await outside() == "c")
            _ = try await admin.query("DROP DATABASE \(database)")
        }

        /// Local History brings a saved state back into the editor, as an edit.
        @Test func aFilesSavedStateComesBack() async throws {
            let (main, harness, console) = try await ConsoleAppTests.console()
            let url = URL(fileURLWithPath: try scratch()).appendingPathComponent("a.sql")
            console.editor.setText("SELECT 1")
            console.setFile(url, savedText: "")
            var saved = false
            console.save(as: false) { saved = $0 }
            #expect(await eventually(timeout: 5) { saved })
            console.editor.setText("SELECT 2")
            console.save(as: false) { _ in }
            #expect(await eventually(timeout: 5) { console.savedText == "SELECT 2" })
            console.showLocalHistory(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            let sheet = try #require(main.window?.attachedSheet?.contentViewController as? LocalHistorySheet)
            sheet.select(row: 1)
            #expect(await call(harness, "press", ["id": "localHistory.restore"]).error == nil)
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            #expect(console.text == "SELECT 1" && console.isEdited)
        }

        /// Sessions… names what uses each session.
        @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
        func theSessionsListNamesEachTab() async throws {
            let (main, harness, console, connection) = try await Self.labConsole()
            defer { ConsoleViewController.openConnection = { _ in nil } }
            console.editor.setText("SELECT 1")
            console.runStatement(nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            let rows = main.sessionRows(await connection.sessions())
            #expect(rows.contains { $0.job == "“\(main.selectedTab?.title ?? "")”" && $0.state == "Idle" })
            #expect(rows.contains { $0.job == "The connection" })
            await connection.disconnect()
        }

        /// A script's error asks: Skip goes on; a result refreshes by itself only while it only reads; Keep Results keeps.
        @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
        func aScriptAsksAtAnErrorAndAResultRefreshesItself() async throws {
            let (main, harness, console, connection) = try await Self.labConsole()
            defer { ConsoleViewController.openConnection = { _ in nil } }
            console.editor.setText("SELECT nope;\nSELECT RAND() AS r;")
            console.runAll(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(main.window?.attachedSheet != nil)
            #expect(await call(harness, "press", ["title": "Skip"]).error == nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(console.runMarks.marks.map(\.failed) == [true, false])
            let result = try #require(console.resultTabs.first)
            console.selectResult(result)
            let item = NSMenuItem()
            item.tag = 1
            console.setAutoRefresh(item)
            #expect(await eventually(timeout: 5) { console.resultTabs.first !== result })
            #expect(console.resultTabs.count == 1 && console.refreshedResult === console.resultTabs.first)
            console.setAutoRefresh(nil)
            #expect(console.refreshTimer == nil)
            console.keepsResults = true
            console.editor.setText("SELECT 5")
            console.runStatement(nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(console.resultTabs.count == 2)
            await connection.disconnect()
        }

        /// A file edited elsewhere: the tab follows, or with unsaved edits warns; the connection is remembered.
        @Test func aFileChangedOnDiskIsNoticed() async throws {
            let (_, _, console) = try await ConsoleAppTests.console()
            let url = URL(fileURLWithPath: try scratch()).appendingPathComponent("b.sql")
            console.editor.setText("SELECT 1")
            console.setFile(url, savedText: "")
            var saved = false
            console.save(as: false) { saved = $0 }
            #expect(await eventually(timeout: 5) { saved })
            #expect(ConsoleViewController.rememberedConnection(of: url) == Fixtures.production.id)
            try "SELECT 2".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
            console.checkFile()
            #expect(await eventually(timeout: 5) { console.text == "SELECT 2" })
            #expect(!console.isEdited)
            console.editor.setText("SELECT 3")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: url.path)
            console.checkFile()
            #expect(await eventually(timeout: 5) { console.messagesView.messages.last?.text.contains("changed on disk: saving") == true })
            #expect(console.text == "SELECT 3")
        }
    }
}
