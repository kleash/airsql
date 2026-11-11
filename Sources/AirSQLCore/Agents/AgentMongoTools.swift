import Foundation

/// The MongoDB tools (mongo-plan, Agents): typed reads only. Each call becomes a `MongoAgentRequest` from its arguments
/// (documents as Extended JSON text), passes `MongoAgentGuard.check` with the connection's row cap and timeout, and runs
/// on the connection's agent session, one call at a time; on a replica set or mongos the data reads run inside a
/// transaction that is always aborted, so even a write the guard missed is refused by the server (263) and undone.
extension AgentTarget {
    public static let mongoTools = ["mongo_find", "mongo_aggregate", "mongo_count", "mongo_distinct", "mongo_list_databases",
                                    "mongo_list_collections", "mongo_list_indexes", "mongo_stats", "mongo_schema_sample"]

    /// The most BSON a reply's documents add up to; reading stops there and the reply says capped.
    static let mongoReplyBytes = 1 << 20

    public func mongo(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        try require(.schemaRead, engine: .mongodb)
        let request = try mongoRequest(tool, arguments)
        var limits = safety
        limits.agentRowCap = rowCap
        limits.agentTimeout = timeout
        let checked: MongoCheckedRequest
        do {
            checked = try MongoAgentGuard.check(request, safety: limits)
        } catch let refusal as MongoAgentRefusal {
            throw AirSQLError(.readOnly, "Refused: \(refusal).")
        }
        guard let mongo else { throw notConnected }
        let session = try await mongo.session(.agent)
        let wanted = (arguments["limit"] as? NSNumber ?? arguments["max_documents"] as? NSNumber)
            .map { $0.intValue == 0 ? rowCap : $0.intValue } ?? Self.defaultRows
        return try await AgentReadOnly.turns.run(session) {
            try await run(checked, wanted: max(1, min(wanted, rowCap)), on: session, server: mongo.server)
        }
    }

    // MARK: Arguments

    /// The request `arguments` describe, before the guard.
    func mongoRequest(_ tool: String, _ arguments: [String: Any]) throws -> MongoAgentRequest {
        func text(_ key: String) -> String? {
            (arguments[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }
        func needed(_ key: String) throws -> String {
            guard let value = text(key) else { throw AirSQLError(.other, "\(tool) needs \(key).") }
            return value
        }
        func integer(_ key: String) -> Int? { (arguments[key] as? NSNumber)?.intValue }
        func document(_ key: String) throws -> BSONDocument? {
            try Self.extendedJSON(arguments[key], key)
        }
        let db = { () throws -> String in
            guard let name = text("database") ?? self.database else {
                throw AirSQLError(.other, "\(tool) needs database: the connection has no current one.")
            }
            return name
        }
        switch tool {
        case "mongo_find":
            // One more than wanted, to tell whether there were more (the guard still caps it).
            let limit = integer("limit").map { $0 == 0 ? rowCap : $0 } ?? Self.defaultRows
            return .find(db: try db(), collection: try needed("collection"), filter: try document("filter") ?? BSONDocument(),
                         projection: try document("projection"), sort: try document("sort"), skip: integer("skip"),
                         limit: limit < 0 ? limit : min(limit, rowCap) + 1, collation: try document("collation"),
                         hint: try Self.hint(arguments["hint"]))
        case "mongo_aggregate":
            return .aggregate(db: try db(), collection: try needed("collection"),
                              pipeline: try Self.pipeline(arguments["pipeline"]), collation: try document("collation"),
                              hint: try Self.hint(arguments["hint"]))
        case "mongo_count":
            return .count(db: try db(), collection: try needed("collection"), filter: try document("filter") ?? BSONDocument())
        case "mongo_distinct":
            return .distinct(db: try db(), collection: try needed("collection"), key: try needed("key"),
                             filter: try document("filter") ?? BSONDocument())
        case "mongo_list_databases": return .listDatabases
        case "mongo_list_collections": return .listCollections(db: try db())
        case "mongo_list_indexes": return .listIndexes(db: try db(), collection: try needed("collection"))
        case "mongo_stats": return .stats(db: try db(), collection: text("collection"))
        case "mongo_schema_sample":
            return .schemaSample(db: try db(), collection: try needed("collection"), size: integer("size") ?? Self.defaultRows)
        default: throw AirSQLError(.other, "AirSQL has no tool “\(tool)”.")
        }
    }

    /// A document argument: Extended JSON text, as a string (an object would have lost its keys' order on the way).
    static func extendedJSON(_ value: Any?, _ key: String) throws -> BSONDocument? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String else {
            throw AirSQLError(.other, "\(key) is Extended JSON text: pass it as a string, such as \"{\\\"status\\\": \\\"A\\\"}\".")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            return try BSONDocument(extendedJSON: text)
        } catch {
            throw AirSQLError(.other, "\(key) isn't Extended JSON: \(error)")
        }
    }

    /// The pipeline: Extended JSON text of an array of stages.
    static func pipeline(_ value: Any?) throws -> [BSONDocument] {
        guard let text = value as? String else {
            throw AirSQLError(.other, "mongo_aggregate needs pipeline: Extended JSON text of an array of stages, as a string.")
        }
        let wrapped: BSONDocument
        do {
            wrapped = try BSONDocument(extendedJSON: "{\"pipeline\":" + text + "\n}")
        } catch {
            throw AirSQLError(.other, "pipeline isn't Extended JSON: \(error)")
        }
        guard wrapped.fields.count == 1, case .array(let stages)? = wrapped["pipeline"] else {
            throw AirSQLError(.other, "pipeline needs an array of stages.")
        }
        return try stages.map { stage in
            guard case .document(let document) = stage else { throw AirSQLError(.other, "Each stage of pipeline is a document.") }
            return document
        }
    }

    /// An index's name, or its key pattern as Extended JSON text.
    static func hint(_ value: Any?) throws -> BSONValue? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            if value == nil || value is NSNull { return nil }
            throw AirSQLError(.other, "hint is an index's name, or its key pattern as Extended JSON text.")
        }
        return text.hasPrefix("{") ? .document(try extendedJSON(text, "hint") ?? BSONDocument()) : .string(text)
    }

    // MARK: Running

    func run(_ checked: MongoCheckedRequest, wanted: Int, on session: MongoSession,
                     server: MongoServerInfo?) async throws -> [String: Any] {
        try Task.checkCancellation()  // the person cancelled the call, or turned agents off
        let started = Date(), time = checked.maxTimeMS
        let watchdog = Task { [timeout] in
            try await Task.sleep(nanoseconds: UInt64(timeout + 2) * 1_000_000_000)
            await session.cancel()
        }
        defer { watchdog.cancel() }
        var reply: [String: Any] = ["connection": saved.displayName]
        // The listings and stats can't run in a transaction; they are fixed commands that only read.
        var reads = true
        if case .listDatabases = checked.request { reads = false }
        if case .listCollections = checked.request { reads = false }
        if case .listIndexes = checked.request { reads = false }
        if case .stats = checked.request { reads = false }
        let transaction = reads && (server?.setName != nil || server?.isMongos == true)
        func read() async throws {
            switch checked.request {
            case let .find(db, collection, filter, projection, sort, skip, limit, collation, hint):
                let cursor = try await session.find(database: db, collection: collection, MongoFind(
                    filter: filter, projection: projection, sort: sort, skip: skip.map(Int64.init),
                    limit: limit.map(Int64.init), collation: collation, hint: hint, maxTimeMS: time))
                reply.merge(try await Self.documents(cursor, wanted: wanted, cap: checked.documentCap)) { $1 }
                reply.merge(["database": db, "collection": collection]) { $1 }
            case let .aggregate(db, collection, pipeline, collation, hint):
                let cursor = try await session.aggregate(database: db, collection: collection, pipeline: pipeline,
                                                         maxTimeMS: time, collation: collation, hint: hint)
                reply.merge(try await Self.documents(cursor, wanted: wanted, cap: checked.documentCap)) { $1 }
                reply.merge(["database": db, "collection": collection]) { $1 }
            case let .count(db, collection, filter):
                let count = try await session.count(database: db, collection: collection, filter: filter, maxTimeMS: time)
                reply.merge(["database": db, "collection": collection, "count": Int(count)]) { $1 }
            case let .distinct(db, collection, key, filter):
                let values = try await session.distinct(database: db, collection: collection, key: key, filter: filter,
                                                        maxTimeMS: time)
                reply.merge(["database": db, "collection": collection, "key": key,
                             "values": values.prefix(checked.documentCap).map(Self.text),
                             "count": min(values.count, checked.documentCap), "capped": values.count > checked.documentCap]) { $1 }
            case .listDatabases:
                let databases = try await session.listDatabases().filter {
                    guard case .string(let name)? = $0["name"] else { return false }
                    return !MongoAgentGuard.internalDatabases.contains(name.lowercased())
                }
                reply["databases"] = databases.prefix(checked.documentCap).map { Self.json(.document($0)) }
            case let .listCollections(db):
                let collections = try await session.listCollections(database: db).filter { !$0.name.hasPrefix("system.") }
                reply["database"] = db
                reply["collections"] = collections.prefix(checked.documentCap).map { info -> [String: Any] in
                    var entry: [String: Any] = ["name": info.name, "type": info.kind.rawValue]
                    if !info.options.fields.isEmpty { entry["options"] = Self.json(.document(info.options)) }
                    return entry
                }
            case let .listIndexes(db, collection):
                let indexes = try await session.listIndexes(database: db, collection: collection)
                reply.merge(["database": db, "collection": collection,
                             "indexes": indexes.prefix(checked.documentCap).map(Self.text)]) { $1 }
            case let .stats(db, collection):
                var stats = try await collection == nil ? session.databaseStats(database: db)
                    : session.collectionStats(database: db, collection: collection ?? "")
                // The storage engine's own figures are long and say little to an agent.
                stats.fields.removeAll { ["wiredTiger", "indexDetails", "$clusterTime", "operationTime"].contains($0.key) }
                reply.merge(["database": db, "stats": Self.text(stats)]) { $1 }
                if let collection { reply["collection"] = collection }
            case let .schemaSample(db, collection, size):
                let sample = BSONDocument([("$sample", .document(BSONDocument([("size", .int64(Int64(size)))])))])
                let cursor = try await session.aggregate(database: db, collection: collection, pipeline: [sample], maxTimeMS: time)
                let found = try await cursor.next(maxCount: size, maxBytes: 32 << 20).map { try BSONDocument(bytes: $0) }
                await cursor.close()
                reply.merge(["database": db, "collection": collection,
                             "documents": found.count, "fields": Self.fields(MongoSchema(sample: found, topLimit: 5))]) { $1 }
            }
        }
        do {
            if transaction { try await session.startTransaction() }
            do {
                try await read()
            } catch {
                if transaction { try? await session.abortTransaction() }
                throw error
            }
            if transaction { try? await session.abortTransaction() }
        } catch var error as AirSQLError {
            if Task.isCancelled { throw CancellationError() }  // the person's Cancel stopped it
            // MaxTimeMSExpired (50), or the watchdog's killOp (11601).
            if [50, 11601].contains(error.code) || error.kind == .cancelled {
                error.message = "Stopped at the agent timeout (\(timeout) s)."
            }
            throw error
        }
        reply["durationMs"] = Int(Date().timeIntervalSince(started) * 1000)
        return reply
    }

    /// Up to `wanted` documents of `cursor` (it was asked for one more), and whether there were more: past `wanted`,
    /// stopped by the byte budget, or at the cap.
    private static func documents(_ cursor: MongoCursor, wanted: Int, cap: Int) async throws -> [String: Any] {
        let raw = try await cursor.next(maxCount: wanted + 1, maxBytes: mongoReplyBytes)
        let stopped = !cursor.isExhausted
        await cursor.close()
        let documents = try raw.prefix(wanted).map { try BSONDocument(bytes: $0) }
        return ["documents": documents.map(text), "count": documents.count,
                "capped": raw.count > wanted || stopped || raw.count >= cap]
    }

    /// A sample's fields for a reply.
    static func fields(_ schema: MongoSchema) -> [[String: Any]] {
        schema.fields.map { field in
            var entry: [String: Any] = ["path": field.path, "present": field.present, "missing": field.missing,
                                        "nulls": field.nulls, "distinct": field.distinct,
                                        "distinctIsExact": field.distinctIsExact,
                                        "types": field.types.map { ["type": $0.name, "count": $0.count] },
                                        "top": field.top.map { ["value": $0.value, "count": $0.count] as [String: Any] }]
            for (key, value) in [("min", field.minNumber ?? field.minDate), ("max", field.maxNumber ?? field.maxDate)] {
                if let value { entry[key] = json(value) }
            }
            return entry
        }
    }

    /// A document for a reply: its relaxed Extended JSON text in a string, exactly as written. As JSON objects it would
    /// pass through Foundation's JSON on the way (the socket, the bridge), which loses the keys' order and a whole
    /// double's `.0`. Long strings cut as `AgentFormat` cuts cells.
    static func text(_ document: BSONDocument) -> String { text(.document(document)) }
    static func text(_ value: BSONValue) -> String { cut(value).extendedJSON(.relaxed) }

    /// A value for a reply: relaxed Extended JSON as JSON, long strings cut as `AgentFormat` cuts cells.
    static func json(_ value: BSONValue) -> Any {
        let text = cut(value).extendedJSON(.relaxed)
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) ?? text
    }

    private static func cut(_ value: BSONValue) -> BSONValue {
        switch value {
        case .string(let text) where text.count > AgentFormat.cellLimit:
            return .string(String(text.prefix(AgentFormat.cellLimit)) + "…")
        case .document(let document): return .document(BSONDocument(document.fields.map { ($0.key, cut($0.value)) }))
        case .array(let values): return .array(values.map(cut))
        default: return value
        }
    }
}

// MARK: mongo_open (lane: agent control)

/// What mongo_open puts in a new tab: a find's fields, or a pipeline, in shell form as the person types them.
public struct MongoProposal: Sendable {
    public var database: String
    public var collection: String
    /// The find's fields; for a pipeline, only its collation.
    public var query: MongoQueryText
    /// The pipeline as the aggregation tab's editor shows it; nil for a find.
    public var pipeline: String?
}

extension AgentTarget {
    /// mongo_open's arguments, checked: Schema + read on a connected MongoDB connection, a namespace agents may read,
    /// and documents that parse. Nothing is sent to the server; what may run is the person's to decide (Run, and its
    /// preview for a $merge or $out), so the stages aren't checked as the read tools' are.
    public func mongoProposal(_ arguments: [String: Any]) throws -> MongoProposal {
        try require(.schemaRead, engine: .mongodb)
        func given(_ key: String) -> Bool { arguments[key] != nil && !(arguments[key] is NSNull) }
        func text(_ key: String) -> String? {
            (arguments[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        guard let database = text("database") ?? self.database else {
            throw AirSQLError(.other, "mongo_open needs database: the connection has no current one.")
        }
        guard let collection = text("collection") else { throw AirSQLError(.other, "mongo_open needs collection.") }
        do {
            try MongoAgentGuard.checkNamespace(database, collection)
        } catch let refusal as MongoAgentRefusal {
            throw AirSQLError(.readOnly, "Refused: \(refusal).")
        }
        func shell(_ key: String) throws -> String { try Self.extendedJSON(arguments[key], key)?.shellForm() ?? "" }
        func count(_ key: String) throws -> String {
            guard given(key) else { return "" }
            guard let number = arguments[key] as? NSNumber, number.doubleValue >= 0, number.doubleValue == number.doubleValue.rounded()
            else { throw AirSQLError(.other, "\(key) is a whole number, 0 or more.") }
            return String(number.int64Value)
        }
        var query = MongoQueryText(collation: try shell("collation"))
        if given("pipeline") {
            let find = ["filter", "projection", "sort", "skip", "limit"].filter(given)
            guard find.isEmpty else {
                throw AirSQLError(.other, "Pass pipeline or the find's \(find.joined(separator: ", ")), not both.")
            }
            let pipeline = MongoPipeline.text(try Self.pipeline(arguments["pipeline"]))
            guard mongo != nil else { throw notConnected }
            return MongoProposal(database: database, collection: collection, query: query, pipeline: pipeline)
        }
        query.filter = try shell("filter")
        query.projection = try shell("projection")
        query.sort = try shell("sort")
        query.skip = try count("skip")
        query.limit = try count("limit")
        guard mongo != nil else { throw notConnected }
        return MongoProposal(database: database, collection: collection, query: query)
    }

    /// A value for read_console: its relaxed Extended JSON text, long strings cut, as mongo_find gives it.
    public static func mongoText(_ value: BSONValue) -> String { text(value) }

    /// Documents for read_console, as mongo_find gives them and within its byte budget; capped: some were left out.
    public static func mongoTexts(_ documents: [BSONDocument]) -> (texts: [String], capped: Bool) {
        var texts: [String] = [], bytes = 0
        for document in documents {
            let text = text(document)
            bytes += text.utf8.count
            if bytes > mongoReplyBytes { return (texts, true) }
            texts.append(text)
        }
        return (texts, false)
    }

    /// A query bar's field or a pipeline as an agent may read it (read_console): as the command log has it, with the
    /// values of fields named as secrets replaced. Text that names one but doesn't parse is left out whole.
    public static func mongoRedacted(_ text: String) -> String {
        let lower = text.lowercased()
        guard MongoLog.secretFields.contains(where: { lower.contains($0) }) else { return text }
        guard let value = try? BSONValue(shellForm: text) else { return "<hidden: it names a secret field>" }
        return MongoLog.redacted(BSONDocument([("v", value)]))["v"]?.shellForm(pretty: text.contains("\n")) ?? ""
    }
}
