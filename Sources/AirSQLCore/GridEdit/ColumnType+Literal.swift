import Foundation

extension ColumnType {
    /// The SQL literal for a value typed or pasted into a cell of this type, or why it can't be saved as typed. Text is
    /// taken exactly as typed; numbers, dates, bits and hex may have spaces around them. An empty text is an empty
    /// string for text columns and an error elsewhere: NULL and DEFAULT are their own commands, so a NULL cell passed
    /// through never becomes a value (and never NOW(), HeidiSQL t=9771).
    public func literal(_ text: String, _ context: EditContext) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .integer(let bytes): return try integer(trimmed, bytes: bytes)
        case .decimal(let precision, let scale): return try decimal(trimmed, precision: precision, scale: scale)
        case .float(let bytes): return try float(trimmed, bytes: bytes)
        case .bit(let width): return try bit(trimmed, width: width)
        case .date, .time, .datetime, .timestamp, .year: return try DateTimeText.literal(trimmed, self, context)
        case .text(let characters, let bytes):
            try checkText(text, characters: characters, bytes: bytes)
            return SQLQuote.string(text, noBackslashEscapes: context.noBackslashEscapes)
        case .binary(let bytes, _):
            let value = try Self.hexBytes(trimmed)
            guard value.count <= bytes else {
                throw EditError("\(definition) holds at most \(bytes) bytes; this is \(value.count)")
            }
            return SQLQuote.hex(value)
        case .json:
            try JSONText.validate(text, maxDepth: context.flavour == .mariadb ? 31 : 100)
            return SQLQuote.string(text, noBackslashEscapes: context.noBackslashEscapes)
        case .enumeration(let members):
            guard let member = Self.member(text, of: members) else {
                throw EditError("Choose one of " + Self.list(members))
            }
            return SQLQuote.string(member, noBackslashEscapes: context.noBackslashEscapes)
        case .set(let members):
            return SQLQuote.string(try setValue(text, members: members), noBackslashEscapes: context.noBackslashEscapes)
        case .other:
            return SQLQuote.string(text, noBackslashEscapes: context.noBackslashEscapes)
        }
    }

    /// The literal for a value as the server sent it (a ResultStore cell; nil is NULL): for keys in a WHERE clause and
    /// for related rows. Numbers stay bare and exact, bytes become hex, BIT its bits, everything else a string.
    public func literal(stored bytes: [UInt8]?, _ context: EditContext) -> String {
        guard let bytes else { return "NULL" }
        let text = String(decoding: bytes, as: UTF8.self)
        switch kind {
        case .bit: return SQLQuote.bits(bytes.reduce(0) { $0 << 8 | UInt64($1) })
        case .binary: return SQLQuote.hex(bytes)
        // Whole and decimal numbers stay bare (exact); anything else, FLOAT and DOUBLE included, is a string.
        case .integer, .decimal, .year: if Self.decimalParts(text) != nil { return text }
        default: break
        }
        return SQLQuote.string(text, noBackslashEscapes: context.noBackslashEscapes)
    }

    /// The text an editor starts from for a stored value: "" for NULL (never a made-up value), every bit of a BIT
    /// (BIT(64) in full, HeidiSQL #56), bytes as 0x and hex digits (all of them), anything else as the server sent it.
    public func editorText(stored bytes: [UInt8]?) -> String {
        guard let bytes else { return "" }
        switch kind {
        case .bit(let width):
            let bits = bytes.map { byte -> String in
                let digits = String(byte, radix: 2)
                return String(repeating: "0", count: 8 - digits.count) + digits
            }.joined()
            return String(repeating: "0", count: max(0, width - bits.count)) + bits.suffix(width)
        case .binary:
            return "0x" + bytes.map { String(format: "%02X", $0) }.joined()
        default:
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// A SET value from its members, in the column's order: what the SET checklist saves.
    public func setText(_ chosen: [String]) -> String {
        guard case .set(let members) = kind else { return chosen.joined(separator: ",") }
        return members.filter { member in chosen.contains { $0.caseInsensitiveCompare(member) == .orderedSame } }
            .joined(separator: ",")
    }

    // MARK: Numbers

    /// Whole numbers within the type's range: "+0042" → 42. "12.00" is 12; "12.5" is refused, as the server would round.
    private func integer(_ text: String, bytes: Int) throws -> String {
        if isBoolean, let truth = ["true": "1", "false": "0"][text.lowercased()] { return truth }
        guard let number = Self.decimalParts(text), number.fraction.allSatisfy({ $0 == "0" }) else {
            throw EditError("\(definition) holds whole numbers, such as 42; \(Self.quoted(text)) isn't one")
        }
        let bits = UInt64(bytes * 8)
        let max: UInt64 = unsigned ? (bits == 64 ? .max : (1 << bits) - 1) : (1 << (bits - 1)) - 1
        let min: UInt64 = unsigned ? 0 : 1 << (bits - 1)
        let value = UInt64(number.whole)
        let fits = value.map { number.negative ? $0 <= min : $0 <= max } ?? false
        guard fits else {
            let low = unsigned ? "0" : "-\(min)"
            throw EditError("\(definition) holds \(low) to \(max); \(text) is outside that")
        }
        return (number.negative && number.whole != "0" ? "-" : "") + number.whole
    }

    /// DECIMAL kept exact: at most precision − scale digits before the point and scale after it (extra zeros at the end
    /// are fine; other digits are refused, as the server would round them).
    private func decimal(_ text: String, precision: Int, scale: Int) throws -> String {
        guard let number = Self.decimalParts(text) else {
            throw EditError("\(definition) holds numbers such as 1234.56 (no exponent, no grouping); \(Self.quoted(text)) isn't one")
        }
        var fraction = number.fraction
        while fraction.count > scale, fraction.last == "0" { fraction.removeLast() }
        guard fraction.count <= scale else {
            throw EditError("\(definition) keeps \(scale) digit\(scale == 1 ? "" : "s") after the point; round \(text) first")
        }
        guard number.whole.count <= precision - scale || number.whole == "0" else {
            throw EditError("\(definition) holds at most \(precision - scale) digits before the point; "
                + "\(text) has \(number.whole.count)")
        }
        let zero = number.whole == "0" && fraction.allSatisfy { $0 == "0" }
        guard !(unsigned && number.negative && !zero) else { throw EditError("\(definition) holds no negative numbers") }
        return (number.negative && !zero ? "-" : "") + number.whole + (fraction.isEmpty ? "" : "." + fraction)
    }

    /// FLOAT and DOUBLE: a decimal number with an optional exponent, within the type's range (the server rounds it to
    /// the type's precision: that is what FLOAT is).
    private func float(_ text: String, bytes: Int) throws -> String {
        let characters = Array(text.utf8), digit = { (byte: UInt8) in byte >= 48 && byte <= 57 }
        var index = characters.first == UInt8(ascii: "-") || characters.first == UInt8(ascii: "+") ? 1 : 0
        let start = index
        while index < characters.count, digit(characters[index]) { index += 1 }
        var digits = index - start
        if index < characters.count, characters[index] == UInt8(ascii: ".") {
            index += 1
            let fractionStart = index
            while index < characters.count, digit(characters[index]) { index += 1 }
            digits += index - fractionStart
        }
        if digits > 0, index < characters.count, characters[index] | 0x20 == UInt8(ascii: "e") {
            index += 1
            if index < characters.count, [UInt8(ascii: "-"), UInt8(ascii: "+")].contains(characters[index]) { index += 1 }
            let exponentStart = index
            while index < characters.count, digit(characters[index]) { index += 1 }
            if index == exponentStart { digits = 0 }
        }
        guard digits > 0, index == characters.count, let value = Double(text), value.isFinite,
              bytes == 8 || abs(value) <= 3.402823466e38 else {
            throw EditError("\(definition) holds numbers such as 1.5 or 2.5e-3; \(Self.quoted(text)) isn't one")
        }
        guard !(unsigned && value < 0) else { throw EditError("\(definition) holds no negative numbers") }
        return text.hasPrefix("+") ? String(text.dropFirst()) : text
    }

    /// Sign, whole digits without leading zeros, and fraction digits of a plain decimal number: "-007.50" →
    /// (true, "7", "50"). nil for anything else (grouping, exponents, two points).
    static func decimalParts(_ text: String) -> (negative: Bool, whole: String, fraction: String)? {
        var rest = Substring(text)
        let negative = rest.first == "-"
        if negative || rest.first == "+" { rest = rest.dropFirst() }
        let parts = rest.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let wholePart = parts.first else { return nil }
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        guard !(wholePart.isEmpty && fraction.isEmpty),
              (wholePart + fraction).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let whole = String(wholePart.drop { $0 == "0" })
        return (negative, whole.isEmpty ? "0" : whole, fraction)
    }

    // MARK: Bits, bytes, text, ENUM and SET

    /// BIT(n): up to n binary digits, as the grid shows them ("101"), or b'101' / 0b101; TRUE and FALSE for BIT(1).
    private func bit(_ text: String, width: Int) throws -> String {
        if width == 1, let truth = ["true": "b'1'", "false": "b'0'"][text.lowercased()] { return truth }
        var digits = Substring(text)
        if digits.lowercased().hasPrefix("b'"), digits.hasSuffix("'"), digits.count >= 3 {
            digits = digits.dropFirst(2).dropLast()
        } else if digits.lowercased().hasPrefix("0b") {
            digits = digits.dropFirst(2)
        }
        let significant = digits.drop { $0 == "0" }
        guard !digits.isEmpty, digits.allSatisfy({ $0 == "0" || $0 == "1" }), significant.count <= width,
              let value = UInt64(significant.isEmpty ? "0" : String(significant), radix: 2) else {
            throw EditError("\(definition) holds up to \(width) binary digit\(width == 1 ? "" : "s"), such as "
                + String(repeating: "1", count: min(width, 3)) + "; \(Self.quoted(text)) isn't that")
        }
        return SQLQuote.bits(value)
    }

    /// Hex digits, as the grid shows bytes ("0x00FF") or as X'00FF', with spaces allowed between bytes.
    static func hexBytes(_ text: String) throws -> [UInt8] {
        var digits = Substring(text.filter { !$0.isWhitespace })
        if digits.lowercased().hasPrefix("x'"), digits.hasSuffix("'"), digits.count >= 3 {
            digits = digits.dropFirst(2).dropLast()
        } else if digits.lowercased().hasPrefix("0x") {
            digits = digits.dropFirst(2)
        }
        guard digits.count.isMultiple(of: 2), digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw EditError("Bytes are typed as hex digits, two per byte, such as 0x00FF; \(quoted(text)) isn't that")
        }
        var bytes: [UInt8] = [], index = digits.startIndex
        bytes.reserveCapacity(digits.count / 2)
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            bytes.append(UInt8(digits[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    /// CHAR/VARCHAR count characters (code points), TEXT types bytes in the column's character set; the character set
    /// itself limits which characters fit (latin1 has no emoji, utf8mb3 nothing beyond U+FFFF).
    private func checkText(_ text: String, characters: Int?, bytes: Int?) throws {
        let charset = (self.charset ?? "utf8mb4").lowercased()
        if let characters, text.unicodeScalars.count > characters {
            throw EditError("\(definition) holds \(characters) characters; this is \(text.unicodeScalars.count)")
        }
        let scalars = text.unicodeScalars
        let unfit: Unicode.Scalar?
        switch charset {
        case "utf8mb3", "utf8", "ucs2": unfit = scalars.first { $0.value > 0xFFFF }
        case "ascii": unfit = scalars.first { !$0.isASCII }
        case "latin1":
            unfit = text.canBeConverted(to: .windowsCP1252) ? nil : scalars.first { !String($0).canBeConverted(to: .windowsCP1252) }
        default: unfit = nil
        }
        if let unfit {
            let code = String(format: "U+%04X", unfit.value)
            throw EditError("The column's character set (\(charset)) has no \(String(unfit)) (\(code))")
        }
        if let bytes {
            let size: Int
            switch charset {
            case "latin1", "ascii": size = scalars.count
            case "ucs2": size = scalars.count * 2
            case "utf16", "utf16le": size = text.utf16.count * 2
            case "utf32": size = scalars.count * 4
            default: size = text.utf8.count
            }
            guard size <= bytes else {
                throw EditError("\(definition) holds \(bytes) bytes; this is \(size) in \(charset)")
            }
        }
    }

    /// The member as the column defines it: exactly, else ignoring case (as the server compares them).
    static func member(_ text: String, of members: [String]) -> String? {
        members.first { $0 == text } ?? members.first { $0.caseInsensitiveCompare(text) == .orderedSame }
    }

    /// Members separated by commas, each one the column's: "b, a" → "a,b" (the column's order, each once).
    private func setValue(_ text: String, members: [String]) throws -> String {
        var chosen: [String] = []
        for item in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !item.isEmpty {
            guard let member = Self.member(item, of: members) else {
                throw EditError("\(Self.quoted(item)) isn't one of " + Self.list(members))
            }
            chosen.append(member)
        }
        return members.filter(chosen.contains).joined(separator: ",")
    }

    static func list(_ members: [String]) -> String {
        members.isEmpty ? "the column's values" : members.map(quoted).joined(separator: ", ")
    }

    /// A value in a message, cut short.
    static func quoted(_ text: String) -> String {
        "“" + (text.count > 40 ? text.prefix(40) + "…" : text) + "”"
    }
}
