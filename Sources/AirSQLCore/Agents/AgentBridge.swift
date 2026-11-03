// Ported from AirSCP 1.4.0 Sources/AirSCPCore/AgentBridge.swift: `--mcp` over stdio, the guide and the client's name.
// AirSQL adds resources, progress notifications and structured results (MCP 2025-06-18).
import Foundation

/// `AirSQL --mcp`: MCP over stdio (newline-delimited JSON-RPC 2.0). Tool calls and resource reads go to the running
/// app's agent socket (`AgentSocket`), whose progress lines become `notifications/progress`. The tool list and the
/// guide live here, so an MCP client sees them even when AirSQL starts after it.
public enum AgentBridge {
    public static let offMessage = "AirSQL isn't running, or agents are off (AirSQL ▸ Settings ▸ Agents ▸ Allow AI agents to "
        + "use AirSQL)."
    static let busyMessage = "AirSQL didn't answer: it may be busy or quitting. Try again."

    /// The MCP versions this server speaks: the client's own when it is one of them, else 2025-06-18.
    static let protocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

    /// Who uses AirSQL, as the activity list names it: the MCP client's name and version from `initialize`.
    private static var client = "an MCP client"
    private static let clientLock = NSLock()

    // MARK: The guide

    /// Resources/AgentGuide.md: in the app bundle, else (a development build) next to the sources.
    public static let guideText: String = {
        let bundled = Bundle.main.url(forResource: "AgentGuide", withExtension: "md")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/AgentGuide.md")
        return [bundled, source].compactMap { $0 }.lazy.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.first
            ?? "# AirSQL agent guide\n\n## overview\nThe guide is missing from this AirSQL build. Start with context.\n"
    }()

    /// The guide's sections by topic ("" is the introduction before the first one), in the file's order.
    static var guideSections: [(topic: String, text: String)] {
        var sections: [(topic: String, text: String)] = [("", "")]
        for line in guideText.components(separatedBy: "\n") where !line.hasPrefix("# ") {
            if line.hasPrefix("## ") {
                sections.append((String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased(), ""))
            } else {
                sections[sections.count - 1].text += line + "\n"
            }
        }
        return sections.map { ($0.topic, $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static var guideTopics: [String] { guideSections.map(\.topic).filter { !$0.isEmpty } }

    /// MCP's `instructions`: the introduction and the overview.
    static var instructions: String {
        let sections = guideSections
        return [sections.first { $0.topic == "" }?.text, sections.first { $0.topic == "overview" }?.text]
            .compactMap { $0 }.joined(separator: "\n\n")
    }

    /// The guide tool: a topic's section, or the overview with the list of topics.
    static func guide(_ topic: String?) -> [String: Any] {
        guard let topic = topic?.lowercased(), !topic.isEmpty, topic != "overview" else {
            return text(instructions + "\n\nTopics (guide topic=…): " + guideTopics.joined(separator: ", "))
        }
        guard let section = guideSections.first(where: { $0.topic == topic }) else {
            return failure("No topic “\(topic)”. Topics: " + guideTopics.joined(separator: ", "))
        }
        return text("## \(topic)\n" + section.text)
    }

    static func text(_ text: String) -> [String: Any] { ["content": [["type": "text", "text": text]], "isError": false] }

    /// An MCP tool result saying `text` went wrong.
    public static func failure(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": true]
    }

    // MARK: The app

    /// One request to the running app: its reply, or nil with why it couldn't be reached.
    static func ask(_ tool: String, _ arguments: [String: Any],
                    progress: ([String: Any]) -> Void = { _ in }) -> (reply: [String: Any]?, problem: String?) {
        let path = AgentSocket.directory.path
        if let problem = AgentSocket.socketPathProblem(path + "/sock") { return (nil, problem) }
        guard let token = try? String(contentsOfFile: path + "/token", encoding: .utf8) else { return (nil, offMessage) }
        let request: [String: Any] = ["tool": tool, "arguments": arguments, "client": clientLock.locked { client },
                                      "token": token.trimmingCharacters(in: .whitespacesAndNewlines)]
        guard let reply = AgentSocket.exchange(request, socket: path + "/sock", progress: progress) else {
            return (nil, AgentSocket.answers(path + "/sock") ? busyMessage : offMessage)
        }
        return (reply, nil)
    }

    /// One tool call, as an MCP tool result.
    static func call(_ tool: String, _ arguments: [String: Any], progress: ([String: Any]) -> Void = { _ in }) -> [String: Any] {
        if tool == "guide" { return guide(arguments["topic"] as? String) }
        let (reply, problem) = ask(tool, arguments, progress: progress)
        guard let reply, reply["content"] != nil else { return failure(problem ?? busyMessage) }
        return reply
    }

    // MARK: MCP

    /// `AirSQL --mcp`: answers until stdin ends. Requests run in parallel (a long query doesn't hold up a ping).
    public static func runMCP(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) -> Int32 {
        let lock = NSLock(), group = DispatchGroup()
        let send: ([String: Any]) -> Void = { message in
            var data = AgentJSON.data(message)
            data.append(0x0A)
            lock.locked { output.write(data) }
        }
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) else { continue }
                guard let json = try? JSONSerialization.jsonObject(with: line) else {
                    send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                    continue
                }
                guard let message = json as? [String: Any] else {  // a batch: MCP has none since 2025-06-18
                    send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid Request"]])
                    continue
                }
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }
                    if let reply = answer(message, send: send) { send(reply) }
                }
            }
        }
        // stdin has ended: calls that end soon still answer; a longer one isn't waited for.
        _ = group.wait(timeout: .now() + 5)
        return 0
    }

    /// The JSON-RPC response to one message (nil for a notification). `send` carries progress notifications.
    static func answer(_ message: [String: Any], send: @escaping ([String: Any]) -> Void = { _ in }) -> [String: Any]? {
        guard let id = message["id"], !(id is NSNull) else { return nil }  // notifications/initialized and the like
        let params = message["params"] as? [String: Any] ?? [:]
        func result(_ value: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
        func error(_ code: Int, _ text: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]
        }
        switch message["method"] as? String {
        case "initialize":
            if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String, !name.isEmpty {
                let named = [name, info["version"] as? String].compactMap { $0 }.joined(separator: " ")
                clientLock.locked { client = String(named.prefix(80)) }
            }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            let asked = params["protocolVersion"] as? String ?? ""
            return result(["protocolVersion": protocolVersions.contains(asked) ? asked : "2025-06-18",
                           "capabilities": ["tools": [String: Any](), "resources": [String: Any]()],
                           "serverInfo": ["name": "airsql", "title": "AirSQL", "version": version],
                           "instructions": instructions])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": AgentTools.list])
        case "tools/call":
            guard let name = params["name"] as? String, AgentTools.list.contains(where: { $0["name"] as? String == name }) else {
                return error(-32602, (params["name"] as? String).map { "Unknown tool: \($0)" } ?? "tools/call needs a name")
            }
            let token = (params["_meta"] as? [String: Any])?["progressToken"]
            return result(call(name, params["arguments"] as? [String: Any] ?? [:]) { report in
                guard let token, !(token is NSNull) else { return }
                send(["jsonrpc": "2.0", "method": "notifications/progress",
                      "params": report.merging(["progressToken": token]) { $1 }])
            })
        case "resources/list":
            // Each connection agents may read has its schema as a resource; none while AirSQL isn't running.
            let reply = ask("resources/list", [:]).reply
            return result(["resources": reply?["resources"] as? [[String: Any]] ?? []])
        case "resources/templates/list":
            return result(["resourceTemplates": [AgentTools.schemaTemplate]])
        case "resources/read":
            guard let uri = params["uri"] as? String else { return error(-32602, "resources/read needs a uri") }
            let (reply, problem) = ask("resources/read", ["uri": uri])
            if let contents = reply?["contents"] as? [[String: Any]] { return result(["contents": contents]) }
            return error(-32002, reply?["error"] as? String ?? problem ?? busyMessage)
        default:
            return error(-32601, "Method not found")
        }
    }
}
