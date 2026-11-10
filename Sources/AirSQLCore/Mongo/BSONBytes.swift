import Foundation

extension BSONDocument {
    /// How many levels documents and arrays may nest below the outermost one when read or parsed: MongoDB's limit for a
    /// stored document. It also keeps the recursion inside a secondary thread's 512 KB stack.
    public static let maxDepth = 100

    /// Reads one whole document, checking every length, terminator and string: malformed bytes throw, they never
    /// crash or read past the end. Extra bytes after the document are an error too.
    public init(bytes: some Collection<UInt8>) throws {
        let reader = BSONReader(b: Array(bytes))
        let (document, end) = try reader.document(at: 0, end: reader.b.count, depth: 0)
        guard end == reader.b.count else { throw BSONError("There are \(reader.b.count - end) extra bytes after the document") }
        self = document
    }

    /// The document as BSON bytes; byte for byte what was read, for a document that was read (array keys apart).
    /// Throws for a key, a regex or a namespace with a NUL character in it, which BSON can't hold.
    public func bytes() throws -> [UInt8] {
        var writer = BSONWriter()
        try writer.document(self)
        return writer.out
    }

    /// The top-level keys of a document's bytes, without decoding its values.
    public static func topLevelKeys(in bytes: some Collection<UInt8>) throws -> [String] {
        let reader = BSONReader(b: Array(bytes))
        var keys: [String] = []
        try reader.elements(at: 0, end: reader.b.count) { key, _, _, _ in keys.append(key); return true }
        return keys
    }

    /// The value at a path of keys (an array's element by its index: ["items", "0", "price"]), decoding only that
    /// value and the lengths on the way to it; nil when the path isn't there.
    public static func value(at path: [String], in bytes: some Collection<UInt8>) throws -> BSONValue? {
        let reader = BSONReader(b: Array(bytes))
        var start = 0, end = reader.b.count
        for (depth, key) in path.enumerated() {
            var found: (type: UInt8, at: Int, end: Int)?
            try reader.elements(at: start, end: end) { k, type, at, valueEnd in
                guard k == key else { return true }
                found = (type, at, valueEnd)
                return false
            }
            guard let hit = found else { return nil }
            if depth == path.count - 1 { return try reader.value(hit.type, at: hit.at, end: hit.end, depth: depth).0 }
            guard hit.type == 0x03 || hit.type == 0x04 else { return nil }
            (start, end) = (hit.at, hit.end)
        }
        return nil
    }
}

private struct BSONReader {
    let b: [UInt8]

    func fail(_ message: String, _ at: Int) -> BSONError { BSONError("\(message) (at byte \(at))") }

    func need(_ count: Int, at i: Int, end: Int, _ what: String) throws {
        guard i >= 0, count >= 0, count <= end - i else { throw fail("The data ends inside \(what)", i) }
    }

    func le(_ i: Int, _ count: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in (0..<count).reversed() { v = v << 8 | UInt64(b[i + k]) }
        return v
    }

    func int32(at i: Int, end: Int, _ what: String) throws -> Int {
        try need(4, at: i, end: end, what)
        return Int(Int32(truncatingIfNeeded: le(i, 4)))
    }

    func utf8(_ from: Int, _ to: Int) throws -> String {
        let s = String(decoding: b[from..<to], as: UTF8.self)
        // A repaired decode differs from the bytes: invalid UTF-8 is an error, not replacement characters.
        guard s.utf8.elementsEqual(b[from..<to]) else { throw fail("A string isn't valid UTF-8", from) }
        return s
    }

    func cstring(at i: Int, end: Int, _ what: String) throws -> (String, Int) {
        guard i <= end, let zero = b[i..<end].firstIndex(of: 0) else { throw fail("\(what) has no terminating NUL", i) }
        return (try utf8(i, zero), zero + 1)
    }

    func string(at i: Int, end: Int) throws -> (String, Int) {
        let n = try int32(at: i, end: end, "a string's length")
        guard n >= 1, n <= end - i - 4 else { throw fail("A string's length (\(n)) doesn't fit", i) }
        guard b[i + 4 + n - 1] == 0 else { throw fail("A string doesn't end with NUL", i) }
        return (try utf8(i + 4, i + 4 + n - 1), i + 4 + n)
    }

    /// Checks a document's length and terminator and calls `each` with every element's key, type and value bounds
    /// until it returns false. Returns the document's end.
    @discardableResult
    func elements(at start: Int, end: Int, _ each: (String, UInt8, Int, Int) throws -> Bool) throws -> Int {
        let n = try int32(at: start, end: end, "a document's length")
        guard n >= 5, n <= end - start else { throw fail("A document's length (\(n)) doesn't fit", start) }
        let last = start + n - 1
        guard b[last] == 0 else { throw fail("A document doesn't end with NUL", last) }
        var i = start + 4
        while i < last {
            let type = b[i]
            let (key, at) = try cstring(at: i + 1, end: last, "A key")
            let valueEnd = try skip(type, at: at, end: last)
            guard try each(key, type, at, valueEnd) else { return start + n }
            i = valueEnd
        }
        return start + n
    }

    /// Where a value of this type that starts at `i` ends, from its lengths alone.
    func skip(_ type: UInt8, at i: Int, end: Int) throws -> Int {
        func fixed(_ count: Int, _ what: String) throws -> Int { try need(count, at: i, end: end, what); return i + count }
        switch type {
        case 0x01, 0x09, 0x11, 0x12: return try fixed(8, "an 8-byte value")
        case 0x10: return try fixed(4, "an int32")
        case 0x13: return try fixed(16, "a decimal")
        case 0x07: return try fixed(12, "an ObjectId")
        case 0x08: return try fixed(1, "a boolean")
        case 0x06, 0x0A, 0xFF, 0x7F: return i
        case 0x02, 0x0D, 0x0E: return try string(at: i, end: end).1
        case 0x0C:
            let next = try string(at: i, end: end).1
            try need(12, at: next, end: end, "a DBPointer's ObjectId")
            return next + 12
        case 0x03, 0x04, 0x0F:
            let n = try int32(at: i, end: end, "a length")
            guard n >= 5, n <= end - i else { throw fail("A length (\(n)) doesn't fit", i) }
            return i + n
        case 0x05:
            let n = try int32(at: i, end: end, "a binary's length")
            guard n >= 0, n <= end - i - 5 else { throw fail("A binary's length (\(n)) doesn't fit", i) }
            return i + 5 + n
        case 0x0B:
            let (_, next) = try cstring(at: i, end: end, "A regex's pattern")
            return try cstring(at: next, end: end, "A regex's options").1
        default: throw fail(String(format: "Unknown BSON type 0x%02X", type), i - 1)
        }
    }

    func document(at start: Int, end: Int, depth: Int) throws -> (BSONDocument, Int) {
        guard depth <= BSONDocument.maxDepth else { throw fail("Documents nest more than \(BSONDocument.maxDepth) deep", start) }
        var fields: [(key: String, value: BSONValue)] = []
        let docEnd = try elements(at: start, end: end) { key, type, at, valueEnd in
            let (value, next) = try value(type, at: at, end: valueEnd, depth: depth)
            guard next == valueEnd else { throw fail("A value's length doesn't match its contents", at) }
            fields.append((key, value))
            return true
        }
        return (BSONDocument(fields), docEnd)
    }

    /// Decodes one value whose bytes lie in `i..<end`.
    func value(_ type: UInt8, at i: Int, end: Int, depth: Int) throws -> (BSONValue, Int) {
        switch type {
        case 0x01: try need(8, at: i, end: end, "a double"); return (.double(Double(bitPattern: le(i, 8))), i + 8)
        case 0x02: let (s, n) = try string(at: i, end: end); return (.string(s), n)
        case 0x03: let (d, n) = try document(at: i, end: end, depth: depth + 1); return (.document(d), n)
        case 0x04: let (d, n) = try document(at: i, end: end, depth: depth + 1); return (.array(d.fields.map(\.value)), n)
        case 0x05:
            let n = try int32(at: i, end: end, "a binary's length")
            guard n >= 0, n <= end - i - 5 else { throw fail("A binary's length (\(n)) doesn't fit", i) }
            let subtype = b[i + 4]
            if subtype == 2 {
                // The old binary subtype repeats its length inside.
                guard n >= 4, Int(Int32(truncatingIfNeeded: le(i + 5, 4))) == n - 4 else {
                    throw fail("An old binary's inner length doesn't match", i)
                }
            }
            return (.binary(subtype: subtype, data: Data(b[(i + 5)..<(i + 5 + n)])), i + 5 + n)
        case 0x06: return (.undefined, i)
        case 0x07: try need(12, at: i, end: end, "an ObjectId"); return (.objectId(BSONObjectId(bytes: Array(b[i..<(i + 12)]))!), i + 12)
        case 0x08:
            try need(1, at: i, end: end, "a boolean")
            guard b[i] <= 1 else { throw fail("A boolean is neither 0 nor 1", i) }
            return (.bool(b[i] == 1), i + 1)
        case 0x09: try need(8, at: i, end: end, "a date"); return (.datetime(Int64(bitPattern: le(i, 8))), i + 8)
        case 0x0A: return (.null, i)
        case 0x0B:
            let (pattern, next) = try cstring(at: i, end: end, "A regex's pattern")
            let (options, after) = try cstring(at: next, end: end, "A regex's options")
            return (.regex(pattern: pattern, options: options), after)
        case 0x0C:
            let (namespace, next) = try string(at: i, end: end)
            try need(12, at: next, end: end, "a DBPointer's ObjectId")
            return (.dbPointer(namespace: namespace, id: BSONObjectId(bytes: Array(b[next..<(next + 12)]))!), next + 12)
        case 0x0D: let (s, n) = try string(at: i, end: end); return (.javascript(s), n)
        case 0x0E: let (s, n) = try string(at: i, end: end); return (.symbol(s), n)
        case 0x0F:
            let total = try int32(at: i, end: end, "code with scope's length")
            guard total >= 14, total <= end - i else { throw fail("Code with scope's length (\(total)) doesn't fit", i) }
            let (code, next) = try string(at: i + 4, end: i + total)
            let (scope, after) = try document(at: next, end: i + total, depth: depth + 1)
            guard after == i + total else { throw fail("Code with scope's length doesn't match its contents", i) }
            return (.javascriptWithScope(code: code, scope: scope), after)
        case 0x10: try need(4, at: i, end: end, "an int32"); return (.int32(Int32(truncatingIfNeeded: le(i, 4))), i + 4)
        case 0x11:
            try need(8, at: i, end: end, "a timestamp")
            return (.timestamp(t: UInt32(le(i + 4, 4)), i: UInt32(le(i, 4))), i + 8)
        case 0x12: try need(8, at: i, end: end, "an int64"); return (.int64(Int64(bitPattern: le(i, 8))), i + 8)
        case 0x13:
            try need(16, at: i, end: end, "a decimal")
            return (.decimal128(BSONDecimal128(low: le(i, 8), high: le(i + 8, 8))), i + 16)
        case 0xFF: return (.minKey, i)
        case 0x7F: return (.maxKey, i)
        default: throw fail(String(format: "Unknown BSON type 0x%02X", type), i - 1)
        }
    }
}

private struct BSONWriter {
    var out: [UInt8] = []

    mutating func le(_ v: UInt64, _ count: Int) {
        for k in 0..<count { out.append(UInt8(truncatingIfNeeded: v >> (8 * k))) }
    }

    mutating func cstring(_ s: String, _ what: String) throws {
        guard !s.utf8.contains(0) else { throw BSONError("\(what) can't contain a NUL character") }
        out += s.utf8
        out.append(0)
    }

    mutating func string(_ s: String) {
        le(UInt64(s.utf8.count + 1), 4)
        out += s.utf8
        out.append(0)
    }

    /// Writes a length placeholder, the body, then the length.
    mutating func sized(_ body: (inout BSONWriter) throws -> Void) rethrows {
        let start = out.count
        out += [0, 0, 0, 0]
        try body(&self)
        let n = UInt32(out.count - start)
        for k in 0..<4 { out[start + k] = UInt8(truncatingIfNeeded: n >> (8 * k)) }
    }

    mutating func document(_ d: BSONDocument) throws {
        try sized { w in
            for (key, value) in d.fields { try w.element(key, value) }
            w.out.append(0)
        }
    }

    mutating func element(_ key: String, _ value: BSONValue) throws {
        out.append(value.typeByte)
        try cstring(key, "A key")
        switch value {
        case .double(let v): le(v.bitPattern, 8)
        case .string(let s), .javascript(let s), .symbol(let s): string(s)
        case .document(let d): try document(d)
        case .array(let values):
            try sized { w in
                for (index, v) in values.enumerated() { try w.element(String(index), v) }
                w.out.append(0)
            }
        case let .binary(subtype, data):
            le(UInt64(data.count), 4)
            out.append(subtype)
            out += data
        case .undefined, .null, .minKey, .maxKey: break
        case .objectId(let id): out += id.bytes
        case .bool(let v): out.append(v ? 1 : 0)
        case .datetime(let v): le(UInt64(bitPattern: v), 8)
        case let .regex(pattern, options):
            try cstring(pattern, "A regex's pattern")
            try cstring(options, "A regex's options")
        case let .dbPointer(namespace, id):
            string(namespace)
            out += id.bytes
        case let .javascriptWithScope(code, scope):
            try sized { w in
                w.string(code)
                try w.document(scope)
            }
        case .int32(let v): le(UInt64(UInt32(bitPattern: v)), 4)
        case let .timestamp(t, i): le(UInt64(t) << 32 | UInt64(i), 8)
        case .int64(let v): le(UInt64(bitPattern: v), 8)
        case .decimal128(let d): le(d.low, 8); le(d.high, 8)
        }
    }
}
