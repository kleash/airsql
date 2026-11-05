import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// What a tab's parameters and an import promise, whatever the session and the engine turn out to be.
@Suite struct SafetyCoreTests {
    /// In either mode: on a tab's first run the mode may not be known yet, and `\'` ends a string under NO_BACKSLASH_ESCAPES.
    @Test func aValueWithAQuoteStaysAStringInEitherMode() {
        for noBackslashEscapes in [false, true] {
            #expect(QueryParameters.literal("' OR 1=1 -- ", noBackslashEscapes: noBackslashEscapes) == "''' OR 1=1 -- '")
        }
        #expect(QueryParameters.literal(#"a\b"#, noBackslashEscapes: false) == #"'a\\b'"#)
        #expect(QueryParameters.literal(#"a\b"#, noBackslashEscapes: true) == #"'a\b'"#)
    }

    /// Taking a connection away takes its passwords with it: the person's, even with Ask before agents change anything off.
    @Test func aConnectionGoingIsThePersons() {
        var old = AirSQLData()
        old.connections = [SavedConnection(name: "Shop"), SavedConnection(name: "Stage")]
        var new = old
        new.connections.removeLast()
        #expect(AgentGate.personOnlyChange(from: old, to: new) == "which connections there are")
        #expect(AgentGate.personOnlyChange(from: old, to: old) == nil)
    }
}

extension AppTests {
    @MainActor @Suite struct SafetyAppTests {
        @Test func importWarnsOfAnEngineThatCantRollBack() {
            let warnings = { CSVImportSheet.warnings(table: "t", engine: $0, emptyFirst: $1) }
            #expect(warnings("InnoDB", false).isEmpty && warnings(nil, false).isEmpty)
            #expect(warnings("InnoDB", true) == ["Every row t has now is deleted first."])
            #expect(warnings("MyISAM", true).count == 2 && warnings("MyISAM", true)[1].contains("its old rows are gone"))
            #expect(warnings("Aria", false).count == 1 && warnings("Aria", false)[0].contains("the rows before it stay"))
        }

        /// The views that show rows outside a grid: the process's statement, Export Rows' and Import's previews, a table's note.
        @Test func previewsOfRowsCountAsRows() {
            for id in ["processes.statement", "export.preview", "csv.preview", "console.insightNote"] {
                let view = NSView()
                view.setAccessibilityIdentifier(id)
                #expect(AgentServer.showsData(view), "\(id)")
            }
        }

        /// Export Rows… on a grid the agent can't read: the sheet opens, its preview of the rows doesn't reach the reply.
        @Test func exportRowsShowsAgentsNoRowsTheyMayNotRead() async throws {
            let (main, harness, service) = try await AgentGateUITests.agents()
            defer {
                service.close()
                ConsoleViewController.openConnection = { _ in nil }
            }
            let console = try await AgentGateUITests.console(main, harness, on: Fixtures.production.id)  // Schema access: no data
            ConsoleFixtures.dress(console)
            let window = try #require(main.window)
            window.layoutIfNeeded()
            let content = try #require(window.contentView)
            let grid = try #require(find(DataGridView.self, in: content))
            let rect = grid.convert(grid.cellRect(GridPosition(row: 1, column: 1)), to: nil)
            #expect(await agentCall(service, "right_click", ["x": rect.midX, "y": window.frame.height - rect.midY]).error == nil)
            let export = await agentCall(service, "menu", ["path": "context > Export Rows…"])
            #expect(export.error == nil, "\(export.error ?? "")")
            _ = await agentCall(service, "wait", ["until": "sheet", "timeout": 10])
            let sheet = try #require(window.attachedSheet?.contentView)
            let shown = try #require(find(NSTextField.self, id: "export.preview", in: sheet))
            #expect(shown.stringValue.contains("Nordlicht"), "the person sees it")
            let reply = await agentCall(service, "snapshot", ["include": ["elements", "sheets"]])
            let text = String(decoding: (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data(), as: UTF8.self)
            #expect(!text.contains("Nordlicht"))
            _ = await call(harness, "press", ["title": "Cancel"])
        }

        /// Open and Save panels are the person's: of what reaches a window, only Cancel goes through.
        @Test func anAgentCanOnlyCancelAnOpenOrSavePanel() async throws {
            let (_, harness, service) = try await AgentGateUITests.agents()
            defer { service.close() }
            let panel = NSSavePanel()
            AgentGate.$agent.withValue("Claude Code") {
                #expect(throws: AgentServer.Failure.self) { try harness.checkAgentMayAct(in: panel) }
                #expect(throws: AgentServer.Failure.self) { try harness.checkAgentMayAct(in: panel, pressing: "Save") }
                #expect(throws: Never.self) { try harness.checkAgentMayAct(in: panel, pressing: "Cancel") }
            }
            #expect(throws: Never.self) { try harness.checkAgentMayAct(in: panel) }
        }

        /// Open in Terminal writes the login to a file and starts a client with no gate in front of it.
        @Test func openInTerminalIsThePersons() async throws {
            let (main, harness, service) = try await AgentGateUITests.agents()
            defer {
                service.close()
                ConsoleViewController.openConnection = { _ in nil }
            }
            _ = try await AgentGateUITests.console(main, harness, on: Fixtures.local.id)
            let reply = await agentCall(service, "menu", ["path": "Tools > Open in Terminal"])
            #expect(reply.error?.contains("Only the person at the Mac can open a client in Terminal") == true, "\(reply.error ?? "no error")")
        }

        /// The Production preset without the colour counts as Production: an agent's text waits at its console too.
        @Test func thePresetAloneMakesAConsoleProduction() async throws {
            var saved = Fixtures.staging
            saved.colour = .none
            saved.safety = .production
            let (main, harness, service) = try await AgentGateUITests.agents([saved])
            defer {
                service.close()
                ConsoleViewController.openConnection = { _ in nil }
            }
            let console = try await AgentGateUITests.console(main, harness, on: saved.id)
            #expect(AgentGuard.productionConsole(console.editor)?.id == saved.id)
        }

        /// READ ONLY doesn't stop a kill: a read-only connection's menu does, whatever is selected.
        @Test func aReadOnlyConnectionKillsNothing() async throws {
            var saved = Fixtures.staging
            saved.readOnly = true
            let model = testModel([saved])
            _ = appWindow(model)
            let list = ProcessListContent(await openReplayed(model, saved.id))
            for command in [Commands.killQuery, Commands.killConnection] {
                let item = command.item()
                #expect(!list.validateMenuItem(item) && item.toolTip?.contains("read-only") == true)
            }
        }

        /// A tab that has just fallen back to the main session doesn't run beside the tab already running there: its
        /// Cancel would stop that one's statement.
        @Test func aTabThatFallsBackWaitsForTheMainSessionsRunner() async throws {
            let (_, _, console) = try await ConsoleAppTests.console()
            let id = try #require(console.connectionID)
            defer { ConsoleViewController.shared[id] = nil }
            console.sharing = true
            ConsoleViewController.shared[id] = .init(runner: UUID())
            let nowhere = Connection(options: ConnectOptions(host: "127.0.0.1", port: 1, user: "root", connectTimeout: 1))
            do {
                _ = try await console.sessionForRun(on: nowhere)
                Issue.record("it went on")
            } catch {
                #expect(error.localizedDescription.contains("Another query tab is running"), "\(error.localizedDescription)")
            }
        }
    }

    @MainActor @Suite(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh")) struct SafetyLabTests {
        private func answerNewSession(_ main: MainWindowController, _ harness: AgentServer, _ console: ConsoleViewController) async {
            console.editor.setText("SELECT 1;")
            console.editor.setSelectedRange(NSRange(location: 0, length: 0))
            console.runStatement(nil)
            #expect(await eventually(timeout: 10) { main.window?.attachedSheet != nil })
            #expect(await call(harness, "press", ["title": "Open New Session"]).error == nil)
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            console.runStatement(nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
        }

        /// In Manual with no transaction open, a tab's session goes with the route: the tab stops, and comes back in Manual.
        @Test func manualCommitOutlivesItsSessionWithNoTransactionOpen() async throws {
            let (main, harness, console, connection) = try await ConsoleRunAppTests.labConsole()
            defer { ConsoleViewController.openConnection = { _ in nil } }
            console.setTransactionMode(ConsoleRunAppTests.manualItem())
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(console.session?.autocommit == false && console.session?.inTransaction == false)
            connection.dropped()  // a route's exit: closed here, with no failed call on the session itself
            #expect(await eventually(timeout: 10) { console.session == nil })
            console.model.states[Fixtures.production.id] = .failed("The connection was lost.")
            #expect(await eventually(timeout: 5) { console.lostSession != nil })
            #expect(console.lostSession?.manual == true && console.lostSession?.transaction == false)
            _ = try await connection.reconnect()
            console.model.states[Fixtures.production.id] = .connected(server: "MariaDB")
            await answerNewSession(main, harness, console)
            #expect(console.session?.autocommit == false, "the next UPDATE waits for Commit")
            await connection.disconnect()
        }

        /// A shared session reconnected before the person answers is the same object, set up anew: the sheet's promise of
        /// Manual Commit holds there too.
        @Test func aSharedSessionReconnectedStaysInManual() async throws {
            let (main, harness, console, connection) = try await ConsoleRunAppTests.labConsole()
            defer { ConsoleViewController.openConnection = { _ in nil } }
            var saved = try #require(console.connection)
            saved.sharedQuerySession = true
            console.model.save(saved)
            console.setTransactionMode(ConsoleRunAppTests.manualItem())
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            let session = try #require(console.session)
            #expect(session.role == .main && session.autocommit == false)
            let admin = try await connection.toolsSession()
            _ = try await admin.query("KILL \(try #require(session.server?.threadID))")
            try? await session.ping()
            #expect(session.wasLost)
            console.noticeLostSession()
            #expect(console.lostSession?.manual == true)
            _ = try await connection.reconnect()
            #expect(session.isConnected && session.autocommit)
            await answerNewSession(main, harness, console)
            #expect(session.autocommit == false, "\(console.messagesView.messages.map(\.text))")
            await connection.disconnect()
        }

        /// Cancel while a tab's session opens has no statement to stop: what Explain Analyze would have run doesn't run.
        @Test func cancelWhileTheSessionOpensStopsExplainAnalyze() async throws {
            let (_, harness, console, connection) = try await ConsoleRunAppTests.labConsole()
            defer { ConsoleViewController.openConnection = { _ in nil } }
            let admin = try await connection.toolsSession()
            let database = "lane_fix_cancel"
            for sql in ["DROP DATABASE IF EXISTS \(database)", "CREATE DATABASE \(database)", "CREATE TABLE \(database).t (id INT PRIMARY KEY)"] {
                _ = try await admin.query(sql)
            }
            console.start(ConsoleRun(kind: .analyze, statements: [SQLStatement(sql: "INSERT INTO \(database).t VALUES (1)")], text: ""))
            console.cancelQuery(nil)  // before the task that opens the session gets to run
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(await eventually(timeout: 10) { console.running == nil })
            #expect(try await admin.query("SELECT COUNT(*) FROM \(database).t").first?.rows?.string(0, 0) == "0")
            _ = try await admin.query("DROP DATABASE \(database)")
            await connection.disconnect()
        }

        /// A parameter on a tab's first run takes the server's sql_mode: a backslash in the value can't end its string.
        @Test func aFirstRunBindsForTheServersSqlMode() async throws {
            let saved = SavedConnection(name: "Lab", host: "127.0.0.1", port: Lab.mariadb114.port!, user: Lab.airsql.user)
            let model = testModel([saved])
            let (main, harness) = appWindow(model)
            var options = DBLab.options(Lab.mariadb114)
            options.startupSQL = ["SET SESSION sql_mode = CONCAT(@@sql_mode, ',NO_BACKSLASH_ESCAPES')"]
            let connection = Connection(options: options, log: DBLab.log)
            try await connection.connect()
            let open = model.attach(connection, to: saved.id) { $0 == "fixture" }
            defer {
                model.detach(open.id)
                ConsoleViewController.openConnection = { _ in nil }
            }
            _ = await eventually(timeout: 60) { open.snapshot.server != nil && open.loading.isEmpty }
            #expect(open.snapshot.server?.noBackslashEscapes == true)
            ConsoleViewController.openConnection = { $0 == saved.id ? connection : nil }
            model.states[saved.id] = .connected(server: "MariaDB")
            let console = try #require(main.openConsole(text: "SELECT :v AS v, 'x' AS w;", title: nil, connection: saved.id).content as? ConsoleViewController)
            console.parameterValues = [":v": #"\' OR 1=1 -- "#]
            console.editor.setSelectedRange(NSRange(location: 0, length: 0))
            console.runStatement(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(await call(harness, "press", ["title": "Run"]).error == nil)
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            #expect(console.lastOutcome?.results.first?.rows?.string(0, 0) == #"\' OR 1=1 -- "#, "\(console.messagesView.messages.map(\.text))")
            await connection.disconnect()
        }

        /// The read lock's session is the connection's own, and Unlock says when the lock had gone already.
        @Test func theReadLockIsTrackedAndSaysWhenItWentEarly() async throws {
            let saved = SavedConnection(name: "Lab", host: "127.0.0.1", port: Lab.mariadb114.port!, user: Lab.airsql.user)
            let model = testModel([saved])
            let (main, harness) = appWindow(model)
            let connection = Connection(options: DBLab.options(Lab.mariadb114), log: DBLab.log)
            try await connection.connect()
            let open = model.attach(connection, to: saved.id) { $0 == "fixture" }
            defer { model.detach(open.id) }
            _ = await eventually(timeout: 60) { open.snapshot.server != nil && open.loading.isEmpty }
            model.states[saved.id] = .connected(server: "MariaDB")
            main.sidebar.select([saved.id])
            let before = await connection.sessions().map(\.role)
            let tools = try #require(main.nextResponder as? ToolsResponder)
            tools.flushReadLock(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            #expect(await call(harness, "press", ["id": "preview.run"]).error == nil)
            #expect(await eventually(timeout: 20) { main.window?.attachedSheet?.windowController == nil && main.window?.attachedSheet != nil })
            let held = await connection.sessions().filter { $0.role == .tools && !before.isEmpty }
            let lock = try #require(held.last, "tracked by the connection, so keep-alive pings it")
            let killer = try await connection.toolsSession()
            _ = try await killer.query("KILL \(try #require(lock.server?.threadID))")
            await killer.close()
            #expect(await call(harness, "press", ["title": "Unlock"]).error == nil)
            #expect(await eventually(timeout: 10) {
                main.window?.attachedSheet.map { AgentServer.views(NSTextField.self, in: $0.contentView).contains { $0.stringValue == "The lock had already gone" } } == true
            })
            _ = await call(harness, "press", ["title": "OK"])
            await connection.disconnect()
        }

        /// A deadlock ends the whole transaction, with what earlier Applies wrote: the tab says so.
        @Test func aDeadlockInAManualTableTabSaysTheEarlierAppliesWentToo() async throws {
            let connection = Connection(options: DBLab.options(Lab.mariadb114, tls: DBLab.required), log: DBLab.log)
            try await connection.connect()
            defer { Task { await connection.disconnect() } }
            let database = "lane_fix_deadlock"
            let admin = try await connection.session(.schema), other = try await connection.toolsSession()
            let values = (1...50).map { "(\($0), 'a')" }.joined(separator: ", ")
            for sql in ["DROP DATABASE IF EXISTS \(database)", "CREATE DATABASE \(database)",
                        "CREATE TABLE \(database).t (id INT PRIMARY KEY, name VARCHAR(20)) ENGINE=InnoDB", "INSERT INTO \(database).t VALUES \(values)"] {
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
            tab.setTransactionMode(ConsoleRunAppTests.manualItem())
            #expect(await eventually(timeout: 10) { tab.transactionSession != nil })
            await ready()
            let source = try #require(tab.source)
            tab.keep(.text("b"), row: 0, column: 1)
            tab.applyChanges(nil)
            #expect(await eventually(timeout: 20) { try? await Task.sleep(nanoseconds: 50_000_000); return source.changes.isEmpty && tab.loading == nil })
            #expect(tab.inTransaction)
            // The other session holds most rows and waits for row 1; the tab then waits for it: InnoDB rolls back the smaller side.
            _ = try await other.query("START TRANSACTION")
            _ = try await other.query("UPDATE \(database).t SET name = 'z' WHERE id > 1")
            let waiting = Task { try? await other.query("UPDATE \(database).t SET name = 'z' WHERE id = 1") }
            try await Task.sleep(nanoseconds: 300_000_000)
            tab.keep(.text("c"), row: 1, column: 1)
            tab.applyChanges(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 20])
            let sheet = try #require(main.window?.attachedSheet)
            let words = AgentServer.views(NSTextField.self, in: sheet.contentView).map(\.stringValue).joined(separator: " ")
            #expect(words.contains("rolled back the whole transaction"), "\(words)")
            _ = await call(harness, "press", ["title": "OK"])
            _ = await waiting.value
            _ = try await other.query("ROLLBACK")
            #expect(!tab.inTransaction && tab.transactionRows == 0)
            _ = try await admin.query("DROP DATABASE \(database)")
        }
    }
}
