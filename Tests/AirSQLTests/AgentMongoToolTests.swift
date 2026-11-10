import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// The MongoDB agent tools without a server: their arguments, and every refusal through the tool itself (the guard
/// runs before the connection is needed, so a refused call says why and an allowed one goes on to "isn't connected").
struct AgentMongoToolTests {
    static func target(_ access: AgentAccess = .schemaRead, engine: Engine = .mongodb) -> AgentTarget {
        var saved = SavedConnection(name: "Docs", host: "db.invalid", user: "app")
        saved.engine = engine
        saved.agentAccess = access
        return AgentTarget(saved: saved, safety: saved.safety(defaults: SafetySettings()), database: "shop")
    }

    static func error(_ tool: String, _ arguments: [String: Any], _ target: AgentTarget = target()) async -> String {
        do {
            _ = try await target.mongo(tool, arguments)
            return "ran"
        } catch {
            return AgentReply.message(error)
        }
    }

    @Test func argumentsBecomeTypedRequests() throws {
        let target = Self.target()
        let find = try target.mongoRequest("mongo_find", [
            "collection": "orders", "filter": "{\"total\": {\"$gt\": {\"$numberDecimal\": \"9.5\"}}}",
            "sort": "{\"b\": 1, \"a\": -1}", "projection": "{\"b\": 1}", "skip": 2, "limit": 3, "hint": "b_1"])
        guard case let .find(db, collection, filter, projection, sort, skip, limit, _, hint) = find else {
            Issue.record("\(find)")
            return
        }
        #expect(db == "shop" && collection == "orders" && skip == 2 && hint == .string("b_1"))
        #expect(sort?.keys == ["b", "a"], "the order of the sort's keys is kept")
        #expect(projection?.keys == ["b"] && filter.shellForm() == "{ total: { $gt: NumberDecimal(\"9.5\") } }")
        #expect(limit == 4, "one more than wanted, to tell whether there were more")
        guard case .find(_, _, _, _, _, _, let unset, _, .document(let pattern)?) = try target.mongoRequest(
            "mongo_find", ["collection": "c", "hint": "{\"a\": 1}", "database": "other"]) else { Issue.record("hint"); return }
        #expect(unset == AgentTarget.defaultRows + 1 && pattern.keys == ["a"])

        let aggregate = try target.mongoRequest("mongo_aggregate", ["collection": "c",
                                                                     "pipeline": "[{\"$match\": {}}, {\"$count\": \"n\"}]"])
        guard case .aggregate(_, _, let pipeline, _, _) = aggregate else { Issue.record("\(aggregate)"); return }
        #expect(pipeline.map(\.keys) == [["$match"], ["$count"]])
        #expect(try target.mongoRequest("mongo_distinct", ["collection": "c", "key": "a.b"])
            == .distinct(db: "shop", collection: "c", key: "a.b", filter: BSONDocument()))
        #expect(try target.mongoRequest("mongo_stats", ["database": "x"]) == .stats(db: "x", collection: nil))
        #expect(try target.mongoRequest("mongo_list_databases", [:]) == .listDatabases)
        #expect(try target.mongoRequest("mongo_schema_sample", ["collection": "c"])
            == .schemaSample(db: "shop", collection: "c", size: AgentTarget.defaultRows))
    }

    @Test func badArgumentsAreRefusedInPlainWords() async {
        #expect(await Self.error("mongo_find", ["collection": "c", "filter": ["a": 1]]).contains("pass it as a string"))
        #expect(await Self.error("mongo_find", ["collection": "c", "filter": "{a: 1}"]).hasPrefix("filter isn't Extended JSON"))
        #expect(await Self.error("mongo_find", [:]).contains("needs collection"))
        #expect(await Self.error("mongo_aggregate", ["collection": "c"]).contains("needs pipeline"))
        #expect(await Self.error("mongo_aggregate", ["collection": "c", "pipeline": "{}"]).contains("array of stages"))
        #expect(await Self.error("mongo_aggregate", ["collection": "c", "pipeline": "[1]"]).contains("is a document"))
        // A pipeline's text can't add fields of its own beside the array.
        #expect(await Self.error("mongo_aggregate", ["collection": "c", "pipeline": "[], \"x\": 1"]).contains("array of stages"))
        #expect(await Self.error("mongo_distinct", ["collection": "c"]).contains("needs key"))
        var none = Self.target()
        none.database = nil
        #expect(await Self.error("mongo_count", ["collection": "c"], none).contains("needs database"))
        #expect(await Self.error("mongo_drop", ["collection": "c"]).contains("no tool"))
    }

    /// Each forbidden thing, as an agent would send it, through the tool: refused before any connection is needed.
    @Test(arguments: [
        ("mongo_find", ["filter": "{\"$where\": \"sleep(100)\"}"], "filter: $where runs JavaScript"),
        ("mongo_find", ["filter": "{\"$expr\": {\"$function\": {\"body\": \"x\", \"args\": [], \"lang\": \"js\"}}}"],
         "filter.$expr: $function"),
        ("mongo_find", ["filter": "{\"a\": {\"$code\": \"function () {}\"}}"], "filter.a: JavaScript code"),
        ("mongo_find", ["projection": "{\"a\": {\"$accumulator\": {}}}"], "projection.a: $accumulator"),
        ("mongo_find", ["skip": -1], "skip: can't be negative"),
        ("mongo_find", ["hint": "{\"a\": {\"$out\": 1}}"], "hint.a: $out"),
        ("mongo_count", ["filter": "{\"$where\": \"true\"}"], "$where"),
        ("mongo_distinct", ["key": "$a"], "key: needs a field"),
        ("mongo_aggregate", ["pipeline": "[{\"$out\": \"copy\"}]"], "pipeline.0: $out writes"),
        ("mongo_aggregate", ["pipeline": "[{\"$match\": {}}, {\"$merge\": {\"into\": \"copy\"}}]"], "pipeline.1: $merge writes"),
        ("mongo_aggregate", ["pipeline": "[{\"$facet\": {\"a\": [{\"$out\": \"x\"}]}}]"], "$out writes"),
        ("mongo_aggregate", ["pipeline": "[{\"$lookup\": {\"from\": \"b\", \"as\": \"x\", \"pipeline\": [{\"$currentOp\": {}}]}}]"],
         "$currentOp isn't a stage"),
        ("mongo_aggregate", ["pipeline": "[{\"$lookup\": {\"from\": {\"db\": \"admin\", \"coll\": \"x\"}, \"as\": \"x\"}}]"],
         "this database"),
        ("mongo_aggregate", ["pipeline": "[{\"$unionWith\": \"system.users\"}]"], "system collection"),
        ("mongo_aggregate", ["pipeline": "[{\"$changeStream\": {}}]"], "isn't a stage agents may use"),
        ("mongo_list_collections", ["database": "admin"], "MongoDB's own database"),
        ("mongo_stats", ["database": "local"], "MongoDB's own database"),
        ("mongo_list_indexes", ["collection": "system.profile"], "system collection"),
        ("mongo_schema_sample", ["size": 0], "at least 1"),
    ] as [(String, [String: Any], String)])
    func forbiddenThingsAreRefusedThroughTheTool(_ tool: String, _ arguments: [String: Any], _ reason: String) async {
        let message = await Self.error(tool, ["collection": "c"].merging(arguments) { $1 })
        #expect(message.hasPrefix("Refused: ") && message.contains(reason), "\(message)")
    }

    @Test func allowedCallsGoOnToNeedTheConnection() async {
        for (tool, arguments) in [("mongo_find", ["filter": "{\"a\": {\"$regex\": \"^x\"}}"]),
                                  ("mongo_aggregate", ["pipeline": "[{\"$lookup\": {\"from\": \"b\", \"localField\": \"a\", "
                                                       + "\"foreignField\": \"a\", \"as\": \"x\"}}]"]),
                                  ("mongo_list_databases", [:])] as [(String, [String: Any])] {
            #expect(await Self.error(tool, ["collection": "c"].merging(arguments) { $1 }).contains("isn't connected"), "\(tool)")
        }
    }

    /// SQL tools refuse a MongoDB connection and the mongo_ tools a MySQL one, whatever the access.
    @Test func eachEngineHasItsOwnTools() async {
        let mongo = Self.target(.schemaReadAnalytics), mysql = Self.target(.schemaReadAnalytics, engine: .mysql)
        for message in [await AgentToolTests.refusal { try await mongo.getSchema([:]) },
                        await AgentToolTests.refusal { try await mongo.describe(["objects": ["t"]]) },
                        await AgentToolTests.refusal { try await mongo.searchColumns(["pattern": "a"]) },
                        await AgentToolTests.refusal { try await mongo.runQueries(["queries": ["SELECT 1"]]) },
                        await AgentToolTests.refusal { try await mongo.profile(["table": "t"]) },
                        await AgentToolTests.refusal { try await mongo.explain(["sql": "SELECT 1"]) },
                        await AgentToolTests.refusal { try await mongo.schemaText() }] {
            #expect(message?.contains("is a MongoDB connection, and this tool is for MySQL and MariaDB") == true, "\(message ?? "")")
        }
        #expect(await Self.error("mongo_find", ["collection": "c"], mysql)
            == "“Docs” is a MySQL or MariaDB connection, and this tool is for MongoDB: use the SQL tools.")
        #expect(await Self.error("mongo_list_databases", [:], Self.target(.schema)).contains("needs Schema + read"))
    }

    @Test func valuesComeBackAsRelaxedExtendedJSON() throws {
        let document = try BSONDocument(extendedJSON: "{\"n\": {\"$numberLong\": \"9007199254740993\"}, \"d\": "
                                        + "{\"$date\": \"2024-02-29T12:34:56.789Z\"}, \"s\": \"" + String(repeating: "x", count: 3000) + "\"}")
        let json = try #require(AgentTarget.json(.document(document)) as? [String: Any])
        #expect((json["n"] as? NSNumber)?.int64Value == 9007199254740993, "exact, not through a double")
        #expect((json["d"] as? [String: Any])?["$date"] as? String == "2024-02-29T12:34:56.789Z")
        #expect((json["s"] as? String)?.count == AgentFormat.cellLimit + 1)
        #expect(AgentJSON.text(json).contains("9007199254740993"))
    }

    /// A connection's MongoDB settings are the person's, as the rest of how it connects is.
    @Test func mongoSettingsArePersonOnly() {
        let edits: [(inout SavedConnection) -> Void] = [
            { $0.engine = .mongodb }, { $0.mongoHosts = ["evil.invalid:27017"] }, { $0.mongoSRV = true },
            { $0.authSource = "admin" }, { $0.replicaSet = "rs0" }, { $0.directConnection = true },
            { $0.mongoOptions = "tlsInsecure=true" },
        ]
        let saved = SavedConnection(name: "Docs", host: "db.invalid")
        let before = AirSQLData(connections: [saved])
        for edit in edits {
            var changed = saved
            edit(&changed)
            #expect(AgentGate.personOnlyChange(from: before, to: AirSQLData(connections: [changed]))
                == "a connection's server, route, login, TLS, startup SQL or client tools")
        }
    }

    @MainActor @Test func theActivityListShowsTheShellForm() {
        let call: [String: Any] = ["database": "shop", "collection": "orders", "filter": "{\"status\": \"A\"}"]
        #expect(AgentService.shellForm("mongo_find", call) == "shop.orders.find({ status: \"A\" })")
        #expect(AgentService.shellForm("mongo_aggregate", ["collection": "o", "pipeline": "[{\"$count\": \"n\"}]"])
            == "o.aggregate([ { $count: \"n\" } ])")
        #expect(AgentService.shellForm("mongo_distinct", ["collection": "o", "key": "a"]) == "o.distinct(\"a\")")
        #expect(AgentService.shellForm("mongo_list_databases", [:]) == "show dbs")
    }
}

extension AppTests {
    /// A MongoDB connection's tools go through the service like the SQL ones: listed, refused or run.
    @Test func mongoToolsGoThroughTheService() async throws {
        var docs = SavedConnection(name: "Docs", host: "db.invalid", user: "app")
        docs.engine = .mongodb
        docs.agentAccess = .schemaRead
        let model = testModel([docs])
        let service = AgentService(model: model, main: nil, directory: URL(fileURLWithPath: try scratch() + "/agent"))
        model.data.settings.agentsAllowed = true
        defer { service.close() }
        let context = Self.structured(await service.handle("context", [:], client: "test"))
        let entry = (context["connections"] as? [[String: Any]])?.first
        #expect(entry?["engine"] as? String == "mongodb" && entry?["connected"] as? Bool == false)
        let refused = await service.handle("mongo_find", ["connection": "Docs", "database": "shop", "collection": "c",
                                                          "filter": "{\"$where\": \"1\"}"], client: "test")
        #expect(refused["isError"] as? Bool == true && text(refused).hasPrefix("Refused: filter: $where"))
        let sql = await service.handle("run_queries", ["connection": "Docs", "queries": ["SELECT 1"]], client: "test")
        #expect(text(sql).contains("is a MongoDB connection"))
        let notOpen = await service.handle("mongo_count", ["connection": "Docs", "database": "shop", "collection": "c"],
                                           client: "test")
        #expect(text(notOpen).contains("isn't connected"))
        #expect(service.events.map(\.summary).last == "mongo_count · shop.c.countDocuments()")
        #expect(service.events.filter(\.failed).count == 3)
    }
}
