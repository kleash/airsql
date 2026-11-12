import AirSQLCore
import Foundation
import Testing

private func doc(_ text: String) -> BSONDocument { try! BSONDocument(shellForm: text) }
private func stages(_ text: String) -> [BSONDocument] {
    guard case .array(let values) = try! BSONValue(shellForm: text) else { fatalError("not an array: \(text)") }
    return values.map { value -> BSONDocument in
        guard case .document(let d) = value else { fatalError("not a stage: \(value)") }
        return d
    }
}

private func refusal(_ request: MongoAgentRequest) -> MongoAgentRefusal? {
    do { _ = try MongoAgentGuard.check(request); return nil } catch let refusal as MongoAgentRefusal { return refusal } catch {
        Issue.record("unexpected error \(error)")
        return nil
    }
}

private func find(_ filter: BSONDocument, db: String = "shop", collection: String = "orders") -> MongoAgentRequest {
    .find(db: db, collection: collection, filter: filter)
}
private func aggregate(_ pipeline: String) -> MongoAgentRequest {
    .aggregate(db: "shop", collection: "orders", pipeline: stages(pipeline))
}

private let forbidden = ["$where", "$function", "$accumulator", "$out", "$merge"]

struct MongoAgentGuardTests {
    // MARK: Forbidden keys

    @Test(arguments: forbidden) func forbiddenKeyAtTopIsRefused(key: String) {
        let filter = BSONDocument([(key, .string("x"))])
        let r = refusal(find(filter))
        #expect(r?.path == "filter")
        #expect(r?.reason.hasPrefix(key + " ") == true)
    }

    @Test(arguments: forbidden) func forbiddenKeyDeepIsRefused(key: String) {
        let inner = BSONValue.document(BSONDocument([(key, .document(BSONDocument([("a", .int32(1))])))]))
        // $and > $or > $expr > $cond > the key
        let filter = BSONDocument([("$and", .array([.document(BSONDocument([("$or", .array([
            .document(BSONDocument([("b", .int32(1))])),
            .document(BSONDocument([("$expr", .document(BSONDocument([("$cond", .array([inner, .bool(true), .bool(false)]))])))])),
        ]))]))]))])
        #expect(refusal(find(filter))?.description == "filter.$and.0.$or.1.$expr.$cond.0: \(key) "
            + MongoAgentGuardTests.reason(key))
        // In every other argument of find.
        let bad = BSONDocument([("x", inner)])
        #expect(refusal(.find(db: "shop", collection: "orders", filter: BSONDocument(), projection: bad))?.path == "projection.x")
        #expect(refusal(.find(db: "shop", collection: "orders", filter: BSONDocument(), sort: bad))?.path == "sort.x")
        #expect(refusal(.find(db: "shop", collection: "orders", filter: BSONDocument(), collation: bad))?.path == "collation.x")
        #expect(refusal(.find(db: "shop", collection: "orders", filter: BSONDocument(), hint: .document(bad)))?.path == "hint.x")
        #expect(refusal(.count(db: "shop", collection: "orders", filter: bad))?.path == "filter.x")
        #expect(refusal(.distinct(db: "shop", collection: "orders", key: "a", filter: bad))?.path == "filter.x")
        #expect(refusal(.aggregate(db: "shop", collection: "orders", pipeline: [], collation: bad))?.path == "collation.x")
    }

    static func reason(_ key: String) -> String {
        ["$out", "$merge"].contains(key) ? "writes to a collection, which agents can't" : "runs JavaScript, which agents can't"
    }

    @Test(arguments: forbidden) func forbiddenKeyInsideStagesIsRefused(key: String) {
        let value = BSONValue.document(BSONDocument([(key, .string("x"))]))
        let match = BSONValue.document(BSONDocument([("$match", value)]))
        let lookup = BSONDocument([("$lookup", .document(BSONDocument([
            ("from", .string("items")), ("as", .string("i")), ("pipeline", .array([match])),
        ])))])
        let facet = BSONDocument([("$facet", .document(BSONDocument([("left", .array([.document(lookup)]))])))])
        let union = BSONDocument([("$unionWith", .document(BSONDocument([("coll", .string("old")), ("pipeline", .array([.document(facet)]))])))])
        let pipeline = [doc("{$match: {a: 1}}"), union]
        let r = refusal(.aggregate(db: "shop", collection: "orders", pipeline: pipeline))
        #expect(r?.path == "pipeline.1.$unionWith.pipeline.0.$facet.left.0.$lookup.pipeline.0.$match")
        #expect(r?.reason == key + " " + MongoAgentGuardTests.reason(key))
    }

    @Test func outAndMergeStagesAreRefused() {
        #expect(refusal(aggregate("[{$match: {}}, {$out: 'copy'}]"))?.description
            == "pipeline.1: $out writes to a collection, which agents can't")
        #expect(refusal(aggregate("[{$merge: {into: 'copy'}}]"))?.path == "pipeline.0")
        #expect(refusal(aggregate("[{$group: {_id: null, v: {$accumulator: {init: 'x'}}}}]"))?.path == "pipeline.0.$group.v")
    }

    // MARK: JavaScript values

    @Test func javascriptValuesAreRefusedAnywhere() {
        let code = BSONDocument([("a", .array([.int32(1), .javascript("return 1")]))])
        #expect(refusal(find(code))?.description == "filter.a.1: JavaScript code, which agents can't send")
        let scoped = BSONDocument([("b", .document(BSONDocument([("c", .javascriptWithScope(code: "x", scope: BSONDocument()))])))])
        #expect(refusal(find(scoped))?.path == "filter.b.c")
        let stage = BSONDocument([("$project", .document(BSONDocument([("f", .javascript("x"))])))])
        #expect(refusal(.aggregate(db: "shop", collection: "orders", pipeline: [stage]))?.path == "pipeline.0.$project.f")
    }

    // MARK: Namespaces

    @Test(arguments: ["admin", "local", "config", "Admin", "CONFIG"]) func internalDatabasesAreRefused(db: String) {
        #expect(refusal(find(BSONDocument(), db: db))?.path == "db")
        #expect(refusal(.listCollections(db: db))?.path == "db")
        #expect(refusal(.stats(db: db, collection: nil))?.path == "db")
    }

    @Test(arguments: ["", "a.b", "a b", "a$b", "a/b", "a\\b", "a\"b", "a\0b", String(repeating: "d", count: 64)])
    func invalidDatabaseNamesAreRefused(db: String) {
        #expect(refusal(.listIndexes(db: db, collection: "orders"))?.reason.contains("isn't a valid database name") == true)
    }

    @Test(arguments: ["", "a$b", "a\0b", "system.users", "system.profile", "system.js", "system.views"])
    func invalidOrSystemCollectionsAreRefused(collection: String) {
        let requests: [MongoAgentRequest] = [
            find(BSONDocument(), collection: collection), .count(db: "shop", collection: collection, filter: BSONDocument()),
            .distinct(db: "shop", collection: collection, key: "a", filter: BSONDocument()),
            .listIndexes(db: "shop", collection: collection), .stats(db: "shop", collection: collection),
            .schemaSample(db: "shop", collection: collection, size: 10),
            .aggregate(db: "shop", collection: collection, pipeline: []),
        ]
        for request in requests { #expect(refusal(request)?.path == "collection") }
    }

    @Test func overLongNamespaceIsRefused() {
        #expect(refusal(find(BSONDocument(), collection: String(repeating: "c", count: 251)))?.path == "collection")
        #expect(refusal(find(BSONDocument(), collection: String(repeating: "c", count: 250))) == nil)
    }

    @Test func stageTargetsStayInThisDatabase() {
        #expect(refusal(aggregate("[{$lookup: {from: 'system.users', localField: 'a', foreignField: 'b', as: 'u'}}]"))?.path
            == "pipeline.0.$lookup.from")
        #expect(refusal(aggregate("[{$lookup: {from: {db: 'other', coll: 'x'}, localField: 'a', foreignField: 'b', as: 'u'}}]"))?
            .reason.contains("this database") == true)
        #expect(refusal(aggregate("[{$lookup: {from: 'x', db: 'other', localField: 'a', foreignField: 'b', as: 'u'}}]"))?.path
            == "pipeline.0.$lookup.db")
        #expect(refusal(aggregate("[{$graphLookup: {from: 'system.views', startWith: '$a', connectFromField: 'a', connectToField: 'b', as: 'g'}}]"))?.path
            == "pipeline.0.$graphLookup.from")
        #expect(refusal(aggregate("[{$graphLookup: {startWith: '$a', connectFromField: 'a', connectToField: 'b', as: 'g'}}]"))?.path
            == "pipeline.0.$graphLookup.from")
        #expect(refusal(aggregate("[{$unionWith: 'system.profile'}]"))?.path == "pipeline.0.$unionWith")
        #expect(refusal(aggregate("[{$unionWith: {coll: 'x', db: 'admin'}}]"))?.path == "pipeline.0.$unionWith.db")
        #expect(refusal(aggregate("[{$unionWith: {pipeline: []}}]"))?.path == "pipeline.0.$unionWith.coll")
        #expect(refusal(aggregate("[{$facet: {a: [{$unionWith: 'system.js'}]}}]"))?.path == "pipeline.0.$facet.a.0.$unionWith")
        #expect(refusal(aggregate("[{$facet: {a: {$match: {}}}}]"))?.path == "pipeline.0.$facet.a")
        #expect(refusal(aggregate("[{$unionWith: 3}]"))?.path == "pipeline.0.$unionWith")
    }

    // MARK: Stages

    @Test(arguments: ["$changeStream", "$currentOp", "$listSessions", "$listLocalSessions", "$planCacheStats",
                      "$search", "$searchMeta", "$vectorSearch", "$queryStats", "$listSearchIndexes", "$madeUp", "match"])
    func stagesOffTheListAreRefused(stage: String) {
        let pipeline = [doc("{$match: {}}"), BSONDocument([(stage, .document(BSONDocument()))])]
        #expect(refusal(.aggregate(db: "shop", collection: "orders", pipeline: pipeline))?.description
            == "pipeline.1: \(stage) isn't a stage agents may use")
        // Nested too.
        let nested = BSONDocument([("$facet", .document(BSONDocument([("f", .array([.document(pipeline[1])]))])))])
        #expect(refusal(.aggregate(db: "shop", collection: "orders", pipeline: [nested]))?.path == "pipeline.0.$facet.f.0")
    }

    @Test func malformedStagesAreRefused() {
        #expect(refusal(aggregate("[{}]"))?.path == "pipeline.0")
        #expect(refusal(aggregate("[{$match: {}, $limit: 1}]"))?.path == "pipeline.0")
        #expect(refusal(aggregate("[{$lookup: {from: 'x', as: 'y', pipeline: {$match: {}}}}]"))?.path == "pipeline.0.$lookup.pipeline")
        #expect(refusal(aggregate("[{$facet: {a: [5]}}]"))?.path == "pipeline.0.$facet.a.0")
    }

    // MARK: Allowed, with caps

    @Test func allowedFindPassesWithCaps() throws {
        var safety = SafetySettings()
        safety.agentRowCap = 500
        safety.agentTimeout = 12
        let filter = doc("{$and: [{a: {$gt: 1}}, {$expr: {$eq: ['$b', '$c']}}], tags: {$in: ['x', /y/i]}}")
        let request = MongoAgentRequest.find(db: "shop", collection: "orders", filter: filter, projection: doc("{a: 1}"),
                                             sort: doc("{a: -1}"), skip: 5, limit: 100, collation: doc("{locale: 'en'}"),
                                             hint: .string("a_1"))
        let checked = try MongoAgentGuard.check(request, safety: safety)
        #expect(checked.request == request)
        #expect(checked.maxTimeMS == 12_000)
        #expect(checked.documentCap == 500)
        for (asked, got) in [(nil, 500), (0, 500), (499, 499), (501, 500), (Int.max, 500)] as [(Int?, Int)] {
            let c = try MongoAgentGuard.check(.find(db: "shop", collection: "orders", filter: filter, limit: asked), safety: safety)
            #expect(c.request == .find(db: "shop", collection: "orders", filter: filter, limit: got))
        }
        #expect(refusal(.find(db: "shop", collection: "orders", filter: filter, limit: -1))?.path == "limit")
        #expect(refusal(.find(db: "shop", collection: "orders", filter: filter, skip: -1))?.path == "skip")
        #expect(refusal(.find(db: "shop", collection: "orders", filter: filter, hint: .int32(1)))?.path == "hint")
    }

    @Test func allowedPipelinePassesWithALimitAppended() throws {
        let pipeline = stages("""
            [{$match: {status: 'A', $expr: {$gt: ['$qty', 2]}}},
             {$lookup: {from: 'items', let: {id: '$item'}, as: 'i', pipeline: [{$match: {$expr: {$eq: ['$_id', '$$id']}}}]}},
             {$lookup: {as: 'lit', pipeline: [{$documents: [{x: 1}]}]}},
             {$graphLookup: {from: 'people', startWith: '$boss', connectFromField: 'boss', connectToField: 'name', as: 'chain'}},
             {$unionWith: 'archive'}, {$unionWith: {coll: 'old', pipeline: [{$project: {a: 1}}]}},
             {$facet: {byA: [{$sortByCount: '$a'}], buckets: [{$bucketAuto: {groupBy: '$p', buckets: 4}}]}},
             {$group: {_id: '$a', n: {$sum: 1}}}, {$set: {b: 1}}, {$addFields: {c: 2}}, {$unset: 'c'},
             {$unwind: '$tags'}, {$replaceWith: {x: '$a'}}, {$replaceRoot: {newRoot: {y: 1}}},
             {$sort: {n: -1}}, {$skip: 1}, {$limit: 10}, {$sample: {size: 3}}, {$count: 'n'}]
            """)
        let checked = try MongoAgentGuard.check(.aggregate(db: "shop", collection: "orders", pipeline: pipeline))
        let cap = SafetySettings().agentRowCap
        #expect(checked.request == .aggregate(db: "shop", collection: "orders",
                                              pipeline: pipeline + [BSONDocument([("$limit", .int64(Int64(cap)))])]))
        #expect(checked.maxTimeMS == SafetySettings().agentTimeout * 1000)
        for stage in ["{$geoNear: {near: [0, 0], distanceField: 'd', query: {a: 1}}}", "{$collStats: {count: {}}}",
                      "{$indexStats: {}}", "{$redact: '$$KEEP'}", "{$bucket: {groupBy: '$a', boundaries: [0, 5]}}",
                      "{$densify: {field: 'a', range: {step: 1, bounds: 'full'}}}",
                      "{$fill: {output: {a: {value: 0}}}}",
                      "{$setWindowFields: {sortBy: {a: 1}, output: {s: {$sum: '$a'}}}}"] {
            #expect(refusal(aggregate("[\(stage)]")) == nil, "\(stage)")
        }
    }

    @Test func otherRequestsPass() throws {
        var safety = SafetySettings()
        safety.agentRowCap = 50
        let filter = doc("{a: {$exists: true}}")
        for request: MongoAgentRequest in [
            .count(db: "shop", collection: "orders", filter: filter),
            .distinct(db: "shop", collection: "orders", key: "a.b", filter: filter),
            .listDatabases, .listCollections(db: "shop"), .listIndexes(db: "shop", collection: "orders"),
            .stats(db: "shop", collection: nil), .stats(db: "shop", collection: "orders"),
            .schemaSample(db: "shop", collection: "orders", size: 20),
            .find(db: "shop", collection: "System.notReally", filter: filter, limit: 1),
        ] {
            #expect(try MongoAgentGuard.check(request, safety: safety).request == request)
        }
        #expect(try MongoAgentGuard.check(.schemaSample(db: "shop", collection: "orders", size: 1_000), safety: safety).request
            == .schemaSample(db: "shop", collection: "orders", size: 50))
        #expect(refusal(.schemaSample(db: "shop", collection: "orders", size: 0))?.path == "size")
        for key in ["", "$a", "a\0b"] {
            #expect(refusal(.distinct(db: "shop", collection: "orders", key: key, filter: filter))?.path == "key")
        }
    }

    // MARK: Property

    /// Random documents of allowed and forbidden keys, at random depths in documents and arrays: one passes exactly
    /// when it holds no forbidden key and no JavaScript.
    @Test func randomDocumentsPassOnlyWhenClean() {
        var rng = SplitMix(seed: 0xA1A5)
        let allowed = ["a", "b", "$and", "$or", "$expr", "$eq", "$gt", "$in", "$elemMatch", "$not", "$literal", "where", "$$out", "$whereX", "function"]
        func value(_ depth: Int, _ dirty: inout Bool) -> BSONValue {
            switch depth > 4 ? rng.next(4) : rng.next(7) {
            case 0: return .int32(Int32(rng.next(100)))
            case 1: return .string("$where")
            case 2: return .null
            case 3:
                if rng.next(10) == 0 { dirty = true; return rng.next(2) == 0 ? .javascript("1") : .javascriptWithScope(code: "1", scope: BSONDocument()) }
                return .bool(true)
            case 4, 5: return .document(document(depth + 1, &dirty))
            default: return .array((0..<rng.next(4)).map { _ in value(depth + 1, &dirty) })
            }
        }
        func document(_ depth: Int, _ dirty: inout Bool) -> BSONDocument {
            BSONDocument((0..<rng.next(4)).map { _ in
                let key: String
                if rng.next(12) == 0 { key = forbidden[rng.next(forbidden.count)]; dirty = true } else { key = allowed[rng.next(allowed.count)] }
                return (key, value(depth, &dirty))
            })
        }
        var dirtyCount = 0
        for _ in 0..<3_000 {
            var dirty = false
            let filter = document(0, &dirty)
            let passed = refusal(find(filter)) == nil
            #expect(passed == !dirty, "\(filter.shellForm())")
            if dirty {
                dirtyCount += 1
                #expect(refusal(.aggregate(db: "shop", collection: "orders", pipeline: [BSONDocument([("$match", .document(filter))])])) != nil)
            }
        }
        #expect(dirtyCount > 300)
    }
}

/// A small seeded generator, so a failure repeats.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}
