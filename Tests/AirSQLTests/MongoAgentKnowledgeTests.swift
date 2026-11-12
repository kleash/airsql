import Foundation
import Testing
@testable import AirSQLCore

private func docs(_ texts: [String]) -> [BSONDocument] { texts.map { try! BSONDocument(extendedJSON: $0) } }
private func doc(_ text: String) -> BSONDocument { try! BSONDocument(extendedJSON: text) }
private func oid(_ n: Int) -> String { "{\"$oid\": \"cc\(String(format: "%022x", n))\"}" }

/// mongo_schema's text and references, and the hints and warnings of the Mongo agent tools, without a server.
struct MongoAgentKnowledgeTests {
    static let customers = MongoSchemaSummary.Collection(
        name: "customers", count: 20, averageSize: 90,
        indexes: [doc("{\"v\": 2, \"key\": {\"_id\": 1}, \"name\": \"_id_\"}"),
                  doc("{\"v\": 2, \"key\": {\"email\": 1}, \"name\": \"email_1\", \"unique\": true}")],
        sample: MongoSchema(sample: docs((1...20).map {
            "{\"_id\": \(oid($0)), \"email\": \"c\($0)@example.test\", \"tier\": \"\($0 % 3 == 0 ? "gold" : "bronze")\", "
                + "\"since\": {\"$date\": \"2024-0\($0 % 9 + 1)-01T00:00:00Z\"}}"
        }), topLimit: 12))
    static let products = MongoSchemaSummary.Collection(
        name: "products", indexes: [doc("{\"key\": {\"_id\": 1}, \"name\": \"_id_\"}"),
                                    doc("{\"key\": {\"sku\": 1}, \"name\": \"sku_1\", \"unique\": true}"),
                                    doc("{\"key\": {\"name\": 1}, \"name\": \"name_1\"}")],
        sample: MongoSchema(sample: docs((1...10).map { "{\"_id\": \($0), \"sku\": \"S-\($0)\", \"name\": \"n\($0)\"}" })))
    static let orders = MongoSchemaSummary.Collection(
        name: "orders", options: doc("{\"validator\": {\"$jsonSchema\": {\"required\": [\"customerId\"], \"properties\": "
                                     + "{\"status\": {\"enum\": [\"paid\", \"sent\"]}}}}}"),
        indexes: [doc("{\"key\": {\"_id\": 1}, \"name\": \"_id_\"}")],
        sample: MongoSchema(sample: docs((1...30).map {
            "{\"_id\": \($0), \"customerId\": \(oid($0 % 20 + 1)), \"userId\": \(oid($0)), \"customer_id\": \"x\($0)\", "
                + "\"status\": \"\($0 % 2 == 0 ? "paid" : "sent")\", \"items\": [{\"sku\": \"S-\($0 % 10 + 1)\", \"qty\": \($0 % 4 + 1)}], "
                + "\"productSku\": \($0), \"name\": \"n\($0 % 10 + 1)\", \"total\": {\"$numberDecimal\": \"\($0).50\"}}"
        }), topLimit: 12))

    @Test func summaryListsCollectionsPathsAndValues() {
        var orders = Self.orders
        orders.references["customerId"] = "customers._id (20/20)"
        let view = MongoSchemaSummary.Collection(name: "paid", kind: .view,
                                                 options: doc("{\"viewOn\": \"orders\", \"pipeline\": [{\"$match\": {\"status\": \"paid\"}}]}"))
        let (text, capped) = MongoSchemaSummary.text([Self.customers, orders, view], database: "shop", values: true)
        #expect(!capped && text.hasPrefix("database shop: 2 collections, 1 view."))
        #expect(text.contains("collection customers (20 documents, avg 90 B)\n  indexes: _id_ { _id: 1 }; email_1 { email: 1 } unique\n"))
        #expect(text.contains("\n  tier string enum \"bronze\" 70%, \"gold\" 30%\n"), "\(text)")
        #expect(text.contains("\n  since date 2024-01-01T00:00:00Z..2024-09-01T00:00:00Z\n"))
        #expect(text.contains("\n  email string\n"), "20 distinct values are no enum")
        #expect(text.contains("\n  customerId objectId -> customers._id (20/20)\n"))
        #expect(text.contains("\n  items.[].qty int 1..4\n") && text.contains("\n  total decimal 1.50..30.50\n"))
        #expect(text.contains("validator: $jsonSchema required customerId; status enum \"paid\"|\"sent\""))
        #expect(text.contains("\nview paid on orders: [ { $match: { status: \"paid\" } } ]\n"))
        // Schema access: types and shares, no values.
        let bare = MongoSchemaSummary.text([Self.customers, orders], database: "shop", values: false).text
        #expect(bare.contains("\n  tier string\n") && bare.contains("\n  since date\n") && !bare.contains(".."))
        #expect(bare.contains("\n  customerId objectId -> customers._id (20/20)\n"))
    }

    @Test func sharesTypesAndPathLimits() {
        let mixed = MongoSchema(sample: docs(["{\"a\": 1, \"b\": {\"c\": {\"d\": {\"e\": {\"f\": 1}}}}}", "{\"a\": \"x\"}",
                                              "{\"a\": 2}", "{\"z\": 1}"]))
        let text = MongoSchemaSummary.text([MongoSchemaSummary.Collection(name: "m", sample: mixed)], database: "d",
                                           values: true).text
        #expect(text.contains("\n  a int 66%|string 33% 75%"), "types by share, then the path's share: \(text)")
        #expect(text.contains("\n  b object 25%\n") && text.contains("\n  b.c.d.e object\n") && !text.contains("b.c.d.e.f"),
                "4 deep at most; a share of the documents holding it")
        #expect(text.contains("… 1 more path, less often present or deeper"))
        let wide = MongoSchema(sample: [BSONDocument((0..<90).map { ("field\($0)", .int32(Int32($0))) })])
        let many = MongoSchemaSummary.text([MongoSchemaSummary.Collection(name: "w", sample: wide)], database: "d", values: true)
        #expect(many.text.contains("  field59 int") && !many.text.contains("  field60 int") && many.text.contains("… 30 more paths"))
    }

    @Test func staysWithinTheBudget() {
        let wide = MongoSchema(sample: (0..<5).map { n in
            BSONDocument((0..<60).map { ("a_rather_long_field_name_\($0)", .string("value \(n)")) })
        })
        let collections = (0..<40).map { MongoSchemaSummary.Collection(name: "collection_\($0)", sample: wide) }
        let (text, capped) = MongoSchemaSummary.text(collections, database: "big", values: true)
        #expect(capped && text.utf8.count <= MongoSchemaSummary.budget)
        #expect(text.contains("collection_0") && text.contains("more paths"), "fewer paths first")
        let more = (0..<400).map { MongoSchemaSummary.Collection(name: "collection_\($0)", sample: wide) }
        let (cut, alsoCapped) = MongoSchemaSummary.text(more, database: "big", values: true)
        #expect(alsoCapped && cut.utf8.count <= MongoSchemaSummary.budget && cut.contains("left out to fit: "))
        #expect(MongoSchemaSummary.hash(text) == MongoSchemaSummary.hash(text) && MongoSchemaSummary.hash(text) != MongoSchemaSummary.hash(cut))
    }

    @Test func referencesByNameAndTypeOnly() {
        let found = MongoSchemaSummary.candidates([Self.customers, Self.products, Self.orders])
        let pairs = Set(found.map { "\($0.collection).\($0.path) -> \($0.target).\($0.field)" })
        #expect(pairs.contains("orders.customerId -> customers._id"))
        #expect(pairs.contains("orders.items.[].sku -> products.sku"))
        // customer_id is a string (customers._id is an objectId); productSku an int (sku a string); userId has no users;
        // name's index isn't unique; status matches nothing; sku itself isn't its own reference.
        #expect(pairs.count == 2, "\(pairs)")
        let customer = try! #require(found.first { $0.path == "customerId" })
        #expect(customer.probe.count == 20, "the distinct sampled values")
        #expect(MongoSchemaSummary.reference(customer, hits: 16, of: 20) == "customers._id (16/20)")
        #expect(MongoSchemaSummary.reference(customer, hits: 15, of: 20) == nil, "under 80% isn't a reference")
        #expect(MongoSchemaSummary.reference(customer, hits: 0, of: 0) == nil)
        let ids = MongoSchemaSummary.Collection(name: "carts", sample: MongoSchema(sample: docs([
            "{\"categoryIds\": [1, 2]}", "{\"categoryIds\": [3]}"])))
        let categories = MongoSchemaSummary.Collection(name: "categories", sample: MongoSchema(sample: docs(["{\"_id\": 1}"])))
        #expect(MongoSchemaSummary.candidates([ids, categories]).map(\.path) == ["categoryIds.[]"], "an array of ids")
    }

    @Test func hintsName() {
        #expect(MongoAgentHints.unknownWord("unknown group operator '$sume'") == "$sume")
        #expect(MongoAgentHints.unknownWord("Invalid $project :: caused by :: Unrecognized expression '$concatt'") == "$concatt")
        #expect(MongoAgentHints.unknownWord("Unrecognized expression '$median'") == "$median")
        #expect(MongoAgentHints.unknownWord("unknown top level operator: $orr. If you…") == "$orr")
        #expect(MongoAgentHints.unknownWord("Document failed validation") == nil)
        #expect(MongoAgentHints.hint("$sume", version: "7.0.1")?.hasPrefix("Did you mean $sum? ") == true)
        #expect(MongoAgentHints.hint("$median", version: "6.0.3") == "$median needs MongoDB 7.0; this server runs 6.0.3")
        #expect(MongoAgentHints.hint("$median", version: "7.0.3") == nil, "a known word: the server's message says where")
        #expect(MongoAgentHints.hint("$zzzzzzzz", version: nil) == nil)
        #expect(MongoAgentHints.refused(MongoAgentRefusal(path: "pipeline.1", reason: "$gruop isn't a stage agents may use"))
            == "Refused: pipeline.1: $gruop isn't a stage agents may use. Did you mean $group? "
            + "Groups by _id's expression, with accumulators for the other fields")
        #expect(MongoAgentHints.refused(MongoAgentRefusal(path: "pipeline.0", reason: "$currentOp isn't a stage agents may use"))
            == "Refused: pipeline.0: $currentOp isn't a stage agents may use.", "a real stage that isn't allowed: no hint")
        #expect(MongoAgentHints.codeName(2) == "BadValue" && MongoAgentHints.codeName(15952) == "Location15952"
                && MongoAgentHints.codeName(999) == nil)
    }

    @Test func serverErrorsBecomeJSON() throws {
        let pipeline = [doc("{\"$match\": {}}"), doc("{\"$group\": {\"_id\": 1, \"n\": {\"$sume\": 1}}}")]
        let error = MongoErrorMapping.map(domain: 17, code: 15952, message: "unknown group operator '$sume'")
        let taught = MongoAgentHints.teach(error, .aggregate(db: "d", collection: "c", pipeline: pipeline), version: "7.0.2")
        let entry = try #require(try JSONSerialization.jsonObject(with: Data(AgentReply.message(taught).utf8)) as? [String: Any])
        #expect(entry["code"] as? Int == 15952 && entry["codeName"] as? String == "Location15952" && entry["stage"] as? Int == 1)
        #expect(entry["message"] as? String == "unknown group operator '$sume'")
        #expect((entry["hint"] as? String)?.hasPrefix("Did you mean $sum?") == true)
        let own = AirSQLError(.other, "AirSQL's own")
        #expect(MongoAgentHints.teach(own, .find(db: "d", collection: "c", filter: BSONDocument()), version: nil) == own)
    }

    @Test func warningsFromTheSample() {
        let sample = MongoSample(schema: Self.orders.sample!, validatorPaths: ["status"])
        func find(_ filter: String, sort: String? = nil) -> MongoAgentRequest {
            .find(db: "d", collection: "orders", filter: doc(filter), sort: sort.map(doc))
        }
        let misspelt = MongoAgentHints.warnings(find("{\"customerID\": 1, \"$or\": [{\"stauts\": \"paid\"}]}"), sample: sample,
                                                matched: 0)
        #expect(misspelt == ["customerID is not in the sample of 30 documents; nearest: customerId",
                             "stauts is not in the sample of 30 documents; nearest: status",
                             "Nothing matched, which the warnings above may explain."])
        #expect(MongoAgentHints.warnings(find("{\"items.sku\": \"S-1\", \"items.0.qty\": {\"$gt\": 1}}", sort: "{\"total\": -1}"),
                                         sample: sample, matched: 0).isEmpty, "array steps as a query writes them")
        let typed = MongoAgentHints.warnings(find("{\"customerId\": \"cc01\", \"total\": {\"$gte\": \"10\"}, "
                                                  + "\"items.qty\": {\"$in\": [1, \"2\"]}, \"status\": null}"), sample: sample)
        #expect(typed == ["customerId is objectId in the sample of 30 documents, never string: compare with {\"$oid\": "
                          + "\"<24 hex digits>\"} (ObjectId(…) in the shell)",
                          "total is decimal in the sample of 30 documents, never string: compare with {\"$numberDecimal\": "
                          + "\"9.99\"} or a number, not a string",
                          "items.qty is int in the sample of 30 documents, never string: compare with a number, not a string"])
        #expect(MongoAgentHints.warnings(find("{\"total\": {\"$gt\": 3}}"), sample: sample).isEmpty, "numbers compare")
        // An aggregate's leading $match only: after $group the paths are the group's.
        let pipeline: MongoAgentRequest = .aggregate(db: "d", collection: "orders", pipeline: [
            doc("{\"$match\": {\"custmerId\": 1}}"), doc("{\"$group\": {\"_id\": \"$status\"}}"), doc("{\"$match\": {\"n\": 1}}")])
        #expect(MongoAgentHints.warnings(pipeline, sample: sample) == ["custmerId is not in the sample of 30 documents; "
                                                                      + "nearest: customerId"])
        #expect(MongoAgentHints.warnings(.explain(find("{\"zz\": 1}"), execute: false), sample: sample)
            == ["zz is not in the sample of 30 documents"])
        #expect(MongoAgentHints.warnings(find("{\"x\": 1}"), sample: MongoSample(schema: MongoSchema(sample: []))).isEmpty,
                "an empty sample says nothing")
    }

    @Test func explainIsCheckedAsItsQuery() throws {
        let checked = try MongoAgentGuard.check(.explain(.aggregate(db: "d", collection: "c", pipeline: []), execute: true),
                                                safety: { var s = SafetySettings(); s.agentRowCap = 7; return s }())
        guard case .explain(.aggregate(_, _, let pipeline, _, _), true) = checked.request else {
            Issue.record("\(checked.request)")
            return
        }
        #expect(pipeline.last?.shellForm() == "{ $limit: NumberLong(7) }" || pipeline.last?.shellForm() == "{ $limit: 7 }",
                "capped as the aggregate is")
        #expect(throws: MongoAgentRefusal.self) {
            try MongoAgentGuard.check(.explain(.find(db: "d", collection: "c", filter: doc("{\"$where\": \"1\"}")), execute: false))
        }
        #expect(throws: MongoAgentRefusal.self) { try MongoAgentGuard.check(.explain(.count(db: "d", collection: "c",
                                                                                            filter: BSONDocument()), execute: false)) }
        #expect(throws: MongoAgentRefusal.self) {
            try MongoAgentGuard.check(.explain(.find(db: "admin", collection: "c", filter: BSONDocument()), execute: false))
        }
    }

    @Test func explainRepliesFromThePlan() {
        let planner = doc("{\"queryPlanner\": {\"winningPlan\": {\"stage\": \"FETCH\", \"inputStage\": {\"stage\": \"IXSCAN\", "
                          + "\"indexName\": \"status_1\"}}, \"rejectedPlans\": [{\"stage\": \"COLLSCAN\"}]}}")
        let plan = AgentTarget.explained(planner, ran: false)
        #expect(plan["scan"] as? String == "index" && plan["index"] as? String == "status_1" && plan["docsExamined"] == nil)
        #expect((plan["plan"] as? String)?.contains("IXSCAN status_1") == true && plan["verbosity"] as? String == "plan")
        let ran = AgentTarget.explained(doc("{\"queryPlanner\": {\"winningPlan\": {\"stage\": \"COLLSCAN\"}}, \"executionStats\": "
                                            + "{\"nReturned\": 3, \"totalDocsExamined\": 1500, \"executionTimeMillis\": 4, "
                                            + "\"executionStages\": {\"stage\": \"COLLSCAN\", \"docsExamined\": 1500, \"nReturned\": 3}}}"),
                                        ran: true)
        #expect(ran["scan"] as? String == "collection" && ran["docsExamined"] as? Int == 1500 && ran["returned"] as? Int == 3
                && ran["ms"] as? Int == 4)
        #expect((ran["warnings"] as? [String])?.first?.hasPrefix("Reads the whole collection (1500 documents)") == true)
    }

    @Test func newToolsAreListedAndFailClosed() async {
        let names = AgentTools.list.compactMap { $0["name"] as? String }
        #expect(names.contains("mongo_schema") && names.contains("mongo_explain"))
        #expect(AgentTarget.mongoTools.contains("mongo_schema") && AgentTarget.mongoTools.contains("mongo_explain"))
        // The guard first, then "isn't connected": nothing reaches a server it can't vouch for.
        #expect(await AgentMongoToolTests.error("mongo_explain", ["collection": "c", "pipeline": "[{\"$out\": \"x\"}]"])
            .hasPrefix("Refused: pipeline.0: $out writes"))
        #expect(await AgentMongoToolTests.error("mongo_explain", ["collection": "c", "verbosity": "all"]).contains("plan"))
        #expect(await AgentMongoToolTests.error("mongo_schema", ["database": "admin"]).hasPrefix("Refused: db: admin"))
        #expect(await AgentMongoToolTests.error("mongo_schema", [:], AgentMongoToolTests.target(.schema)).contains("isn't connected"))
        #expect(await AgentMongoToolTests.error("mongo_explain", ["collection": "c"], AgentMongoToolTests.target(.schema))
            .contains("needs Schema + read"))
        #expect(await AgentMongoToolTests.error("mongo_find", ["collection": "c", "to_file": true]).contains("analytics"))
        #expect(await AgentMongoToolTests.error("mongo_count", ["collection": "c", "to_file": true])
            == "to_file is for mongo_find and mongo_aggregate.")
        #expect(await AgentMongoToolTests.error("mongo_find", ["collection": "c", "to_file": true],
                                                AgentMongoToolTests.target(.schemaReadAnalytics)).contains("isn't connected"))
    }
}
