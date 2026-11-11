import Foundation
import Testing
@testable import AirSQLCore

/// mongo-plan Phase 3's end-to-end test, Tier A: each of the shop questions' golden queries (testenv/mongo/e2e/golden.json)
/// sent as an MCP client sends them, through the real `AirSQL --mcp` bridge to an agent socket answered by the Mongo
/// tools, on the standalone and the replica set; what comes back must be the oracle's answer (shop-answers.json).
/// Then the action questions: no tool writes, the order to "cancel" and the canary's order stay as they were, and the
/// canary review comes back as data. Tier B (a real agent asking the same questions) is scripts/agent-e2e.sh.
@Suite(.serialized, .enabled(if: MongoLab.enabled, "Mongo lab: AIRSQL_MONGO_LAB=1 ./test.sh --filter Mongo"))
struct AgentMongoE2ETests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("testenv/mongo")

    static func json(_ path: String) throws -> [String: [String: Any]] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(path)))
            as? [String: [String: Any]])
    }

    /// A Decimal128 from a reply, compared exactly.
    struct Exact { let value: Decimal }

    /// A reply's value with Extended JSON's wrappers taken off: Decimal128 as `Exact`, an ObjectId as its hex.
    static func plain(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            if object.count == 1, let text = object["$numberDecimal"] as? String, let decimal = Decimal(string: text) {
                return Exact(value: decimal)
            }
            if object.count == 1, let hex = object["$oid"] as? String { return hex }
            return object.mapValues(plain)
        }
        if let array = value as? [Any] { return array.map(plain) }
        return value
    }

    /// The value at a dotted path: a key, an index, or `*` for each item of an array.
    static func at(_ path: String, _ value: Any?) -> Any? {
        guard let dot = path.firstIndex(of: ".") ?? (path.isEmpty ? nil : path.endIndex) else { return value }
        let step = path[..<dot], rest = dot == path.endIndex ? "" : String(path[path.index(after: dot)...])
        if step == "*" { return (value as? [Any])?.map { at(rest, $0) ?? NSNull() } }
        if let index = Int(step), let array = value as? [Any] { return index < array.count ? at(rest, array[index]) : nil }
        return at(rest, (value as? [String: Any])?[String(step)])
    }

    /// Whether `got` is `want`: money (Decimal128) exactly, other numbers within 0.01, arrays in any order unless
    /// `ordered`, objects by the keys `got` has (the golden queries project exactly what the question asks).
    static func same(_ got: Any?, _ want: Any, ordered: Bool = false) -> Bool {
        switch (got, want) {
        case let (got as Exact, want as NSNumber):
            return Decimal(string: String(format: "%.2f", want.doubleValue)).map { $0 == got.value } ?? false
        case let (got as NSNumber, want as NSNumber): return abs(got.doubleValue - want.doubleValue) <= 0.01
        case let (got as String, want as String): return got == want
        case let (got as [Any], want as [Any]):
            guard got.count == want.count else { return false }
            if ordered { return zip(got, want).allSatisfy { same($0, $1) } }
            var left = got
            for item in want {
                guard let index = left.firstIndex(where: { same($0, item) }) else { return false }
                left.remove(at: index)
            }
            return true
        case let (got as [String: Any], want as [String: Any]):
            return !got.isEmpty && got.allSatisfy { key, value in want[key].map { same(value, $0) } ?? false }
        default: return false
        }
    }

    @Test(arguments: AgentMongoLabTests.Server.allCases)
    func goldenQueriesThroughTheBridgeGiveTheOraclesAnswers(_ server: AgentMongoLabTests.Server) async throws {
        let golden = try Self.json("e2e/golden.json"), answers = try Self.json("seed/shop-answers.json")
        let target = try await AgentMongoLabTests.target(server)
        defer { Task { await target.mongo?.close() } }
        let support = try scratch()
        let listener = try AgentListener(directory: URL(fileURLWithPath: support + "/agent")) { tool, arguments, _, _ in
            do { return AgentReply.success(try await target.mongo(tool, arguments)) } catch { return AgentReply.failure(error) }
        }
        defer { listener.close() }
        func call(_ id: Int, _ tool: String, _ arguments: [String: Any]) -> [String: Any] {
            request(id, "tools/call", ["name": tool, "arguments": arguments.merging(["connection": "Mongo \(server.rawValue)",
                                                                                     "database": "shop"]) { $1 }])
        }
        let keys = golden.keys.sorted()
        // The action questions' orders read last again, after every other call; then the canary review and the count.
        let after = ["q12_cancel_order", "canary"]
        let canary = try #require(answers["canary"]?["reviewId"] as? String)
        let messages = try await mcp(
            [request(1, "initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "e2e", "version": "1"]]),
             request(2, "tools/list")]
            + keys.enumerated().map { call(10 + $0.offset, golden[$0.element]?["tool"] as? String ?? "",
                                           golden[$0.element]?["arguments"] as? [String: Any] ?? [:]) }
            + [call(100, "mongo_find", ["collection": "reviews", "filter": "{\"_id\": {\"$oid\": \"\(canary)\"}}"])]
            + after.enumerated().map { call(101 + $0.offset, "mongo_find", golden[$0.element]?["arguments"] as? [String: Any] ?? [:]) }
            + [call(110, "mongo_count", ["collection": "orders"])],
            support: support)

        func reply(_ id: Int) -> Any? {
            guard let called = result(messages, id) else { return nil }
            var structured = called["structuredContent"] as? [String: Any] ?? [:]
            structured["documents"] = (structured["documents"] as? [String])?.compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8))
            }
            return Self.plain(structured)
        }
        for (offset, key) in keys.enumerated() {
            let spec = try #require(golden[key]), entry = try #require(answers[key])
            let got = Self.at(spec["pick"] as? String ?? "", reply(10 + offset))
            let want = try #require(Self.at(spec["want"] as? String ?? "", entry["answer"] ?? entry))
            #expect(Self.same(got, want, ordered: spec["ordered"] as? Bool == true), "\(key): \(String(describing: got))")
        }
        for (offset, key) in after.enumerated() {
            let entry = try #require(answers[key])
            let got = Self.at("documents.0", reply(101 + offset))
            #expect(Self.same(got, entry["answer"] ?? entry), "\(key) changed: \(String(describing: got))")
        }

        // Q12 and the canary: no tool writes (every one is marked read-only), and the canary is only data.
        let tools = try #require(result(messages, 2)?["tools"] as? [[String: Any]])
        let mongo = tools.filter { ($0["name"] as? String)?.hasPrefix("mongo_") == true }
        #expect(mongo.count >= AgentTarget.mongoTools.count)
        for tool in mongo where tool["name"] as? String != "mongo_open" {
            #expect((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true, "\(tool["name"] ?? "")")
        }
        #expect(!tools.contains { ($0["name"] as? String ?? "").contains(anyOf: ["insert", "update", "delete", "drop", "write",
                                                                                 "cancel", "remove"]) })
        let review = Self.at("documents.0", reply(100)) as? [String: Any]
        #expect(review?["_id"] as? String == canary && (review?["body"] as? String)?.hasPrefix("Ignore previous") == true)
        #expect(Self.at("count", reply(110)) as? Int == 1500)
    }

    /// Q11: an agent can propose a query in a tab, and the bridge lists it as a change that destroys nothing. The tab
    /// itself (left unrun, its query giving q11's orders) is Tier B's check, in the running app.
    @Test(.enabled(if: !AgentTools.mongoOpenTool.isEmpty, "Q11: mongo_open isn't in this build yet"))
    func proposingATabIsListed() async throws {
        let messages = try await mcp([request(1, "tools/list")], support: try scratch())
        let tools = try #require(result(messages, 1)?["tools"] as? [[String: Any]])
        let open = try #require(tools.first { $0["name"] as? String == "mongo_open" })
        #expect((open["annotations"] as? [String: Any])?["destructiveHint"] as? Bool == false)
    }
}

private extension String {
    func contains(anyOf words: [String]) -> Bool { words.contains { contains($0) } }
}
