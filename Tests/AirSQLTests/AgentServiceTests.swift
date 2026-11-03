import AppKit
import CMariaDB
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// A console tab as the console lane's will be, for read_console.
@MainActor
private final class FakeConsole: NSViewController, AgentConsole {
    var agentText = "SELECT name FROM customers"
    var agentDatabase: String? = "shop"
    var agentLastRun: AgentConsoleRun?
    override func loadView() { view = NSView() }
}

@MainActor
private final class FakeConsoles: AgentConsoles {
    var opened: [(sql: String, title: String, connection: UUID?)] = []
    weak var main: MainWindowController?
    func open(sql: String, title: String, connection: UUID?) -> Tab? {
        opened.append((sql, title, connection))
        return main?.open(FakeConsole(), title: title, connection: connection)
    }
}

/// The agent service in the app: what agents see, what they're refused, the socket, the activity list.
extension AppTests {
    static func agentConnections() -> [SavedConnection] {
        var production = SavedConnection(name: "Production", host: "db.invalid", user: "app", colour: .production)
        production.agentAccess = .off
        var staging = SavedConnection(name: "Staging", host: "db.invalid", user: "app", colour: .staging)
        staging.agentAccess = .schema
        var reports = SavedConnection(name: "Reports", host: "db.invalid", user: "app")
        reports.agentAccess = .schemaRead
        return [production, staging, reports]
    }

    static func structured(_ reply: [String: Any]) -> [String: Any] { reply["structuredContent"] as? [String: Any] ?? [:] }

    @Test func agentsSeeOnlyWhatEachConnectionAllows() async throws {
        let model = testModel(Self.agentConnections())
        let service = AgentService(model: model, main: nil, directory: URL(fileURLWithPath: try scratch() + "/agent"))
        #expect(text(await service.handle("context", [:], client: "test 1")).contains("agents are off"))
        model.data.settings.agentsAllowed = true
        defer { service.close() }
        let context = Self.structured(await service.handle("context", [:], client: "test 1"))
        let names = (context["connections"] as? [[String: Any]])?.compactMap { $0["connection"] as? String }
        #expect(names == ["Reports", "Staging"] && context["hiddenConnections"] as? Int == 1)
        #expect(!AgentJSON.text(context).contains("db.invalid"), "no host names")

        let hidden = await service.handle("get_schema", ["connection": "Production"], client: "test 1")
        #expect(hidden["isError"] as? Bool == true && text(hidden).contains("No connection “Production” is open to agents"))
        let schemaOnly = await service.handle("run_queries", ["connection": "Staging", "queries": ["SELECT 1"]], client: "test 1")
        #expect(text(schemaOnly).contains("needs Schema + read"))
        let notConnected = await service.handle("get_schema", ["connection": "Reports"], client: "test 1")
        #expect(text(notConnected).contains("isn't connected"))
        let byID = await service.handle("describe", ["connection": model.data.connections[2].id.uuidString, "objects": ["t"]],
                                        client: "test 1")
        #expect(text(byID).contains("isn't connected"))

        #expect(service.events.count == 5 && service.events.filter(\.failed).count == 4)
        #expect(service.events.first?.summary == "context" && service.events[2].summary.hasPrefix("run_queries · SELECT 1"))
        #expect(model.agentStatus?.hasPrefix("test 1 · describe") == true)
    }

    @Test func theSocketFollowsTheSetting() async throws {
        let model = testModel(Self.agentConnections())
        let folder = try scratch() + "/agent"
        let service = AgentService(model: model, main: nil, directory: URL(fileURLWithPath: folder))
        model.data.settings.agentsAllowed = true
        #expect(await eventually(timeout: 5) { service.isListening })
        #expect(model.agentStatus == "Agents on")
        let token = try String(contentsOfFile: folder + "/token", encoding: .utf8)
        let reply = await Task.detached {
            AgentSocket.exchange(["tool": "context", "token": token, "client": "claude-code 2"], socket: folder + "/sock")
        }.value
        #expect((Self.structured(reply ?? [:])["connections"] as? [Any])?.count == 2)
        #expect(model.agentStatus?.hasPrefix("claude-code 2 · context") == true)
        model.data.settings.agentsAllowed = false
        #expect(await eventually(timeout: 5) { !service.isListening })
        #expect(!FileManager.default.fileExists(atPath: folder + "/sock") && model.agentStatus == "Agents off")
    }

    @Test func agentsReachTheAppThroughAirSQLMCP() async throws {
        let model = testModel(Self.agentConnections())
        let support = try scratch()
        let service = AgentService(model: model, main: nil, directory: URL(fileURLWithPath: support + "/agent"))
        model.data.settings.agentsAllowed = true
        #expect(await eventually(timeout: 5) { service.isListening })
        let messages = try await mcp([
            request(1, "initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-code", "version": "2"]]),
            request(2, "tools/call", ["name": "context", "arguments": [:]]),
            request(3, "tools/call", ["name": "get_schema", "arguments": ["connection": "Production"]]),
            request(4, "tools/call", ["name": "run_queries", "arguments": ["connection": "Staging", "queries": [["sql": "SELECT 1"]]]]),
            request(5, "resources/list"),
        ], support: support)
        let context = try #require(result(messages, 2))
        let structured = try #require(context["structuredContent"] as? [String: Any])
        #expect((structured["connections"] as? [[String: Any]])?.count == 2 && context["isError"] as? Bool == false)
        #expect(text(context) == AgentJSON.text(structured), "the same JSON as text")
        #expect(result(messages, 3)?["isError"] as? Bool == true && result(messages, 3)?["structuredContent"] == nil)
        #expect(text(try #require(result(messages, 4))).contains("needs Schema + read"))
        #expect((result(messages, 5)?["resources"] as? [Any])?.isEmpty == true, "nothing is connected")
        #expect(service.events.map(\.client).allSatisfy { $0 == "claude-code 2" })
        model.data.settings.agentsAllowed = false
        #expect(await eventually(timeout: 5) { !service.isListening })
    }

    @Test func consoleTabsTakeProposalsAndShowWhatRan() async throws {
        let model = testModel(Self.agentConnections())
        let (main, _) = appWindow(model)
        let service = AgentService(model: model, main: main, directory: URL(fileURLWithPath: try scratch() + "/agent"))
        model.data.settings.agentsAllowed = true
        defer { service.close() }
        let refused = await service.handle("open_in_console", ["sql": "UPDATE t SET a = 1"], client: "test")
        #expect(text(refused).contains("no console yet"))

        let consoles = FakeConsoles()
        consoles.main = main
        service.consoles = consoles
        let staging = model.data.connections[1], reports = model.data.connections[2]
        let opened = Self.structured(await service.handle("open_in_console", ["sql": "UPDATE t SET a = 1", "title": "Fix",
                                                                             "connection": "Staging"], client: "test"))
        #expect(consoles.opened.first?.sql == "UPDATE t SET a = 1" && consoles.opened.first?.connection == staging.id)
        #expect(opened["title"] as? String == "Fix" && opened["connection"] as? String == "Staging")
        #expect(text(await service.handle("open_in_console", ["sql": "SELECT 1", "connection": "Production"],
                                          client: "test")).contains("No connection"))

        let rows = ResultStore(columns: [ResultStore.Column(name: "name", type: MYSQL_TYPE_VAR_STRING)])
        _ = rows.append([Array("Ada".utf8)])
        let console = try #require(main.selectedTab?.content as? FakeConsole)
        console.agentLastRun = AgentConsoleRun(sql: "SELECT name FROM customers", finished: Date(), rows: rows)
        let schemaOnly = Self.structured(await service.handle("read_console", [:], client: "test"))
        let run = try #require(schemaOnly["run"] as? [String: Any])
        #expect(run["state"] as? String == "done" && run["rows"] == nil && (run["note"] as? String)?.contains("Schema") == true)
        #expect(schemaOnly["text"] as? String == "SELECT name FROM customers")

        let readable = main.open(FakeConsole(), title: "Report", connection: reports.id)
        (readable.content as? FakeConsole)?.agentLastRun = AgentConsoleRun(sql: "SELECT name FROM customers", finished: Date(),
                                                                          error: nil, rows: rows)
        let read = Self.structured(await service.handle("read_console", ["tab": "Report"], client: "test"))
        #expect(((read["run"] as? [String: Any])?["rows"] as? [[Any]])?.first?.first as? String == "Ada")
        let hidden = main.open(FakeConsole(), title: "Secret", connection: model.data.connections[0].id)
        #expect(text(await service.handle("read_console", ["tab": hidden.id.uuidString], client: "test")).contains("No console tab"))
        let context = Self.structured(await service.handle("context", [:], client: "test"))
        #expect((context["consoleTabs"] as? [[String: Any]])?.compactMap { $0["title"] as? String } == ["Fix", "Report"])
        for tab in main.tabs { main.close(tab) }
    }
}
