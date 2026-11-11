import Foundation

/// What an agent may ask of a MongoDB connection: reads only, each built from typed fields, so there is no options
/// pass-through and no runCommand. Nothing runs until `MongoAgentGuard.check` has passed it.
public enum MongoAgentRequest: Sendable, Equatable {
    case find(db: String, collection: String, filter: BSONDocument, projection: BSONDocument? = nil,
              sort: BSONDocument? = nil, skip: Int? = nil, limit: Int? = nil, collation: BSONDocument? = nil,
              hint: BSONValue? = nil)
    case aggregate(db: String, collection: String, pipeline: [BSONDocument], collation: BSONDocument? = nil,
                   hint: BSONValue? = nil)
    case count(db: String, collection: String, filter: BSONDocument)
    case distinct(db: String, collection: String, key: String, filter: BSONDocument)
    case listDatabases
    case listCollections(db: String)
    case listIndexes(db: String, collection: String)
    /// A collection's stats, or the database's without one.
    case stats(db: String, collection: String?)
    case schemaSample(db: String, collection: String, size: Int)
    /// A find's or an aggregate's plan: `execute` false asks for queryPlanner (nothing runs), true for executionStats
    /// (the query runs, as it would on its own).
    indirect case explain(MongoAgentRequest, execute: Bool)
}

/// A request the guard passed, with its caps applied: find's limit and schemaSample's size at most `documentCap`,
/// aggregate's pipeline ending in `{$limit: documentCap}`. The session runs this, never a bare request; it sends
/// `maxTimeMS` with every command and stops reading at `documentCap` (distinct's values, listings).
public struct MongoCheckedRequest: Sendable, Equatable {
    public let request: MongoAgentRequest
    public let maxTimeMS: Int
    public let documentCap: Int
}

/// Why the guard refused, naming where: "pipeline.2.$lookup.pipeline.0: $where runs JavaScript, which agents can't".
public struct MongoAgentRefusal: Error, Equatable, CustomStringConvertible {
    public let path: String
    public let reason: String
    public var description: String { path.isEmpty ? reason : path + ": " + reason }
}

/// The agents' first guard on MongoDB, which has no read-only session: every argument's whole BSON is walked and
/// anything that runs JavaScript or writes is refused at any depth, stages are on an allow-list, the internal
/// databases and `system.*` collections are out of reach, and a timeout and a document cap are forced. It fails
/// closed: what it doesn't know is refused. (The second guard, an always-aborted transaction on replica sets, is the
/// session's.)
public enum MongoAgentGuard {
    static let forbiddenKeys: [String: String] = [
        "$where": "runs JavaScript, which agents can't",
        "$function": "runs JavaScript, which agents can't",
        "$accumulator": "runs JavaScript, which agents can't",
        "$out": "writes to a collection, which agents can't",
        "$merge": "writes to a collection, which agents can't",
    ]

    /// Stages agents may use. Each only reads the documents flowing through it, or (`$lookup`, `$graphLookup`,
    /// `$unionWith`) another collection of the same database, which `checkPipeline` checks. Everything else is
    /// refused: `$out`/`$merge` write, `$changeStream` holds a cursor open, `$currentOp`, `$listSessions`,
    /// `$listLocalSessions`, `$planCacheStats` and `$queryStats` show other people's work, `$search`, `$searchMeta`
    /// and `$vectorSearch` reach Atlas Search outside these rules, and unknown or newer stages aren't vetted.
    static let allowedStages: Set<String> = [
        // Filter, reshape, order or count the stream.
        "$match", "$project", "$addFields", "$set", "$unset", "$group", "$sort", "$limit", "$skip", "$count",
        "$unwind", "$sortByCount", "$bucket", "$bucketAuto", "$replaceRoot", "$replaceWith", "$sample", "$redact",
        // Fill gaps or compute over windows of the stream.
        "$densify", "$fill", "$setWindowFields",
        // Read through a geo index; its query is walked like any filter.
        "$geoNear",
        // Literal documents typed in the request: nothing read.
        "$documents",
        // Read-only figures about this same collection and its indexes, as the stats tool gives.
        "$collStats", "$indexStats",
        // Read another collection of this database; the target and any sub-pipeline are checked.
        "$lookup", "$graphLookup", "$unionWith",
        // Sub-pipelines, each checked as a pipeline.
        "$facet",
    ]

    public static func check(_ request: MongoAgentRequest,
                             safety: SafetySettings = SafetySettings()) throws -> MongoCheckedRequest {
        let cap = max(1, safety.agentRowCap)
        func done(_ request: MongoAgentRequest) -> MongoCheckedRequest {
            MongoCheckedRequest(request: request, maxTimeMS: max(1, safety.agentTimeout) * 1000, documentCap: cap)
        }
        switch request {
        case let .find(db, collection, filter, projection, sort, skip, limit, collation, hint):
            try checkNamespace(db, collection)
            try walk([("filter", .document(filter)), ("projection", projection.map(BSONValue.document)),
                      ("sort", sort.map(BSONValue.document)), ("collation", collation.map(BSONValue.document)),
                      ("hint", hint)])
            try checkHint(hint)
            if let skip, skip < 0 { throw MongoAgentRefusal(path: "skip", reason: "can't be negative") }
            if let limit, limit < 0 { throw MongoAgentRefusal(path: "limit", reason: "can't be negative") }
            // MongoDB reads a limit of 0 as no limit: that is the cap here.
            let effective = min(limit.flatMap { $0 == 0 ? nil : $0 } ?? cap, cap)
            return done(.find(db: db, collection: collection, filter: filter, projection: projection, sort: sort,
                              skip: skip, limit: effective, collation: collation, hint: hint))
        case let .aggregate(db, collection, pipeline, collation, hint):
            try checkNamespace(db, collection)
            try walk([("pipeline", .array(pipeline.map(BSONValue.document))),
                      ("collation", collation.map(BSONValue.document)), ("hint", hint)])
            try checkHint(hint)
            try checkPipeline(pipeline.map(BSONValue.document), path: "pipeline", db: db)
            return done(.aggregate(db: db, collection: collection,
                                   pipeline: pipeline + [BSONDocument([("$limit", .int64(Int64(cap)))])],
                                   collation: collation, hint: hint))
        case let .count(db, collection, filter):
            try checkNamespace(db, collection)
            try walk([("filter", .document(filter))])
            return done(request)
        case let .distinct(db, collection, key, filter):
            try checkNamespace(db, collection)
            if key.isEmpty || key.hasPrefix("$") || key.contains("\0") {
                throw MongoAgentRefusal(path: "key", reason: "needs a field's name or dotted path")
            }
            try walk([("filter", .document(filter))])
            return done(request)
        case .listDatabases:
            return done(request)
        case let .listCollections(db):
            try checkDatabase(db)
            return done(request)
        case let .listIndexes(db, collection):
            try checkNamespace(db, collection)
            return done(request)
        case let .stats(db, collection):
            if let collection { try checkNamespace(db, collection) } else { try checkDatabase(db) }
            return done(request)
        case let .schemaSample(db, collection, size):
            try checkNamespace(db, collection)
            guard size > 0 else { throw MongoAgentRefusal(path: "size", reason: "needs at least 1 document") }
            return done(.schemaSample(db: db, collection: collection, size: min(size, cap)))
        case let .explain(inner, execute):
            // Only a find's or an aggregate's, checked and capped as each is on its own.
            switch inner {
            case .find, .aggregate:
                return done(.explain(try check(inner, safety: safety).request, execute: execute))
            default:
                throw MongoAgentRefusal(path: "", reason: "only a find or an aggregate can be explained")
            }
        }
    }

    // MARK: Names

    /// MongoDB's own databases, which hold users, roles, the oplog and the cluster's settings.
    public static let internalDatabases: Set<String> = ["admin", "local", "config"]

    static func checkDatabase(_ db: String) throws {
        // The characters MongoDB refuses in a database's name on any platform, and its 64-byte limit.
        if db.isEmpty || db.utf8.count >= 64 || db.contains(where: { "/\\. \"$*<>:|?\0".contains($0) }) {
            throw MongoAgentRefusal(path: "db", reason: "\"\(db)\" isn't a valid database name")
        }
        if internalDatabases.contains(db.lowercased()) {
            throw MongoAgentRefusal(path: "db", reason: "\(db) is MongoDB's own database, which agents can't read")
        }
    }

    static func checkCollection(_ collection: String, path: String = "collection") throws {
        if collection.isEmpty || collection.contains("$") || collection.contains("\0") {
            throw MongoAgentRefusal(path: path, reason: "\"\(collection)\" isn't a valid collection name")
        }
        if collection.hasPrefix("system.") {
            throw MongoAgentRefusal(path: path, reason: "\(collection) is a system collection, which agents can't read")
        }
    }

    static func checkNamespace(_ db: String, _ collection: String) throws {
        try checkDatabase(db)
        try checkCollection(collection)
        if db.utf8.count + 1 + collection.utf8.count > 255 {
            throw MongoAgentRefusal(path: "collection", reason: "the name is longer than MongoDB allows")
        }
    }

    // MARK: The walk

    /// Refuses a forbidden key or a JavaScript value anywhere under the arguments.
    static func walk(_ arguments: [(String, BSONValue?)]) throws {
        var refusal: MongoAgentRefusal?
        BSONDocument(arguments.compactMap { key, value in value.map { (key, $0) } }).walk { path, value in
            guard refusal == nil else { return }
            if case .key(let key) = path.last, let reason = forbiddenKeys[key] {
                refusal = MongoAgentRefusal(path: Array(path.dropLast()).dotted, reason: key + " " + reason)
            }
            switch value {
            case .javascript, .javascriptWithScope:
                refusal = refusal ?? MongoAgentRefusal(path: path.dotted, reason: "JavaScript code, which agents can't send")
            default: break
            }
        }
        if let refusal { throw refusal }
    }

    static func checkHint(_ hint: BSONValue?) throws {
        switch hint {
        case nil, .string?, .document?: return
        default: throw MongoAgentRefusal(path: "hint", reason: "needs an index's name or its key pattern")
        }
    }

    // MARK: Stages

    static func checkPipeline(_ stages: [BSONValue], path: String, db: String) throws {
        for (index, stage) in stages.enumerated() {
            let here = path + "." + String(index)
            guard case .document(let document) = stage, document.fields.count == 1, let field = document.fields.first
            else { throw MongoAgentRefusal(path: here, reason: "a stage is a document with one stage name") }
            let (name, spec) = (field.key, field.value)
            guard allowedStages.contains(name) else {
                throw MongoAgentRefusal(path: here, reason: "\(name) isn't a stage agents may use")
            }
            let at = here + "." + name
            switch (name, spec) {
            case ("$lookup", .document(let spec)):
                // Without `from`, the sub-pipeline starts with $documents and reads nothing else.
                if spec["from"] != nil { try checkTarget(spec["from"], path: at + ".from") }
                if let pipeline = spec["pipeline"] { try checkSubPipeline(pipeline, path: at + ".pipeline", db: db) }
            case ("$graphLookup", .document(let spec)):
                try checkTarget(spec["from"], path: at + ".from")
            case ("$unionWith", .string):
                try checkTarget(spec, path: at)
            case ("$unionWith", .document(let spec)):
                if spec["db"] != nil { throw crossDatabase(at + ".db") }
                try checkTarget(spec["coll"], path: at + ".coll")
                if let pipeline = spec["pipeline"] { try checkSubPipeline(pipeline, path: at + ".pipeline", db: db) }
            case ("$facet", .document(let facets)):
                for (facet, pipeline) in facets.fields {
                    try checkSubPipeline(pipeline, path: at + "." + facet, db: db)
                }
            case ("$lookup", _), ("$graphLookup", _), ("$unionWith", _), ("$facet", _):
                throw MongoAgentRefusal(path: at, reason: "isn't written the way MongoDB takes it")
            default: break
            }
            if case .document(let spec) = spec, ["$lookup", "$graphLookup"].contains(name), spec["db"] != nil {
                throw crossDatabase(at + ".db")
            }
        }
    }

    static func checkSubPipeline(_ value: BSONValue, path: String, db: String) throws {
        guard case .array(let stages) = value else { throw MongoAgentRefusal(path: path, reason: "needs a list of stages") }
        try checkPipeline(stages, path: path, db: db)
    }

    /// Another collection read by a stage: named plainly, so in this database (`{db, coll}` would leave it).
    static func checkTarget(_ value: BSONValue?, path: String) throws {
        guard case .string(let collection)? = value else { throw crossDatabase(path) }
        try checkCollection(collection, path: path)
    }

    static func crossDatabase(_ path: String) -> MongoAgentRefusal {
        MongoAgentRefusal(path: path, reason: "agents read only a collection of this database, named plainly")
    }
}
