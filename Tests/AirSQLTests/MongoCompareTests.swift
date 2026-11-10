// Compare and reconcile two MongoDB collections (docs/dev/mongo-plan.md, Phase 2 compare): where two documents differ
// (types, key order, ignored paths, arrays), indexes matched by keys, the reconcile's changes; then, against the Mongo
// lab (AIRSQL_MONGO_LAB=1) on the standalone and the replica set and from one to the other, every kind of difference,
// the sorted merge and the $in lookups, 20,000 documents, and a reconcile that applies exactly and stops at a change.
import Foundation
import Testing
@testable import AirSQLCore

private func doc(_ fields: KeyValuePairs<String, BSONValue>) -> BSONDocument {
    BSONDocument(fields.map { ($0.key, $0.value) })
}

struct MongoCompareTests {
    @Test func typesAndValues() {
        let a = doc(["_id": .int32(1), "n": .int32(1), "s": .string("x"), "z": .double(0)])
        #expect(MongoDiff.paths(a, a).isEmpty)
        #expect(MongoDiff.paths(a, doc(["_id": .int32(1), "n": .int64(1), "s": .string("x"), "z": .double(0)])) == ["n"])
        #expect(MongoDiff.paths(a, doc(["_id": .int32(1), "n": .int32(1), "s": .string("x"), "z": .double(-0.0)])) == ["z"])
        #expect(MongoDiff.paths(a, doc(["_id": .int32(1), "n": .int32(1), "s": .string("x")])) == ["z"])
        #expect(MongoDiff.paths(a, doc(["_id": .int32(1), "n": .int32(1), "s": .string("x"), "z": .double(0), "new": .null])) == ["new"])
        // Composed and decomposed é are two keys to BSON.
        #expect(MongoDiff.paths(doc(["\u{e9}": .int32(1)]), doc(["e\u{301}": .int32(1)])).sorted() == ["e\u{301}", "\u{e9}"])
    }

    @Test func keyOrder() {
        let a = doc(["a": .int32(1), "b": .document(doc(["x": .int32(1), "y": .int32(2)]))])
        let b = doc(["b": .document(doc(["y": .int32(2), "x": .int32(1)])), "a": .int32(1)])
        #expect(MongoDiff.paths(a, b) == ["", "b"])
        #expect(MongoDiff.paths(a, b, MongoCompareOptions(ignoreKeyOrder: true)).isEmpty)
        // A field only on one side doesn't make the others' order differ.
        #expect(MongoDiff.paths(a, doc(["a": .int32(1), "c": .int32(3), "b": a["b"]!])) == ["c"])
    }

    @Test func ignoredPathsAndArrays() {
        let a = doc(["_id": .int32(1), "updatedAt": .datetime(1), "items": .array([.document(doc(["price": .int32(5), "seen": .int32(1)])), .int32(2)]),
                     "meta": .document(doc(["at": .int32(1), "by": .string("x")]))])
        let b = doc(["_id": .int32(1), "updatedAt": .datetime(2), "items": .array([.document(doc(["price": .int32(6), "seen": .int32(2)])), .int64(2), .int32(3)]),
                     "meta": .document(doc(["at": .int32(2), "by": .string("x")]))])
        #expect(MongoDiff.paths(a, b) == ["updatedAt", "items.0.price", "items.0.seen", "items.1", "items.2", "meta.at"])
        let options = MongoCompareOptions(ignoredPaths: MongoCompareOptions.paths("updatedAt, items.seen meta.at"))
        #expect(MongoDiff.paths(a, b, options) == ["items.0.price", "items.1", "items.2"])
        // A path covers what is under it, and only it.
        #expect(MongoDiff.paths(a, b, MongoCompareOptions(ignoredPaths: ["items", "meta", "updatedAt"])).isEmpty)
        #expect(MongoDiff.paths(a, b, MongoCompareOptions(ignoredPaths: ["update"])).first == "updatedAt")
        // An array's elements in another order differ; arrays of documents compare inside.
        #expect(MongoDiff.paths(doc(["t": .array([.int32(1), .int32(2)])]), doc(["t": .array([.int32(2), .int32(1)])])) == ["t.0", "t.1"])
        #expect(MongoDiff.paths(doc(["t": .array([])]), doc(["t": .document(BSONDocument())])) == ["t"])
    }

    @Test func itemsAndOrder() throws {
        let a = try doc(["_id": .int32(1), "x": .int32(1)]).bytes()
        #expect(try MongoCompare.item(.int32(1), source: a, target: a, MongoCompareOptions()).status == .same)
        let b = try doc(["_id": .int32(1), "x": .int32(2)]).bytes()
        let item = try MongoCompare.item(.int32(1), source: a, target: b, MongoCompareOptions())
        #expect(item.status == .different && item.paths == ["x"] && item.target?["x"] == .int32(2))
        #expect(try MongoCompare.item(.int32(1), source: a, target: nil, MongoCompareOptions()).status == .onlyInSource)
        #expect(try MongoCompare.order(.string("B"), .string("a")) == -1)
        #expect(try MongoCompare.order(.string("\u{e9}"), .string("z")) == 1)
        #expect(try MongoCompare.order(.int64(-5), .int64(3)) == -1)
        #expect(try MongoCompare.order(.objectId(BSONObjectId(hex: "000000000000000000000002")!), .objectId(BSONObjectId(hex: "000000000000000000000001")!)) == 1)
        #expect(throws: AirSQLError.self) { try MongoCompare.order(.int32(1), .int64(2)) }
    }

    @Test func indexesMatchByKeys() {
        let id = doc(["v": .int32(2), "key": .document(doc(["_id": .int32(1)])), "name": .string("_id_")])
        let a = doc(["v": .int32(2), "key": .document(doc(["a": .int32(1)])), "name": .string("a_1"), "unique": .bool(true)])
        let a2 = doc(["v": .int32(2), "key": .document(doc(["a": .int64(1)])), "name": .string("byA")])
        let b = doc(["v": .int32(2), "key": .document(doc(["b": .int32(-1)])), "name": .string("b_-1")])
        let c = doc(["v": .int32(2), "key": .document(doc(["c": .string("text")])), "name": .string("c_text")])
        let found = MongoCompare.indexes([id, a, b], [c, a2, id])
        #expect(found.map(\.status) == [.same, .different, .onlyInSource, .onlyInTarget])
        #expect(found[1].paths == ["unique"])
    }

    @Test func reconcileChanges() throws {
        var result = MongoCompareResult(options: MongoCompareOptions(), sourceName: "s.c", targetName: "t.c")
        let new = doc(["_id": .int32(1), "x": .int32(1)]), old = doc(["_id": .int32(2), "x": .int32(1)]), now = doc(["_id": .int32(2), "x": .int32(2)])
        let gone = doc(["_id": .int32(3)]), odd = doc(["_id": .int32(4), "a.b": .int32(1)])
        result.add(.init(id: .int32(1), status: .onlyInSource, source: new))
        result.add(.init(id: .int32(2), status: .different, source: now, target: old, paths: ["x"]))
        result.add(.init(id: .int32(3), status: .onlyInTarget, target: gone))
        result.add(.init(id: .int32(4), status: .onlyInSource, source: odd))
        result.add(.init(id: .int32(5), status: .same))
        #expect(result.count(.onlyInSource) == 2 && result.same == [.int32(5)] && result.items.count == 4)
        let (changes, skipped) = try result.changes(database: "t", collection: "c", inserts: true, replaces: true, deletes: false)
        #expect(changes.inserts == [new] && changes.replaces.map(\.new) == [now] && changes.deletes.isEmpty)
        #expect(skipped.count == 1 && skipped[0].contains("_id: 4"))
        #expect(changes.preview == [
            #"db.getSiblingDB("t").getCollection("c").findOne({ _id: 2 }, {}, { collation: { locale: "simple" } })  // must be exactly as compared"#,
            #"db.getSiblingDB("t").getCollection("c").replaceOne({ _id: 2 }, { _id: 2, x: 2 }, { collation: { locale: "simple" } })"#,
            #"db.getSiblingDB("t").getCollection("c").insertOne({ _id: 1, x: 1 })"#,
        ])
        let all = try result.changes(database: "t", collection: "c", inserts: false, replaces: false, deletes: true).changes
        #expect(all.deletes == [gone] && all.inserts.isEmpty && all.replaces.isEmpty)
        // Stopped after the replace: the insert is left.
        var rest = changes
        rest.dropApplied(1)
        #expect(rest.replaces.isEmpty && rest.inserts.count == 1)
        // A view's documents aren't written.
        result.targetKind = .view
        #expect(throws: AirSQLError.self) { try result.changes(database: "t", collection: "c", inserts: true, replaces: true, deletes: false) }
    }
}

// MARK: The lab

@Suite(.serialized, .enabled(if: MongoLab.enabled, "Mongo lab: AIRSQL_MONGO_LAB=1 ./test.sh --filter MongoCompare"))
struct MongoCompareLabTests {
    static let source = "lane_mongo_compare_a", target = "lane_mongo_compare_b"

    private static func solo() -> MongoConnection {
        MongoConnection(uri: "mongodb://127.0.0.1:\(MongoLab.soloPort)/", user: "airsql", password: "airsql-pass",
                        route: MongoRoute(SavedConnection(name: "Mongo lab", host: "127.0.0.1", port: MongoLab.soloPort, user: "airsql", route: .direct)),
                        name: "Mongo solo")
    }

    private static func replicaSet() -> MongoConnection {
        var set = SavedConnection(name: "Mongo lab", host: MongoLab.members[0], port: 27017, user: "airsql", route: .proxy)
        let proxy = Lab.socksProxy
        set.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: proxy.port, user: proxy.user)
        return MongoConnection(uri: MongoLab.allSeeds, user: "airsql", password: "airsql-pass", tls: MongoLab.tls,
                               route: MongoRoute(set, proxyPassword: proxy.password), name: "Mongo rs0")
    }

    /// Source and target on the standalone, on the replica set, and from the standalone to the replica set: each pair's
    /// sessions, the target's own data session (Apply's) and whether it is atomic.
    private func eachPair(_ body: (_ source: MongoSession, _ target: MongoSession, _ atomic: Bool) async throws -> Void) async throws {
        for pair in ["solo", "rs", "solo→rs"] {
            let (a, b) = pair == "solo" ? (Self.solo(), nil) : pair == "rs" ? (Self.replicaSet(), nil) : (Self.solo(), Self.replicaSet())
            try await a.connect()
            let info = try await (b ?? a).connect()
            let source = try await a.session(.main), target = try await (b ?? a).session(.data)
            for (session, database) in [(source, Self.source), (target, Self.target)] {
                _ = try await session.command(doc(["dropDatabase": .int32(1)]), database: database)
            }
            do {
                try await body(source, target, MongoApply.isAtomic(info))
            } catch {
                Issue.record("\(pair): \(error)")
            }
            for (session, database) in [(source, Self.source), (target, Self.target)] {
                _ = try? await session.command(doc(["dropDatabase": .int32(1)]), database: database)
            }
            await a.close()
            await b?.close()
        }
    }

    private func fill(_ session: MongoSession, _ database: String, _ documents: [BSONDocument]) async throws {
        _ = try await session.command(doc(["create": .string("c")]), database: database)
        if !documents.isEmpty { _ = try await session.insertMany(database: database, collection: "c", documents) }
    }

    private func compare(_ source: MongoSession, _ target: MongoSession, _ options: MongoCompareOptions = MongoCompareOptions()) async throws -> MongoCompareResult {
        try await MongoCompare.run(source: MongoCompareSide(session: source, database: Self.source, collection: "c"),
                                   target: MongoCompareSide(session: target, database: Self.target, collection: "c"), options: options)
    }

    private func all(_ session: MongoSession, _ database: String) async throws -> [BSONDocument] {
        try await session.all(session.find(database: database, collection: "c", MongoFind(sort: doc(["_id": .int32(1)]))))
    }

    @Test func equalCollectionsAndEveryKindOfDifference() async throws {
        try await eachPair { source, target, _ in
            let base = (0..<10).map { doc(["_id": .int32(Int32($0)), "n": .int32(Int32($0)), "at": .datetime(Int64($0))]) }
            try await fill(source, Self.source, base)
            try await fill(target, Self.target, base)
            var same = try await compare(source, target)
            #expect(same.merged && !same.differs && same.count(.same) == 10 && same.items.isEmpty)
            // Only in the target, a number's type, key order, an ignored field.
            _ = try await target.insertMany(database: Self.target, collection: "c", [doc(["_id": .int32(50)])])
            _ = try await target.deleteOne(database: Self.target, collection: "c", filter: doc(["_id": .int32(0)]))
            _ = try await target.updateOne(database: Self.target, collection: "c", filter: doc(["_id": .int32(1)]), update: doc(["$set": .document(doc(["n": .int64(1)]))]))
            _ = try await target.replaceOne(database: Self.target, collection: "c", filter: doc(["_id": .int32(2)]),
                                            replacement: doc(["_id": .int32(2), "at": .datetime(2), "n": .int32(2)]))
            _ = try await target.updateOne(database: Self.target, collection: "c", filter: doc(["_id": .int32(3)]), update: doc(["$set": .document(doc(["at": .datetime(99)]))]))
            _ = try await target.createIndex(database: Self.target, collection: "c", keys: doc(["n": .int32(1)]))
            same = try await compare(source, target)
            #expect(same.count(.onlyInSource) == 1 && same.count(.onlyInTarget) == 1 && same.count(.different) == 3 && same.count(.same) == 6)
            #expect(same.items.map(\.id) == [.int32(0), .int32(1), .int32(2), .int32(3), .int32(50)])
            #expect(same.items.first { $0.id == .int32(1) }?.paths == ["n"] && same.items.first { $0.id == .int32(2) }?.paths == [""])
            #expect(same.indexes.map(\.status) == [.same, .onlyInTarget])
            let lenient = try await compare(source, target, MongoCompareOptions(ignoreKeyOrder: true, ignoredPaths: ["at"]))
            #expect(lenient.count(.different) == 1 && lenient.count(.same) == 8)
            // A validator differs; a target that doesn't exist yet has every document only in the source.
            _ = try await target.command(doc(["collMod": .string("c"), "validator": .document(doc(["n": .document(doc(["$type": .string("int")]))]))]), database: Self.target)
            #expect(try await compare(source, target).optionPaths.contains("validator"))
            _ = try await target.command(doc(["drop": .string("c")]), database: Self.target)
            let empty = try await compare(source, target)
            #expect(empty.count(.onlyInSource) == 10 && empty.targetOptions == nil && empty.indexes.allSatisfy { $0.status == .onlyInSource })
        }
    }

    @Test func mixedIdTypesAreLookedUp() async throws {
        try await eachPair { source, target, _ in
            let oid = BSONObjectId.generate()
            try await fill(source, Self.source, [doc(["_id": .int32(1)]), doc(["_id": .string("1")]), doc(["_id": .objectId(oid)]),
                                                 doc(["_id": .document(doc(["k": .int32(1)])), "v": .int32(1)])])
            try await fill(target, Self.target, [doc(["_id": .int64(1)]), doc(["_id": .string("1")]), doc(["_id": .objectId(oid)]),
                                                 doc(["_id": .document(doc(["k": .int32(1)])), "v": .int32(2)])])
            let result = try await compare(source, target)
            // NumberLong(1) is another _id than 1, though $in finds it.
            #expect(!result.merged)
            #expect(result.count(.onlyInSource) == 1 && result.count(.onlyInTarget) == 1 && result.count(.different) == 1 && result.count(.same) == 2)
            #expect(result.items.first { $0.status == .onlyInTarget }?.id == .int64(1))
        }
    }

    @Test func twentyThousandDocumentsStayBounded() async throws {
        try await eachPair { source, target, _ in
            let documents = (0..<20_000).map { doc(["_id": .int32(Int32($0)), "name": .string("item \($0)"), "n": .double(Double($0) / 3)]) }
            try await fill(source, Self.source, documents)
            try await fill(target, Self.target, documents.enumerated().map { $0.offset % 1_000 == 0 ? doc(["_id": $0.element["_id"]!, "changed": .bool(true)]) : $0.element })
            let started = Date()
            let result = try await compare(source, target)
            #expect(result.merged && result.count(.different) == 20 && result.count(.same) == 19_980 && result.items.count == 20)
            #expect(result.same.count == MongoCompare.keep)
            #expect(Date().timeIntervalSince(started) < 60)
        }
    }

    @Test func reconcileAppliesExactlyAndStopsAtAChange() async throws {
        try await eachPair { source, target, atomic in
            try await fill(source, Self.source, [doc(["_id": .int32(1), "n": .int32(1)]), doc(["_id": .int32(2), "n": .int32(2)]),
                                                 doc(["_id": .int32(3), "n": .int32(3)])])
            try await fill(target, Self.target, [doc(["_id": .int32(2), "n": .int64(2)]), doc(["_id": .int32(3), "n": .int32(30)]),
                                                 doc(["_id": .int32(4)])])
            var result = try await compare(source, target)
            // Deletes are off unless asked: the document only in the target stays.
            var (changes, _) = try result.changes(database: Self.target, collection: "c", inserts: true, replaces: true, deletes: false)
            #expect(changes.steps.count == 3)
            // Someone changes a compared document before Apply: it isn't overwritten.
            _ = try await target.updateOne(database: Self.target, collection: "c", filter: doc(["_id": .int32(3)]), update: doc(["$set": .document(doc(["n": .int32(31)]))]))
            let stopped = await MongoApply.run(changes, on: target, atomic: atomic)
            #expect(stopped.outcome == .stopped && stopped.message.contains("changed by someone else"))
            #expect(try await all(target, Self.target).first { $0["_id"] == .int32(3) }?["n"] == .int32(31))
            #expect(try await all(target, Self.target).count == 3)
            // Compared again, it applies exactly: types kept, the extra document still there.
            result = try await compare(source, target)
            (changes, _) = try result.changes(database: Self.target, collection: "c", inserts: true, replaces: true, deletes: false)
            let report = await MongoApply.run(changes, on: target, atomic: atomic)
            #expect(report.outcome == .applied, "\(report.message)")
            let now = try await all(target, Self.target)
            #expect(Array(now.prefix(3)) == (try await all(source, Self.source)) && now.count == 4)
            // With deletes, the two match.
            result = try await compare(source, target)
            changes = try result.changes(database: Self.target, collection: "c", inserts: true, replaces: true, deletes: true).changes
            #expect(await MongoApply.run(changes, on: target, atomic: atomic).outcome == .applied)
            #expect(try await !compare(source, target).differs)
        }
    }
}
