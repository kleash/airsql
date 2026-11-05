import Foundation

extension GridColumn {
    /// The types the server stores as a shape.
    public static let spatialTypes = ["geometry", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon",
                                      "geometrycollection", "geomcollection"]
}

/// A shape as the server sends it (four bytes of SRID, then well-known binary) as well-known text: `POINT(1 2)`.
struct WellKnownText {
    private(set) var text = ""
    private var bytes: ArraySlice<UInt8>

    /// Nil for bytes that aren't a whole shape.
    init?(_ value: [UInt8]) {
        guard value.count > 4 else { return nil }
        bytes = value[4...]
        guard let shape = shape(), bytes.isEmpty else { return nil }
        text = shape
    }

    private mutating func uint32(little: Bool) -> UInt32? {
        guard bytes.count >= 4 else { return nil }
        let raw = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        bytes = bytes.dropFirst(4)
        return little ? raw.byteSwapped : raw
    }

    private mutating func number(little: Bool) -> String? {
        guard bytes.count >= 8 else { return nil }
        let raw = bytes.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        bytes = bytes.dropFirst(8)
        let value = Double(bitPattern: little ? raw.byteSwapped : raw)
        return value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }

    private mutating func point(little: Bool) -> String? {
        guard let x = number(little: little), let y = number(little: little) else { return nil }
        return x + " " + y
    }

    /// `count` of something, as "(a, b)": a count a real shape can't have stops here, not in memory.
    private mutating func list(little: Bool, _ item: (inout WellKnownText) -> String?) -> String? {
        guard let count = uint32(little: little), Int(count) <= bytes.count else { return nil }
        var parts: [String] = []
        for _ in 0..<count {
            guard let part = item(&self) else { return nil }
            parts.append(part)
        }
        return "(" + parts.joined(separator: ", ") + ")"
    }

    private mutating func shape() -> String? {
        guard let order = bytes.first, order <= 1 else { return nil }
        bytes = bytes.dropFirst()
        let little = order == 1
        guard let type = uint32(little: little) else { return nil }
        func points(_ text: inout WellKnownText) -> String? { text.list(little: little) { $0.point(little: little) } }
        func child(_ text: inout WellKnownText) -> String? { text.shape() }
        // A MULTI shape's members print without their name.
        func bare(_ text: inout WellKnownText) -> String? { text.shape().map { String($0.drop { $0 != "(" }) } }
        switch type {
        case 1: return point(little: little).map { "POINT(\($0))" }
        case 2: return points(&self).map { "LINESTRING" + $0 }
        case 3: return list(little: little, points).map { "POLYGON" + $0 }
        case 4: return list(little: little, bare).map { "MULTIPOINT" + $0 }
        case 5: return list(little: little, bare).map { "MULTILINESTRING" + $0 }
        case 6: return list(little: little, bare).map { "MULTIPOLYGON" + $0 }
        case 7: return list(little: little, child).map { "GEOMETRYCOLLECTION" + $0 }
        default: return nil
        }
    }
}
