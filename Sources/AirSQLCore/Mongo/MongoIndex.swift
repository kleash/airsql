import Foundation

/// A collection's index as its Indexes page shows it (mongo-plan, Indexes): listIndexes' description, its size from
/// `$collStats` and its use from `$indexStats`, which counts on one member only, since that member started or the index
/// was made. The commands that change indexes are made here, so the preview shows exactly what the session sends.
public struct MongoIndex: Sendable, Equatable {
    /// listIndexes' description: v, key, name and its options (or `$indexStats`' spec while it is being built).
    public var spec: BSONDocument
    /// Its size on disk, in bytes.
    public var size: Int64?
    /// How many operations used it on `host` since `since`.
    public var ops: Int64?
    public var since: Date?
    public var host: String?
    /// Still being built: not in listIndexes yet.
    public var building = false

    public init(spec: BSONDocument) { self.spec = spec }

    public var name: String {
        if case .string(let name)? = spec["name"] { return name }
        return ""
    }

    public var keys: BSONDocument {
        if case .document(let keys)? = spec["key"] { return keys }
        return BSONDocument()
    }

    public var isHidden: Bool { spec["hidden"] == .bool(true) }

    /// What sets it apart, in a few words each: unique, sparse, TTL 3600 s, partial { … }, collation fr, hidden, and its
    /// kind when not a plain one (text, 2dsphere, 2d, hashed, wildcard).
    public var options: [String] {
        var found: [String] = []
        let kinds = keys.fields.compactMap { field -> String? in
            if field.key == "$**" || field.key.hasSuffix(".$**") { return "wildcard" }
            if case .string(let kind) = field.value { return kind }
            return nil
        }
        for kind in kinds where !found.contains(kind) { found.append(kind) }
        if spec["unique"] == .bool(true) { found.append("unique") }
        if spec["sparse"] == .bool(true) { found.append("sparse") }
        if let seconds = spec["expireAfterSeconds"]?.integer { found.append("TTL \(seconds) s") }
        if case .document(let filter)? = spec["partialFilterExpression"] { found.append("partial " + filter.shellForm()) }
        if case .document(let collation)? = spec["collation"] {
            if case .string(let locale)? = collation["locale"] { found.append("collation " + locale) } else { found.append("collation") }
        }
        if isHidden { found.append("hidden") }
        return found
    }

    // MARK: Commands

    /// createIndexes for one index on `keys`; without a name in `options`, the name mongosh would give it ("a_1_b_-1").
    public static func createCommand(collection: String, keys: BSONDocument, options: BSONDocument = BSONDocument()) -> BSONDocument {
        var index = BSONDocument([("key", .document(keys))] + options.fields)
        if index["name"] == nil {
            index.fields.insert(("name", .string(keys.fields.map { "\($0.key)_\($0.value.indexNamePart)" }.joined(separator: "_"))), at: 1)
        }
        return BSONDocument([("createIndexes", .string(collection)), ("indexes", .array([.document(index)]))])
    }

    /// The keys and options the Create Index sheet's fields give (each in shell form, empty when not set), or which field
    /// is wrong and why.
    public static func create(keys: String, name: String = "", unique: Bool = false, sparse: Bool = false, hidden: Bool = false,
                              expireAfterSeconds ttl: String = "", partial: String = "",
                              collation: String = "") throws -> (keys: BSONDocument, options: BSONDocument) {
        typealias Problem = MongoQueryText.Problem
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        func document(_ text: String, _ field: String) throws -> BSONDocument? {
            guard !trimmed(text).isEmpty else { return nil }
            do { return try BSONDocument(shellForm: text) } catch { throw Problem(field: field, message: "\(error)") }
        }
        guard let keys = try document(keys, "Keys"), !keys.fields.isEmpty else {
            throw Problem(field: "Keys", message: "Name at least one field, such as { field: 1 }")
        }
        var options: [(key: String, value: BSONValue)] = []
        if !trimmed(name).isEmpty { options.append(("name", .string(trimmed(name)))) }
        if unique { options.append(("unique", .bool(true))) }
        if sparse { options.append(("sparse", .bool(true))) }
        if !trimmed(ttl).isEmpty {
            guard let seconds = Int32(trimmed(ttl)), seconds >= 0 else {
                throw Problem(field: "Expire After", message: "Type a whole number of seconds, 0 or more")
            }
            options.append(("expireAfterSeconds", .int32(seconds)))
        }
        if let filter = try document(partial, "Partial Filter") { options.append(("partialFilterExpression", .document(filter))) }
        if let collation = try document(collation, "Collation") { options.append(("collation", .document(collation))) }
        if hidden { options.append(("hidden", .bool(true))) }
        return (keys, BSONDocument(options))
    }

    public static func dropCommand(collection: String, name: String) -> BSONDocument {
        BSONDocument([("dropIndexes", .string(collection)), ("index", .string(name))])
    }

    /// collMod that hides an index from the planner (it is still kept up to date), or shows it again.
    public static func hideCommand(collection: String, name: String, hidden: Bool) -> BSONDocument {
        BSONDocument([("collMod", .string(collection)),
                      ("index", .document(BSONDocument([("name", .string(name)), ("hidden", .bool(hidden))])))])
    }

    /// A command as mongosh runs it: what the preview shows and Copy Commands copies.
    public static func shellForm(_ command: BSONDocument, database: String) -> String {
        "db.getSiblingDB(\(BSONValue.string(database).shellForm())).runCommand(\(command.shellForm()))"
    }

    /// Why an index wasn't made, in plain words: a unique index over documents that share a key names the first
    /// duplicate the server found.
    public static func createFailure(_ error: Error) -> String {
        guard let error = error as? AirSQLError, error.kind == .duplicate else { return error.localizedDescription }
        let duplicate = error.details.range(of: "dup key: ").map { String(error.details[$0.upperBound...]) }
        return "The index can't be unique: some documents share the same keys"
            + (duplicate.map { ", such as \($0.trimmingCharacters(in: .whitespaces))." } ?? ".")
            + " Remove the duplicates, or make the index without Unique."
    }
}

extension MongoSession {
    /// The collection's indexes with their sizes and use; when sizes or use can't be read (a view, a time-series, a
    /// user without the privilege), the indexes come without them, and `unavailable` says why.
    public func indexes(database: String, collection: String) async throws -> (indexes: [MongoIndex], unavailable: String?) {
        var found = try await listIndexes(database: database, collection: collection).map(MongoIndex.init)
        var problems: [String] = []
        do {
            if case .document(let sizes)? = try await collectionStats(database: database, collection: collection)["indexSizes"] {
                for i in found.indices { found[i].size = sizes[found[i].name]?.integer }
            }
        } catch {
            problems.append("sizes: " + error.localizedDescription)
        }
        do {
            for stats in try await indexStats(database: database, collection: collection) {
                guard case .string(let name)? = stats["name"] else { continue }
                var at = found.firstIndex { $0.name == name }
                if at == nil, case .document(let spec)? = stats["spec"] {
                    found.append(MongoIndex(spec: spec))
                    at = found.count - 1
                }
                guard let at else { continue }
                found[at].building = stats["building"] == .bool(true)
                if case .string(let host)? = stats["host"] { found[at].host = host }
                if case .document(let accesses)? = stats["accesses"] {
                    found[at].ops = accesses["ops"]?.integer
                    if case .datetime(let ms)? = accesses["since"] { found[at].since = Date(timeIntervalSince1970: Double(ms) / 1000) }
                }
            }
        } catch {
            problems.append("use: " + error.localizedDescription)
        }
        return (found, problems.isEmpty ? nil : problems.joined(separator: "; "))
    }

    /// `$indexStats`: each index's use on the member that answers, since it started.
    public func indexStats(database: String, collection: String) async throws -> [BSONDocument] {
        try await all(aggregate(database: database, collection: collection,
                                pipeline: [BSONDocument([("$indexStats", .document(BSONDocument()))])]))
    }

    /// Hides an index from the query planner (still kept up to date), or shows it again.
    public func setIndexHidden(database: String, collection: String, name: String, hidden: Bool) async throws {
        _ = try await command(MongoIndex.hideCommand(collection: collection, name: name, hidden: hidden), database: database)
    }
}
