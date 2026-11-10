import Foundation

/// One BSON value exactly as it travels (bsonspec.org): every type keeps its own case, so an int32, an int64, a double
/// and a decimal are never the same thing, a double keeps -0.0 and NaN, and a decimal keeps its raw 16 bytes. MongoDB
/// documents stay in this form from the wire to the grid, the editor and the agents (mongo-plan, risk 2).
public enum BSONValue: Sendable {
    case double(Double)
    case string(String)
    case document(BSONDocument)
    /// The keys of an array's BSON document ("0", "1", …) are not kept: they are written back in order.
    case array([BSONValue])
    /// Subtype 4 with 16 bytes is a UUID; subtype 2 (old binary) keeps its inner length in `data`, as on the wire.
    case binary(subtype: UInt8, data: Data)
    case undefined
    case objectId(BSONObjectId)
    case bool(Bool)
    /// Milliseconds since 1970-01-01 UTC.
    case datetime(Int64)
    case null
    case regex(pattern: String, options: String)
    case dbPointer(namespace: String, id: BSONObjectId)
    case javascript(String)
    case symbol(String)
    case javascriptWithScope(code: String, scope: BSONDocument)
    case int32(Int32)
    case timestamp(t: UInt32, i: UInt32)
    case int64(Int64)
    case decimal128(BSONDecimal128)
    case minKey
    case maxKey

    /// The type's byte in a BSON element.
    public var typeByte: UInt8 {
        switch self {
        case .double: return 0x01
        case .string: return 0x02
        case .document: return 0x03
        case .array: return 0x04
        case .binary: return 0x05
        case .undefined: return 0x06
        case .objectId: return 0x07
        case .bool: return 0x08
        case .datetime: return 0x09
        case .null: return 0x0A
        case .regex: return 0x0B
        case .dbPointer: return 0x0C
        case .javascript: return 0x0D
        case .symbol: return 0x0E
        case .javascriptWithScope: return 0x0F
        case .int32: return 0x10
        case .timestamp: return 0x11
        case .int64: return 0x12
        case .decimal128: return 0x13
        case .minKey: return 0xFF
        case .maxKey: return 0x7F
        }
    }

    /// The name `$type` takes for this value's type ("double", "long", "objectId", …), for filters such as
    /// `{path: old, path: {$type: alias}}` that match the old value's type as well as its value.
    public var typeAlias: String {
        switch self {
        case .double: return "double"
        case .string: return "string"
        case .document: return "object"
        case .array: return "array"
        case .binary: return "binData"
        case .undefined: return "undefined"
        case .objectId: return "objectId"
        case .bool: return "bool"
        case .datetime: return "date"
        case .null: return "null"
        case .regex: return "regex"
        case .dbPointer: return "dbPointer"
        case .javascript: return "javascript"
        case .symbol: return "symbol"
        case .javascriptWithScope: return "javascriptWithScope"
        case .int32: return "int"
        case .timestamp: return "timestamp"
        case .int64: return "long"
        case .decimal128: return "decimal"
        case .minKey: return "minKey"
        case .maxKey: return "maxKey"
        }
    }

    /// Deprecated types: shown and kept as they are, but the editor doesn't offer to change them.
    public var isReadOnly: Bool {
        switch self {
        case .undefined, .dbPointer, .symbol, .javascriptWithScope: return true
        default: return false
        }
    }

    /// The same BSON type and the same value: 1, 1.0 and NumberLong(1) differ, so do -0.0 and 0.0, a decimal's
    /// 1.0 and 1.00, and two documents with their keys in another order; NaN equals NaN. What Apply compares an old
    /// value with.
    public func typeExactEqual(_ other: BSONValue) -> Bool {
        switch (self, other) {
        case let (.double(a), .double(b)): return a.isNaN ? b.isNaN : a.bitPattern == b.bitPattern
        case let (.string(a), .string(b)), let (.javascript(a), .javascript(b)), let (.symbol(a), .symbol(b)):
            return a.utf8.elementsEqual(b.utf8)
        case let (.document(a), .document(b)): return a.typeExactEqual(b)
        case let (.array(a), .array(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.typeExactEqual($1) }
        case let (.binary(s1, d1), .binary(s2, d2)): return s1 == s2 && d1 == d2
        case (.undefined, .undefined), (.null, .null), (.minKey, .minKey), (.maxKey, .maxKey): return true
        case let (.objectId(a), .objectId(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case let (.datetime(a), .datetime(b)): return a == b
        case let (.regex(p1, o1), .regex(p2, o2)): return p1.utf8.elementsEqual(p2.utf8) && o1.utf8.elementsEqual(o2.utf8)
        case let (.dbPointer(n1, i1), .dbPointer(n2, i2)): return n1.utf8.elementsEqual(n2.utf8) && i1 == i2
        case let (.javascriptWithScope(c1, s1), .javascriptWithScope(c2, s2)):
            return c1.utf8.elementsEqual(c2.utf8) && s1.typeExactEqual(s2)
        case let (.int32(a), .int32(b)): return a == b
        case let (.timestamp(t1, i1), .timestamp(t2, i2)): return t1 == t2 && i1 == i2
        case let (.int64(a), .int64(b)): return a == b
        case let (.decimal128(a), .decimal128(b)): return a.isNaN ? b.isNaN : a == b
        default: return false
        }
    }
}

/// `==` is `typeExactEqual`: Swift's own would make NaN unequal to itself and -0.0 equal to 0.0.
extension BSONValue: Equatable {
    public static func == (lhs: BSONValue, rhs: BSONValue) -> Bool { lhs.typeExactEqual(rhs) }
}

/// A document's fields in the order they were read. Keys may repeat and may hold `.` or `$`, as the server allows;
/// `keyNeedsCare` flags those, which the editor keeps read-only.
public struct BSONDocument: Sendable, Equatable {
    public var fields: [(key: String, value: BSONValue)]

    public init(_ fields: [(key: String, value: BSONValue)] = []) { self.fields = fields }

    public var keys: [String] { fields.map(\.key) }

    /// The first field with this key.
    public subscript(key: String) -> BSONValue? { fields.first { $0.key == key }?.value }

    /// A key a dotted path or an update operator can't name plainly.
    public static func keyNeedsCare(_ key: String) -> Bool { key.contains(".") || key.contains("$") }

    /// Same keys in the same order, each value `typeExactEqual`.
    public func typeExactEqual(_ other: BSONDocument) -> Bool {
        fields.count == other.fields.count
            && zip(fields, other.fields).allSatisfy { $0.key.utf8.elementsEqual($1.key.utf8) && $0.value.typeExactEqual($1.value) }
    }

    public static func == (lhs: BSONDocument, rhs: BSONDocument) -> Bool { lhs.typeExactEqual(rhs) }

    /// Visits every value under this document, parents before their children, with its path from the top: a key for
    /// a document's field, an index for an array's element. Code with scope is a leaf.
    public func walk(_ visit: (_ path: [BSONPathSegment], _ value: BSONValue) -> Void) {
        var path: [BSONPathSegment] = []
        walk(&path, visit)
    }

    private func walk(_ path: inout [BSONPathSegment], _ visit: ([BSONPathSegment], BSONValue) -> Void) {
        for (key, value) in fields {
            path.append(.key(key))
            BSONDocument.walk(value, &path, visit)
            path.removeLast()
        }
    }

    private static func walk(_ value: BSONValue, _ path: inout [BSONPathSegment],
                             _ visit: ([BSONPathSegment], BSONValue) -> Void) {
        visit(path, value)
        switch value {
        case .document(let document): document.walk(&path, visit)
        case .array(let values):
            for (index, element) in values.enumerated() {
                path.append(.index(index))
                walk(element, &path, visit)
                path.removeLast()
            }
        default: break
        }
    }
}

public enum BSONPathSegment: Hashable, Sendable {
    case key(String)
    case index(Int)
}

extension Array where Element == BSONPathSegment {
    /// The path as MongoDB writes it: `items.0.price`.
    public var dotted: String {
        map { segment -> String in
            switch segment {
            case .key(let key): return key
            case .index(let index): return String(index)
            }
        }.joined(separator: ".")
    }
}

public struct BSONObjectId: Hashable, Sendable {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 12 else { return nil }
        self.bytes = bytes
    }

    /// 24 hex digits, either case.
    public init?(hex: String) {
        guard hex.utf8.count == 24, let bytes = BSONObjectId.bytes(hex: hex) else { return nil }
        self.bytes = bytes
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func bytes(hex: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var high: UInt8?
        for c in hex.utf8 {
            let nibble: UInt8
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): nibble = c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): nibble = c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): nibble = c - UInt8(ascii: "A") + 10
            default: return nil
            }
            if let h = high { bytes.append(h << 4 | nibble); high = nil } else { high = nibble }
        }
        return high == nil ? bytes : nil
    }
}

/// What a read, a write or a parse of BSON found wrong, in plain words.
public struct BSONError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
