import Darwin
import Foundation
import Testing
@testable import AirSQLCore

// `AirSQL --mcp` speaks MCP (newline-delimited JSON-RPC 2.0) on stdio and passes tool calls and resource reads to the
// app's agent socket. These run the real binary (the debug build next to the tests) against a real `AgentListener`.

private final class Marker {}

/// The debug build of AirSQL, with the libmariadb and libmongoc2 the tests use (the app finds them in its bundle).
private var airsqlBinary: String {
    Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("AirSQL").path
}
private let vendorLibrary = ["vendor/out/universal/lib", "vendor/mongoc/universal/lib"].map {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent($0).path
}.joined(separator: ":")

/// Runs `AirSQL --mcp` with these messages on stdin (which then ends), its settings folder `support`; the messages it
/// wrote, in order.
func mcp(_ messages: [[String: Any]], support: String) async throws -> [[String: Any]] {
    let base = support + "/mcp-" + UUID().uuidString.prefix(8)
    let input = messages.map { AgentJSON.text($0) }.joined(separator: "\n") + "\n"
    FileManager.default.createFile(atPath: base + ".out", contents: nil)
    func written() -> [[String: Any]] {
        let output = (try? String(contentsOfFile: base + ".out", encoding: .utf8)) ?? ""
        return output.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    let stdin = Pipe()
    stdin.fileHandleForWriting.write(Data(input.utf8))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: airsqlBinary)
    process.arguments = ["--mcp"]
    process.environment = TestEnvironment.environment.merging(["AIRSQL_SUPPORT_DIR": support,
                                                              "DYLD_LIBRARY_PATH": vendorLibrary]) { $1 }
    process.standardInput = stdin
    process.standardOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: base + ".out"))
    process.standardError = FileHandle.nullDevice
    // Stdin stays open until every request has its reply, as a client's does: once it ends the bridge gives what is
    // running 5 s, too little when all the suites start at once.
    let requests = messages.filter { $0["id"] != nil }.count
    Task {
        _ = await eventually(timeout: 60) { written().filter { $0["id"] != nil }.count >= requests }
        try? stdin.fileHandleForWriting.close()
    }
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do { try process.run() } catch {
            process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
    }
    #expect(status == 0)
    let output = try String(contentsOfFile: base + ".out", encoding: .utf8)
    return try output.split(separator: "\n").map {
        try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
}

func request(_ id: Int, _ method: String, _ params: [String: Any] = [:]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
}

func reply(_ messages: [[String: Any]], _ id: Int) -> [String: Any]? {
    messages.first { $0["id"] as? Int == id }
}

func result(_ messages: [[String: Any]], _ id: Int) -> [String: Any]? {
    reply(messages, id)?["result"] as? [String: Any]
}

@Suite struct AgentBridgeTests {
    @Test func initializeAndListTheToolsWithoutTheApp() async throws {
        let support = try scratch()
        let messages = try await mcp([
            request(1, "initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test", "version": "1"],
                                      "capabilities": [:]]),
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            request(2, "tools/list"), request(3, "resources/templates/list"), request(4, "resources/list"),
            request(5, "ping"), request(6, "nope"),
        ], support: support)
        let initialized = try #require(result(messages, 1))
        #expect(initialized["protocolVersion"] as? String == "2025-06-18")
        #expect((initialized["serverInfo"] as? [String: Any])?["name"] as? String == "airsql")
        let capabilities = try #require(initialized["capabilities"] as? [String: Any])
        #expect(capabilities["tools"] != nil && capabilities["resources"] != nil)
        #expect((initialized["instructions"] as? String)?.contains("context") == true)
        let tools = try #require(result(messages, 2)?["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        let ui = ["snapshot", "screenshot", "menu", "press", "set", "select", "key", "type", "click", "double_click",
                  "right_click", "wait"]
        #expect(names == ["context", "get_schema", "describe", "search_columns", "run_queries", "profile", "explain"]
                + AgentTarget.mongoTools + ["mongo_open", "open_in_console", "read_console", "guide"] + ui)
        for tool in tools {
            let name = tool["name"] as? String ?? ""
            let annotations = try #require(tool["annotations"] as? [String: Any])
            #expect(annotations["destructiveHint"] as? Bool == false)
            let reads = !["mongo_open", "open_in_console", "menu", "press", "set", "select", "key", "type", "click", "double_click",
                          "right_click"].contains(name)
            #expect(annotations["readOnlyHint"] as? Bool == reads, "\(name)")
            // UI tools answer with JSON as text (screenshot: an image), as AirSCP's do.
            guard name != "guide", !ui.contains(name) else { continue }
            let output = try #require(tool["outputSchema"] as? [String: Any], "\(name) has an output schema")
            #expect(output["type"] as? String == "object")
        }
        let templates = try #require(result(messages, 3)?["resourceTemplates"] as? [[String: Any]])
        #expect(templates.first?["uriTemplate"] as? String == "airsql://{connection}/schema")
        #expect((result(messages, 4)?["resources"] as? [Any])?.isEmpty == true)
        #expect(result(messages, 5)?.isEmpty == true)
        #expect((reply(messages, 6)?["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(messages.count == 6, "the notification has no reply")
    }

    @Test func callsSayWhenAirSQLIsOffAndTheGuideStillAnswers() async throws {
        let support = try scratch()
        let messages = try await mcp([
            request(1, "tools/call", ["name": "context", "arguments": [:]]),
            request(2, "tools/call", ["name": "guide", "arguments": [:]]),
            request(3, "tools/call", ["name": "guide", "arguments": ["topic": "no such topic"]]),
            request(4, "tools/call", ["name": "drop_everything", "arguments": [:]]),
            request(5, "resources/read", ["uri": "airsql://shop/schema"]),
        ], support: support)
        let off = try #require(result(messages, 1))
        #expect(off["isError"] as? Bool == true)
        #expect(text(off).contains("isn't running, or agents are off"))
        #expect(text(try #require(result(messages, 2))).contains("Topics"))
        #expect(result(messages, 3)?["isError"] as? Bool == true)
        #expect((reply(messages, 4)?["error"] as? [String: Any])?["code"] as? Int == -32602)
        #expect((reply(messages, 5)?["error"] as? [String: Any])?["code"] as? Int == -32002)
    }

    @Test func callsReachTheAppWithTheirProgress() async throws {
        let support = try scratch()
        let seen = Recorder<String>()
        let listener = try AgentListener(directory: URL(fileURLWithPath: support + "/agent")) { tool, arguments, client, progress in
            seen.append("\(tool) \(client) \(AgentJSON.text(arguments))")
            if tool == "resources/list" { return ["resources": [["uri": "airsql://shop/schema", "name": "shop"]]] }
            if tool == "resources/read" { return ["contents": [["uri": arguments["uri"] ?? "", "text": "t(a int)"]]] }
            progress(1, 2, "first")
            progress(2, 2, nil)
            return ["content": [["type": "text", "text": "{}"]], "structuredContent": ["ok": true], "isError": false]
        }
        defer { listener.close() }
        let attributes = try FileManager.default.attributesOfItem(atPath: support + "/agent")
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: support + "/agent/token")[.posixPermissions] as? Int) == 0o600)
        let messages = try await mcp([
            request(1, "initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test", "version": "1"]]),
            request(2, "tools/call", ["name": "context", "arguments": ["x": 1], "_meta": ["progressToken": "p"]]),
            request(3, "resources/list"), request(4, "resources/read", ["uri": "airsql://shop/schema"]),
        ], support: support)
        let called = try #require(result(messages, 2))
        #expect((called["structuredContent"] as? [String: Any])?["ok"] as? Bool == true)
        let progress = messages.filter { $0["method"] as? String == "notifications/progress" }
            .compactMap { $0["params"] as? [String: Any] }
        #expect(progress.map { $0["progress"] as? Double } == [1, 2])
        #expect(progress.allSatisfy { $0["progressToken"] as? String == "p" && $0["total"] as? Double == 2 })
        #expect(progress.first?["message"] as? String == "first")
        let resources = try #require(result(messages, 3)?["resources"] as? [[String: Any]])
        #expect(resources.first?["uri"] as? String == "airsql://shop/schema")
        #expect((result(messages, 4)?["contents"] as? [[String: Any]])?.first?["text"] as? String == "t(a int)")
        #expect(seen.all.contains("context test 1 {\"x\":1}"))
    }

    @Test func theSocketAnswersOnlyWithItsToken() async throws {
        let support = try scratch()
        let listener = try AgentListener(directory: URL(fileURLWithPath: support + "/agent")) { _, _, _, _ in
            ["content": [], "isError": false]
        }
        defer { listener.close() }
        #expect(throws: AirSQLError.self) { try AgentListener(directory: URL(fileURLWithPath: support + "/agent")) { _, _, _, _ in [:] } }
        let sock = support + "/agent/sock"
        #expect(AgentSocket.exchange(["tool": "context", "token": "wrong"], socket: sock) == nil)
        let token = try String(contentsOfFile: support + "/agent/token", encoding: .utf8)
        #expect(AgentSocket.exchange(["tool": "context", "token": token], socket: sock)?["isError"] as? Bool == false)
        listener.close()
        #expect(!FileManager.default.fileExists(atPath: sock) && !FileManager.default.fileExists(atPath: support + "/agent/token"))
    }
}

/// A tool result's text.
func text(_ result: [String: Any]) -> String {
    ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
}
