import Foundation

/// The query bar of a collection tab as typed (mongo-plan, Query bar): each field in shell form, empty when unused.
/// `find()` reads it into the find it stands for, or says which field is wrong and where.
public struct MongoQueryText: Codable, Equatable, Sendable {
    public var filter = ""
    public var projection = ""
    public var sort = ""
    public var limit = ""
    public var skip = ""
    public var collation = ""
    public var hint = ""
    public var maxTimeMS = ""

    public init(filter: String = "", projection: String = "", sort: String = "", limit: String = "", skip: String = "",
                collation: String = "", hint: String = "", maxTimeMS: String = "") {
        self.filter = filter
        self.projection = projection
        self.sort = sort
        self.limit = limit
        self.skip = skip
        self.collation = collation
        self.hint = hint
        self.maxTimeMS = maxTimeMS
    }

    /// A field the bar couldn't read: which one, and why.
    public struct Problem: Error, Equatable, CustomStringConvertible {
        public let field: String
        public let message: String
        public var description: String { "\(field): \(message)" }
    }

    public var isEmpty: Bool { self == MongoQueryText() }

    /// The find these fields describe. A hint is an index's name (a string, quoted or not) or its keys (a document).
    public func find() throws -> MongoFind {
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        func document(_ text: String, _ field: String) throws -> BSONDocument? {
            guard !trimmed(text).isEmpty else { return nil }
            do { return try BSONDocument(shellForm: text) } catch { throw Problem(field: field, message: "\(error)") }
        }
        func count(_ text: String, _ field: String) throws -> Int64? {
            let text = trimmed(text)
            guard !text.isEmpty else { return nil }
            guard let number = Int64(text), number >= 0 else { throw Problem(field: field, message: "Type a whole number, 0 or more") }
            return number
        }
        var find = MongoFind(filter: try document(filter, "Filter") ?? BSONDocument())
        find.projection = try document(projection, "Project")
        find.sort = try document(sort, "Sort")
        find.collation = try document(collation, "Collation")
        find.limit = try count(limit, "Limit")
        find.skip = try count(skip, "Skip")
        find.maxTimeMS = try count(maxTimeMS, "Max Time").map { Int(clamping: $0) }
        let hint = trimmed(self.hint)
        if hint.hasPrefix("{") {
            find.hint = .document(try document(hint, "Hint")!)
        } else if !hint.isEmpty {
            let name = (try? BSONValue(shellForm: hint)).flatMap { if case .string(let name) = $0 { return name } else { return nil } }
            find.hint = .string(name ?? hint)
        }
        return find
    }

    /// The fields one line each, the empty ones left out, for the history's menu: "{ age: { $gt: 30 } } · sort { age: -1 }".
    public var summary: String {
        let parts = [("", filter), ("project ", projection), ("sort ", sort), ("skip ", skip), ("limit ", limit),
                     ("collation ", collation), ("hint ", hint), ("maxTimeMS ", maxTimeMS)]
        let shown = parts.map { ($0.0, $0.1.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.1.isEmpty }.map { $0.0 + $0.1 }
        return shown.isEmpty ? "{} (every document)" : shown.joined(separator: " · ")
    }
}

/// The queries run in each collection, and the ones kept as favourites (mongo-plan, Query bar): beside the SQL history
/// (`QueryHistory`), in MongoHistory/<connection>.json (0600), read and written on a queue of its own. Not masked by the
/// SQL scanner, which doesn't read shell form.
public final class MongoQueryHistory: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var database: String
        public var collection: String
        public var query: MongoQueryText
        public var date: Date
        public var favourite: Bool

        public init(database: String, collection: String, query: MongoQueryText, date: Date = Date(), favourite: Bool = false) {
            self.database = database
            self.collection = collection
            self.query = query
            self.date = date
            self.favourite = favourite
        }
    }

    public static let shared = MongoQueryHistory(directory: Store.directory.appendingPathComponent("MongoHistory", isDirectory: true))

    public let directory: URL
    /// Queries kept per collection besides the favourites; the oldest go first.
    let limit: Int
    private let queue = DispatchQueue(label: "com.kleash.airsql.mongo-history")

    public init(directory: URL, limit: Int = 50) {
        self.directory = directory
        self.limit = limit
    }

    func file(_ connection: UUID) -> URL { directory.appendingPathComponent(connection.uuidString + ".json") }

    /// The collection's queries, newest first.
    public func entries(_ connection: UUID, database: String, collection: String) async -> [Entry] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: read(connection).filter { $0.database == database && $0.collection == collection }
                    .sorted { $0.date > $1.date })
            }
        }
    }

    /// Notes a query run: it moves to the top (a favourite stays one); the collection keeps its newest `limit`.
    public func add(_ query: MongoQueryText, connection: UUID, database: String, collection: String) {
        change(connection) { all in
            let old = all.firstIndex { $0.database == database && $0.collection == collection && $0.query == query }
            let favourite = old.map { all[$0].favourite } ?? false
            if let old { all.remove(at: old) }
            all.append(Entry(database: database, collection: collection, query: query, favourite: favourite))
            let plain = all.indices.filter { all[$0].database == database && all[$0].collection == collection && !all[$0].favourite }
            let dropped = Set(plain.prefix(max(0, plain.count - self.limit)))
            all = all.indices.filter { !dropped.contains($0) }.map { all[$0] }
        }
    }

    /// Marks a query a favourite or not (one not run yet is added).
    public func setFavourite(_ favourite: Bool, _ query: MongoQueryText, connection: UUID, database: String, collection: String) {
        change(connection) { all in
            if let index = all.firstIndex(where: { $0.database == database && $0.collection == collection && $0.query == query }) {
                all[index].favourite = favourite
            } else if favourite {
                all.append(Entry(database: database, collection: collection, query: query, favourite: true))
            }
        }
    }

    /// Forgets the collection's queries but its favourites.
    public func clear(_ connection: UUID, database: String, collection: String) {
        change(connection) { all in all.removeAll { $0.database == database && $0.collection == collection && !$0.favourite } }
    }

    /// Waits for the writes asked for so far (tests).
    public func flush() { queue.sync {} }

    private func change(_ connection: UUID, _ body: @escaping (inout [Entry]) -> Void) {
        queue.async { [self] in
            var all = read(connection)
            body(&all)
            guard let data = try? JSONEncoder().encode(all) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = file(connection)
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func read(_ connection: UUID) -> [Entry] {
        guard let data = try? Data(contentsOf: file(connection)) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}
