import Foundation

/// What a compare of two collections leaves out.
public struct MongoCompareOptions: Sendable, Equatable {
    /// Fields in another order don't make two documents differ (to the server they do: `$eq` on a sub-document).
    public var ignoreKeyOrder = false
    /// Dotted paths left out of the compare, and all under them ("updatedAt", "meta.seen"); written without array
    /// indexes, "items.price" covers every item's price.
    public var ignoredPaths: [String] = []

    public init(ignoreKeyOrder: Bool = false, ignoredPaths: [String] = []) {
        self.ignoreKeyOrder = ignoreKeyOrder
        self.ignoredPaths = ignoredPaths
    }

    /// The paths typed in a field, separated by commas or spaces.
    public static func paths(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }
}

/// Where two documents differ.
public enum MongoDiff {
    /// The dotted paths where `target` differs from `source` (a value, its type, a field only on one side, an array
    /// element); a sub-document's own path when only its fields' order differs ("" for the document's top level). Empty:
    /// the same, as the options see them.
    public static func paths(_ source: BSONDocument, _ target: BSONDocument, _ options: MongoCompareOptions = MongoCompareOptions()) -> [String] {
        var found: [String] = []
        let ignored = Set(options.ignoredPaths)
        func isIgnored(_ path: [BSONPathSegment]) -> Bool {
            !ignored.isEmpty && ignored.contains(path.compactMap { if case .key(let key) = $0 { return key } else { return nil } }.joined(separator: "."))
        }
        func compare(_ a: BSONValue?, _ b: BSONValue?, _ path: [BSONPathSegment]) {
            if isIgnored(path) { return }
            switch (a, b) {
            case let (.document(x)?, .document(y)?):
                documents(x, y, path)
            case let (.array(x)?, .array(y)?):
                for index in 0..<max(x.count, y.count) {
                    compare(index < x.count ? x[index] : nil, index < y.count ? y[index] : nil, path + [.index(index)])
                }
            case let (x?, y?) where x.typeExactEqual(y):
                break
            case (nil, nil):
                break
            default:
                found.append(path.dotted)
            }
        }
        func documents(_ x: BSONDocument, _ y: BSONDocument, _ path: [BSONPathSegment]) {
            // Keys as their bytes: Swift's String == takes "é" and "e\u{301}" as one, BSON doesn't.
            let left = x.keys.map { Array($0.utf8) }.filter { !isIgnored(path + [.key(String(decoding: $0, as: UTF8.self))]) }
            let right = y.keys.map { Array($0.utf8) }.filter { !isIgnored(path + [.key(String(decoding: $0, as: UTF8.self))]) }
            let (inLeft, inRight) = (Set(left), Set(right))
            if !options.ignoreKeyOrder, left.filter(inRight.contains) != right.filter(inLeft.contains) { found.append(path.dotted) }
            func value(_ key: [UInt8], in document: BSONDocument) -> BSONValue? {
                document.fields.first { $0.key.utf8.elementsEqual(key) }?.value
            }
            var seen = Set<[UInt8]>()
            for key in left + right where seen.insert(key).inserted {
                compare(value(key, in: x), value(key, in: y), path + [.key(String(decoding: key, as: UTF8.self))])
            }
        }
        documents(source, target, [])
        return found
    }
}

/// A collection on one side of a compare.
public struct MongoCompareSide: Sendable {
    public var session: MongoSession
    public var database: String
    public var collection: String

    public init(session: MongoSession, database: String, collection: String) {
        self.session = session
        self.database = database
        self.collection = collection
    }
}

/// What a compare of two collections found: their documents by `_id`, their indexes and their options (the validator).
public struct MongoCompareResult: Sendable {
    public enum Status: String, Sendable, CaseIterable {
        case onlyInSource, onlyInTarget, different, same
    }

    /// One `_id` that differs: the documents as read, and where they differ.
    public struct Item: Sendable {
        public var id: BSONValue
        public var status: Status
        public var source: BSONDocument?
        public var target: BSONDocument?
        public var paths: [String] = []

        public init(id: BSONValue, status: Status, source: BSONDocument? = nil, target: BSONDocument? = nil, paths: [String] = []) {
            self.id = id
            self.status = status
            self.source = source
            self.target = target
            self.paths = paths
        }
    }

    /// An index of either side, matched by its keys: its spec on each side and the options that differ.
    public struct Index: Sendable {
        public var keys: BSONDocument
        public var status: Status
        public var source: BSONDocument?
        public var target: BSONDocument?
        public var paths: [String] = []

        public init(keys: BSONDocument, status: Status, source: BSONDocument? = nil, target: BSONDocument? = nil, paths: [String] = []) {
            self.keys = keys
            self.status = status
            self.source = source
            self.target = target
            self.paths = paths
        }
    }

    public var options: MongoCompareOptions
    /// "shop.orders" on each side.
    public var sourceName: String
    public var targetName: String
    /// The target's kind (a collection when it doesn't exist yet): a view's or a time-series' documents aren't written.
    public var targetKind: MongoCollectionInfo.Kind = .collection
    /// The differences, as found: at most `MongoCompare.keep`.
    public var items: [Item] = []
    /// The `_id`s of the same documents (not the documents, to save memory): at most `MongoCompare.keep`.
    public var same: [BSONValue] = []
    /// Every `_id` counted, listed or not.
    public var counts: [Status: Int] = [:]
    /// Some differences weren't listed (over `MongoCompare.keep`): reconcile those listed, then compare again.
    public var truncated = false
    /// Two `_id`-sorted streams merged (every `_id` of one type); otherwise looked up by `$in`.
    public var merged = false
    public var indexes: [Index] = []
    /// listCollections' options of each side (the validator, its level and action, a collation, capped…): nil when
    /// the collection doesn't exist; and where they differ.
    public var sourceOptions: BSONDocument?
    public var targetOptions: BSONDocument?
    public var optionPaths: [String] = []
    public var duration: TimeInterval = 0

    public init(options: MongoCompareOptions, sourceName: String, targetName: String) {
        self.options = options
        self.sourceName = sourceName
        self.targetName = targetName
    }

    public func count(_ status: Status) -> Int { counts[status] ?? 0 }

    public var differs: Bool {
        count(.onlyInSource) + count(.onlyInTarget) + count(.different) > 0 || !optionPaths.isEmpty
            || indexes.contains { $0.status != .same }
    }

    mutating func add(_ item: Item) {
        counts[item.status, default: 0] += 1
        if item.status == .same {
            if same.count < MongoCompare.keep { same.append(item.id) }
        } else if items.count < MongoCompare.keep {
            items.append(item)
        } else {
            truncated = true
        }
    }

    /// The target's changes that make its documents match the source's: new documents (only in the source), whole
    /// documents put in place (different) and deletes (only in the target), each kind when asked. A document AirSQL
    /// can't write (a field name with . or $) is left out, with why.
    public func changes(database: String, collection: String, inserts: Bool, replaces: Bool,
                        deletes: Bool) throws -> (changes: MongoChanges, skipped: [String]) {
        var changes = MongoChanges(database: database, collection: collection, kind: targetKind)
        var skipped: [String] = []
        for item in items {
            do {
                switch (item.status, item.source, item.target) {
                case (.onlyInSource, let source?, _) where inserts: try changes.insert(source)
                case (.different, let source?, let target?) where replaces: try changes.replace(target, with: source)
                case (.onlyInTarget, _, let target?) where deletes: try changes.delete(target)
                default: break
                }
            } catch let error as AirSQLError where error.kind == .readOnly && targetKind == .collection {
                skipped.append("{ _id: \(item.id.shellForm(maxLength: 80)) }: \(error.message)")
            }
        }
        return (changes, skipped)
    }
}

/// Compares two collections, on one server or two (mongo-plan, Phase 2 compare): their documents by `_id`, reading both
/// in batches of at most 1,000 documents or 4 MB; their indexes by keys; their options. When every `_id` on both sides
/// is of one type that sorts plainly (ObjectId, string, int, long), two `_id`-sorted streams are merged; otherwise each
/// batch of the source is looked up in the target by `$in`, then the target's documents left over in the source.
/// Nothing is written.
public enum MongoCompare {
    /// The differences (and, apart, the same documents) a result lists at most: memory stays bounded.
    public static let keep = 10_000

    public struct Progress: Sendable {
        /// Documents read on both sides so far, and about how many there are (the collections' counts).
        public var read: Int
        public var total: Int
        public var step: String
    }

    public static func run(source: MongoCompareSide, target: MongoCompareSide, options: MongoCompareOptions,
                           progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> MongoCompareResult {
        let started = Date()
        var result = MongoCompareResult(options: options, sourceName: source.database + "." + source.collection,
                                        targetName: target.database + "." + target.collection)
        progress(Progress(read: 0, total: 0, step: "Reading the collections' options and indexes…"))
        func info(_ side: MongoCompareSide) async throws -> MongoCollectionInfo? {
            try await side.session.listCollections(database: side.database).first { $0.name.utf8.elementsEqual(side.collection.utf8) }
        }
        guard let left = try await info(source) else {
            throw AirSQLError(.notFound, "\(source.database) has no collection named \(source.collection).")
        }
        let right = try await info(target)
        result.targetKind = right?.kind ?? .collection
        result.sourceOptions = left.options
        result.targetOptions = right?.options
        result.optionPaths = MongoDiff.paths(left.options, right?.options ?? BSONDocument(), MongoCompareOptions(ignoreKeyOrder: options.ignoreKeyOrder))
        if left.kind != .view, right == nil || right?.kind != .view {
            result.indexes = indexes(try await source.session.listIndexes(database: source.database, collection: source.collection),
                                     right == nil ? [] : try await target.session.listIndexes(database: target.database, collection: target.collection))
        }

        progress(Progress(read: 0, total: 0, step: "Reading the types of the _ids…"))
        let types = try await source.session.idTypes(database: source.database, collection: source.collection)
            .union(right == nil ? [] : target.session.idTypes(database: target.database, collection: target.collection))
        // A collection with its own collation sorts strings by it; the merge needs binary order, which its index hasn't.
        let collated = left.options["collation"] != nil || right?.options["collation"] != nil
        result.merged = types.count <= 1 && types.isSubset(of: collated ? ["objectId", "int", "long"] : ["objectId", "string", "int", "long"])
        let total = Int(try await source.session.estimatedCount(database: source.database, collection: source.collection))
            + Int(right == nil ? 0 : try await target.session.estimatedCount(database: target.database, collection: target.collection))
        var read = 0
        let step = result.merged ? "Merging the documents in _id order" : "Looking the documents up by _id"
        func advance(_ count: Int) {
            read += count
            progress(Progress(read: read, total: max(total, read), step: step))
        }
        advance(0)
        if right == nil {
            try await each(source, sorted: false) { batch in
                for bytes in batch { result.add(try item(id(bytes), source: bytes, target: nil, options)) }
                advance(batch.count)
            }
        } else if result.merged {
            try await merge(source, target, options, into: &result, advance: advance)
        } else {
            try await lookUp(source, target, options, into: &result, advance: advance)
        }
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    // MARK: Documents

    /// Classifies one `_id`'s documents (nil: not on that side). Equal bytes are the same without decoding them.
    static func item(_ id: BSONValue, source: [UInt8]?, target: [UInt8]?, _ options: MongoCompareOptions) throws -> MongoCompareResult.Item {
        switch (source, target) {
        case let (s?, t?):
            if s == t { return .init(id: id, status: .same) }
            let (a, b) = (try BSONDocument(bytes: s), try BSONDocument(bytes: t))
            let paths = MongoDiff.paths(a, b, options)
            return paths.isEmpty ? .init(id: id, status: .same) : .init(id: id, status: .different, source: a, target: b, paths: paths)
        case let (s?, nil): return .init(id: id, status: .onlyInSource, source: try BSONDocument(bytes: s))
        case let (nil, t?): return .init(id: id, status: .onlyInTarget, target: try BSONDocument(bytes: t))
        case (nil, nil): return .init(id: id, status: .same)
        }
    }

    static func id(_ bytes: [UInt8]) throws -> BSONValue {
        guard let id = try BSONDocument.value(at: ["_id"], in: bytes) else { throw AirSQLError(.other, "A document has no _id to compare it by.") }
        return id
    }

    /// The order of two `_id`s of one sortable type, as the server sorts them with the simple collation.
    static func order(_ a: BSONValue, _ b: BSONValue) throws -> Int {
        func compare<T: Comparable>(_ x: T, _ y: T) -> Int { x < y ? -1 : x == y ? 0 : 1 }
        func bytes<S: Sequence>(_ x: S, _ y: S) -> Int where S.Element == UInt8 {
            x.lexicographicallyPrecedes(y) ? -1 : y.lexicographicallyPrecedes(x) ? 1 : 0
        }
        switch (a, b) {
        case let (.objectId(x), .objectId(y)): return bytes(x.bytes, y.bytes)
        case let (.string(x), .string(y)): return bytes(Array(x.utf8), Array(y.utf8))
        case let (.int32(x), .int32(y)): return compare(x, y)
        case let (.int64(x), .int64(y)): return compare(x, y)
        default: throw AirSQLError(.other, "The _ids changed type during the compare (\(a.typeAlias), \(b.typeAlias)). Compare again.")
        }
    }

    /// Reads a side's documents in batches, closing the cursor however it ends.
    private static func each(_ side: MongoCompareSide, sorted: Bool, _ body: ([[UInt8]]) async throws -> Void) async throws {
        let cursor = try await side.session.scan(database: side.database, collection: side.collection, sorted: sorted)
        do {
            while true {
                try Task.checkCancellation()
                let batch = try await cursor.next()
                if batch.isEmpty { break }
                try await body(batch)
            }
        } catch {
            await cursor.close()
            throw error
        }
    }

    /// One side's documents in `_id` order, one at a time.
    private struct Stream {
        let cursor: MongoCursor
        var batch: [[UInt8]] = []
        var at = 0
        var last: BSONValue?

        init(_ cursor: MongoCursor) { self.cursor = cursor }

        mutating func next() async throws -> (id: BSONValue, bytes: [UInt8])? {
            if at == batch.count {
                try Task.checkCancellation()
                batch = try await cursor.next()
                at = 0
                if batch.isEmpty { return nil }
            }
            defer { at += 1 }
            let id = try MongoCompare.id(batch[at])
            // Out of order would pair the wrong documents: never trusted silently.
            if let last, try MongoCompare.order(last, id) >= 0 {
                throw AirSQLError(.other, "The documents didn't come in _id order, so they can't be merged. Compare again.")
            }
            last = id
            return (id, batch[at])
        }
    }

    private static func merge(_ source: MongoCompareSide, _ target: MongoCompareSide, _ options: MongoCompareOptions,
                              into result: inout MongoCompareResult, advance: (Int) -> Void) async throws {
        var left = Stream(try await source.session.scan(database: source.database, collection: source.collection, sorted: true))
        var right = Stream(try await target.session.scan(database: target.database, collection: target.collection, sorted: true))
        do {
            var (a, b) = (try await left.next(), try await right.next())
            var counted = 0
            while a != nil || b != nil {
                let side: Int
                switch (a, b) {
                case let (x?, y?): side = try order(x.id, y.id)
                case (_?, nil): side = -1
                default: side = 1
                }
                if side < 0 {
                    result.add(try item(a!.id, source: a!.bytes, target: nil, options))
                    a = try await left.next()
                    counted += 1
                } else if side > 0 {
                    result.add(try item(b!.id, source: nil, target: b!.bytes, options))
                    b = try await right.next()
                    counted += 1
                } else {
                    result.add(try item(a!.id, source: a!.bytes, target: b!.bytes, options))
                    (a, b) = (try await left.next(), try await right.next())
                    counted += 2
                }
                if counted >= 1_000 {
                    advance(counted)
                    counted = 0
                }
            }
            advance(counted)
        } catch {
            await left.cursor.close()
            await right.cursor.close()
            throw error
        }
    }

    /// An `_id` as its bytes: a key that tells 1 from NumberLong(1) and 1.0, as `$in` doesn't.
    private static func key(_ id: BSONValue) throws -> [UInt8] { try BSONDocument([("", id)]).bytes() }

    private static func lookUp(_ source: MongoCompareSide, _ target: MongoCompareSide, _ options: MongoCompareOptions,
                               into result: inout MongoCompareResult, advance: (Int) -> Void) async throws {
        // The source's documents, each batch's _ids looked up in the target.
        try await each(source, sorted: false) { batch in
            let ids = try batch.map(id)
            var found: [[UInt8]: [UInt8]] = [:]
            for bytes in try await target.session.lookUp(database: target.database, collection: target.collection, ids: ids, idsOnly: false) {
                found[try key(try id(bytes))] = bytes
            }
            for (id, bytes) in zip(ids, batch) { result.add(try item(id, source: bytes, target: found[try key(id)], options)) }
            advance(batch.count)
        }
        // Then the target's documents whose _id the source hasn't.
        try await each(target, sorted: false) { batch in
            let ids = try batch.map(id)
            let there = Set(try await source.session.lookUp(database: source.database, collection: source.collection, ids: ids, idsOnly: true)
                .map { try key(try id($0)) })
            for (id, bytes) in zip(ids, batch) where !there.contains(try key(id)) {
                result.add(try item(id, source: nil, target: bytes, options))
            }
            advance(batch.count)
        }
    }

    // MARK: Indexes

    /// The indexes matched by their keys (1 and NumberLong(1) alike, as the server takes them), and their options
    /// compared, the name, version and namespace aside.
    static func indexes(_ source: [BSONDocument], _ target: [BSONDocument]) -> [MongoCompareResult.Index] {
        func keys(_ spec: BSONDocument) -> BSONDocument { if case .document(let keys)? = spec["key"] { return keys } else { return BSONDocument() } }
        func sameKeys(_ a: BSONDocument, _ b: BSONDocument) -> Bool {
            a.fields.count == b.fields.count && zip(a.fields, b.fields).allSatisfy { $0.key.utf8.elementsEqual($1.key.utf8) && $0.value.indexNamePart == $1.value.indexNamePart }
        }
        func options(_ spec: BSONDocument) -> BSONDocument { BSONDocument(spec.fields.filter { !["v", "key", "name", "ns"].contains($0.key) }) }
        var left = target
        var found: [MongoCompareResult.Index] = []
        for spec in source {
            if let at = left.firstIndex(where: { sameKeys(keys($0), keys(spec)) }) {
                let paths = MongoDiff.paths(options(spec), options(left[at]), MongoCompareOptions(ignoreKeyOrder: true))
                found.append(.init(keys: keys(spec), status: paths.isEmpty ? .same : .different, source: spec, target: left[at], paths: paths))
                left.remove(at: at)
            } else {
                found.append(.init(keys: keys(spec), status: .onlyInSource, source: spec))
            }
        }
        return found + left.map { .init(keys: keys($0), status: .onlyInTarget, target: $0) }
    }
}
