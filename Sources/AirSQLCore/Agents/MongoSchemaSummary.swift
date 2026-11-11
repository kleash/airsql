import CryptoKit
import Foundation

/// mongo_schema's text (mongo-plan, Phase 3, Agents): a whole database for an LLM within `budget` bytes. Per collection
/// its count, average size, indexes and validator; per path (the `pathLimit` most often present, `depthLimit` deep) its
/// types and share, and with `values` the enums (strings of at most `enumLimit` values) and ranges of numbers and
/// dates; views with their pipeline; and references found by `references`.
public struct MongoSchemaSummary {
    public struct Collection {
        public var name: String
        public var kind: MongoCollectionInfo.Kind
        public var options: BSONDocument
        public var count: Int?
        public var averageSize: Int?
        /// As listIndexes describes them.
        public var indexes: [BSONDocument]
        /// nil: not sampled (a view, or no time left).
        public var sample: MongoSchema?
        /// "customers._id (50/50)" by path.
        public var references: [String: String] = [:]

        public init(name: String, kind: MongoCollectionInfo.Kind = .collection, options: BSONDocument = BSONDocument(),
                    count: Int? = nil, averageSize: Int? = nil, indexes: [BSONDocument] = [], sample: MongoSchema? = nil) {
            self.name = name
            self.kind = kind
            self.options = options
            self.count = count
            self.averageSize = averageSize
            self.indexes = indexes
            self.sample = sample
        }
    }

    public static let budget = 24 * 1024
    public static let pathLimit = 60
    public static let depthLimit = 4
    public static let enumLimit = 12
    /// A reference is kept when at least this share of the probed values is found.
    public static let hitRate = 0.8

    /// The text, and whether something was left out to fit the budget.
    public static func text(_ collections: [Collection], database: String, values: Bool) -> (text: String, capped: Bool) {
        // Fewer paths per collection first, down to 5.
        var limit = pathLimit, blocks: [String] = []
        let head = header(collections, database: database)
        while true {
            blocks = collections.map { describe($0, values: values, paths: limit).joined(separator: "\n") }
            let size = head.utf8.count + blocks.reduce(0) { $0 + $1.utf8.count + 2 } + 1
            if size <= budget { return (([head] + blocks).joined(separator: "\n\n") + "\n", limit < pathLimit) }
            if limit <= 5 { break }
            limit = limit * 2 / 3
        }
        // Then whole collections from the end, named (as many as fit) in a last line.
        var text = head, kept = 0
        for block in blocks {
            guard text.utf8.count + block.utf8.count + 2 <= budget - 2048 else { break }
            text += "\n\n" + block
            kept += 1
        }
        let rest = collections[kept...].map(\.name)
        var names = ""
        for name in rest {
            if names.utf8.count + name.utf8.count > 1800 {
                names += ", …"
                break
            }
            names += (names.isEmpty ? "" : ", ") + name
        }
        return (text + "\n\n… \(rest.count) more, left out to fit: \(names) (ask with collections)\n", true)
    }

    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func header(_ collections: [Collection], database: String) -> String {
        let views = collections.filter { $0.kind == .view }.count
        return "database \(database): \(collections.count - views) collection\(collections.count - views == 1 ? "" : "s")"
            + (views > 0 ? ", \(views) view\(views == 1 ? "" : "s")" : "")
            + ". Paths from a sample of each collection (arrays' items under path.[]); a share is shown when under "
            + "100%; -> a reference, with how many sampled values were found there."
    }

    private static func describe(_ collection: Collection, values: Bool, paths limit: Int) -> [String] {
        if collection.kind == .view {
            let on = collection.options["viewOn"]?.string ?? "?"
            return ["view \(collection.name) on \(on): " + (collection.options["pipeline"]?.shellForm(maxLength: 400) ?? "[]")]
        }
        var head = (collection.kind == .timeseries ? "timeseries " : "collection ") + collection.name
        let figures = [collection.count.map { "\($0) documents" }, collection.averageSize.map { "avg \($0) B" }].compactMap { $0 }
        if !figures.isEmpty { head += " (" + figures.joined(separator: ", ") + ")" }
        var lines = [head]
        if case .document(let series)? = collection.options["timeseries"] { lines.append("  timeseries: " + series.shellForm(maxLength: 200)) }
        if let validator = validator(collection.options) { lines.append("  validator: " + validator) }
        let indexes = collection.indexes.map { index -> String in
            var text = (index["name"]?.string ?? "?") + " " + (index["key"]?.shellForm(maxLength: 200) ?? "")
            if index["unique"] == .bool(true) { text += " unique" }
            if index["partialFilterExpression"] != nil { text += " partial" }
            if index["sparse"] == .bool(true) { text += " sparse" }
            return text
        }
        if !indexes.isEmpty { lines.append("  indexes: " + indexes.joined(separator: "; ")) }
        guard let sample = collection.sample else {
            lines.append("  (not sampled: ask again, or with fewer collections)")
            return lines
        }
        guard sample.documents > 0 else {
            lines.append("  (no documents in the sample)")
            return lines
        }
        let deep = sample.fields.filter { depth($0.path) <= depthLimit }
        let chosen = Set(deep.enumerated().sorted { a, b in
            a.element.present != b.element.present ? a.element.present > b.element.present : a.offset < b.offset
        }.prefix(limit).map(\.element.path))
        for field in sample.fields where chosen.contains(field.path) {
            lines.append("  " + line(field, documents: sample.documents, values: values,
                                     reference: collection.references[field.path]))
        }
        let left = sample.fields.count - chosen.count
        if left > 0 { lines.append("  … \(left) more path\(left == 1 ? "" : "s"), less often present or deeper") }
        return lines
    }

    /// Named steps (array steps don't count): `items.[].sku` is 2 deep.
    static func depth(_ path: String) -> Int { path.split(separator: ".").filter { $0 != "[]" }.count }

    static func line(_ field: MongoSchema.Field, documents: Int, values: Bool, reference: String?) -> String {
        var text = field.path + " "
        if field.types.count == 1 {
            text += field.types[0].name
        } else {
            text += field.types.map { "\($0.name) \(percent($0.count, field.present))" }.joined(separator: "|")
        }
        let holders = field.present + field.missing
        if field.missing > 0, holders > 0 { text += " " + percent(field.present, holders) }
        if let reference { text += " -> " + reference }
        guard values else { return text }
        let strings = field.types.allSatisfy { $0.name == "string" || $0.name == "null" } && field.types.contains { $0.name == "string" }
        let counted = field.present - field.nulls
        if strings, field.distinctIsExact, field.distinct <= enumLimit, field.distinct < counted, field.top.count == field.distinct {
            // A long value is cut: an enum names the values, and a sentence in one is text, not a kind.
            text += " enum " + field.top.filter { $0.value != "null" }.map { value in
                (value.value.count > 40 ? value.value.prefix(39) + "…\"" : value.value) + " " + percent(value.count, field.present)
            }.joined(separator: ", ")
        }
        if let low = field.minNumber, let high = field.maxNumber { text += " " + plain(low) + ".." + plain(high) }
        if let low = field.minDate, let high = field.maxDate { text += " " + plain(low) + ".." + plain(high) }
        return text
    }

    private static func percent(_ part: Int, _ whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        let share = part * 100 / whole
        return "\(share == 0 && part > 0 ? 1 : share)%"
    }

    /// A number or date as an LLM reads it best: `2.99`, `2024-03-01T00:00:00Z`.
    static func plain(_ value: BSONValue) -> String {
        switch value {
        case .int32(let n): return String(n)
        case .int64(let n): return String(n)
        case .double(let d): return String(d)
        case .decimal128(let d): return d.description
        case .datetime(let ms):
            let formatter = ISO8601DateFormatter()
            return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
        default: return value.shellForm(maxLength: 60)
        }
    }

    /// A validator in a line: `$jsonSchema`'s required fields, types and enums; any other as its start.
    static func validator(_ options: BSONDocument) -> String? {
        guard case .document(let validator)? = options["validator"] else { return nil }
        var text: String
        if validator.fields.count == 1, case .document(let schema)? = validator["$jsonSchema"] {
            var parts: [String] = []
            if case .array(let required)? = schema["required"] {
                parts.append("required " + required.compactMap(\.string).joined(separator: ", "))
            }
            for (path, rule) in MongoSampleCache.schemaRules(schema) { parts.append(path + " " + rule) }
            text = "$jsonSchema " + parts.joined(separator: "; ")
        } else {
            text = validator.shellForm(maxLength: 300)
        }
        if let action = options["validationAction"]?.string, action != "error" { text += " (validationAction \(action))" }
        if let level = options["validationLevel"]?.string, level != "strict" { text += " (validationLevel \(level))" }
        return text
    }

    // MARK: References

    /// A path that may hold another collection's key: `customerId` or `customerIds.[]` for `customers._id`, or a path
    /// whose last step ends in a unique-indexed field's name (`productSku`, `items.[].sku` for `products.sku`), of the
    /// same type in both samples. `probe` values are the path's sampled ones, at most `MongoSchema.exampleLimit`.
    public struct Candidate: Equatable {
        public var collection: String
        public var path: String
        public var target: String
        public var field: String
        public var probe: [BSONValue]
    }

    public static func candidates(_ collections: [Collection]) -> [Candidate] {
        struct Key { let collection: String, field: String, type: String }
        var keys: [Key] = []
        for collection in collections where collection.kind != .view {
            guard let sample = collection.sample else { continue }
            var fields = ["_id"]
            for index in collection.indexes where index["unique"] == .bool(true) && index["partialFilterExpression"] == nil {
                if case .document(let key)? = index["key"], key.fields.count == 1, let name = key.keys.first,
                   !name.contains("."), name != "_id", key.fields[0].value.isNumber { fields.append(name) }
            }
            for field in fields {
                if let type = sample[field].flatMap(dominant) { keys.append(Key(collection: collection.name, field: field, type: type)) }
            }
        }
        var found: [Candidate] = []
        for collection in collections where collection.kind != .view {
            for field in collection.sample?.fields ?? [] where field.path != "_id" && !field.examples.isEmpty {
                guard let type = dominant(field) else { continue }
                let name = field.path.split(separator: ".").last { $0 != "[]" }.map(String.init) ?? field.path
                let lower = name.lowercased()
                // customerId, customer_id, customerIds: the collection named after the stem.
                var stem: String?
                for suffix in ["_ids", "ids", "_id", "id"] where lower.hasSuffix(suffix) && lower.count > suffix.count {
                    stem = String(lower.dropLast(suffix.count))
                    break
                }
                let matches = keys.filter { key in
                    guard key.type == type || (MongoWords.numbers.contains(key.type) && MongoWords.numbers.contains(type)),
                          !(key.collection == collection.name && key.field == field.path) else { return false }
                    if key.field == "_id" {
                        guard let stem else { return false }
                        let target = key.collection.lowercased()
                        return [stem, stem + "s", stem + "es", stem.hasSuffix("y") ? stem.dropLast() + "ies" : nil].contains(target)
                    }
                    let other = key.field
                    return name == other || name.hasSuffix("_" + other)
                        || name.hasSuffix(other.prefix(1).uppercased() + other.dropFirst())
                }
                found += matches.map { Candidate(collection: collection.name, path: field.path, target: $0.collection,
                                                 field: $0.field, probe: field.examples) }
            }
        }
        return found
    }

    /// A probed candidate as the text names it, `customers._id (49/50)`; nil when fewer than `hitRate` of the values were
    /// found, which a name that only looks like a reference gets.
    public static func reference(_ candidate: Candidate, hits: Int, of probed: Int) -> String? {
        guard probed > 0, Double(hits) >= hitRate * Double(probed) else { return nil }
        return "\(candidate.target).\(candidate.field) (\(hits)/\(probed))"
    }

    /// The type of most of a field's values, nulls aside: documents and arrays have none.
    private static func dominant(_ field: MongoSchema.Field) -> String? {
        guard let type = field.types.first(where: { $0.name != "null" })?.name, !["object", "array"].contains(type) else { return nil }
        return type
    }
}

extension BSONValue {
    var isNumber: Bool {
        switch self {
        case .int32, .int64, .double, .decimal128: return true
        default: return false
        }
    }
}

extension MongoSampleCache {
    /// A `$jsonSchema`'s rules per path, as `schemaPaths` names them: `status enum "pending"|"paid"`, `qty int`.
    static func schemaRules(_ schema: BSONDocument, under path: String? = nil) -> [(String, String)] {
        var rules: [(String, String)] = []
        if case .document(let properties)? = schema["properties"] {
            for (name, value) in properties.fields {
                guard case .document(let sub) = value else { continue }
                let here = path.map { $0 + "." + name } ?? name
                var rule: [String] = []
                if let type = sub["bsonType"] ?? sub["type"] { rule.append(type.string ?? type.shellForm(maxLength: 60)) }
                if case .array(let values)? = sub["enum"] {
                    rule.append("enum " + values.map { $0.shellForm(maxLength: 60) }.joined(separator: "|"))
                }
                if !rule.isEmpty { rules.append((here, rule.joined(separator: " "))) }
                rules += schemaRules(sub, under: here)
            }
        }
        if let path, case .document(let items)? = schema["items"] { rules += schemaRules(items, under: path + ".[]") }
        return rules
    }
}

// MARK: The tool

extension AgentTarget {
    /// mongo_schema: lists the database's collections and indexes on the agent session (each name through the guard),
    /// takes their samples from `connection.samples` (filling what isn't cached, within two thirds of the timeout), probes
    /// candidate references with one `$in` find each (through the guard), and answers `{hash, text, capped}`, or
    /// `{hash, unchanged: true}` when `if_changed_from` is that hash.
    func mongoSchema(_ arguments: [String: Any]) async throws -> [String: Any] {
        try require(.schema, engine: .mongodb)
        guard let db = (arguments["database"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? database else {
            throw AirSQLError(.other, "mongo_schema needs database: the connection has no current one.")
        }
        do {
            _ = try MongoAgentGuard.check(.listCollections(db: db))
        } catch let refusal as MongoAgentRefusal {
            throw AirSQLError(.readOnly, MongoAgentHints.refused(refusal))
        }
        let wanted = (arguments["collections"] as? [Any])?.compactMap { $0 as? String }
        let fill = arguments["sample"] as? Bool ?? true
        guard let link = mongo else { throw notConnected }
        let session = try await link.session(.agent)
        let started = Date(), seconds = Double(timeout)
        let infos = try await AgentReadOnly.turns.run(session) { try await session.listCollections(database: db) }
            .filter { info in
                (try? MongoAgentGuard.checkCollection(info.name)) != nil && (wanted?.contains(info.name) ?? true)
            }
        // The samples: those not cached are read now, all at once on the connection's main session, for as long as
        // allowed; one still being read when time is up stays cached for the next call.
        final class Done: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
        }
        let done = Done(), samples = link.samples
        let missing = infos.filter { $0.kind != .view && samples.cached(database: db, collection: $0.name) == nil }
        if fill {
            for info in missing {
                Task.detached {
                    _ = try? await samples.sample(database: db, collection: info.name)
                    done.lock.locked { done.count += 1 }
                }
            }
            while done.lock.locked({ done.count }) < missing.count, Date().timeIntervalSince(started) < seconds * 2 / 3 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        var collections: [MongoSchemaSummary.Collection] = []
        var capped = false
        for info in infos {
            var collection = MongoSchemaSummary.Collection(name: info.name, kind: info.kind, options: info.options)
            if info.kind != .view {
                collection.sample = samples.cached(database: db, collection: info.name)?.schema
                if collection.sample == nil { capped = true }
                let (indexes, stats) = try await AgentReadOnly.turns.run(session) {
                    ((try? await session.listIndexes(database: db, collection: info.name)) ?? [],
                     try? await session.collectionStats(database: db, collection: info.name))
                }
                collection.indexes = indexes
                collection.count = MongoExplain.number(stats?["count"]).map { Int($0) }
                collection.averageSize = MongoExplain.number(stats?["avgObjSize"]).map { Int($0) }
            }
            collections.append(collection)
        }
        // References: one probe per candidate path, the first that holds.
        let cap = min(MongoSchema.exampleLimit, rowCap)
        for candidate in MongoSchemaSummary.candidates(collections) {
            guard let index = collections.firstIndex(where: { $0.name == candidate.collection }),
                  collections[index].references[candidate.path] == nil else { continue }
            guard Date().timeIntervalSince(started) < seconds else {
                capped = true
                break
            }
            let values = Array(candidate.probe.prefix(cap))
            let filter = BSONDocument([(candidate.field, .document(BSONDocument([("$in", .array(values))])))])
            let projection = BSONDocument([(candidate.field, .int32(1))])
            let reply = try await mongo(.find(db: db, collection: candidate.target, filter: filter, projection: projection,
                                              limit: values.count), wanted: values.count)
            collections[index].references[candidate.path] = MongoSchemaSummary.reference(candidate, hits: reply["count"] as? Int ?? 0,
                                                                                        of: values.count)
        }
        let (text, trimmed) = MongoSchemaSummary.text(collections, database: db, values: access.rank >= AgentAccess.schemaRead.rank)
        let hash = MongoSchemaSummary.hash(text)
        if let earlier = arguments["if_changed_from"] as? String, earlier == hash {
            return ["connection": saved.displayName, "database": db, "hash": hash, "unchanged": true]
        }
        return ["connection": saved.displayName, "database": db, "hash": hash, "unchanged": false, "text": text,
                "capped": capped || trimmed]
    }
}
