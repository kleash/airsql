// What completion and agents know of MongoDB: its words (MongoWords) and the collections' samples (MongoSampleCache):
// lookups, and the cache's fill, single flight, invalidation and bounds with a fake fill; the lab's fill with
// AIRSQL_MONGO_LAB=1.
import Foundation
import Testing
@testable import AirSQLCore

struct MongoWordsTests {
    @Test func lookups() throws {
        #expect(MongoWords.query(for: "string").contains { $0.name == "$regex" })
        #expect(!MongoWords.query(for: "int").contains { $0.name == "$regex" })
        #expect(Set(MongoWords.query(for: "array").map(\.name)).isSuperset(of: ["$size", "$all", "$elemMatch", "$in"]))
        #expect(MongoWords.query(for: "date").contains { $0.name == "$gte" })
        #expect(!MongoWords.query(for: nil).contains { $0.topLevel || $0.name == "$regex" }, "a field of unknown type: any-type operators")
        #expect(MongoWords.named("$or", kind: .query).first?.topLevel == true)
        #expect(MongoWords.update(for: "long").contains { $0.name == "$inc" } && !MongoWords.update(for: "string").contains { $0.name == "$inc" })

        let lookup = try #require(MongoWords.stage("$lookup"))
        #expect(lookup.slot("from") == .collection && lookup.slot("foreignField") == .field && lookup.slot("pipeline") == .pipeline)
        #expect(MongoWords.stage("$match")?.argument == .query && MongoWords.stage("$group")?.argument == .accumulators)
        #expect(MongoWords.stage("$unionWith")?.slot("coll") == .collection)
        #expect(MongoWords.stage("$nope") == nil)

        #expect(MongoWords.named("$sum").map(\.kind) == [.expression, .accumulator])
        #expect(MongoWords.accumulators(in: "$group").contains { $0.name == "$push" })
        #expect(!MongoWords.accumulators(in: "$group").contains { $0.name == "$rank" })
        #expect(MongoWords.accumulators(in: "$setWindowFields").contains { $0.name == "$rank" })
        #expect(!MongoWords.expressions.contains { $0.name == "$push" }, "$push is an accumulator only")
        #expect(Set(MongoWords.variables.map(\.name)).isSuperset(of: ["$$ROOT", "$$NOW", "$$REMOVE", "$$CURRENT"]))

        let fill = try #require(MongoWords.stage("$fill"))
        #expect(fill.since == "5.3" && !fill.isAvailable(on: "5.0.2") && fill.isAvailable(on: "7.0.45") && fill.isAvailable(on: "5.3"))
        #expect(MongoWords.stage("$match")?.isAvailable(on: "4.4.0") == true)
        #expect(MongoWords.all.allSatisfy { !$0.summary.isEmpty && !$0.summary.hasSuffix(".") })
        for kind in [MongoWord.Kind.query, .update, .stage, .expression, .accumulator, .variable] {
            let names = MongoWords.all.filter { $0.kind == kind }.map(\.name)
            #expect(names.count == Set(names).count, "\(kind) names once each")
        }
    }

    /// The agents' allow-list is the guard's own, narrower on purpose; every name on it is a stage the table knows.
    @Test func guardStagesAreWords() {
        #expect(MongoAgentGuard.allowedStages.allSatisfy { MongoWords.stage($0) != nil })
        #expect(MongoWords.stage("$out") != nil && !MongoAgentGuard.allowedStages.contains("$out"))
    }
}

struct MongoSampleCacheTests {
    /// A fill that counts its reads and takes `delay` seconds.
    final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        private var _reads: [String] = []
        var reads: [String] { lock.locked { _reads } }
        let delay: Double
        init(delay: Double = 0) { self.delay = delay }

        func cache() -> MongoSampleCache {
            MongoSampleCache { [self] database, collection in
                lock.locked { _reads.append(database + "." + collection) }
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
                let documents = [BSONDocument([("_id", .int32(1)), ("name", .string("a"))])]
                return MongoSample(schema: MongoSchema(sample: documents), validatorPaths: ["name", "tier"])
            }
        }
    }

    @Test func fillsOnceAndKeeps() async throws {
        let fake = Fake(delay: 0.1), cache = fake.cache()
        #expect(cache.cached(database: "shop", collection: "orders") == nil)
        async let one = cache.sample(database: "shop", collection: "orders")
        async let two = cache.sample(database: "shop", collection: "orders")
        _ = try await (one, two)
        #expect(fake.reads == ["shop.orders"], "one read in flight per collection")
        _ = try await cache.sample(database: "shop", collection: "orders")
        #expect(fake.reads.count == 1)

        cache.add(paths: ["name", "address.city"], database: "shop", collection: "orders")
        let sample = try #require(cache.cached(database: "shop", collection: "orders"))
        #expect(sample.paths == ["_id", "name", "tier", "address.city"])
        #expect(sample.loadedPaths == ["name", "address.city"])
    }

    @Test func invalidates() async throws {
        let fake = Fake(), cache = fake.cache()
        for (database, collection) in [("shop", "orders"), ("shop", "customers"), ("other", "orders")] {
            _ = try await cache.sample(database: database, collection: collection)
        }
        cache.invalidate(database: "shop", collection: "orders")
        #expect(cache.cached(database: "shop", collection: "orders") == nil)
        #expect(cache.cached(database: "shop", collection: "customers") != nil)
        cache.invalidate(database: "shop")
        #expect(cache.cached(database: "shop", collection: "customers") == nil)
        #expect(cache.cached(database: "other", collection: "orders") != nil)
        cache.invalidate()
        #expect(cache.cached(database: "other", collection: "orders") == nil)
        _ = try await cache.sample(database: "shop", collection: "orders")
        #expect(fake.reads.count == 4, "read again after invalidating")

        // Invalidated during its read: the reader gets it, the cache doesn't keep it.
        let slow = Fake(delay: 0.3), later = slow.cache()
        async let read = later.sample(database: "shop", collection: "orders")
        try await Task.sleep(nanoseconds: 100_000_000)
        later.invalidate(database: "shop", collection: "orders")
        #expect(try await read.schema.documents == 1)
        #expect(later.cached(database: "shop", collection: "orders") == nil)
    }

    @Test func staysBounded() async throws {
        let fake = Fake(), cache = fake.cache()
        _ = try await cache.sample(database: "db", collection: "c0")
        cache.add(paths: (0..<3_000).map { "f\($0)" }, database: "db", collection: "c0")
        #expect(cache.cached(database: "db", collection: "c0")?.loadedPaths.count == MongoSampleCache.pathLimit)
        #expect(cache.cached(database: "db", collection: "c0")?.paths.count == MongoSampleCache.pathLimit)
        for i in 1...MongoSampleCache.collectionLimit { _ = try await cache.sample(database: "db", collection: "c\(i)") }
        #expect(cache.cached(database: "db", collection: "c0") == nil, "the least recently used went")
        #expect(cache.cached(database: "db", collection: "c1") != nil)
    }

    @Test func validatorPaths() throws {
        let schema = try BSONDocument(extendedJSON: """
            {"properties": {"status": {"enum": ["paid"]}, "address": {"properties": {"city": {}}},
             "items": {"bsonType": "array", "items": {"properties": {"sku": {}, "qty": {}}}}}}
            """)
        #expect(MongoSampleCache.schemaPaths(schema) == ["status", "address", "address.city", "items", "items.[]",
                                                         "items.[].sku", "items.[].qty"])
    }
}

@Suite(.serialized, .enabled(if: MongoLab.enabled, "Mongo lab: AIRSQL_MONGO_LAB=1 ./test.sh --filter Mongo"))
struct MongoSampleCacheLabTests {
    @Test func fillsFromTheLab() async throws {
        let mongo = try #require(try await AgentMongoLabTests.target(.standalone).mongo)
        let many = try await mongo.samples.sample(database: "fixture", collection: "many")
        #expect(many.schema.documents == MongoSampleCache.sampleSize && !many.isFirstDocuments)
        #expect(many.indexes.map { $0.fields.map(\.key) } == [["_id"]] && many.paths == ["_id", "n"])
        let view = try await mongo.samples.sample(database: "fixture", collection: "all_types_names")
        #expect(view.isFirstDocuments && view.schema.documents > 0 && view.indexes.isEmpty)
        #expect(mongo.samples.cached(database: "fixture", collection: "many")?.sampledAt == many.sampledAt)

        // A write AirSQL makes to a collection forgets its sample.
        let data = try await mongo.session(.data), scratch = MongoLab.scratch + "_samples"
        _ = try? await data.command(BSONDocument([("dropDatabase", .int32(1))]), database: scratch)
        try await data.insertOne(database: scratch, collection: "sampled", BSONDocument([("_id", .int32(1)), ("a", .int32(1))]))
        _ = try await mongo.samples.sample(database: scratch, collection: "sampled")
        try await data.insertOne(database: scratch, collection: "sampled", BSONDocument([("_id", .int32(2)), ("b", .int32(1))]))
        #expect(mongo.samples.cached(database: scratch, collection: "sampled") == nil)
        #expect(Set(try await mongo.samples.sample(database: scratch, collection: "sampled").paths) == ["_id", "a", "b"])
        _ = try await data.command(BSONDocument([("dropDatabase", .int32(1))]), database: scratch)
        await mongo.close()
    }
}
