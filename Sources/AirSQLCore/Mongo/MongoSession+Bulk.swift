import CMongoC
import Foundation

// Update Many and Delete Many (`MongoBulk`): the count the preview shows and the write, on the same session, with the
// same filter and collation. Neither is retried after a network error (multi-document writes aren't retryable), so a
// lost connection leaves the outcome unknown.
extension MongoSession {
    /// How many documents `bulk`'s filter matches now, under its collation.
    public func count(_ bulk: MongoBulk) async throws -> Int64 {
        let pipeline = [BSONDocument([("$match", .document(bulk.filter))]), BSONDocument([("$count", .string("n"))])]
        let found = try await all(aggregate(database: bulk.database, collection: bulk.collection, pipeline: pipeline,
                                            collation: bulk.collation))
        return found.first?["n"]?.integer ?? 0
    }

    /// Runs `bulk`: updateMany (upsert off) or deleteMany. The documents matched (for a delete, deleted) and modified.
    public func run(_ bulk: MongoBulk) async throws -> (matched: Int64, modified: Int64) {
        var statement: [(key: String, value: BSONValue)] = [("q", .document(bulk.filter))]
        if let update = bulk.update {
            statement += [("u", update), ("multi", .bool(true)), ("upsert", .bool(false))]
        } else {
            statement.append(("limit", .int32(0)))
        }
        if let collation = bulk.collation { statement.append(("collation", .document(collation))) }
        let logged = BSONDocument([(bulk.isDelete ? "delete" : "update", .string(bulk.collection)),
                                   (bulk.isDelete ? "deletes" : "updates", .array([.document(BSONDocument(statement))]))])
        var modified: Int64 = 0
        let matched = try await write(logged, database: bulk.database, collection: bulk.collection,
                                      count: bulk.isDelete ? "deletedCount" : "matchedCount", collation: bulk.collation) { target, options, reply, error in
            let selector = try bulk.filter.bson()
            defer { bson_destroy(selector) }
            guard let update = bulk.update else { return mongoc_collection_delete_many(target, selector, options, reply, error) }
            // The driver takes a pipeline as a document whose keys are "0", "1", …
            let change: BSONDocument
            switch update {
            case .array(let stages): change = BSONDocument(stages.enumerated().map { (String($0.offset), $0.element) })
            case .document(let operators): change = operators
            default: return false
            }
            let made = try change.bson()
            defer { bson_destroy(made) }
            let ok = mongoc_collection_update_many(target, selector, made, options, reply, error)
            if ok { modified = (try? BSONDocument(bson: reply))?["modifiedCount"]?.integer ?? 0 }
            return ok
        }
        return (matched, bulk.isDelete ? matched : modified)
    }
}
