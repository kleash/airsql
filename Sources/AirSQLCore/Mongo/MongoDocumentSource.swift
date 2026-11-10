import Foundation

/// A collection's documents as the grid shows them (mongo-plan, Collection tab): a row per document, kept as the BSON
/// bytes the server sent; a column per dotted path, in the order keys first appear (`_id` first). A sub-document is one
/// column until it is expanded into its fields' columns; an array is always one cell. Only the cells on screen are
/// decoded, from the bytes, and a missing field differs from null: it shows blank, with "missing" as its tooltip.
///
/// Like `ResultSetSource`, it tells nobody about changes: the host calls the viewer's `reloadData()` after `append`
/// (which says whether the columns changed) and after `setExpanded`.
public final class MongoDocumentSource: GridSource {
    public private(set) var columns: [GridColumn] = []
    /// Each column's path, keys from the top: ["address", "city"] is `address.city`.
    public private(set) var paths: [[String]] = []
    /// The most characters a cell shows (never cut: `_id`).
    static let shownLimit = 1_000
    /// Cells decoded so far, for the tests: only those asked for are.
    var decodes = 0

    private var documents: [[UInt8]] = []
    /// Paths are their keys joined by NUL, which no BSON key holds. "" is the top.
    private var children: [String: [String]] = ["": []]
    private var known: Set<String> = []
    /// How many documents hold each path, by BSON type byte.
    private var types: [String: [UInt8: Int]] = [:]
    private var expanded: Set<String> = []
    private var cache: [Int: GridCell] = [:]
    /// shortcut: the cache is dropped whole when full, an LRU if scrolling back ever shows in a profile.
    private static let cacheLimit = 20_000

    public init() {}

    public var rowCount: Int { documents.count }

    /// Adds a page of documents (each one's whole BSON bytes) after the loaded ones; true when it brought new columns (the
    /// headers' types and "missing in" counts may change with any page).
    @discardableResult
    public func append(_ page: [[UInt8]]) -> Bool {
        for bytes in page {
            scan(bytes, 0, bytes.count, parent: "", depth: 0)
            documents.append(bytes)
        }
        return rebuild()
    }

    /// The document behind a row, decoded whole; nil when its bytes can't be read.
    public func document(_ row: Int) -> BSONDocument? { try? BSONDocument(bytes: documents[row]) }

    /// The document's bytes as the server sent them.
    public func bytes(_ row: Int) -> [UInt8] { documents[row] }

    /// A cell's BSON value (the value panel, editing); nil when the document has no such field.
    public func bsonValue(_ row: Int, _ column: Int) -> BSONValue? {
        decodes += 1
        return try? BSONDocument.value(at: paths[column], in: documents[row]) ?? nil
    }

    /// A sub-document column, which `setExpanded` can turn into its fields' columns.
    public func canExpand(_ column: Int) -> Bool {
        let path = Self.key(paths[column])
        return types[path]?[0x03] != nil && !(children[path] ?? []).isEmpty
    }

    /// Shows a sub-document's fields as columns in its place, or one column again; kept per path, so collapsing a parent
    /// and expanding it again brings back what was expanded under it. True when the columns changed.
    @discardableResult
    public func setExpanded(_ path: [String], _ on: Bool) -> Bool {
        let key = Self.key(path)
        if on { expanded.insert(key) } else { expanded.remove(key) }
        return rebuild()
    }

    public func isExpanded(_ path: [String]) -> Bool { expanded.contains(Self.key(path)) }

    public func cell(_ row: Int, _ column: Int) -> GridCell {
        let slot = row &* max(columns.count, 1) &+ column
        if let hit = cache[slot] { return hit }
        let shown: GridCell
        switch bsonValue(row, column) {
        case nil: shown = .text("")
        case .null?: shown = .null
        case let value?: shown = .text(value.shellForm(maxLength: columns[column].isKey ? nil : Self.shownLimit))
        }
        if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[slot] = shown
        return shown
    }

    /// The whole value: numbers as plain digits, so that the status bar adds them up; other types in shell form. Nil for
    /// null and missing.
    public func value(_ row: Int, _ column: Int) -> String? {
        switch bsonValue(row, column) {
        case nil, .null?: return nil
        case .int32(let n)?: return String(n)
        case .int64(let n)?: return String(n)
        case .double(let d)?: return BSONValue.doubleText(d)
        case .decimal128(let d)?: return d.description
        case let value?: return value.shellForm()
        }
    }

    public func note(_ row: Int, _ column: Int) -> String? {
        bsonValue(row, column) == nil ? "Missing: this document has no such field" : nil
    }

    // MARK: - Columns

    static func key(_ path: [String]) -> String { path.joined(separator: "\0") }

    /// Records each field's path and type, recursing into sub-documents (not arrays).
    private func scan(_ b: [UInt8], _ start: Int, _ end: Int, parent: String, depth: Int) {
        // Bytes it can't read stop the scan quietly: their fields then show as missing.
        _ = try? BSONReader(b: b).elements(at: start, end: end) { name, type, at, valueEnd in
            let path = parent.isEmpty ? name : parent + "\0" + name
            if known.insert(path).inserted { children[parent, default: []].append(name) }
            types[path, default: [:]][type, default: 0] += 1
            if type == 0x03, depth < BSONDocument.maxDepth { scan(b, at, valueEnd, parent: path, depth: depth + 1) }
            return true
        }
    }

    private func rebuild() -> Bool {
        var order: [String] = []
        func add(_ parent: String) {
            var names = children[parent] ?? []
            if parent.isEmpty, let id = names.firstIndex(of: "_id") { names.insert(names.remove(at: id), at: 0) }
            for name in names {
                let path = parent.isEmpty ? name : parent + "\0" + name
                if expanded.contains(path), !(children[path] ?? []).isEmpty { add(path) } else { order.append(path) }
            }
        }
        add("")
        let old = paths
        paths = order.map { $0.split(separator: "\0", omittingEmptySubsequences: false).map(String.init) }
        columns = order.map(column)
        cache.removeAll()
        return paths != old
    }

    /// The column for a path: its type, or "mixed" with the types it holds most often first; its kind when every
    /// non-null value agrees.
    private func column(_ path: String) -> GridColumn {
        let counts = types[path] ?? [:]
        let held = counts.filter { $0.key != 0x0A }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
        let present = counts.values.reduce(0, +)
        var marks: GridColumn.Marks = counts[0x0A] != nil || present < documents.count ? .nullable : []
        let isId = path == "_id"
        if isId { marks.insert(.primary) }
        let names = held.map { Self.typeNames[$0] ?? "?" }
        let type = names.count > 1 ? "mixed: " + names.joined(separator: ", ") : names.first ?? (counts.isEmpty ? "" : "null")
        let missing = documents.count - present
        return GridColumn(name: path.replacingOccurrences(of: "\0", with: "."), type: type, kind: Self.kind(held), isKey: isId,
                          marks: marks, comment: missing > 0 ? "missing in \(missing) of \(documents.count) documents" : "")
    }

    static func kind(_ held: [UInt8]) -> GridColumn.Kind {
        let kinds = Set(held.map { type -> GridColumn.Kind in
            switch type {
            case 0x01, 0x10, 0x12, 0x13: return .number
            case 0x09: return .date
            case 0x05: return .binary
            case 0x03, 0x04: return .json
            default: return .text
            }
        })
        return kinds.count == 1 ? kinds.first! : .text
    }

    /// `$type`'s names, as `BSONValue.typeAlias` gives them, by type byte.
    static let typeNames: [UInt8: String] = [
        0x01: "double", 0x02: "string", 0x03: "object", 0x04: "array", 0x05: "binData", 0x06: "undefined", 0x07: "objectId",
        0x08: "bool", 0x09: "date", 0x0A: "null", 0x0B: "regex", 0x0C: "dbPointer", 0x0D: "javascript", 0x0E: "symbol",
        0x0F: "javascriptWithScope", 0x10: "int", 0x11: "timestamp", 0x12: "long", 0x13: "decimal", 0xFF: "minKey",
        0x7F: "maxKey",
    ]
}
