import CMongoC
import Foundation

/// What the compare of two collections reads (`MongoCompare`), and the whole-document write its reconcile needs.
extension MongoSession {
    /// The BSON types of the collection's `_id`s ("objectId", "string", "int", …): a merge of two sorted streams needs one.
    func idTypes(database: String, collection: String) async throws -> Set<String> {
        let group = BSONDocument([("$group", .document(BSONDocument([("_id", .document(BSONDocument([("$type", .string("$_id"))])))])))])
        let found = try await all(aggregate(database: database, collection: collection, pipeline: [group]))
        return Set(found.compactMap { if case .string(let type)? = $0["_id"] { return type } else { return nil } })
    }

    /// Every document, in `_id` order when `sorted` (binary order for strings: the simple collation).
    func scan(database: String, collection: String, sorted: Bool) async throws -> MongoCursor {
        try await find(database: database, collection: collection,
                       MongoFind(sort: sorted ? BSONDocument([("_id", .int32(1))]) : nil, collation: MongoApplyStep.simple))
    }

    /// The documents whose `_id` is one of `ids` (an `$in` matches 1, NumberLong(1) and 1.0 alike: the caller keeps the
    /// exact ones), whole or only their `_id`, within a minute.
    func lookUp(database: String, collection: String, ids: [BSONValue], idsOnly: Bool) async throws -> [[UInt8]] {
        let filter = BSONDocument([("_id", .document(BSONDocument([("$in", .array(ids))])))])
        let cursor = try await find(database: database, collection: collection,
                                    MongoFind(filter: filter, projection: idsOnly ? BSONDocument([("_id", .int32(1))]) : nil,
                                              collation: MongoApplyStep.simple, maxTimeMS: 60_000))
        var found: [[UInt8]] = []
        while case let batch = try await cursor.next(), !batch.isEmpty { found += batch }
        return found
    }

    /// Puts `replacement` in place of the one document `filter` matches; how many it matched, which Apply checks.
    public func replaceOne(database: String, collection: String, filter: BSONDocument, replacement: BSONDocument,
                           collation: BSONDocument? = nil) async throws -> Int64 {
        var statement: [(key: String, value: BSONValue)] = [("q", .document(filter)), ("u", .document(replacement))]
        if let collation { statement.append(("collation", .document(collation))) }
        let logged = BSONDocument([("update", .string(collection)), ("updates", .array([.document(BSONDocument(statement))]))])
        return try await write(logged, database: database, collection: collection, count: "matchedCount",
                               collation: collation) { target, options, reply, error in
            let (selector, made) = (try filter.bson(), try replacement.bson())
            defer { [selector, made].forEach { bson_destroy($0) } }
            return mongoc_collection_replace_one(target, selector, made, options, reply, error)
        }
    }
}
