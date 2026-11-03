import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// A console tab driven through the harness (plan §2.6): New Query, typing with colours, the editor's commands, and
/// what Run says without a connection. The lab test runs statements, Manual mode and closing with a transaction open.
extension AppTests {
    @MainActor @Suite struct ConsoleAppTests {
        /// A window with the shop's connections and a new console on Production.
        static func console(_ given: AppModel? = nil) async throws -> (MainWindowController, AgentServer, ConsoleViewController) {
            let (main, harness) = appWindow(given ?? testModel(Fixtures.shop))
            main.sidebar.select([Fixtures.production.id])
            let reply = await call(harness, "menu", ["path": "File > New Query"])
            #expect(reply.error == nil, "\(reply.error ?? "")")
            let console = try #require(main.selectedTab?.content as? ConsoleViewController)
            return (main, harness, console)
        }

        @Test func newQueryOpensAConsoleOnTheSelectedConnection() async throws {
            let (main, _, console) = try await Self.console()
            #expect(main.selectedTab?.title == "Query 1" && console.connectionID == Fixtures.production.id)
            #expect(main.window?.firstResponder === console.editor)
            #expect(!console.isEdited && console.canRename && console.fileURL == nil)
            main.openConsole(text: "", title: nil, connection: Fixtures.production.id)
            #expect(main.selectedTab?.title == "Query 2")
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
