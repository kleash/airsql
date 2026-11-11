import Foundation
import Testing
@testable import AirSQLCore

/// Phase 3's agent knowledge on `shop` (testenv/mongo/seed/shop.js) through `AirSQL --mcp`: mongo_schema with its
/// references and hash, mongo_explain's plan that runs nothing, to_file, and errors and warnings that teach.
@Suite(.serialized, .enabled(if: MongoLab.enabled, "Mongo lab: AIRSQL_MONGO_LAB=1 ./test.sh --filter Mongo"))
struct AgentMongoKnowledgeLabTests {
    /// Each call through the real bridge to `target`, in `shop`: its structured content, or the error's text.
    static func calls(_ target: AgentTarget, exports: URL, _ calls: [(String, [String: Any])]) async throws -> [Any] {
        let support = try scratch()
        let listener = try AgentListener(directory: URL(fileURLWithPath: support + "/agent")) { tool, arguments, _, _ in
            do { return AgentReply.success(try await target.mongo(tool, arguments, exports: exports)) } catch {
                return AgentReply.failure(error)
            }
        }
        defer { listener.close() }
        let messages = try await mcp([request(1, "initialize", ["protocolVersion": "2025-06-18",
                                                                "clientInfo": ["name": "test", "version": "1"]])]
            + calls.enumerated().map { request($0.offset + 2, "tools/call", ["name": $0.element.0, "arguments":
                ["connection": target.saved.name, "database": "shop"].merging($0.element.1) { $1 }]) }, support: support)
        return calls.indices.map { index -> Any in
            let called = result(messages, index + 2) ?? [:]
            if called["isError"] as? Bool == true { return text(called) }
            return called["structuredContent"] as? [String: Any] ?? [:]
        }
    }

    @Test func mongoSchemaKnowsShopAndItsReferences() async throws {
        let target = try await AgentMongoLabTests.target(.standalone)
        defer { Task { await target.mongo?.close() } }
        var schemaOnly = target
        schemaOnly.saved.agentAccess = .schema
        let folder = URL(fileURLWithPath: try scratch())
        let first = try await Self.calls(target, exports: folder, [("mongo_schema", [:])])[0] as? [String: Any] ?? [:]
        let text = first["text"] as? String ?? ""
        #expect(text.utf8.count <= MongoSchemaSummary.budget && first["capped"] as? Bool == false, "\(first)")
        #expect(text.contains("collection orders (1500 documents") && text.contains("view paid_orders on orders"), "\(text)")
        #expect(text.contains("status_1_createdAt_-1 { status: 1, createdAt: -1 }") && text.contains("email_1 { email: 1 } unique"))
        #expect(text.contains("$jsonSchema required customerId, status, createdAt, items, total"))
        #expect(text.contains("  status string enum \"delivered\" "), "an enum, with read access")
        #expect(text.contains("  createdAt date 2024-"), "a range of dates")
        // 20 of the 1,500 orders name a customer that doesn't exist: the probe's ratio stays over 80%, so it is kept.
        func ratio(_ prefix: String) -> (Int, Int)? {
            guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }),
                  let open = line.lastIndex(of: "(") else { return nil }
            let parts = line[line.index(after: open)...].dropLast().split(separator: "/").compactMap { Int($0) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        for prefix in ["  customerId objectId -> customers._id (", "  productSku string -> products.sku (",
                       "  items.[].sku string -> products.sku ("] {
            let found = try #require(ratio(prefix), "\(prefix) in \(text)")
            #expect(found.1 > 0 && found.1 <= MongoSchema.exampleLimit && found.0 <= found.1
                    && Double(found.0) >= 0.8 * Double(found.1), "\(prefix) \(found)")
        }
        #expect(!text.contains("tier string -> ") && !text.contains("name string -> "), "no reference by a lookalike name")
        let again = try await Self.calls(target, exports: folder, [("mongo_schema", ["if_changed_from": first["hash"] ?? ""])])
        #expect((again[0] as? [String: Any])?["unchanged"] as? Bool == true, "\(again)")

        let bare = try await Self.calls(schemaOnly, exports: folder, [("mongo_schema", [:])])[0] as? [String: Any] ?? [:]
        let lines = (bare["text"] as? String ?? "").split(separator: "\n")
        #expect(lines.contains { $0.hasPrefix("  customerId objectId -> customers._id") }, "references at Schema access")
        #expect(!lines.contains { $0.hasPrefix("  ") && !$0.hasPrefix("  validator") && ($0.contains(" enum ") || $0.contains("..")) },
                "no values, enums or ranges at Schema access: \(lines)")
    }

    @Test func explainsAPlanWithoutRunningItAndRunsItForFigures() async throws {
        let file = URL(fileURLWithPath: TestEnvironment.root).appendingPathComponent("agent-explain-\(UUID().uuidString).log")
        let target = try await AgentMongoLabTests.target(.standalone, log: SQLLog(fileURL: file))
        defer { Task { await target.mongo?.close() } }
        let filter = "{\"status\": \"paid\", \"createdAt\": {\"$gte\": {\"$date\": \"2024-03-01T00:00:00Z\"}}}"
        let replies = try await Self.calls(target, exports: URL(fileURLWithPath: try scratch()), [
            ("mongo_explain", ["collection": "orders", "filter": filter]),
            ("mongo_explain", ["collection": "orders", "filter": filter, "verbosity": "run"]),
            ("mongo_explain", ["collection": "orders", "pipeline": "[{\"$match\": {\"total\": {\"$gt\": 100}}}, "
                               + "{\"$group\": {\"_id\": \"$status\", \"n\": {\"$sum\": 1}}}]", "verbosity": "run"]),
            ("mongo_explain", ["collection": "orders", "pipeline": "[{\"$out\": \"copy\"}]"]),
        ])
        let plan = try #require(replies[0] as? [String: Any], "\(replies[0])")
        #expect(plan["scan"] as? String == "index" && (plan["index"] as? String)?.contains("status_1_createdAt_-1") == true, "\(plan)")
        #expect(plan["docsExamined"] == nil && plan["returned"] == nil && (plan["plan"] as? String)?.contains("IXSCAN") == true)
        let log = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        #expect(log.split(separator: "\n").contains { $0.contains("explain") && $0.contains("queryPlanner") }, "\(log)")
        #expect(!log.split(separator: "\n").contains { $0.contains("find: \"orders\"") && !$0.contains("explain") },
                "the plan ran no find: \(log)")
        let run = try #require(replies[1] as? [String: Any], "\(replies[1])")
        #expect((run["docsExamined"] as? Int ?? 0) > 0 && run["returned"] as? Int != nil && run["ms"] as? Int != nil, "\(run)")
        let scan = try #require(replies[2] as? [String: Any], "\(replies[2])")
        #expect(scan["scan"] as? String == "collection" && (scan["docsExamined"] as? Int) == 1500, "\(scan)")
        #expect((scan["warnings"] as? [String])?.contains { $0.hasPrefix("Reads the whole collection") } == true)
        #expect((replies[3] as? String)?.hasPrefix("Refused: pipeline.0: $out writes") == true, "\(replies[3])")
    }

    @Test func toFileWritesInTheExportFolderOnly() async throws {
        var target = try await AgentMongoLabTests.target(.standalone)
        defer { Task { [target] in await target.mongo?.close() } }
        let folder = URL(fileURLWithPath: try scratch()).appendingPathComponent("Agent Exports")
        let refused = try await Self.calls(target, exports: folder, [("mongo_find", ["collection": "orders", "to_file": true])])
        #expect((refused[0] as? String)?.contains("needs Schema + read + analytics") == true, "\(refused)")
        target.saved.agentAccess = .schemaReadAnalytics
        let replies = try await Self.calls(target, exports: folder, [
            ("mongo_find", ["collection": "orders", "filter": "{\"status\": \"paid\"}", "to_file": true,
                            "path": "/tmp/airsql-elsewhere.jsonl"]),
            ("mongo_aggregate", ["collection": "orders", "pipeline": "[{\"$group\": {\"_id\": \"$status\"}}]", "to_file": true]),
            ("mongo_count", ["collection": "orders", "filter": "{\"status\": \"paid\"}"]),
        ])
        let found = try #require(replies[0] as? [String: Any], "\(replies[0])")
        let path = try #require(found["file"] as? String)
        #expect(path.hasPrefix(folder.path + "/") && !path.dropFirst(folder.path.count + 1).contains("/"), "\(path)")
        #expect(path.hasSuffix(".jsonl") && !FileManager.default.fileExists(atPath: "/tmp/airsql-elsewhere.jsonl"))
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == found["count"] as? Int && found["count"] as? Int == (replies[2] as? [String: Any])?["count"] as? Int)
        #expect(lines.allSatisfy { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) is [String: Any] })
        #expect(lines.first?.contains("\"$numberDecimal\"") == true && lines.first?.contains("\"$date\"") == true, "relaxed")
        let grouped = try #require(replies[1] as? [String: Any], "\(replies[1])")
        #expect(grouped["count"] as? Int == 6 && (grouped["file"] as? String)?.hasPrefix(folder.path) == true)
    }

    @Test func errorsAndWarningsTeach() async throws {
        let target = try await AgentMongoLabTests.target(.standalone)
        defer { Task { await target.mongo?.close() } }
        let replies = try await Self.calls(target, exports: URL(fileURLWithPath: try scratch()), [
            ("mongo_find", ["collection": "orders", "filter": "{\"customerID\": {\"$oid\": \"cc0000000000000000000001\"}}"]),
            ("mongo_find", ["collection": "orders", "filter": "{\"createdAt\": {\"$gte\": \"2024-03-01\"}}"]),
            ("mongo_aggregate", ["collection": "orders", "pipeline": "[{\"$group\": {\"_id\": \"$status\", \"n\": {\"$sume\": 1}}}]"]),
            ("mongo_aggregate", ["collection": "orders", "pipeline": "[{\"$match\": {}}, {\"$gruop\": {\"_id\": 1}}]"]),
            ("mongo_find", ["collection": "orders", "filter": "{\"items.sku\": \"SKU-007\"}", "limit": 1]),
        ])
        let misspelt = try #require(replies[0] as? [String: Any], "\(replies[0])")
        let warnings = misspelt["warnings"] as? [String] ?? []
        #expect(misspelt["count"] as? Int == 0 && warnings.contains {
            $0.hasPrefix("customerID is not in the sample of 200") && $0.hasSuffix("nearest: customerId")
        }, "\(misspelt)")
        #expect(warnings.last?.hasPrefix("Nothing matched") == true && !warnings.joined().contains("doesn't exist"))
        let dated = try #require(replies[1] as? [String: Any], "\(replies[1])")
        #expect(dated["count"] as? Int == 0 && (dated["warnings"] as? [String])?.contains {
            $0.hasPrefix("createdAt is date in the sample") && $0.contains("$date")
        } == true, "\(dated)")
        let error = try JSONSerialization.jsonObject(with: Data((replies[2] as? String ?? "").utf8)) as? [String: Any] ?? [:]
        #expect(error["code"] as? Int != nil && error["codeName"] as? String != nil && error["stage"] as? Int == 0
                && (error["hint"] as? String)?.hasPrefix("Did you mean $sum?") == true, "\(replies[2])")
        #expect((replies[3] as? String)?.hasPrefix("Refused: pipeline.1: $gruop isn't a stage agents may use. Did you mean $group?")
                == true, "\(replies[3])")
        let nested = try #require(replies[4] as? [String: Any], "\(replies[4])")
        #expect(nested["count"] as? Int == 1 && nested["warnings"] == nil, "an array's path as a query names it: \(nested)")
    }

    /// On the replica set too: the references and an explain that runs, neither inside the aborted transaction.
    @Test func schemaAndExplainOnTheReplicaSet() async throws {
        let target = try await AgentMongoLabTests.target(.replicaSet)
        defer { Task { await target.mongo?.close() } }
        let schema = try await target.mongo("mongo_schema", ["database": "shop"])
        #expect((schema["text"] as? String)?.contains("customerId objectId -> customers._id (") == true, "\(schema)")
        let run = try await target.mongo("mongo_explain", ["database": "shop", "collection": "customers",
                                                           "filter": "{\"country\": \"DE\"}", "verbosity": "run"])
        #expect(run["scan"] as? String == "index" && run["returned"] as? Int == 45, "\(run)")
    }
}
