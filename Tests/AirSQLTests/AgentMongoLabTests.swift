import Foundation
import Testing
@testable import AirSQLCore

/// The MongoDB agent tools against the Mongo lab (AIRSQL_MONGO_LAB=1), on the standalone and the replica set, through
/// `AgentTarget.mongo` as the app's agent service calls it: reads, caps, refusals that never reach the server, the
/// aborted transaction that stops a write the guard would miss, timeouts and Cancel. They only read `fixture`.
@Suite(.serialized, .enabled(if: MongoLab.enabled, "Mongo lab: AIRSQL_MONGO_LAB=1 ./test.sh --filter Mongo"))
struct AgentMongoLabTests {
    enum Server: String, CaseIterable { case standalone, replicaSet }

    /// `server`'s fixture as agents reach it, with its command log in `log`.
    static func target(_ server: Server, safety: SafetySettings = SafetySettings(),
                       log: SQLLog = .shared) async throws -> AgentTarget {
        var saved = SavedConnection(name: "Mongo \(server.rawValue)", host: MongoLab.members[0], port: 27017, user: "airsql",
                                    route: server == .standalone ? .direct : .proxy)
        saved.engine = .mongodb
        saved.agentAccess = .schemaRead
        saved.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: Lab.socksProxy.port, user: Lab.socksProxy.user)
        let uri = server == .standalone ? "mongodb://127.0.0.1:\(MongoLab.soloPort)/?authMechanism=SCRAM-SHA-256"
            : MongoLab.allSeeds
        let mongo = MongoConnection(uri: uri, user: MongoLab.airsql.user, password: MongoLab.airsql.password,
                                    tls: server == .standalone ? TLSOptions() : MongoLab.tls,
                                    route: MongoRoute(saved, proxyPassword: Lab.socksProxy.password), name: saved.name, log: log)
        try await mongo.connect()
        return AgentTarget(saved: saved, safety: safety, database: "fixture", mongo: mongo)
    }

    static func documents(_ reply: [String: Any]) -> [[String: Any]] { reply["documents"] as? [[String: Any]] ?? [] }

    @Test(arguments: Server.allCases)
    func everyToolReadsTheFixture(_ server: Server) async throws {
        let target = try await Self.target(server)
        defer { Task { await target.mongo?.close() } }
        let find = try await target.mongo("mongo_find", ["collection": "many", "filter": "{\"n\": {\"$gte\": 10}}",
                                                        "sort": "{\"n\": -1}", "projection": "{\"_id\": 0}", "limit": 3])
        #expect(Self.documents(find).compactMap { $0["n"] as? Int } == [999, 998, 997] && find["capped"] as? Bool == true)
        let few = try await target.mongo("mongo_find", ["collection": "many", "filter": "{\"n\": {\"$lt\": 2}}"])
        #expect(few["count"] as? Int == 2 && few["capped"] as? Bool == false)
        let long = try await target.mongo("mongo_find", ["collection": "all_types", "filter": "{\"type\": \"long\"}"])
        #expect((Self.documents(long).first?["value"] as? NSNumber)?.int64Value == 9007199254740993)
        let decimal = try await target.mongo("mongo_find", ["collection": "all_types", "filter": "{\"_id\": 16}"])
        #expect(AgentJSON.text(decimal).contains("{\"$numberDecimal\":\"1234567890.123456789012345678901234\"}"))

        let grouped = try await target.mongo("mongo_aggregate", ["collection": "many", "pipeline":
            "[{\"$match\": {\"n\": {\"$lt\": 100}}}, {\"$group\": {\"_id\": {\"$mod\": [\"$n\", 2]}, \"c\": {\"$sum\": 1}}}, "
            + "{\"$sort\": {\"_id\": 1}}]"])
        #expect(Self.documents(grouped).compactMap { $0["c"] as? Int } == [50, 50] && grouped["capped"] as? Bool == false)
        #expect(try await target.mongo("mongo_count", ["collection": "many", "filter": "{\"n\": {\"$gte\": 900}}"])["count"]
            as? Int == 100)
        let types = try await target.mongo("mongo_distinct", ["collection": "all_types", "key": "type"])
        #expect((types["values"] as? [String])?.count == 19 && types["capped"] as? Bool == false)

        let databases = try await target.mongo("mongo_list_databases", [:])
        let names = (databases["databases"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        #expect(names.contains("fixture") && !names.contains { ["admin", "local", "config"].contains($0) }, "\(names)")
        let collections = try await target.mongo("mongo_list_collections", [:])["collections"] as? [[String: Any]] ?? []
        let kinds = Dictionary(collections.map { ($0["name"] as? String ?? "", $0["type"] as? String ?? "") }) { a, _ in a }
        #expect(kinds["all_types"] == "collection" && kinds["all_types_names"] == "view" && kinds["readings"] == "timeseries")
        #expect(!kinds.keys.contains { $0.hasPrefix("system.") })
        let indexes = try await target.mongo("mongo_list_indexes", ["collection": "many"])["indexes"] as? [[String: Any]]
        #expect(indexes?.first?["name"] as? String == "_id_")
        let stats = try await target.mongo("mongo_stats", ["collection": "many"])["stats"] as? [String: Any]
        #expect(stats?["count"] as? Int == 1000 && stats?["wiredTiger"] == nil)
        #expect((try await target.mongo("mongo_stats", [:])["stats"] as? [String: Any])?["collections"] != nil)
        let sample = try await target.mongo("mongo_schema_sample", ["collection": "all_types", "size": 50])
        let fields = sample["fields"] as? [[String: Any]] ?? []
        #expect(sample["documents"] as? Int == 19 && fields.contains { $0["path"] as? String == "value" })
    }

    @Test(arguments: Server.allCases)
    func capsApplyToEveryReply(_ server: Server) async throws {
        var safety = SafetySettings()
        safety.agentRowCap = 5
        let target = try await Self.target(server, safety: safety)
        defer { Task { await target.mongo?.close() } }
        for (tool, arguments) in [("mongo_find", ["limit": 0]), ("mongo_find", ["limit": 500]),
                                  ("mongo_aggregate", ["pipeline": "[]", "max_documents": 500])] as [(String, [String: Any])] {
            let reply = try await target.mongo(tool, ["collection": "many"].merging(arguments) { $1 })
            #expect(reply["count"] as? Int == 5 && reply["capped"] as? Bool == true, "\(tool) \(arguments)")
        }
        let distinct = try await target.mongo("mongo_distinct", ["collection": "many", "key": "n"])
        #expect((distinct["values"] as? [Any])?.count == 5 && distinct["capped"] as? Bool == true)
        #expect(try await target.mongo("mongo_schema_sample", ["collection": "many"])["documents"] as? Int == 5)
    }

    /// $out, $merge and $where are refused before anything reaches the server: the command log shows none of them.
    @Test(arguments: Server.allCases)
    func refusedRequestsNeverReachTheServer(_ server: Server) async throws {
        let file = URL(fileURLWithPath: TestEnvironment.root).appendingPathComponent("agent-mongo-\(UUID().uuidString).log")
        let target = try await Self.target(server, log: SQLLog(fileURL: file))
        defer { Task { await target.mongo?.close() } }
        for (tool, arguments) in [("mongo_aggregate", ["pipeline": "[{\"$out\": \"agent_copy\"}]"]),
                                  ("mongo_aggregate", ["pipeline": "[{\"$merge\": {\"into\": \"agent_copy\"}}]"]),
                                  ("mongo_find", ["filter": "{\"$where\": \"sleep(1000) || true\"}"]),
                                  ("mongo_count", ["filter": "{\"$expr\": {\"$function\": {\"body\": \"x\", \"args\": [], "
                                                   + "\"lang\": \"js\"}}}"])] as [(String, [String: Any])] {
            await #expect { try await target.mongo(tool, ["collection": "many"].merging(arguments) { $1 }) } throws: {
                AgentReply.message($0).hasPrefix("Refused: ")
            }
        }
        let log = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        #expect(!log.contains("agent_copy") && !log.contains("$where") && !log.contains("$function"), "\(log)")
        let collections = try await target.mongo("mongo_list_collections", [:])["collections"] as? [[String: Any]] ?? []
        #expect(!collections.contains { $0["name"] as? String == "agent_copy" })
    }

    /// The second guard: on a replica set a request the guard would have refused, run as if it had passed, is refused by
    /// the server inside the aborted transaction (263), and nothing is written.
    @Test func aWriteCantHappenOnAReplicaSet() async throws {
        let target = try await Self.target(.replicaSet)
        defer { Task { await target.mongo?.close() } }
        let mongo = try #require(target.mongo)
        let session = try await mongo.session(.agent)
        for stage in ["{\"$out\": \"agent_copy\"}", "{\"$merge\": {\"into\": \"agent_copy\"}}"] {
            let unchecked = MongoCheckedRequest(request: .aggregate(db: "fixture", collection: "many",
                                                                    pipeline: [try BSONDocument(extendedJSON: stage)]),
                                                maxTimeMS: 10_000, documentCap: 10)
            await #expect { try await target.run(unchecked, wanted: 10, on: session, server: mongo.server) } throws: {
                ($0 as? AirSQLError)?.code == 263
            }
            #expect(!session.inTransaction, "aborted")
        }
        let collections = try await target.mongo("mongo_list_collections", [:])["collections"] as? [[String: Any]] ?? []
        #expect(!collections.contains { $0["name"] as? String == "agent_copy" })
        // Calls at once take turns on the one session, each in its own transaction.
        async let one = target.mongo("mongo_count", ["collection": "many"])
        async let two = target.mongo("mongo_find", ["collection": "many", "limit": 1])
        let (counted, found) = try await (one, two)
        #expect(counted["count"] as? Int == 1000 && found["count"] as? Int == 1)
    }

    /// A slow read stops at the agent timeout (maxTimeMS), and the person's Cancel ends one under way.
    @Test(arguments: Server.allCases)
    func timeoutsAndCancel(_ server: Server) async throws {
        var safety = SafetySettings()
        safety.agentTimeout = 1
        let target = try await Self.target(server, safety: safety)
        defer { Task { await target.mongo?.close() } }
        // Correlated lookups within lookups (so the server can't cache them): about 10⁸ documents compared, small output.
        func after(_ variable: String) -> String { "{\"$match\": {\"$expr\": {\"$gte\": [\"$n\", \"$$\(variable)\"]}}}" }
        let inner = "{\"$lookup\": {\"from\": \"many\", \"as\": \"y\", \"let\": {\"p\": \"$n\"}, \"pipeline\": [\(after("p")), "
            + "{\"$count\": \"c\"}]}}"
        let slow: [String: Any] = ["collection": "many", "pipeline":
            "[{\"$lookup\": {\"from\": \"many\", \"as\": \"x\", \"let\": {\"o\": \"$n\"}, \"pipeline\": [\(after("o")), \(inner), "
            + "{\"$count\": \"c\"}]}}, {\"$count\": \"n\"}]"]
        await #expect { try await target.mongo("mongo_aggregate", slow) } throws: {
            AgentReply.message($0).hasPrefix("Stopped at the agent timeout (1 s).")
        }
        // Still usable after.
        #expect(try await target.mongo("mongo_count", ["collection": "many"])["count"] as? Int == 1000)

        var patient = safety
        patient.agentTimeout = 60
        let cancelled = try await Self.target(server, safety: patient)
        defer { Task { await cancelled.mongo?.close() } }
        let task = Task { try await cancelled.mongo("mongo_aggregate", slow) }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        await (try? await cancelled.mongo?.session(.agent))?.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
