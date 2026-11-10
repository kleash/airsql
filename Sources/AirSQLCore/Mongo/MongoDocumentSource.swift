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
        return Self.value(at: paths[column], in: documents[row])
    }

    /// Decodes only the value at a path: the lengths lead to its element, which is read as a one-field document.
    /// (`BSONDocument.value(at:in:)` checks every string it passes, which is seconds for a cell beside a 16 MB one.)
    static func value(at path: [String], in b: [UInt8]) -> BSONValue? {
        var (start, end) = (0, b.count)
        for (depth, key) in path.enumerated() {
            var hit: (type: UInt8, element: Int, at: Int, end: Int)?
            elements(b, start, end) { name, type, element, at, valueEnd in
                guard name == key else { return true }
                hit = (type, element, at, valueEnd)
                return false
            }
            guard let hit else { return nil }
            if depth == path.count - 1 {
                let size = UInt32(hit.end - hit.element + 5)
                let one = (0..<4).map { UInt8(truncatingIfNeeded: size >> (8 * $0)) } + b[hit.element..<hit.end] + [0]
                return (try? BSONDocument(bytes: one))?.fields.first?.value
            }
            guard hit.type == 0x03 else { return nil }
            (start, end) = (hit.at, hit.end)
        }
        return nil
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
        Self.elements(b, start, end) { name, type, _, at, valueEnd in
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

    /// Each element of the document in `b[start..<end]`: its key, type byte, start and value's bounds, from the lengths
    /// alone (no value is decoded), until `each` returns false. Stops quietly at bytes it can't read: their fields then
    /// show as missing.
    static func elements(_ b: [UInt8], _ start: Int, _ end: Int, _ each: (String, UInt8, Int, Int, Int) -> Bool) {
        func int32(_ i: Int, _ limit: Int) -> Int? {
            guard i >= 0, i + 4 <= limit else { return nil }
            return Int(Int32(bitPattern: UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24))
        }
        guard let n = int32(start, end), n >= 5, n <= end - start else { return }
        let last = start + n - 1
        var i = start + 4
        while i < last {
            let type = b[i]
            guard let zero = b[(i + 1)..<last].firstIndex(of: 0) else { return }
            let at = zero + 1
            let size: Int?
            switch type {
            case 0x01, 0x09, 0x11, 0x12: size = 8
            case 0x10: size = 4
            case 0x13: size = 16
            case 0x07: size = 12
            case 0x08: size = 1
            case 0x06, 0x0A, 0xFF, 0x7F: size = 0
            case 0x02, 0x0D, 0x0E: size = int32(at, last).map { $0 + 4 }
            case 0x03, 0x04, 0x0F: size = int32(at, last)
            case 0x05: size = int32(at, last).map { $0 + 5 }
            case 0x0C: size = int32(at, last).map { $0 + 16 }
            case 0x0B:
                let pattern = b[at..<last].firstIndex(of: 0)
                size = pattern.flatMap { p in b[(p + 1)..<last].firstIndex(of: 0).map { $0 + 1 - at } }
            default: size = nil
            }
            guard let size, size >= 0, size <= last - at else { return }
            guard each(String(decoding: b[(i + 1)..<zero], as: UTF8.self), type, i, at, at + size) else { return }
            i = at + size
        }
    }
}
