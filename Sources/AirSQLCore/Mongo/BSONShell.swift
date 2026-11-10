import Foundation

// Shell form: values as mongosh writes them (ObjectId("…"), ISODate("…"), NumberLong(…), …), which the grid and the
// document editor show and accept. Every value the formatter writes parses back to the same `typeExactEqual` value.
// The parser reads literals and a fixed list of constructors; it is not JavaScript and runs nothing.

extension BSONValue {
    /// The value in shell form, on one line or indented; with `maxLength`, cut to that many characters plus "…",
    /// without formatting the rest (a grid cell of a 16 MB document).
    public func shellForm(pretty: Bool = false, maxLength: Int? = nil) -> String {
        var formatter = ShellFormatter(pretty: pretty, limit: maxLength)
        formatter.value(self, indent: 0)
        return formatter.result
    }

    /// One value in shell form. Plain integers that fit an int32 are int32s and other plain numbers doubles, as in
    /// mongosh. Errors say where (line and column) and what.
    public init(shellForm text: String) throws {
        var parser = ShellParser(text)
        self = try parser.whole(documentOnly: false)
    }
}

extension BSONDocument {
    public func shellForm(pretty: Bool = false, maxLength: Int? = nil) -> String {
        BSONValue.document(self).shellForm(pretty: pretty, maxLength: maxLength)
    }

    /// A whole document in shell form: the editor's text.
    public init(shellForm text: String) throws {
        var parser = ShellParser(text)
        guard case .document(let document) = try parser.whole(documentOnly: true) else { fatalError("unreachable") }
        self = document
    }
}

extension BSONValue {
    /// A double's shortest text that reads back as the same double: -0.0, NaN, Infinity and -Infinity included, and
    /// always with a point or an exponent so that it never reads back as an integer.
    public static func doubleText(_ v: Double) -> String {
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v < 0 ? "-Infinity" : "Infinity" }
        return v.description  // Swift's shortest round-trip digits: "1.0", "-0.0", "1e-05", "1.2345678921232e+18"
    }
}

// MARK: - Formatter

private struct ShellFormatter {
    let pretty: Bool
    let limit: Int?
    var out = ""
    var written = 0
    var done = false

    var result: String { done ? out + "…" : out }

    mutating func append(_ s: String) {
        guard !done else { return }
        guard let limit else { out += s; return }
        let n = s.count
        if written + n > limit {
            out += s.prefix(limit - written)
            done = true
        } else {
            out += s
            written += n
        }
    }

    mutating func quoted(_ s: String) {
        append("\"")
        var plain = ""
        for scalar in s.unicodeScalars {
            if done { return }
            switch scalar {
            case "\"": plain += "\\\""
            case "\\": plain += "\\\\"
            case "\n": plain += "\\n"
            case "\r": plain += "\\r"
            case "\t": plain += "\\t"
            case "\u{8}": plain += "\\b"
            case "\u{C}": plain += "\\f"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F || scalar == "\u{2028}" || scalar == "\u{2029}":
                plain += String(format: "\\u%04X", scalar.value)
            default: plain.unicodeScalars.append(scalar)
            }
            // Flushed in pieces, so a cut grid cell doesn't escape a whole 16 MB string first.
            if plain.utf8.count >= 256 { append(plain); plain = "" }
        }
        append(plain)
        append("\"")
    }

    mutating func key(_ k: String) {
        let isIdentifier = k.utf8.first.map { !($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) } ?? false
            && k.utf8.allSatisfy { ShellParser.isIdentifierByte($0) }
        if isIdentifier { append(k) } else { quoted(k) }
    }

    mutating func container<T>(_ open: String, _ close: String, _ items: [T], indent: Int,
                               _ item: (inout ShellFormatter, T, Int) -> Void) {
        guard !items.isEmpty else { append(open + close); return }
        append(pretty ? open + "\n" : open + " ")
        for (n, element) in items.enumerated() {
            if done { return }
            if pretty { append(String(repeating: " ", count: indent + 2)) }
            item(&self, element, indent + 2)
            if n < items.count - 1 { append(pretty ? ",\n" : ", ") }
        }
        append(pretty ? "\n" + String(repeating: " ", count: indent) + close : " " + close)
    }

    mutating func document(_ d: BSONDocument, indent: Int) {
        container("{", "}", d.fields, indent: indent) { f, field, indent in
            f.key(field.key)
            f.append(": ")
            f.value(field.value, indent: indent)
        }
    }

    mutating func value(_ v: BSONValue, indent: Int) {
        switch v {
        case .double(let d): append(BSONValue.doubleText(d))
        case .string(let s): quoted(s)
        case .document(let d): document(d, indent: indent)
        case .array(let values): container("[", "]", values, indent: indent) { f, v, indent in f.value(v, indent: indent) }
        case let .binary(subtype, data):
            if subtype == 4 && data.count == 16 {
                let hex = data.map { String(format: "%02x", $0) }.joined()
                let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                             hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
                append("UUID(\"" + parts.joined(separator: "-") + "\")")
            } else {
                // Only what a cut cell can show is encoded (3 bytes are 4 characters).
                let shown = limit.map { data.prefix(($0 - written) / 4 * 3 + 3) } ?? data
                append("BinData(\(subtype), \"" + shown.base64EncodedString())
                append("\")")
            }
        case .undefined: append("undefined")
        case .objectId(let id): append("ObjectId(\"\(id.hex)\")")
        case .bool(let b): append(b ? "true" : "false")
        case .datetime(let ms): append(ShellDate.text(ms))
        case .null: append("null")
        case let .regex(pattern, options):
            if Self.isLiteral(pattern, options) {
                append("/" + pattern + "/" + options)
            } else {
                append("BSONRegExp(")
                quoted(pattern)
                append(", ")
                quoted(options)
                append(")")
            }
        case let .dbPointer(namespace, id):
            append("DBPointer(")
            quoted(namespace)
            append(", ObjectId(\"\(id.hex)\"))")
        case .javascript(let code):
            append("Code(")
            quoted(code)
            append(")")
        case .symbol(let s):
            append("BSONSymbol(")
            quoted(s)
            append(")")
        case let .javascriptWithScope(code, scope):
            append("Code(")
            quoted(code)
            append(", ")
            document(scope, indent: indent)
            append(")")
        case .int32(let n): append(String(n))
        case let .timestamp(t, i): append("Timestamp({ t: \(t), i: \(i) })")
        case .int64(let n): append(n.magnitude <= 1 << 53 ? "NumberLong(\(n))" : "NumberLong(\"\(n)\")")
        case .decimal128(let d): append("NumberDecimal(\"\(d)\")")
        case .minKey: append("MinKey()")
        case .maxKey: append("MaxKey()")
        }
    }

    /// A pattern that `/…/flags` writes and reads back unchanged: no slash or line break, no trailing lone backslash
    /// (it would escape the closing slash), not starting with * (JavaScript's comment), and sorted options that are
    /// also JavaScript flags. Anything else is written as BSONRegExp("…", "…").
    static func isLiteral(_ pattern: String, _ options: String) -> Bool {
        guard !pattern.isEmpty, !pattern.hasPrefix("*"),
              !pattern.unicodeScalars.contains(where: { "/\n\r\u{2028}\u{2029}".unicodeScalars.contains($0) }),
              options.allSatisfy({ "imsu".contains($0) }), options == String(options.sorted())
        else { return false }
        return pattern.utf8.reversed().prefix { $0 == UInt8(ascii: "\\") }.count % 2 == 0
    }
}

// MARK: - Dates

/// Dates in ISO 8601, UTC, by whole-number calendar arithmetic (Howard Hinnant's days-from-civil), so that every
/// millisecond reads back exactly. Years outside 0000…9999 are written `new Date(ms)`.
enum ShellDate {
    static let msPerDay: Int64 = 86_400_000

    static func text(_ ms: Int64) -> String {
        let (q, r) = ms.quotientAndRemainder(dividingBy: msPerDay)
        let days = r < 0 ? q - 1 : q, time = r < 0 ? r + msPerDay : r
        let (y, m, d) = civil(days)
        guard (0...9999).contains(y) else { return "new Date(\(ms))" }
        return String(format: "ISODate(\"%04lld-%02lld-%02lldT%02lld:%02lld:%02lld.%03lldZ\")", y, m, d,
                      time / 3_600_000, time / 60_000 % 60, time / 1000 % 60, time % 1000)
    }

    static func days(_ y: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let y = m <= 2 ? y - 1 : y
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        return era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
    }

    static func civil(_ days: Int64) -> (Int64, Int64, Int64) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    /// YYYY-MM-DD, optionally THH:MM[:SS[.mmm]], optionally Z or ±HH:MM (no zone is UTC, as in mongosh).
    static func parse(_ text: String) -> Int64? {
        let b = Array(text.utf8)
        var i = 0
        func number(_ count: Int) -> Int64? {
            guard i + count <= b.count else { return nil }
            var v: Int64 = 0
            for c in b[i..<(i + count)] {
                guard c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") else { return nil }
                v = v * 10 + Int64(c - UInt8(ascii: "0"))
            }
            i += count
            return v
        }
        func skip(_ c: Character) -> Bool {
            guard i < b.count, b[i] == c.asciiValue! else { return false }
            i += 1
            return true
        }
        guard let y = number(4), skip("-"), let m = number(2), skip("-"), let d = number(2),
              (1...12).contains(m), d >= 1, d <= days(m == 12 ? y + 1 : y, m == 12 ? 1 : m + 1, 1) - days(y, m, 1)
        else { return nil }
        var ms = days(y, m, d) * msPerDay
        if skip("T") || skip(" ") {
            guard let h = number(2), h < 24, skip(":"), let min = number(2), min < 60 else { return nil }
            ms += h * 3_600_000 + min * 60_000
            if skip(":") {
                guard let s = number(2), s < 60 else { return nil }
                ms += s * 1000
                if skip(".") {
                    var scale: Int64 = 100, digits = 0
                    while i < b.count, let n = number(1) {
                        guard digits < 3 else { return nil }  // milliseconds are all a BSON date holds
                        ms += n * scale
                        scale /= 10
                        digits += 1
                    }
                    guard digits > 0 else { return nil }
                }
            }
            if skip("Z") {
            } else if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") {
                let sign: Int64 = b[i] == UInt8(ascii: "-") ? -1 : 1
                i += 1
                guard let oh = number(2), oh < 24 else { return nil }
                _ = skip(":")
                guard let om = number(2), om < 60 else { return nil }
                ms -= sign * (oh * 3_600_000 + om * 60_000)
            }
        } else {
            _ = skip("Z")
        }
        return i == b.count ? ms : nil
    }
}

// MARK: - Parser

private struct ShellParser {
    let s: [UInt8]
    var i = 0
    var depth = -1  // the outermost document or array is depth 0, as in the reader

    init(_ text: String) { s = Array(text.utf8) }

    static func isIdentifierByte(_ c: UInt8) -> Bool {
        (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
            || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "_") || c == UInt8(ascii: "$")
    }

    static func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }

    var peek: UInt8? { i < s.count ? s[i] : nil }

    func error(_ message: String, at offset: Int? = nil) -> BSONError {
        let at = min(offset ?? i, s.count)
        let lineStart = s[..<at].lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? 0
        let line = s[..<at].filter { $0 == UInt8(ascii: "\n") }.count + 1
        let column = String(decoding: s[lineStart..<at], as: UTF8.self).count + 1
        return BSONError("Line \(line), column \(column): \(message)")
    }

    /// What's at the cursor, for "found …" in an error.
    var found: String {
        guard i < s.count else { return "the end of the text" }
        let rest = String(decoding: s[i..<min(i + 4, s.count)], as: UTF8.self)
        return "‘\(rest.first.map(String.init) ?? "?")’"
    }

    mutating func skipSpace() {
        while let c = peek, c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1 }
    }

    mutating func expect(_ c: Character, _ what: String) throws {
        skipSpace()
        guard peek == c.asciiValue else { throw error("Expected \(what), found \(found)") }
        i += 1
    }

    mutating func whole(documentOnly: Bool) throws -> BSONValue {
        skipSpace()
        if documentOnly && peek != UInt8(ascii: "{") { throw error("A document starts with ‘{’; found \(found)") }
        let v = try value()
        skipSpace()
        guard i == s.count else { throw error("Expected the end of the text after the value, found \(found)") }
        return v
    }

    mutating func value() throws -> BSONValue {
        skipSpace()
        guard let c = peek else { throw error("Expected a value, found the end of the text") }
        switch c {
        case UInt8(ascii: "{"): return .document(try document())
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""), UInt8(ascii: "'"): return .string(try string())
        case UInt8(ascii: "/"): return try regex()
        case UInt8(ascii: "-") where s[(i + 1)...].starts(with: "Infinity".utf8):
            i += 9
            return .double(-.infinity)
        case UInt8(ascii: "-"): return try Self.plainNumber(numberText())
        case _ where Self.isDigit(c): return try Self.plainNumber(numberText())
        case _ where Self.isIdentifierByte(c): return try word()
        default: throw error("Expected a value, found \(found)")
        }
    }

    mutating func nested<T>(_ body: (inout ShellParser) throws -> T) throws -> T {
        depth += 1
        defer { depth -= 1 }
        guard depth <= BSONDocument.maxDepth else { throw error("Values nest more than \(BSONDocument.maxDepth) deep") }
        return try body(&self)
    }

    mutating func document() throws -> BSONDocument {
        try nested { p in
            p.i += 1
            var fields: [(key: String, value: BSONValue)] = []
            while true {
                p.skipSpace()
                if p.peek == UInt8(ascii: "}") { p.i += 1; return BSONDocument(fields) }
                let keyAt = p.i
                let key: String
                if p.peek == UInt8(ascii: "\"") || p.peek == UInt8(ascii: "'") {
                    key = try p.string()
                } else if let c = p.peek, Self.isIdentifierByte(c) {
                    let start = p.i
                    while let c = p.peek, Self.isIdentifierByte(c) { p.i += 1 }
                    key = String(decoding: p.s[start..<p.i], as: UTF8.self)
                } else {
                    throw p.error("Expected a field name or ‘}’, found \(p.found)")
                }
                guard !key.utf8.contains(0) else { throw p.error("A field name can't contain a NUL character", at: keyAt) }
                try p.expect(":", "‘:’ after the field name \(key)")
                fields.append((key, try p.value()))
                p.skipSpace()
                if p.peek == UInt8(ascii: ",") { p.i += 1; continue }
                guard p.peek == UInt8(ascii: "}") else { throw p.error("Expected ‘,’ or ‘}’ after a field, found \(p.found)") }
            }
        }
    }

    mutating func array() throws -> BSONValue {
        try nested { p in
            p.i += 1
            var values: [BSONValue] = []
            while true {
                p.skipSpace()
                if p.peek == UInt8(ascii: "]") { p.i += 1; return .array(values) }
                values.append(try p.value())
                p.skipSpace()
                if p.peek == UInt8(ascii: ",") { p.i += 1; continue }
                guard p.peek == UInt8(ascii: "]") else { throw p.error("Expected ‘,’ or ‘]’ in an array, found \(p.found)") }
            }
        }
    }

    mutating func hex(_ count: Int) throws -> UInt32 {
        guard i + count <= s.count, let v = UInt32(String(decoding: s[i..<(i + count)], as: UTF8.self), radix: 16) else {
            throw error("Expected \(count) hex digits in an escape")
        }
        i += count
        return v
    }

    mutating func string() throws -> String {
        let quote = s[i], start = i
        i += 1
        var bytes: [UInt8] = []
        while true {
            guard let c = peek else { throw error("This string has no closing quote", at: start) }
            i += 1
            if c == quote { return String(decoding: bytes, as: UTF8.self) }
            if c < 0x20 { throw error("A string can't hold a line break or control character; write \\n or \\u0000", at: i - 1) }
            guard c == UInt8(ascii: "\\") else { bytes.append(c); continue }
            guard let e = peek else { throw error("This string has no closing quote", at: start) }
            i += 1
            var scalar: UInt32
            switch e {
            case UInt8(ascii: "n"): scalar = 0x0A
            case UInt8(ascii: "r"): scalar = 0x0D
            case UInt8(ascii: "t"): scalar = 0x09
            case UInt8(ascii: "b"): scalar = 0x08
            case UInt8(ascii: "f"): scalar = 0x0C
            case UInt8(ascii: "v"): scalar = 0x0B
            case UInt8(ascii: "0") where !(peek.map(Self.isDigit) ?? false): scalar = 0
            case UInt8(ascii: "x"): scalar = try hex(2)
            case UInt8(ascii: "u"):
                if peek == UInt8(ascii: "{") {
                    i += 1
                    let end = s[i...].firstIndex(of: UInt8(ascii: "}")) ?? i
                    scalar = try hex(end - i)
                    i += 1
                } else {
                    scalar = try hex(4)
                    if (0xD800..<0xDC00).contains(scalar), s[i...].starts(with: "\\u".utf8) {
                        i += 2
                        let low = try hex(4)
                        guard (0xDC00..<0xE000).contains(low) else { throw error("A \\u escape is half a character", at: i - 6) }
                        scalar = 0x10000 + (scalar - 0xD800) << 10 + (low - 0xDC00)
                    }
                }
            case UInt8(ascii: "\n"): continue  // a line continuation
            default:
                if Self.isDigit(e) { throw error("Octal escapes aren't allowed in strings", at: i - 2) }
                bytes.append(e)
                continue
            }
            guard let u = Unicode.Scalar(scalar) else { throw error("A \\u escape is half a character or out of range", at: i - 1) }
            bytes += String(Character(u)).utf8
        }
    }

    mutating func regex() throws -> BSONValue {
        let start = i
        i += 1
        var inClass = false
        while true {
            guard let c = peek, c != 0x0A, c != 0x0D else { throw error("This regular expression has no closing ‘/’", at: start) }
            if c == UInt8(ascii: "/") && !inClass { break }
            if c == UInt8(ascii: "\\") { i += 1 } else if c == UInt8(ascii: "[") { inClass = true } else if c == UInt8(ascii: "]") { inClass = false }
            i += 1
        }
        let pattern = String(decoding: s[(start + 1)..<min(i, s.count)], as: UTF8.self)
        guard !pattern.isEmpty else { throw error("A regular expression can't be empty", at: start) }
        i += 1
        let flagsAt = i
        while let c = peek, Self.isIdentifierByte(c) { i += 1 }
        let flags = String(decoding: s[flagsAt..<i], as: UTF8.self)
        guard flags.allSatisfy({ "imsxlu".contains($0) }) else {
            throw error("MongoDB's regular expression options are i, m, s, x, l and u", at: flagsAt)
        }
        return .regex(pattern: pattern, options: String(flags.sorted()))  // stored sorted, as drivers do
    }

    mutating func numberText() throws -> String {
        let start = i
        if peek == UInt8(ascii: "-") { i += 1 }
        let intStart = i
        while let c = peek, Self.isDigit(c) { i += 1 }
        guard i > intStart else { throw error("Expected digits after ‘-’, found \(found)") }
        if s[intStart] == UInt8(ascii: "0") && i - intStart > 1 { throw error("A number can't start with 0", at: intStart) }
        if peek == UInt8(ascii: ".") {
            i += 1
            let fraction = i
            while let c = peek, Self.isDigit(c) { i += 1 }
            guard i > fraction else { throw error("Expected digits after the decimal point, found \(found)") }
        }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            i += 1
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { i += 1 }
            let exponent = i
            while let c = peek, Self.isDigit(c) { i += 1 }
            guard i > exponent else { throw error("Expected the exponent's digits, found \(found)") }
        }
        if let c = peek, Self.isIdentifierByte(c) { throw error("Unexpected \(found) after a number") }
        return String(decoding: s[start..<i], as: UTF8.self)
    }

    /// mongosh's rule: an integer that fits an int32 is an int32, any other number a double (-0 too, to keep its sign).
    static func plainNumber(_ text: String) throws -> BSONValue {
        if text != "-0", let n = Int32(text) { return .int32(n) }
        return .double(Double(text)!)
    }

    mutating func word() throws -> BSONValue {
        let start = i
        while let c = peek, Self.isIdentifierByte(c) { i += 1 }
        var name = String(decoding: s[start..<i], as: UTF8.self)
        switch name {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        case "undefined": return .undefined
        case "NaN": return .double(.nan)
        case "Infinity": return .double(.infinity)
        case "MinKey", "MaxKey":
            skipSpace()
            if peek == UInt8(ascii: "(") { i += 1; try expect(")", "‘)’") }
            return name == "MinKey" ? .minKey : .maxKey
        case "new":
            skipSpace()
            let nameAt = i
            while let c = peek, Self.isIdentifierByte(c) { i += 1 }
            name = String(decoding: s[nameAt..<i], as: UTF8.self)
            guard !name.isEmpty else { throw error("Expected a name after ‘new’, found \(found)") }
        default: break
        }
        skipSpace()
        guard peek == UInt8(ascii: "(") else {
            throw error("‘\(name)’ isn't a value; strings need quotes, and values are written as in mongosh, such as ObjectId(\"…\")", at: start)
        }
        i += 1
        var args: [(value: BSONValue, number: String?)] = []
        while true {
            skipSpace()
            if peek == UInt8(ascii: ")") { i += 1; break }
            if let c = peek, Self.isDigit(c) || (c == UInt8(ascii: "-") && !s[(i + 1)...].starts(with: "Infinity".utf8)) {
                let text = try numberText()
                args.append((try Self.plainNumber(text), text))
            } else {
                args.append((try value(), nil))
            }
            skipSpace()
            if peek == UInt8(ascii: ",") { i += 1; continue }
            guard peek == UInt8(ascii: ")") else { throw error("Expected ‘,’ or ‘)’ in \(name)(…), found \(found)") }
        }
        return try call(name, args, at: start)
    }

    func call(_ name: String, _ args: [(value: BSONValue, number: String?)], at: Int) throws -> BSONValue {
        func fail(_ what: String) -> BSONError { error("\(name)(…) takes \(what)", at: at) }
        func text(_ n: Int) -> String? {
            guard n < args.count else { return nil }
            if let number = args[n].number { return number }
            if case .string(let s) = args[n].value { return s }
            return nil
        }
        func string(_ n: Int) -> String? {
            guard n < args.count, case .string(let s) = args[n].value else { return nil }
            return s
        }
        switch name {
        case "ObjectId":
            guard args.count == 1, let hex = string(0), let id = BSONObjectId(hex: hex) else { throw fail("24 hex digits in quotes") }
            return .objectId(id)
        case "ISODate", "Date":
            guard args.count == 1 else { throw fail("a date in quotes, such as \"2024-05-01T12:00:00Z\"") }
            if let number = args[0].number {
                guard let ms = Int64(number) else { throw fail("whole milliseconds") }
                return .datetime(ms)
            }
            guard let s = string(0), let ms = ShellDate.parse(s) else {
                throw fail("a date in quotes, such as \"2024-05-01T12:00:00.000Z\" (UTC, at most milliseconds)")
            }
            return .datetime(ms)
        case "NumberLong", "Long":
            guard args.count == 1, let t = text(0), let n = Int64(t) else { throw fail("a whole number from -9223372036854775808 to 9223372036854775807") }
            return .int64(n)
        case "NumberInt", "Int32":
            guard args.count == 1, let t = text(0), let n = Int32(t) else { throw fail("a whole number from -2147483648 to 2147483647") }
            return .int32(n)
        case "NumberDecimal", "Decimal128":
            guard args.count == 1, let t = text(0), let d = BSONDecimal128(t) else {
                throw fail("a decimal in quotes with at most 34 significant digits")
            }
            return .decimal128(d)
        case "Double":
            guard args.count == 1, let t = text(0), let d = Double(t) else { throw fail("a number") }
            return .double(d)
        case "Timestamp":
            if args.count == 1, case .document(let d) = args[0].value, d.keys == ["t", "i"] || d.keys == ["i", "t"],
               let t = Self.uint32(d["t"]), let i = Self.uint32(d["i"]) {
                return .timestamp(t: t, i: i)
            }
            if args.count == 2, let t = Self.uint32(args[0].value), let i = Self.uint32(args[1].value) {
                return .timestamp(t: t, i: i)
            }
            throw fail("{ t: seconds, i: increment }, each from 0 to 4294967295")
        case "BinData":
            guard args.count == 2, let t = args[0].number, let subtype = UInt8(t), let b64 = string(1),
                  let data = Data(base64Encoded: b64) else { throw fail("a subtype from 0 to 255 and base64 in quotes") }
            return .binary(subtype: subtype, data: data)
        case "UUID":
            guard args.count == 1, let hex = string(0)?.replacingOccurrences(of: "-", with: ""), hex.utf8.count == 32,
                  let bytes = BSONObjectId.bytes(hex: hex) else { throw fail("32 hex digits in quotes") }
            return .binary(subtype: 4, data: Data(bytes))
        case "BSONRegExp":
            guard (1...2).contains(args.count), let pattern = string(0), !pattern.utf8.contains(0) else {
                throw fail("a pattern and options in quotes")
            }
            let options = args.count == 2 ? string(1) : ""
            guard let options, !options.utf8.contains(0) else { throw fail("a pattern and options in quotes") }
            return .regex(pattern: pattern, options: options)
        case "Code":
            guard let code = string(0) else { throw fail("code in quotes, and optionally a scope document") }
            if args.count == 1 { return .javascript(code) }
            guard args.count == 2, case .document(let scope) = args[1].value else { throw fail("code in quotes and a scope document") }
            return .javascriptWithScope(code: code, scope: scope)
        case "BSONSymbol":
            guard args.count == 1, let s = string(0) else { throw fail("text in quotes") }
            return .symbol(s)
        case "DBPointer":
            guard args.count == 2, let namespace = string(0), case .objectId(let id) = args[1].value else {
                throw fail("a namespace in quotes and an ObjectId")
            }
            return .dbPointer(namespace: namespace, id: id)
        default:
            throw error("\(name)(…) isn't a value AirSQL reads; it reads values as mongosh writes them, such as ObjectId(\"…\") or ISODate(\"…\"), and runs no code", at: at)
        }
    }

    static func uint32(_ v: BSONValue?) -> UInt32? {
        switch v {
        case .int32(let n)?: return UInt32(exactly: n)
        case .double(let d)?: return UInt32(exactly: d)
        default: return nil
        }
    }
}
