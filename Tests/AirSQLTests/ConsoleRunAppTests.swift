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
            #expect(console.runMarks.marks.map(\.failed) == [false, false, true])
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
    }
}
