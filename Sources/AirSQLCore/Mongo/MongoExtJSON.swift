import Foundation

// MongoDB Extended JSON v2 (the specifications repository's source/extended-json): what export writes and import
// reads. Pure Swift over BSONValue, with its own tokenizer: no Double detour for integers, no JSONSerialization
// (mongo-plan, risk 2). Legacy (v1) forms such as {"$date": 1356351330501} are refused with a hint, as the spec asks
// of a parser that isn't configured for them.

public enum ExtendedJSONMode: Sendable {
    /// Every type in a wrapper: {"$numberInt": "1"}, {"$date": {"$numberLong": "…"}}. Reads back to the same BSON.
    case canonical
    /// Plain JSON numbers for int32, int64 and finite doubles, and ISO dates from 1970 to 9999. Reads back with
    /// integers as the smallest type that holds them, so an int64 of 1 comes back an int32.
    case relaxed
}

extension BSONValue {
    /// The value in Extended JSON: one line with no spaces, or indented by two spaces (type wrappers stay on one line).
    public func extendedJSON(_ mode: ExtendedJSONMode = .relaxed, pretty: Bool = false) -> String {
        var out = ""
        ExtJSONFormatter(canonical: mode == .canonical, pretty: pretty).value(self, indent: 0, into: &out)
        return out
    }
}

extension BSONDocument {
    public func extendedJSON(_ mode: ExtendedJSONMode = .relaxed, pretty: Bool = false) -> String {
        BSONValue.document(self).extendedJSON(mode, pretty: pretty)
    }

    /// One document in Extended JSON, canonical or relaxed. Errors say where (line and column) and what.
    public init(extendedJSON text: String) throws {
        var parser = ExtJSONParser(buffer: Array(text.utf8), source: nil)
        try parser.skipSpace()
        guard try parser.peek() == UInt8(ascii: "{") else { throw parser.error("A document starts with ‘{’; found \(try parser.found())") }
        self = try parser.topDocument()
        try parser.skipSpace()
        guard try parser.peek() == nil else { throw parser.error("Expected the end of the text after the document, found \(try parser.found())") }
    }
}

/// Many documents to a file a part at a time, as `CopyWriter` writes rows: one document per line (JSON Lines; with
/// `pretty`, indented documents one after another, as mongoexport writes them) or one JSON array.
public struct ExtendedJSONWriter {
    public enum Layout: Sendable { case lines, array }

    public let mode: ExtendedJSONMode
    public let layout: Layout
    public let pretty: Bool
    public private(set) var documentsWritten = 0

    public init(_ mode: ExtendedJSONMode = .relaxed, layout: Layout = .lines, pretty: Bool = false) {
        self.mode = mode
        self.layout = layout
        self.pretty = pretty
    }

    public func header() -> String { layout == .array ? "[" : "" }

    public mutating func document(_ document: BSONDocument) -> String {
        defer { documentsWritten += 1 }
        let text = document.extendedJSON(mode, pretty: pretty)
        switch layout {
        case .lines: return text + "\n"
        case .array: return (documentsWritten == 0 ? "\n" : ",\n") + text
        }
    }

    public func footer() -> String {
        guard layout == .array else { return "" }
        return documentsWritten == 0 ? "]\n" : "\n]\n"
    }
}

/// Reads documents one at a time from JSON Lines, from documents one after another (any spacing), or from one
/// top-level array of documents, without holding more than a document and a 64 KB buffer: a 2 GB file streams.
public struct ExtendedJSONReader {
    private var parser: ExtJSONParser
    private var inArray: Bool?
    private var finished = false

    public init(_ handle: FileHandle) { parser = ExtJSONParser(buffer: [], source: handle) }

    public init(_ data: Data) { parser = ExtJSONParser(buffer: [UInt8](data), source: nil) }

    /// The next document, or nil at the end.
    public mutating func next() throws -> BSONDocument? {
        guard !finished else { return nil }
        if inArray == nil {
            try parser.skipByteOrderMark()
            try parser.skipSpace()
            inArray = try parser.peek() == UInt8(ascii: "[")
            if inArray == true {
                parser.advance()
                try parser.skipSpace()
                if try parser.peek() == UInt8(ascii: "]") { parser.advance(); return try end() }
            }
        } else if inArray == true {
            try parser.skipSpace()
            switch try parser.peek() {
            case UInt8(ascii: "]")?: parser.advance(); return try end()
            case UInt8(ascii: ",")?: parser.advance()
            default: throw parser.error("Expected ‘,’ or ‘]’ after a document in the array, found \(try parser.found())")
            }
        }
        try parser.skipSpace()
        guard let c = try parser.peek() else {
            if inArray == true { throw parser.error("The array has no closing ‘]’") }
            finished = true
            return nil
        }
        guard c == UInt8(ascii: "{") else { throw parser.error("Expected a document starting with ‘{’, found \(try parser.found())") }
        return try parser.topDocument()
    }

    private mutating func end() throws -> BSONDocument? {
        try parser.skipSpace()
        guard try parser.peek() == nil else { throw parser.error("Expected the end of the file after the array, found \(try parser.found())") }
        finished = true
        return nil
    }
}

// MARK: - Formatter

private struct ExtJSONFormatter {
    let canonical: Bool
    let pretty: Bool

    var colon: String { pretty ? ": " : ":" }
    var comma: String { pretty ? ", " : "," }

    func quoted(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{8}": out += "\\b"
            case "\u{C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    func quoted(_ s: String) -> String {
        var out = ""
        quoted(s, into: &out)
        return out
    }

    /// A type wrapper, always on one line: {"$key": inner}.
    func wrap(_ key: String, _ inner: String, into out: inout String) {
        out += "{\"" + key + "\"" + colon + inner + "}"
    }

    func value(_ v: BSONValue, indent: Int, into out: inout String) {
        switch v {
        case .double(let d):
            if canonical || !d.isFinite { wrap("$numberDouble", quoted(BSONValue.doubleText(d)), into: &out) } else { out += BSONValue.doubleText(d) }
        case .string(let s): quoted(s, into: &out)
        case .document(let d): document(d, indent: indent, into: &out)
        case .array(let values):
            container("[", "]", values, indent: indent, into: &out) { f, v, indent, out in f.value(v, indent: indent, into: &out) }
        case let .binary(subtype, data):
            // The old binary subtype keeps its inner length in `data`, which Extended JSON leaves out.
            let payload = subtype == 2 && data.count >= 4 ? data.dropFirst(4) : data
            wrap("$binary", "{\"base64\"" + colon + "\"" + payload.base64EncodedString() + "\"" + comma + "\"subType\"" + colon
                 + "\"" + String(format: "%02x", subtype) + "\"}", into: &out)
        case .undefined: wrap("$undefined", "true", into: &out)
        case .objectId(let id): wrap("$oid", "\"" + id.hex + "\"", into: &out)
        case .bool(let b): out += b ? "true" : "false"
        case .datetime(let ms):
            if !canonical, let iso = Self.isoDate(ms) {
                wrap("$date", "\"" + iso + "\"", into: &out)
            } else {
                wrap("$date", "{\"$numberLong\"" + colon + "\"\(ms)\"}", into: &out)
            }
        case .null: out += "null"
        case let .regex(pattern, options):
            wrap("$regularExpression", "{\"pattern\"" + colon + quoted(pattern) + comma + "\"options\"" + colon + quoted(options) + "}",
                 into: &out)
        case let .dbPointer(namespace, id):
            wrap("$dbPointer", "{\"$ref\"" + colon + quoted(namespace) + comma + "\"$id\"" + colon + "{\"$oid\"" + colon + "\""
                 + id.hex + "\"}}", into: &out)
        case .javascript(let code): wrap("$code", quoted(code), into: &out)
        case .symbol(let s): wrap("$symbol", quoted(s), into: &out)
        case let .javascriptWithScope(code, scope):
            out += "{\"$code\"" + colon + quoted(code) + comma + "\"$scope\"" + colon
            document(scope, indent: indent, into: &out)
            out += "}"
        case .int32(let n): if canonical { wrap("$numberInt", "\"\(n)\"", into: &out) } else { out += String(n) }
        case let .timestamp(t, i): wrap("$timestamp", "{\"t\"" + colon + "\(t)" + comma + "\"i\"" + colon + "\(i)}", into: &out)
        case .int64(let n): if canonical { wrap("$numberLong", "\"\(n)\"", into: &out) } else { out += String(n) }
        case .decimal128(let d): wrap("$numberDecimal", "\"\(d)\"", into: &out)
        case .minKey: wrap("$minKey", "1", into: &out)
        case .maxKey: wrap("$maxKey", "1", into: &out)
        }
    }

    func document(_ d: BSONDocument, indent: Int, into out: inout String) {
        container("{", "}", d.fields, indent: indent, into: &out) { f, field, indent, out in
            f.quoted(field.key, into: &out)
            out += f.colon
            f.value(field.value, indent: indent, into: &out)
        }
    }

    func container<T>(_ open: String, _ close: String, _ items: [T], indent: Int, into out: inout String,
                      _ item: (ExtJSONFormatter, T, Int, inout String) -> Void) {
        guard !items.isEmpty else { out += open + close; return }
        out += open
        for (n, element) in items.enumerated() {
            if n > 0 { out += "," }
            if pretty { out += "\n" + String(repeating: " ", count: indent + 2) }
            item(self, element, indent + 2, &out)
        }
        if pretty { out += "\n" + String(repeating: " ", count: indent) }
        out += close
    }

    /// RFC 3339 in UTC for years 1970 to 9999, milliseconds only when there are some (as the BSON corpus writes it).
    static func isoDate(_ ms: Int64) -> String? {
        guard ms >= 0, ms < ShellDate.days(10000, 1, 1) * ShellDate.msPerDay else { return nil }
        let days = ms / ShellDate.msPerDay, time = ms % ShellDate.msPerDay
        let (y, m, d) = ShellDate.civil(days)
        let text = String(format: "%04lld-%02lld-%02lldT%02lld:%02lld:%02lld", y, m, d, time / 3_600_000, time / 60_000 % 60,
                          time / 1000 % 60)
        return text + (time % 1000 == 0 ? "Z" : String(format: ".%03lldZ", time % 1000))
    }
}

// MARK: - Parser

/// Strict JSON (RFC 8259) read byte by byte from a buffer that refills from a file, building BSON as it goes.
private struct ExtJSONParser {
    var buffer: [UInt8]
    var pos = 0
    let source: FileHandle?
    /// Bytes before `buffer[0]`, and where the document being read started: a broken quote can't swallow the file.
    var base = 0
    var documentStart = 0
    var line = 1, column = 1
    var depth = 0

    static let chunk = 1 << 16
    static let maxDocumentText = 256 << 20

    init(buffer: [UInt8], source: FileHandle?) {
        self.buffer = buffer
        self.source = source
    }

    mutating func peek() throws -> UInt8? {
        if pos < buffer.count { return buffer[pos] }
        guard let source else { return nil }
        // read(2), not FileHandle.read(upToCount:), which waits for a whole chunk from a pipe.
        var more = [UInt8](repeating: 0, count: Self.chunk)
        var n: Int
        repeat { n = read(source.fileDescriptor, &more, Self.chunk) } while n < 0 && errno == EINTR
        guard n >= 0 else { throw BSONError("The file can't be read: \(String(cString: strerror(errno)))") }
        guard n > 0 else { return nil }
        more.removeSubrange(n...)
        base += buffer.count
        buffer = more
        pos = 0
        guard base - documentStart <= Self.maxDocumentText else {
            throw error("A document runs past 256 MB of text; a closing quote or bracket may be missing")
        }
        return buffer[0]
    }

    /// Moves past the byte `peek` returned, counting lines and characters for errors.
    mutating func advance() {
        let c = buffer[pos]
        pos += 1
        if c == 0x0A { line += 1; column = 1 } else if c & 0xC0 != 0x80 { column += 1 }
    }

    func error(_ message: String, at place: (line: Int, column: Int)? = nil) -> BSONError {
        let (l, c) = place ?? (line, column)
        return BSONError("Line \(l), column \(c): \(message)")
    }

    var here: (line: Int, column: Int) { (line, column) }

    mutating func found() throws -> String {
        guard let c = try peek() else { return "the end of the text" }
        return c < 0x80 && c >= 0x20 ? "‘\(Character(Unicode.Scalar(c)))’" : "byte 0x" + String(format: "%02X", c)
    }

    mutating func skipSpace() throws {
        while let c = try peek(), c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { advance() }
    }

    mutating func skipByteOrderMark() throws {
        guard try peek() == 0xEF, pos + 2 < buffer.count, buffer[pos + 1] == 0xBB, buffer[pos + 2] == 0xBF else { return }
        pos += 3
    }

    mutating func topDocument() throws -> BSONDocument {
        documentStart = base + pos
        guard case .document(let d) = try object(top: true) else { fatalError("unreachable") }
        return d
    }

    /// A value and whether it was a JSON literal rather than a type wrapper: {"$date": 5} is legacy, but
    /// {"$date": {"$numberLong": "5"}} isn't, and both are an int64 here.
    /// `wrapped`: the value of a wrapper's key, whose object ({"base64": …, "subType": …}) isn't a document.
    mutating func value(wrapped: Bool = false) throws -> (BSONValue, literal: Bool) {
        try skipSpace()
        guard let c = try peek() else { throw error("Expected a value, found the end of the text") }
        switch c {
        case UInt8(ascii: "{"): return (try object(top: false, wrapped: wrapped), false)
        case UInt8(ascii: "["): return (try array(), false)
        case UInt8(ascii: "\""): return (.string(try string()), true)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return (try number(), true)
        case UInt8(ascii: "t"): try word("true"); return (.bool(true), true)
        case UInt8(ascii: "f"): try word("false"); return (.bool(false), true)
        case UInt8(ascii: "n"): try word("null"); return (.null, true)
        default: throw error("Expected a value, found \(try found())")
        }
    }

    mutating func word(_ w: String) throws {
        let start = here
        for expected in w.utf8 {
            guard try peek() == expected else { throw error("Expected \(w)", at: start) }
            advance()
        }
    }

    /// Opens a container. Type wrappers nest up to 3 levels inside the deepest document ($dbPointer's $id's $oid), so
    /// only documents and arrays are held to BSON's limit, when they close.
    mutating func open() throws {
        depth += 1
        guard depth <= BSONDocument.maxDepth + 4 else { throw error("Values nest more than \(BSONDocument.maxDepth) deep") }
        advance()
    }

    func checkDepth() throws {
        guard depth <= BSONDocument.maxDepth + 1 else { throw error("Documents nest more than \(BSONDocument.maxDepth) deep") }
    }

    mutating func array() throws -> BSONValue {
        try open()
        defer { depth -= 1 }
        try checkDepth()
        var values: [BSONValue] = []
        try skipSpace()
        if try peek() == UInt8(ascii: "]") { advance(); return .array(values) }
        while true {
            values.append(try value().0)
            try skipSpace()
            switch try peek() {
            case UInt8(ascii: ",")?: advance()
            case UInt8(ascii: "]")?: advance(); return .array(values)
            default: throw error("Expected ‘,’ or ‘]’ in an array, found \(try found())")
            }
        }
    }

    mutating func object(top: Bool, wrapped: Bool = false) throws -> BSONValue {
        let start = here
        try open()
        defer { depth -= 1 }
        var fields: [(key: String, value: BSONValue, literal: Bool)] = []
        try skipSpace()
        if try peek() == UInt8(ascii: "}") {
            advance()
        } else {
            while true {
                try skipSpace()
                let keyAt = here
                guard try peek() == UInt8(ascii: "\"") else { throw error("Expected a field name in double quotes, found \(try found())") }
                let key = try string()
                guard !key.utf8.contains(0) else { throw error("A field name can't contain a NUL character", at: keyAt) }
                try skipSpace()
                guard try peek() == UInt8(ascii: ":") else { throw error("Expected ‘:’ after the field name \(key), found \(try found())") }
                advance()
                let (v, literal) = try value(wrapped: !top && Self.wrapperKeys.contains(key))
                fields.append((key, v, literal))
                try skipSpace()
                guard let c = try peek(), c == UInt8(ascii: ",") || c == UInt8(ascii: "}") else {
                    throw error("Expected ‘,’ or ‘}’ after a field, found \(try found())")
                }
                advance()
                if c == UInt8(ascii: "}") { break }
            }
        }
        if !top, fields.contains(where: { Self.wrapperKeys.contains($0.key) }) {
            return try wrapper(fields, at: start)
        }
        if !wrapped { try checkDepth() }
        return .document(BSONDocument(fields.map { ($0.key, $0.value) }))
    }

    static let wrapperKeys: Set<String> = ["$oid", "$symbol", "$numberInt", "$numberLong", "$numberDouble", "$numberDecimal",
                                           "$binary", "$uuid", "$code", "$scope", "$timestamp", "$regularExpression",
                                           "$dbPointer", "$date", "$minKey", "$maxKey", "$undefined"]

    /// An object with a wrapper's key must be exactly that wrapper, in any key order (the spec's parser rules).
    func wrapper(_ fields: [(key: String, value: BSONValue, literal: Bool)], at start: (line: Int, column: Int)) throws -> BSONValue {
        let keys = fields.map(\.key)
        if keys.contains("$code") || keys.contains("$scope") {
            guard let code = fields.first(where: { $0.key == "$code" }), case .string(let text) = code.value,
                  keys.count == Set(keys).count, Set(keys).isSubset(of: ["$code", "$scope"]) else {
                throw error("{\"$code\": …} takes code in a string, and optionally \"$scope\" with a document, and nothing else", at: start)
            }
            guard let scope = fields.first(where: { $0.key == "$scope" }) else { return .javascript(text) }
            guard case .document(let d) = scope.value else { throw error("\"$scope\" takes a document", at: start) }
            return .javascriptWithScope(code: text, scope: d)
        }
        let key = fields[0].key, v = fields[0].value
        func fail(_ what: String) -> BSONError {
            fields.count > 1
                ? error("{\"\(fields.first { Self.wrapperKeys.contains($0.key) }!.key)\": …} can't have other fields beside it", at: start)
                : error("{\"\(key)\": …} takes \(what)", at: start)
        }
        guard fields.count == 1 else { throw fail("") }
        func string() -> String? { if case .string(let s) = v { return s } else { return nil } }
        func inner(_ names: Set<String>) -> BSONDocument? {
            guard case .document(let d) = v, d.fields.count == names.count, Set(d.keys) == names else { return nil }
            return d
        }
        switch key {
        case "$oid":
            guard let s = string(), let id = BSONObjectId(hex: s) else { throw fail("24 hex digits in a string") }
            return .objectId(id)
        case "$symbol":
            guard let s = string() else { throw fail("a string") }
            return .symbol(s)
        case "$numberInt":
            guard let s = string(), Self.isInteger(s), let n = Int32(s) else { throw fail("a whole number from -2147483648 to 2147483647 in a string") }
            return .int32(n)
        case "$numberLong":
            guard let s = string(), Self.isInteger(s), let n = Int64(s) else {
                throw fail("a whole number from -9223372036854775808 to 9223372036854775807 in a string")
            }
            return .int64(n)
        case "$numberDouble":
            guard let s = string() else { throw fail("a number in a string, or \"Infinity\", \"-Infinity\" or \"NaN\"") }
            switch s {
            case "Infinity": return .double(.infinity)
            case "-Infinity": return .double(-.infinity)
            case "NaN": return .double(.nan)
            default:
                guard Self.isNumber(s), let d = Double(s), d.isFinite else {
                    throw fail("a number in a string, or \"Infinity\", \"-Infinity\" or \"NaN\"")
                }
                return .double(d)
            }
        case "$numberDecimal":
            guard let s = string(), let d = BSONDecimal128(s) else { throw fail("a decimal in a string with at most 34 significant digits") }
            return .decimal128(d)
        case "$binary":
            guard let d = inner(["base64", "subType"]), case .string(let b64)? = d["base64"], case .string(let sub)? = d["subType"],
                  (1...2).contains(sub.utf8.count), let subtype = UInt8(sub, radix: 16), let data = Data(base64Encoded: b64) else {
                if case .string = v { throw fail("{\"base64\": \"…\", \"subType\": \"00\"}; the legacy {\"$binary\": \"…\", \"$type\": \"00\"} isn't read") }
                throw fail("{\"base64\": \"…\", \"subType\": \"00\"}: base64 and a subtype of one or two hex digits")
            }
            if subtype == 2 {
                var length = UInt32(data.count).littleEndian
                return .binary(subtype: 2, data: Data(bytes: &length, count: 4) + data)
            }
            return .binary(subtype: subtype, data: data)
        case "$uuid":
            guard let s = string(), s.utf8.count == 36, s.split(separator: "-", omittingEmptySubsequences: false).map(\.count) == [8, 4, 4, 4, 12],
                  let bytes = BSONObjectId.bytes(hex: s.replacingOccurrences(of: "-", with: "")) else {
                throw fail("a UUID in a string, such as \"73ffd264-44b3-4c69-90e8-e7d1dfc035d4\"")
            }
            return .binary(subtype: 4, data: Data(bytes))
        case "$timestamp":
            guard let d = inner(["t", "i"]), let t = Self.uint32(d["t"]), let i = Self.uint32(d["i"]) else {
                throw fail("{\"t\": seconds, \"i\": increment}, each a whole number from 0 to 4294967295")
            }
            return .timestamp(t: t, i: i)
        case "$regularExpression":
            guard let d = inner(["pattern", "options"]), case .string(let pattern)? = d["pattern"], case .string(let options)? = d["options"] else {
                throw fail("{\"pattern\": \"…\", \"options\": \"…\"}")
            }
            guard !pattern.utf8.contains(0), !options.utf8.contains(0) else { throw fail("a pattern and options without NUL characters") }
            return .regex(pattern: pattern, options: String(options.sorted()))  // stored sorted, as drivers do
        case "$dbPointer":
            guard let d = inner(["$ref", "$id"]), case .string(let namespace)? = d["$ref"], case .objectId(let id)? = d["$id"] else {
                throw fail("{\"$ref\": \"namespace\", \"$id\": {\"$oid\": \"…\"}}")
            }
            return .dbPointer(namespace: namespace, id: id)
        case "$date":
            if let s = string() {
                guard let ms = ShellDate.parse(s) else { throw fail("an ISO 8601 date such as \"2024-05-01T12:00:00.000Z\" (at most milliseconds)") }
                return .datetime(ms)
            }
            guard case .int64(let ms) = v, !fields[0].literal else {
                throw fail("an ISO 8601 date in a string or {\"$numberLong\": \"milliseconds\"}; the legacy {\"$date\": milliseconds} isn't read")
            }
            return .datetime(ms)
        case "$minKey", "$maxKey":
            guard case .int32(1) = v, fields[0].literal else { throw fail("1") }
            return key == "$minKey" ? .minKey : .maxKey
        case "$undefined":
            guard case .bool(true) = v else { throw fail("true") }
            return .undefined
        default:
            throw fail("")  // "$scope" alone is handled with "$code" above
        }
    }

    /// JSON's integer: an optional minus, then 0 or digits not starting with 0.
    static func isInteger(_ s: String) -> Bool {
        let digits = s.hasPrefix("-") ? s.utf8.dropFirst() : s.utf8[...]
        return !digits.isEmpty && digits.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
            && (digits.count == 1 || digits.first != UInt8(ascii: "0"))
    }

    /// Text made only of a number's characters (Swift's Double would also take "inf", "nan" and hex).
    static func isNumber(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || "+-.eE".utf8.contains($0) }
    }

    static func uint32(_ v: BSONValue?) -> UInt32? {
        switch v {
        case .int32(let n)?: return UInt32(exactly: n)
        case .int64(let n)?: return UInt32(exactly: n)
        default: return nil
        }
    }

    mutating func number() throws -> BSONValue {
        let start = here
        var text: [UInt8] = []
        func digits(_ p: inout ExtJSONParser, _ text: inout [UInt8]) throws -> Int {
            var n = 0
            while let c = try p.peek(), c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") {
                text.append(c)
                p.advance()
                n += 1
                guard text.count <= 4096 else { throw p.error("This number is too long", at: start) }
            }
            return n
        }
        if try peek() == UInt8(ascii: "-") { text.append(UInt8(ascii: "-")); advance() }
        let intAt = text.count
        guard try digits(&self, &text) > 0 else { throw error("Expected digits after ‘-’, found \(try found())") }
        if text[intAt] == UInt8(ascii: "0") && text.count - intAt > 1 { throw error("A number can't start with 0", at: start) }
        var isInteger = true
        if try peek() == UInt8(ascii: ".") {
            text.append(UInt8(ascii: "."))
            advance()
            isInteger = false
            guard try digits(&self, &text) > 0 else { throw error("Expected digits after the decimal point, found \(try found())") }
        }
        if let c = try peek(), c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
            text.append(c)
            advance()
            isInteger = false
            if let c = try peek(), c == UInt8(ascii: "+") || c == UInt8(ascii: "-") { text.append(c); advance() }
            guard try digits(&self, &text) > 0 else { throw error("Expected the exponent's digits, found \(try found())") }
        }
        let s = String(decoding: text, as: UTF8.self)
        // The spec's rule: an integer is the smallest of int32 and int64 that holds it, anything else a double.
        if isInteger, let n = Int32(s) { return .int32(n) }
        if isInteger, let n = Int64(s) { return .int64(n) }
        guard let d = Double(s), d.isFinite else { throw error("This number is too large for a double", at: start) }
        return .double(d)  // Swift's Double(String) rounds correctly, so every double's shortest text reads back exactly
    }

    mutating func hex4() throws -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<4 {
            guard let c = try peek(), let d = UInt32(String(Unicode.Scalar(c)), radix: 16) else {
                throw error("Expected 4 hex digits after \\u, found \(try found())")
            }
            v = v << 4 | d
            advance()
        }
        return v
    }

    mutating func string() throws -> String {
        let start = here
        advance()
        var bytes: [UInt8] = []
        while true {
            guard let c = try peek() else { throw error("This string has no closing quote", at: start) }
            if c == UInt8(ascii: "\"") {
                advance()
                guard let s = String(bytes: bytes, encoding: .utf8) else { throw error("This string isn't valid UTF-8", at: start) }
                return s
            }
            if c < 0x20 { throw error("A string can't hold a line break or control character; write \\n or \\u0000") }
            advance()
            guard c == UInt8(ascii: "\\") else { bytes.append(c); continue }
            guard let e = try peek() else { throw error("This string has no closing quote", at: start) }
            let escapeAt = here
            advance()
            var scalar: UInt32
            switch e {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): bytes.append(e); continue
            case UInt8(ascii: "n"): scalar = 0x0A
            case UInt8(ascii: "r"): scalar = 0x0D
            case UInt8(ascii: "t"): scalar = 0x09
            case UInt8(ascii: "b"): scalar = 0x08
            case UInt8(ascii: "f"): scalar = 0x0C
            case UInt8(ascii: "u"):
                scalar = try hex4()
                if (0xD800..<0xDC00).contains(scalar) {
                    guard try peek() == UInt8(ascii: "\\") else { throw error("A \\u escape is half a character", at: escapeAt) }
                    advance()
                    guard try peek() == UInt8(ascii: "u") else { throw error("A \\u escape is half a character", at: escapeAt) }
                    advance()
                    let low = try hex4()
                    guard (0xDC00..<0xE000).contains(low) else { throw error("A \\u escape is half a character", at: escapeAt) }
                    scalar = 0x10000 + (scalar - 0xD800) << 10 + (low - 0xDC00)
                }
            default: throw error("‘\\\(Character(Unicode.Scalar(e)))’ isn't a JSON escape", at: escapeAt)
            }
            guard let u = Unicode.Scalar(scalar) else { throw error("A \\u escape is half a character", at: escapeAt) }
            bytes += String(Character(u)).utf8
        }
    }
}
