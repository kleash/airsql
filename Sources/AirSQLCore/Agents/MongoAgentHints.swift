import Foundation

/// Errors and warnings that teach (mongo-plan, Phase 3, Agents): a server's error on mongo_find, mongo_aggregate or
/// mongo_explain as `{code, codeName, message, stage?, hint?}`, with the nearest operator or stage for an unknown one
/// and the version a newer one needs; and warnings on a reply that is likely wrong, from the collection's sample: a path
/// not in it, a literal of a type the field never has there. A sample only shows what it holds, so a warning says "not
/// in the sample", never "doesn't exist".
enum MongoAgentHints {
    // MARK: Errors

    /// The names MongoDB gives the codes agents meet most; a code without a name of its own is "Location<code>".
    static let codeNames: [Int: String] = [
        2: "BadValue", 9: "FailedToParse", 13: "Unauthorized", 14: "TypeMismatch", 16: "InvalidLength",
        20: "IllegalOperation", 26: "NamespaceNotFound", 27: "IndexNotFound", 50: "MaxTimeMSExpired",
        72: "InvalidOptions", 115: "CommandNotSupported", 168: "InvalidPipelineOperator", 263: "OperationNotSupportedInTransaction",
        292: "QueryExceededMemoryLimitNoDiskUseAllowed", 11000: "DuplicateKey", 11601: "Interrupted",
    ]

    static func codeName(_ code: Int) -> String? {
        codeNames[code] ?? (code >= 10_000 ? "Location\(code)" : nil)
    }

    /// The server's error as JSON text in the message, for the agent to read; AirSQL's own errors (code 0) as they are.
    static func teach(_ error: AirSQLError, _ request: MongoAgentRequest, version: String?) -> AirSQLError {
        guard error.code != 0 else { return error }
        let prefix = "Error \(error.code): "
        let message = error.details.hasPrefix(prefix) ? String(error.details.dropFirst(prefix.count)) : error.message
        var entry: [String: Any] = ["code": error.code, "message": message]
        if let name = codeName(error.code) { entry["codeName"] = name }
        if let word = unknownWord(message) {
            if let stage = stage(of: word, in: request) { entry["stage"] = stage }
            if let hint = hint(word, version: version) { entry["hint"] = hint }
        }
        return AirSQLError(error.kind, AgentJSON.text(entry), code: error.code)
    }

    /// The `$word` a server's "Unrecognized …" or "unknown … operator" message names: the first MongoDB doesn't have
    /// ("Invalid $project :: … Unrecognized expression '$concatt'"), else the first.
    static func unknownWord(_ message: String) -> String? {
        let lower = message.lowercased()
        guard lower.contains("unrecognized") || lower.contains("unknown") || lower.contains("invalid") else { return nil }
        let words = message.indices.filter { message[$0] == "$" && message.index(after: $0) < message.endIndex
            && message[message.index(after: $0)].isLetter }.map { String(message[$0...].prefix { $0 == "$" || $0.isLetter || $0.isNumber }) }
        return words.first { MongoWords.named($0).isEmpty } ?? words.first
    }

    /// The version a newer word needs, or the nearest word for one MongoDB doesn't have.
    static func hint(_ word: String, version: String?, among words: [MongoWord] = MongoWords.all) -> String? {
        let known = words.filter { $0.name == word }
        if !known.isEmpty {
            guard let version, let newer = known.first(where: { !$0.isAvailable(on: version) }), let since = newer.since else {
                return nil  // a known word in the wrong place: the server's message says where
            }
            return "\(word) needs MongoDB \(since); this server runs \(version)"
        }
        var seen = Set<String>()
        let names = words.map(\.name).filter { seen.insert($0).inserted }
        guard let near = SQLInspections.closest(to: word, in: names), let found = words.first(where: { $0.name == near })
        else { return nil }
        return "Did you mean \(near)? \(found.summary)"
    }

    /// The guard's refusal, with the nearest stage for one MongoDB doesn't have (`$gruop`: `$group`).
    static func refused(_ refusal: MongoAgentRefusal) -> String {
        let text = "Refused: \(refusal)."
        let suffix = " isn't a stage agents may use"
        guard refusal.reason.hasSuffix(suffix) else { return text }
        let name = String(refusal.reason.dropLast(suffix.count))
        guard MongoWords.stage(name) == nil, let hint = hint(name, version: nil, among: MongoWords.stages) else { return text }
        return text + " " + hint
    }

    /// The index of the first stage of an aggregate (or its explain) that holds `word` as a key.
    static func stage(of word: String, in request: MongoAgentRequest) -> Int? {
        switch request {
        case let .aggregate(_, _, pipeline, _, _):
            return pipeline.firstIndex { stage in
                var found = false
                stage.walk { path, _ in if case .key(word)? = path.last { found = true } }
                return found
            }
        case let .explain(inner, _): return stage(of: word, in: inner)
        default: return nil
        }
    }

    // MARK: Warnings

    /// What may make the reply wrong, from the collection's sample: the paths of a find's filter, sort and projection
    /// (an aggregate's: of its leading $match and $sort stages, before the documents change shape) that the sample
    /// lacks, and literals of a type the field never has there. `matched` 0 adds a line when there is a warning.
    static func warnings(_ request: MongoAgentRequest, sample: MongoSample, matched: Int? = nil) -> [String] {
        var paths: [String] = [], literals: [(path: String, value: BSONValue)] = []
        func filter(_ document: BSONDocument) {
            for (key, value) in document.fields {
                if ["$and", "$or", "$nor"].contains(key), case .array(let list) = value {
                    for case .document(let inner) in list { filter(inner) }
                }
                guard !key.hasPrefix("$") else { continue }
                paths.append(key)
                if case .document(let operators) = value, operators.keys.first?.hasPrefix("$") == true {
                    for (name, operand) in operators.fields {
                        switch (name, operand) {
                        case ("$eq", _), ("$ne", _), ("$gt", _), ("$gte", _), ("$lt", _), ("$lte", _): literals.append((key, operand))
                        case ("$in", .array(let values)), ("$nin", .array(let values)): literals += values.map { (key, $0) }
                        default: break
                        }
                    }
                } else {
                    literals.append((key, value))
                }
            }
        }
        /// Only fields kept or dropped by name: a computed one is new.
        func named(_ document: BSONDocument?) {
            for (key, value) in document?.fields ?? [] where !key.hasPrefix("$") {
                switch value {
                case .int32, .int64, .double, .bool: paths.append(key)
                default: break
                }
            }
        }
        switch request {
        case let .find(_, _, query, projection, sort, _, _, _, _):
            filter(query)
            named(sort)
            named(projection)
        case let .aggregate(_, _, pipeline, _, _):
            for stage in pipeline {
                guard let (name, spec) = stage.fields.first else { break }
                if name == "$match", case .document(let query) = spec { filter(query) }
                else if name == "$sort", case .document(let order) = spec { named(order) }
                else if !["$limit", "$skip"].contains(name) { break }
            }
        case let .explain(inner, _):
            return warnings(inner, sample: sample, matched: matched)
        default: return []
        }
        let documents = sample.schema.documents
        guard documents > 0 else { return [] }
        let known = Dictionary(grouping: sample.paths, by: normalized)
        // A sample with too many paths to list may lack some it holds.
        let complete = sample.schema.fields.count < MongoSampleCache.pathLimit
        var warnings: [String] = [], warned = Set<String>()
        let of = "the sample of \(documents) document\(documents == 1 ? "" : "s")"
        for path in paths where warned.insert(path).inserted {
            let plain = normalized(path)
            guard known[plain] == nil, complete, !plain.isEmpty else { continue }
            let nearest = SQLInspections.closest(to: plain, in: Array(known.keys)) ?? closestEnd(plain, in: Array(known.keys))
            warnings.append("\(path) is not in \(of)" + (nearest.map { "; nearest: \($0)" } ?? ""))
        }
        for (path, value) in literals where known[normalized(path)] != nil && !warned.contains("type " + path) {
            let type = value.typeAlias
            guard !["null", "regex", "array", "object", "minKey", "maxKey"].contains(type) else { continue }
            var seen = Set<String>()
            let types = sample.schema.fields.filter { normalized($0.path) == normalized(path) }
                .flatMap { $0.types.map(\.name) }.filter { !["null", "array"].contains($0) && seen.insert($0).inserted }
            guard !types.isEmpty, !types.contains(where: { compatible($0, type) }) else { continue }
            warned.insert("type " + path)
            warnings.append("\(path) is \(types.joined(separator: " or ")) in \(of), never \(type): "
                            + (types.first.map(literal) ?? "a value of that type"))
        }
        if matched == 0, !warnings.isEmpty {
            warnings.append("Nothing matched, which the warnings above may explain.")
        }
        return warnings
    }

    /// A path as a query names it, without array steps: `items.[].sku` and `items.0.sku` are `items.sku`.
    static func normalized(_ path: String) -> String {
        path.split(separator: ".", omittingEmptySubsequences: false)
            .filter { $0 != "[]" && $0 != "$" && $0 != "$[]" && !($0.allSatisfy(\.isNumber) && !$0.isEmpty) }
            .joined(separator: ".")
    }

    /// A known path whose last step is near the typed one's (`customer_id` for `customerid`), when the whole isn't near.
    private static func closestEnd(_ path: String, in known: [String]) -> String? {
        let last = path.split(separator: ".").last.map(String.init) ?? path
        let ends = known.map { $0.split(separator: ".").last.map(String.init) ?? $0 }
        guard let near = SQLInspections.closest(to: last, in: ends) else { return nil }
        return known.first { ($0.split(separator: ".").last.map(String.init) ?? $0) == near }
    }

    private static func compatible(_ a: String, _ b: String) -> Bool {
        a == b || (MongoWords.numbers.contains(a) && MongoWords.numbers.contains(b))
    }

    /// How to write a literal of `type` in Extended JSON.
    private static func literal(_ type: String) -> String {
        switch type {
        case "date": return "compare with {\"$date\": \"2024-03-01T00:00:00Z\"} (ISODate(…) in the shell)"
        case "objectId": return "compare with {\"$oid\": \"<24 hex digits>\"} (ObjectId(…) in the shell)"
        case "decimal": return "compare with {\"$numberDecimal\": \"9.99\"} or a number, not a string"
        case "int", "long", "double": return "compare with a number, not a string"
        case "string": return "compare with a string in quotes"
        case "bool": return "compare with true or false"
        default: return "compare with a value of that type"
        }
    }
}
