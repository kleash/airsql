import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// The gate against a real server (MariaDB 11.8 and MySQL 8.4): an agent's console write runs only once the person approves it in the
/// SQL preview, and the statements an agent's clicks send on the person's session (the transaction mode, Commit) wait
/// in it too; a declined Commit leaves the transaction open.
extension AppTests.AgentGateUITests {
    @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"), arguments: ["mariadb", "mysql"])
    func agentsChangeNothingOnTheServerWithoutThePerson(flavor: String) async throws {
        let connection = Connection(options: DBLab.options(DBLab.server(flavor), tls: DBLab.required), log: DBLab.log)
        try await connection.connect()
        let database = "lane_l7b_gate"
        let setup = try await connection.toolsSession()
        for sql in ["DROP DATABASE IF EXISTS \(database)", "CREATE DATABASE \(database)", "CREATE TABLE \(database).t (id INT PRIMARY KEY)"] {
            _ = try await setup.query(sql)
        }
        func count() async throws -> String? { try await setup.query("SELECT COUNT(*) FROM \(database).t").first?.rows?.string(0, 0) }
        let (main, harness, service) = try await Self.agents()
        let console = try await Self.console(main, harness, on: Fixtures.local.id)
        ConsoleViewController.openConnection = { $0 == Fixtures.local.id ? connection : nil }
        defer {
            service.close()
            ConsoleViewController.openConnection = { _ in nil }
        }

        #expect(await agentCall(service, "set", ["id": "console.editor", "value": "INSERT INTO \(database).t VALUES (1)"]).error == nil)
        _ = await agentCall(service, "key", ["combo": "cmd+return"])
        _ = await agentCall(service, "wait", ["until": "sheet", "timeout": 10])
        #expect(await agentCall(service, "press", ["id": "preview.run"]).error != nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(try await count() == "0", "nothing ran for the agent")
        #expect(await call(harness, "press", ["id": "preview.run"]).error == nil)
        _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
        #expect(try await count() == "1", "the person's approval ran it")

        // Manual mode from the agent: SET autocommit = 0 waits for the person, who approves it.
        #expect(await agentCall(service, "menu", ["path": "Query > Transaction Mode > Manual"]).error == nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        #expect(Self.preview(main)?.window?.title == "Run this statement for Claude Code?")
        #expect(await call(harness, "press", ["id": "preview.run"]).error == nil)
        _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
        #expect(!console.autocommit)
        // The person writes in the transaction; the agent's Commit waits, and the person declines it.
        console.editor.setText("INSERT INTO \(database).t VALUES (2)")
        #expect(await call(harness, "key", ["combo": "cmd+return"]).error == nil)
        _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
        #expect(console.session?.inTransaction == true)
        #expect(await agentCall(service, "menu", ["path": "Query > Commit"]).error == nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        #expect((Self.preview(main)?.window?.contentView).flatMap { find(NSTextView.self, id: "preview.sql", in: $0) }?.string == "COMMIT;")
        #expect(await call(harness, "press", ["id": "preview.cancel"]).error == nil)
        _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
        #expect(console.session?.inTransaction == true && console.messagesView.messages.last?.level == .error)
        #expect(try await count() == "1", "not committed")
        // The person's own Rollback asks nobody.
        #expect(await call(harness, "menu", ["path": "Query > Rollback"]).error == nil)
        _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
        #expect(main.window?.attachedSheet == nil && console.session?.inTransaction == false)
        _ = try await setup.query("DROP DATABASE \(database)")
        await connection.disconnect()
    }
}
