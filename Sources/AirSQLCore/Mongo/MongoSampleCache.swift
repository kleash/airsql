import Foundation

/// What AirSQL knows of a collection's documents for completion and agents (mongo-plan, Phase 3): a sample's schema,
/// the indexes' key patterns, the validator's paths and the paths a collection tab loaded.
public struct MongoSample: Sendable {
    public var schema: MongoSchema
    public var sampledAt: Date
    /// The first documents in natural order, not a random sample: a view, or `$sample` ran out of time.
    public var isFirstDocuments: Bool
    /// The indexes' key patterns (`{customerId: 1}`), in listIndexes' order.
    public var indexes: [BSONDocument]
    /// The paths the validator's `$jsonSchema` names (`items.[].sku`), if it has one.
    public var validatorPaths: [String]
    /// Paths a collection tab loaded (`MongoSampleCache.add(paths:)`).
    public var loadedPaths: [String] = []

    public init(schema: MongoSchema, sampledAt: Date = Date(), isFirstDocuments: Bool = false, indexes: [BSONDocument] = [],
                validatorPaths: [String] = []) {
        self.schema = schema
        self.sampledAt = sampledAt
        self.isFirstDocuments = isFirstDocuments
        self.indexes = indexes
        self.validatorPaths = validatorPaths
    }

    /// Every path known: the sample's, then the validator's and the loaded ones, once each, at most `pathLimit`.
    public var paths: [String] {
        var seen = Set<String>()
        return Array((schema.fields.map(\.path) + validatorPaths + loadedPaths).filter { seen.insert($0).inserted }
            .prefix(MongoSampleCache.pathLimit))
    }
}

/// The samples of a connection's collections, by database and collection (`MongoConnection.samples`, which completion
/// and agents share): filled on demand off the main thread, one fill at a time per collection, kept in memory only
/// until invalidated (Refresh, or a write AirSQL made to the collection), for the 200 collections used last.
public final class MongoSampleCache: @unchecked Sendable {
    public static let sampleSize = 200
    public static let maxTimeMS = 5_000
    public static let pathLimit = 2_000
    public static let collectionLimit = 200

    typealias Fill = @Sendable (_ database: String, _ collection: String) async throws -> MongoSample
    /// Set once, as the connection is made (tests: a fake).
    var fill: Fill

    private struct Entry {
        var sample: MongoSample?
        var loaded: [String] = []
        var filling: Task<MongoSample, Error>?
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Keys, the least recently used first.
    private var order: [String] = []

    init(fill: @escaping Fill = { _, _ in throw AirSQLError.disconnected }) {
        self.fill = fill
    }

    /// The sample if there is one now; nothing is read.
    public func cached(database: String, collection: String) -> MongoSample? {
        let key = Self.key(database, collection)
        return lock.locked {
            guard entries[key]?.sample != nil else { return nil }
            touch(key)
            return withLoaded(key)
        }
    }

    /// The sample, read first when there is none (callers asking meanwhile share that read).
    public func sample(database: String, collection: String) async throws -> MongoSample {
        let key = Self.key(database, collection)
        let (found, task): (MongoSample?, Task<MongoSample, Error>?) = lock.locked {
            touch(key)
            if entries[key]?.sample != nil { return (withLoaded(key), nil) }
            if let task = entries[key]?.filling { return (nil, task) }
            let fill = self.fill
            let task = Task.detached { try await fill(database, collection) }
            entries[key, default: Entry()].filling = task
            evict()
            return (nil, task)
        }
        if let found { return found }
        guard let task else { throw AirSQLError.disconnected }
        do {
            var sample = try await task.value
            sample.schema.fields = Array(sample.schema.fields.prefix(Self.pathLimit))
            return lock.locked {
                // Else it was invalidated while read: what it read may be out of date, so it isn't kept.
                if entries[key]?.filling == task {
                    entries[key]?.filling = nil
                    entries[key]?.sample = sample
                }
                sample.loadedPaths = entries[key]?.loaded ?? []
                return sample
            }
        } catch {
            lock.locked { if entries[key]?.filling == task { entries[key]?.filling = nil } }
            throw error
        }
    }

    /// Paths a collection tab loaded ("address.city"), joined with the sample's.
    public func add(paths: [String], database: String, collection: String) {
        let key = Self.key(database, collection)
        lock.locked {
            var entry = entries[key] ?? Entry()
            var seen = Set(entry.loaded)
            entry.loaded += paths.filter { seen.insert($0).inserted }.prefix(max(0, Self.pathLimit - entry.loaded.count))
            entries[key] = entry
            touch(key)
            evict()
        }
    }

    /// Forgets the collection's sample (and a read in flight), every collection's of `database`, or every one.
    public func invalidate(database: String? = nil, collection: String? = nil) {
        lock.locked {
            let gone: [String]
            switch (database, collection) {
            case let (database?, collection?): gone = [Self.key(database, collection)]
            case let (database?, nil): gone = entries.keys.filter { $0.hasPrefix(database + "\0") }
            default: gone = Array(entries.keys)
            }
            for key in gone { entries[key] = nil }
            order.removeAll { entries[$0] == nil }
        }
    }

    private static func key(_ database: String, _ collection: String) -> String { database + "\0" + collection }

    /// Under the lock.
    private func withLoaded(_ key: String) -> MongoSample? {
        guard var sample = entries[key]?.sample else { return nil }
        sample.loadedPaths = entries[key]?.loaded ?? []
        return sample
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evict() {
        while order.count > Self.collectionLimit { entries[order.removeFirst()] = nil }
    }

    // MARK: Reading

    /// A `$sample` of `sampleSize` within `maxTimeMS`; a view's, or one that ran out of time, is its first documents.
    static func read(_ session: MongoSession, database: String, collection: String) async throws -> MongoSample {
        // Without the privilege to list collections, it is taken as a collection without a validator.
        let info = (try? await session.listCollections(database: database))?.first { $0.name == collection }
        func documents(_ cursor: MongoCursor) async throws -> [BSONDocument] {
            let read = try await cursor.next(maxCount: sampleSize, maxBytes: 32 << 20)
            await cursor.close()
            return try read.map { try BSONDocument(bytes: $0) }
        }
        var first = info?.kind == .view, found: [BSONDocument] = []
        if !first {
            let stage = BSONDocument([("$sample", .document(BSONDocument([("size", .int64(Int64(sampleSize)))])))])
            do {
                found = try await documents(session.aggregate(database: database, collection: collection, pipeline: [stage],
                                                              maxTimeMS: maxTimeMS))
            } catch let error as AirSQLError where error.code == 50 {  // MaxTimeMSExpired
                first = true
            }
        }
        if first {
            found = try await documents(session.find(database: database, collection: collection,
                                                     MongoFind(limit: Int64(sampleSize), maxTimeMS: maxTimeMS)))
        }
        let indexes = ((try? await session.listIndexes(database: database, collection: collection)) ?? []).compactMap {
            if case .document(let key)? = $0["key"] { return key } else { return nil }
        }
        var validatorPaths: [String] = []
        if case .document(let validator)? = info?.options["validator"], case .document(let schema)? = validator["$jsonSchema"] {
            validatorPaths = schemaPaths(schema)
        }
        // 12 values: mongo_schema lists a string field of up to 12 values as an enum.
        return MongoSample(schema: MongoSchema(sample: found, topLimit: 12), isFirstDocuments: first, indexes: indexes,
                           validatorPaths: validatorPaths)
    }

    /// The paths a `$jsonSchema` names, nested properties dotted and arrays' items under `path.[]`, as `MongoSchema`.
    static func schemaPaths(_ schema: BSONDocument, under path: String? = nil) -> [String] {
        var paths: [String] = []
        if case .document(let properties)? = schema["properties"] {
            for (name, value) in properties.fields {
                let here = path.map { $0 + "." + name } ?? name
                paths.append(here)
                if case .document(let sub) = value { paths += schemaPaths(sub, under: here) }
            }
        }
        if let path, case .document(let items)? = schema["items"] {
            paths.append(path + ".[]")
            paths += schemaPaths(items, under: path + ".[]")
        }
        return paths
    }
}
