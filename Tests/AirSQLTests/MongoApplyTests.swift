// Safe Apply for MongoDB documents (docs/dev/mongo-plan.md, Safe editing): the rules, the commands and their preview;
// then, against the Mongo lab (AIRSQL_MONGO_LAB=1) on the standalone and the replica set, types kept, conflicts found
// (1 vs 1.0 vs NumberLong(1), null vs missing, a case-insensitive collation), all or nothing in a transaction and the
// partial report on a standalone.
import Foundation
import Testing
@testable import AirSQLCore

private func doc(_ fields: KeyValuePairs<String, BSONValue>) -> BSONDocument {
    BSONDocument(fields.map { ($0.key, $0.value) })
}

private func reason(_ body: () throws -> Void) -> String? {
    do { try body() } catch { return (error as? AirSQLError)?.message }
    return nil
}

struct MongoApplyTests {
    private let person = doc(["_id": .int32(1), "name": .string("Ann"), "n": .int32(1), "tags": .array([.string("a")]),
                              "address": .document(doc(["city": .string("Oslo"), "zip": .null])), "odd.key": .int32(0)])

    @Test func theRulesRefuseWithReasons() {
        var changes = MongoChanges(database: "shop", collection: "people", kind: .collection)
        #expect(reason { try changes.edit(person, path: ["_id"], to: .int32(2)) }?.contains("_id is read-only") == true)
        #expect(reason { try changes.edit(person, path: ["odd.key"], to: .int32(1)) }?.contains("holds . or $") == true)
        #expect(reason { try changes.edit(person, path: ["tags", "0"], to: .string("b")) }?.contains("tags is an array") == true)
        #expect(reason { try changes.edit(person, path: ["name", "x"], to: .int32(1)) }?.contains("not a sub-document") == true)
        #expect(reason { try changes.edit(person, path: ["n"], to: .double(2)) }?.contains("from int to double") == true)
        #expect(reason { try changes.edit(person, path: ["n"], to: .document(doc(["$set": .int32(1)]))) } != nil)
        #expect(reason { try changes.edit(doc(["x": .int32(1)]), path: ["x"], to: .int32(2)) }?.contains("no _id") == true)
        #expect(reason { try changes.edit(doc(["_id": .int32(9), "s": .symbol("x")]), path: ["s"], to: .symbol("y")) }?
            .contains("deprecated") == true)
        #expect(reason { try changes.insert(doc(["a": .document(doc(["b.c": .int32(1)]))])) } != nil)
        #expect(changes.isEmpty)

        // Allowed: an explicit type change, null and missing either way, a whole array, a new nested field.
        #expect(reason { try changes.edit(person, path: ["n"], to: .int64(1), changingType: true) } == nil)
        #expect(reason { try changes.edit(person, path: ["address", "zip"], to: .string("0150")) } == nil)
        #expect(reason { try changes.edit(person, path: ["name"], to: .null) } == nil)
        #expect(reason { try changes.edit(person, path: ["tags"], to: .array([])) } == nil)
        #expect(reason { try changes.edit(person, path: ["extra", "deep"], to: .bool(true)) } == nil)
        #expect(changes.edits.count == 1 && changes.edits[0].edits.count == 5)
        // An outer field and one inside it can't both change.
        #expect(reason { try changes.edit(person, path: ["address"], to: .null) }?.contains("address.zip is already changed") == true)
        // Back to the loaded value: no edit.
        try? changes.edit(person, path: ["name"], to: .string("Ann"))
        #expect(changes.edits[0].edits.map(\.path) == [["n"], ["address", "zip"], ["tags"], ["extra", "deep"]])

        for kind in [MongoCollectionInfo.Kind.view, .timeseries] {
            var other = MongoChanges(database: "shop", collection: "v", kind: kind)
            let words = kind == .view ? "is a view" : "time-series"
            #expect(reason { try other.edit(person, path: ["name"], to: .string("B")) }?.contains(words) == true)
            #expect(reason { try other.insert(doc(["a": .int32(1)])) }?.contains(words) == true)
            #expect(reason { try other.delete(person) }?.contains(words) == true)
        }
    }

    @Test func commandsAndTheirPreview() throws {
        var changes = MongoChanges(database: "shop", collection: "people", kind: .collection)
        try changes.edit(person, path: ["name"], to: .string("Bo"))
        try changes.edit(person, path: ["address", "zip"], to: nil)
        try changes.edit(person, path: ["extra"], to: .int64(5))
        try changes.insert(doc(["_id": .int32(2)]))
        let gone = doc(["_id": .string("x"), "re": .regex(pattern: "^a", options: "i")])
        try changes.delete(gone)
        let edit = changes.edits[0].edits
        #expect(MongoApplyStep.filter(id: .int32(1), edits: edit).shellForm()
                == #"{ _id: 1, name: { $eq: "Ann" }, name: { $type: "string" }, "address.zip": { $eq: null }, "address.zip": { $type: "null" }, extra: { $exists: false } }"#)
        #expect(MongoApplyStep.update(edit).shellForm() == #"{ $set: { name: "Bo", extra: NumberLong(5) }, $unset: { "address.zip": "" } }"#)
        #expect(changes.preview == [
            #"db.getSiblingDB("shop").getCollection("people").findOne({ _id: "x" }, {}, { collation: { locale: "simple" } })  // must be exactly as loaded"#,
            #"db.getSiblingDB("shop").getCollection("people").deleteOne({ _id: "x" }, { collation: { locale: "simple" } })"#,
            #"db.getSiblingDB("shop").getCollection("people").findOne({ _id: 1 }, {}, { collation: { locale: "simple" } })  // its old values must be exactly as loaded"#,
            #"db.getSiblingDB("shop").getCollection("people").updateOne({ _id: 1, name: { $eq: "Ann" }, name: { $type: "string" }, "address.zip": { $eq: null }, "address.zip": { $type: "null" }, extra: { $exists: false } }, { $set: { name: "Bo", extra: NumberLong(5) }, $unset: { "address.zip": "" } }, { collation: { locale: "simple" } })"#,
            #"db.getSiblingDB("shop").getCollection("people").insertOne({ _id: 2 })"#,
        ])
        // Deleting forgets the document's edits.
        try changes.delete(person)
        #expect(changes.edits.isEmpty && changes.deletes.count == 2)
        #expect(MongoApply.isAtomic(MongoServerInfo(version: "7.0", setName: "rs0")))
        #expect(MongoApply.isAtomic(MongoServerInfo(version: "7.0", isMongos: true)))
        #expect(!MongoApply.isAtomic(MongoServerInfo(version: "7.0")))
    }
}

@Suite(.serialized, .enabled(if: MongoLab.enabled, "Mongo lab: AIRSQL_MONGO_LAB=1 ./test.sh --filter MongoApply"))
struct MongoApplyLabTests {
    static let database = "lane_mongo_apply"

    /// The standalone directly, and the replica set through the SOCKS proxy.
    private func both() -> [(MongoConnection, atomic: Bool)] {
        let solo = SavedConnection(name: "Mongo lab", host: "127.0.0.1", port: MongoLab.soloPort, user: "airsql", route: .direct)
        var set = SavedConnection(name: "Mongo lab", host: MongoLab.members[0], port: 27017, user: "airsql", route: .proxy)
        let proxy = Lab.socksProxy
        set.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: proxy.port, user: proxy.user)
        return [
            (MongoConnection(uri: "mongodb://127.0.0.1:\(MongoLab.soloPort)/", user: "airsql", password: "airsql-pass",
                             route: MongoRoute(solo), name: "Mongo lab"), false),
            (MongoConnection(uri: MongoLab.allSeeds, user: "airsql", password: "airsql-pass", tls: MongoLab.tls,
                             route: MongoRoute(set, proxyPassword: proxy.password), name: "Mongo lab"), true),
        ]
    }

    /// Each server with a fresh `collection` holding `documents`: its data session (Apply's) and its main one (someone else).
    private func eachServer(_ collection: String, _ documents: [BSONDocument], collation: BSONDocument? = nil,
                            _ body: (_ data: MongoSession, _ other: MongoSession, _ atomic: Bool) async throws -> Void) async throws {
        for (connection, atomic) in both() {
            let info = try await connection.connect()
            #expect(MongoApply.isAtomic(info) == atomic)
            let data = try await connection.session(.data), other = try await connection.session(.main)
            _ = try? await data.command(doc(["drop": .string(collection)]), database: Self.database)
            var create: [(key: String, value: BSONValue)] = [("create", .string(collection))]
            if let collation { create.append(("collation", .document(collation))) }
            _ = try await data.command(BSONDocument(create), database: Self.database)
            if !documents.isEmpty { _ = try await data.insertMany(database: Self.database, collection: collection, documents) }
            try await body(data, other, atomic)
            _ = try await data.command(doc(["dropDatabase": .int32(1)]), database: Self.database)
            await connection.close()
        }
    }

    private func all(_ session: MongoSession, _ collection: String) async throws -> [BSONDocument] {
        try await session.find(database: Self.database, collection: collection, MongoFind(sort: doc(["_id": .int32(1)])))
            .next().map { try BSONDocument(bytes: $0) }
    }

    private func changeSet(_ collection: String) -> MongoChanges {
        MongoChanges(database: Self.database, collection: collection, kind: .collection)
    }

    private func set(_ other: MongoSession, _ collection: String, _ id: BSONValue, _ update: BSONDocument) async throws {
        _ = try await other.updateOne(database: Self.database, collection: collection, filter: doc(["_id": id]), update: update)
    }

    /// Every BSON type of the fixture goes in as a new field and keeps its type; then each is removed, which its old
    /// value's filter ($eq and $type) must match on the server: a regex, NaN, a decimal, MinKey…
    @Test func everyTypeKeepsItsType() async throws {
        try await eachServer("types", [doc(["_id": .int32(1)])]) { data, _, _ in
            let every = try await data.find(database: "fixture", collection: "all_types", MongoFind(filter: doc(["_id": .int32(100)])))
                .next().map { try BSONDocument(bytes: $0) }.first!
            let values = every.fields.filter { $0.key != "_id" } + [("nan", .double(.nan)), ("negativeZero", .double(-0.0))]
            var adding = changeSet("types")
            for (key, value) in values { try adding.edit(doc(["_id": .int32(1)]), path: [key], to: value) }
            let added = await MongoApply.run(adding, on: data, atomic: false)
            #expect(added.outcome == .applied && added.applied == 1, "\(added.message)")
            let loaded = try await all(data, "types")[0]
            // $set adds new fields in name order: each one's value and type are what count.
            #expect(loaded.fields.count == values.count + 1, "\(loaded.shellForm())")
            for (key, value) in values { #expect(loaded[key] == value, "\(key): \(loaded[key]?.shellForm() ?? "missing")") }

            var removing = changeSet("types")
            for (key, _) in values { try removing.edit(loaded, path: [key], to: nil) }
            let removed = await MongoApply.run(removing, on: data, atomic: false)
            #expect(removed.outcome == .applied, "\(removed.message)")
            #expect(try await all(data, "types")[0].typeExactEqual(doc(["_id": .int32(1)])))
        }
    }

    /// Someone changes 1 to 1.0 or NumberLong(1), the same number of another type: Apply finds it, and so does the
    /// update's filter on its own.
    @Test func aNumbersTypeChangeIsAConflict() async throws {
        let loaded = doc(["_id": .int32(1), "n": .int32(1)])
        try await eachServer("numbers", [loaded]) { data, other, atomic in
            for changed in [BSONValue.double(1), .int64(1), .decimal128(BSONDecimal128("1")!)] {
                try await set(other, "numbers", .int32(1), doc(["$set": .document(doc(["n": changed]))]))
                var changes = changeSet("numbers")
                try changes.edit(loaded, path: ["n"], to: .int32(2))
                let report = await MongoApply.run(changes, on: data, atomic: atomic)
                #expect(report.outcome == .stopped && report.applied == 0 && report.failedStep == 0)
                #expect(report.message.contains("{ _id: 1 }") && report.message.contains("n was changed by someone else"), "\(report.message)")
                #expect(try await all(data, "numbers")[0]["n"] == changed)
                let stale = try await data.updateOne(database: Self.database, collection: "numbers",
                                                     filter: MongoApplyStep.filter(id: .int32(1), edits: changes.edits[0].edits),
                                                     update: MongoApplyStep.update(changes.edits[0].edits), collation: MongoApplyStep.simple)
                #expect(stale.matched == 0)
            }
        }
    }

    /// Null and missing are not the same: each turning into the other is a conflict.
    @Test func nullIsNotMissing() async throws {
        let loaded = doc(["_id": .int32(1), "a": .null])
        try await eachServer("nulls", [loaded]) { data, other, atomic in
            var changes = changeSet("nulls")
            try changes.edit(loaded, path: ["a"], to: .string("x"))
            try changes.edit(loaded, path: ["b"], to: .string("y"))
            let edits = changes.edits[0].edits
            for change in [doc(["$unset": .document(doc(["a": .string("")]))]), doc(["$set": .document(doc(["a": .null, "b": .null]))])] {
                try await set(other, "nulls", .int32(1), change)
                let report = await MongoApply.run(changes, on: data, atomic: atomic)
                #expect(report.outcome == .stopped && report.message.contains("changed by someone else"), "\(report.message)")
                let stale = try await data.updateOne(database: Self.database, collection: "nulls",
                                                     filter: MongoApplyStep.filter(id: .int32(1), edits: edits),
                                                     update: MongoApplyStep.update(edits), collation: MongoApplyStep.simple)
                #expect(stale.matched == 0)
            }
            // As loaded again, it applies.
            try await set(other, "nulls", .int32(1), doc(["$unset": .document(doc(["b": .string("")]))]))
            let report = await MongoApply.run(changes, on: data, atomic: atomic)
            #expect(report.outcome == .applied, "\(report.message)")
            #expect(try await all(data, "nulls")[0] == doc(["_id": .int32(1), "a": .string("x"), "b": .string("y")]))
        }
    }

    /// A collection whose collation ignores case: "Alice" is not "alice" to Apply, nor to its filter, nor its _id.
    @Test func aCaseInsensitiveCollationDoesNotHideAChange() async throws {
        let loaded = doc(["_id": .string("a"), "name": .string("alice")])
        try await eachServer("names", [loaded], collation: doc(["locale": .string("en"), "strength": .int32(2)])) { data, other, atomic in
            try await set(other, "names", .string("a"), doc(["$set": .document(doc(["name": .string("Alice")]))]))
            var changes = changeSet("names")
            try changes.edit(loaded, path: ["name"], to: .string("Alicia"))
            let report = await MongoApply.run(changes, on: data, atomic: atomic)
            #expect(report.outcome == .stopped && report.message.contains("changed by someone else"), "\(report.message)")
            let edits = changes.edits[0].edits
            let simple = try await data.updateOne(database: Self.database, collection: "names",
                                                  filter: MongoApplyStep.filter(id: .string("a"), edits: edits),
                                                  update: doc(["$set": .document(doc(["name": .string("Alice")]))]),
                                                  collation: MongoApplyStep.simple)
            #expect(simple.matched == 0)
            // The collection's own collation would have let it through.
            let own = try await data.updateOne(database: Self.database, collection: "names",
                                               filter: MongoApplyStep.filter(id: .string("a"), edits: edits),
                                               update: doc(["$set": .document(doc(["name": .string("Alice")]))]))
            #expect(own.matched == 1)
            // An _id that differs only in case is another document.
            var wrongCase = changeSet("names")
            try wrongCase.edit(doc(["_id": .string("A"), "name": .string("Alice")]), path: ["name"], to: .string("x"))
            let missing = await MongoApply.run(wrongCase, on: data, atomic: atomic)
            #expect(missing.outcome == .stopped && missing.message.contains("deleted by someone else"), "\(missing.message)")
            #expect(try await all(data, "names") == [doc(["_id": .string("a"), "name": .string("Alice")])])
        }
    }

    /// Two edits and an insert, the second document changed by someone else: on the replica set nothing is applied;
    /// on the standalone the first edit stays, and the report says so.
    @Test func aConflictStopsApply() async throws {
        let one = doc(["_id": .int32(1), "v": .string("one")]), two = doc(["_id": .int32(2), "v": .string("two")])
        try await eachServer("conflict", [one, two]) { data, other, atomic in
            var changes = changeSet("conflict")
            try changes.edit(one, path: ["v"], to: .string("ONE"))
            try changes.edit(two, path: ["v"], to: .string("TWO"))
            try changes.insert(doc(["_id": .int32(3)]))
            try await set(other, "conflict", .int32(2), doc(["$set": .document(doc(["v": .string("theirs")]))]))
            let report = await MongoApply.run(changes, on: data, atomic: atomic)
            #expect(report.outcome == .stopped && report.failedStep == 1 && report.total == 3)
            #expect(report.message.contains("{ _id: 2 }"), "\(report.message)")
            let now = try await all(data, "conflict")
            if atomic {
                #expect(report.applied == 0 && report.message.hasSuffix("Nothing was applied."), "\(report.message)")
                #expect(now == [one, doc(["_id": .int32(2), "v": .string("theirs")])])
            } else {
                #expect(report.applied == 1 && report.message.contains("The 1 change before it was applied; the 2 from it on weren't."),
                        "\(report.message)")
                #expect(now == [doc(["_id": .int32(1), "v": .string("ONE")]), doc(["_id": .int32(2), "v": .string("theirs")])])
            }
            #expect(!data.inTransaction)
        }
    }

    /// A delete goes only while the document is exactly as loaded.
    @Test func deleteChecksTheDocumentFirst() async throws {
        let one = doc(["_id": .int32(1), "n": .int32(1)]), two = doc(["_id": .int32(2), "n": .int32(2)])
        try await eachServer("deletes", [one, two]) { data, other, atomic in
            try await set(other, "deletes", .int32(1), doc(["$set": .document(doc(["note": .string("new")]))]))
            var changes = changeSet("deletes")
            try changes.delete(one)
            let refused = await MongoApply.run(changes, on: data, atomic: atomic)
            #expect(refused.outcome == .stopped && refused.message.contains("changed by someone else"), "\(refused.message)")
            #expect(try await all(data, "deletes").count == 2)
            var unchanged = changeSet("deletes")
            try unchanged.delete(two)
            #expect(await MongoApply.run(unchanged, on: data, atomic: atomic).outcome == .applied)
            #expect(try await all(data, "deletes").map { $0["_id"] } == [.int32(1)])
        }
    }

    /// Inserts, deletes and edits (nested, removed, a whole array, an explicit type change) together.
    @Test func aMixApplies() async throws {
        let one = doc(["_id": .int32(1), "a": .document(doc(["b": .int32(1), "c": .string("x")])), "list": .array([.int32(1)])])
        let two = doc(["_id": .int32(2)])
        try await eachServer("mix", [one, two]) { data, _, atomic in
            var changes = changeSet("mix")
            try changes.edit(one, path: ["a", "b"], to: .int64(2), changingType: true)
            try changes.edit(one, path: ["a", "c"], to: nil)
            try changes.edit(one, path: ["list"], to: .array([.int32(1), .string("2")]))
            try changes.delete(two)
            try changes.insert(doc(["_id": .int32(3), "when": .datetime(0)]))
            try changes.insert(doc(["noId": .bool(true)]))
            let report = await MongoApply.run(changes, on: data, atomic: atomic)
            #expect(report.outcome == .applied && report.applied == 4 && report.message == "Applied 4 changes.", "\(report.message)")
            let now = try await all(data, "mix")
            #expect(now.count == 3)
            #expect(now.contains(doc(["_id": .int32(1), "a": .document(doc(["b": .int64(2)])), "list": .array([.int32(1), .string("2")])])))
            #expect(now.contains(doc(["_id": .int32(3), "when": .datetime(0)])))
            #expect(now.contains { $0["noId"] == .bool(true) && $0["_id"] != nil })
            // A duplicate _id stops it with the server's words.
            var again = changeSet("mix")
            try again.insert(doc(["_id": .int32(3)]))
            let duplicate = await MongoApply.run(again, on: data, atomic: atomic)
            #expect(duplicate.outcome == .stopped && duplicate.message.contains("same key"), "\(duplicate.message)")
        }
    }

    /// The fixture's view and time-series collection, as listCollections names them, are read-only.
    @Test func viewsAndTimeSeriesAreReadOnly() async throws {
        for (connection, _) in both() {
            try await connection.connect()
            let collections = try await connection.session(.main).listCollections(database: "fixture")
            for name in ["all_types_names", "readings"] {
                let info = try #require(collections.first { $0.name == name })
                var changes = MongoChanges(database: "fixture", collection: name, kind: info.kind)
                #expect(reason { try changes.insert(doc(["x": .int32(1)])) }?.contains("read-only") == true)
            }
            await connection.close()
        }
    }
}
