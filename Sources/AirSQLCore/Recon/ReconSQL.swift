import Foundation

/// The SQL a data compare sends to one side for one table (plan §2.9, R6), and how it reads values back. Both sides get
/// the same statements, so their answers can be compared.
///
/// Rows are matched on a key: the primary key, or a unique key whose columns are all NOT NULL. Each row is hashed on
/// the server as the first 64 bits of an MD5 over its encoded values, and a chunk of rows (a key range) is summed up as
/// COUNT(*) and the exact SUM of those hashes (SUM over integers is DECIMAL, so nothing rounds). A column's part of the
/// encoded row is `1` for NULL, else `0`, the value's length in bytes, `:` and the value, so NULLs, empty strings,
/// separators and values swapped between columns all encode differently. Text is converted to utf8mb4 first (the same
/// text in latin1 and utf8mb4 is equal); long types (TEXT, BLOB, JSON, spatial) put their value's MD5 in its place, so a
/// row's encoding stays far below max_allowed_packet (CONCAT would return NULL past it). BIT is hashed as its number.
/// Sessions run with time_zone '+00:00', so TIMESTAMP values read the same on both sides.
///
/// Key ranges use each server's own comparison, so the server walks its index. Two servers whose key collations order
/// differently may place a row in different chunks; that only costs fetching more. Which rows are missing, extra or
/// changed is always decided by looking each candidate key up on both sides, matching key bytes exactly (BINARY), so
/// 'a' and 'A' are different keys even under a case-insensitive collation.
struct ReconTableSQL {
    /// The table, qualified and quoted.
    let table: String
    let key: [ReconColumn]
    /// Every compared column, key columns first.
    let columns: [ReconColumn]
    /// The person's WHERE for this table, or "".
    let filter: String
    let noBackslashEscapes: Bool

    init(database: String, table: String, key: [ReconColumn], columns: [ReconColumn], filter: String,
         noBackslashEscapes: Bool) {
        self.table = SQLQuote.identifier(database, table)
        self.key = key
        self.columns = columns
        self.filter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        self.noBackslashEscapes = noBackslashEscapes
    }

    /// A column's part of the encoded row.
    static func part(_ column: ReconColumn) -> String {
        let name = SQLQuote.identifier(column.name)
        let value: String
        switch column.kind {
        case .text: value = "CONVERT(\(name) USING utf8mb4)"
        case .longText, .json: value = "MD5(CONVERT(\(name) USING utf8mb4))"
        case .blob: value = "MD5(\(name))"
        case .bit: value = "(\(name) + 0)"
        case .integer, .decimal, .float, .binary, .temporal: value = name
        }
        return "IFNULL(CONCAT('0', LENGTH(\(value)), ':', \(value)), '1')"
    }

    /// A row's 64-bit hash, as BIGINT UNSIGNED.
    var rowHash: String {
        "CAST(CONV(LEFT(MD5(CONCAT(" + columns.map(Self.part).joined(separator: ", ") + ")), 16), 16, 10) AS UNSIGNED)"
    }

    private var keyList: String { key.map { SQLQuote.identifier($0.name) }.joined(separator: ", ") }

    /// Rows with keys after `after` (nil: from the first) up to and including `upTo` (nil: to the last), within the
    /// person's WHERE.
    func conditions(after: [[UInt8]]?, upTo: [[UInt8]]?) -> String {
        var parts: [String] = []
        // On lines of its own, so a -- comment at its end can't swallow the rest.
        if !filter.isEmpty { parts.append("(\n\(filter)\n)") }
        if let after { parts.append(beyond(after, 0, ">", ">")) }
        if let upTo { parts.append(beyond(upTo, 0, "<", "<=")) }
        return parts.isEmpty ? "" : " WHERE " + parts.joined(separator: " AND ")
    }

    /// The key compared with `values` in key order: (k1 > v1) OR (k1 = v1 AND k2 > v2)…, which both servers turn into
    /// index ranges (MariaDB doesn't for row constructors).
    private func beyond(_ values: [[UInt8]], _ index: Int, _ step: String, _ last: String) -> String {
        let name = SQLQuote.identifier(key[index].name)
        let value = Self.literal(values[index], key[index].kind, noBackslashEscapes: noBackslashEscapes)
        if index == key.count - 1 { return "\(name) \(last) \(value)" }
        return "(\(name) \(step) \(value) OR (\(name) = \(value) AND \(beyond(values, index + 1, step, last))))"
    }

    /// COUNT(*) and the SUM of the rows' hashes in a key range.
    func checksum(after: [[UInt8]]?, upTo: [[UInt8]]?) -> String {
        "SELECT COUNT(*), SUM(\(rowHash)) FROM \(table)" + conditions(after: after, upTo: upTo)
    }

    /// The key `rows` rows on from `after` (within `upTo`): the end of the next chunk, or nothing when fewer remain.
    func boundary(after: [[UInt8]]?, upTo: [[UInt8]]?, rows: Int) -> String {
        "SELECT \(keyList) FROM \(table)" + conditions(after: after, upTo: upTo)
            + " ORDER BY \(keyList) LIMIT 1 OFFSET \(max(0, rows - 1))"
    }

    /// Every row's key and hash in a key range.
    func rowHashes(after: [[UInt8]]?, upTo: [[UInt8]]?) -> String {
        "SELECT \(keyList), \(rowHash) FROM \(table)" + conditions(after: after, upTo: upTo)
    }

    /// Every row's compared columns (within the person's WHERE), at most `limit` of them.
    func all(limit: Int) -> String {
        "SELECT " + columns.map { SQLQuote.identifier($0.name) }.joined(separator: ", ") + " FROM \(table)"
            + conditions(after: nil, upTo: nil) + " LIMIT \(limit)"
    }

    /// The compared columns of the rows with these keys.
    func rows(keys: [[[UInt8]]]) -> String {
        let list = columns.map { SQLQuote.identifier($0.name) }.joined(separator: ", ")
        return "SELECT \(list) FROM \(table) WHERE " + Self.match(keys, key: key, noBackslashEscapes: noBackslashEscapes)
    }

    /// A condition true for exactly the rows with these keys: `k IN (…)`, or (k1 = … AND k2 = …) OR … for a composite
    /// key.
    static func match(_ keys: [[[UInt8]]], key: [ReconColumn], noBackslashEscapes: Bool) -> String {
        func value(_ bytes: [UInt8], _ column: ReconColumn) -> String {
            literal(bytes, column.kind, noBackslashEscapes: noBackslashEscapes)
        }
        if key.count == 1 {
            return SQLQuote.identifier(key[0].name) + " IN (" + keys.map { value($0[0], key[0]) }.joined(separator: ", ")
                + ")"
        }
        return keys.map { values in
            "(" + zip(key, values).map { SQLQuote.identifier($0.name) + " = " + value($1, $0) }.joined(separator: " AND ")
                + ")"
        }.joined(separator: " OR ")
    }

    /// A value as a SQL literal: NULL; numbers as they are (quoted text would make MySQL compare BIGINTs as doubles);
    /// BIT as b'…'; binary as X'…'; everything else as a quoted string.
    static func literal(_ bytes: [UInt8]?, _ kind: ReconColumn.Kind, noBackslashEscapes: Bool) -> String {
        guard let bytes else { return "NULL" }
        switch kind {
        case .binary, .blob:
            return SQLQuote.hex(bytes)
        case .bit:
            return SQLQuote.bits(bytes.suffix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        case .integer, .decimal, .float:
            let text = String(decoding: bytes, as: UTF8.self)
            return isNumber(text) ? text : SQLQuote.string(text, noBackslashEscapes: noBackslashEscapes)
        case .text, .longText, .json, .temporal:
            return SQLQuote.string(String(decoding: bytes, as: UTF8.self), noBackslashEscapes: noBackslashEscapes)
        }
    }

    /// A plain number literal: digits with an optional sign, decimal point and exponent, and nothing else.
    static func isNumber(_ text: String) -> Bool {
        var scalars = Substring(text).unicodeScalars[...]
        func digits() -> Int {
            let count = scalars.prefix { $0.properties.numericType == .decimal && $0.isASCII }.count
            scalars = scalars.dropFirst(count)
            return count
        }
        if scalars.first == "-" || scalars.first == "+" { scalars = scalars.dropFirst() }
        var mantissa = digits()
        if scalars.first == "." {
            scalars = scalars.dropFirst()
            mantissa += digits()
        }
        guard mantissa > 0 else { return false }
        if scalars.first == "e" || scalars.first == "E" {
            scalars = scalars.dropFirst()
            if scalars.first == "-" || scalars.first == "+" { scalars = scalars.dropFirst() }
            guard digits() > 0 else { return false }
        }
        return scalars.isEmpty
    }

    /// Two values are the same: equal bytes, or equal as values where servers write the same value differently (floats,
    /// decimals of another scale, zero-filled integers, JSON with other spacing or key order).
    static func same(_ left: [UInt8]?, _ right: [UInt8]?, _ kind: ReconColumn.Kind) -> Bool {
        guard let left, let right else { return left == nil && right == nil }
        if left == right { return true }
        let a = String(decoding: left, as: UTF8.self), b = String(decoding: right, as: UTF8.self)
        switch kind {
        case .float:
            guard let x = Double(a), let y = Double(b) else { return false }
            return x == y
        case .decimal, .integer:
            // Not through Foundation's Decimal: it keeps 38 significant digits, so two DECIMAL(65) values that differ
            // beyond the 38th would compare equal. Compare the digits exactly, written the one way.
            guard let x = normalizedDecimal(a), let y = normalizedDecimal(b) else { return false }
            return x == y
        case .json:
            let options: JSONSerialization.ReadingOptions = [.fragmentsAllowed]
            guard let x = try? JSONSerialization.jsonObject(with: Data(left), options: options),
                  let y = try? JSONSerialization.jsonObject(with: Data(right), options: options) else {
                return false
            }
            return sameJSON(x, y)
        case .bit, .binary, .blob, .text, .longText, .temporal:
            return false
        }
    }

    /// Parsed JSON the same, with true and 1 apart, which NSNumber's isEqual isn't. shortcut: numbers compare as parsed,
    /// so they tie past about 38 digits; comparing them exactly needs a JSON reader that keeps their text.
    private static func sameJSON(_ left: Any, _ right: Any) -> Bool {
        switch (left, right) {
        case let (a as [String: Any], b as [String: Any]):
            return a.count == b.count && a.allSatisfy { key, value in b[key].map { sameJSON(value, $0) } ?? false }
        case let (a as [Any], b as [Any]):
            return a.count == b.count && zip(a, b).allSatisfy(sameJSON)
        case let (a as NSNumber, b as NSNumber):
            return (CFGetTypeID(a) == CFBooleanGetTypeID()) == (CFGetTypeID(b) == CFBooleanGetTypeID()) && a == b
        default:
            return (left as? NSObject)?.isEqual(right) == true
        }
    }

    /// A plain decimal (no exponent) written the one way, so two equal values match whatever their scale or padding:
    /// sign (none for zero), integer digits without leading zeros, fraction digits without trailing zeros. nil when
    /// `text` isn't a plain decimal, which for a DECIMAL or integer column means the values aren't equal as numbers.
    static func normalizedDecimal(_ text: String) -> String? {
        guard isNumber(text), !text.contains(where: { $0 == "e" || $0 == "E" }) else { return nil }
        var rest = Substring(text)
        let negative = rest.first == "-"
        if rest.first == "-" || rest.first == "+" { rest = rest.dropFirst() }
        var whole = rest, fraction: Substring = ""
        if let dot = rest.firstIndex(of: ".") {
            whole = rest[..<dot]
            fraction = rest[rest.index(after: dot)...]
        }
        while whole.first == "0" { whole = whole.dropFirst() }
        while fraction.last == "0" { fraction = fraction.dropLast() }
        let digits = (whole.isEmpty ? "0" : String(whole)) + (fraction.isEmpty ? "" : "." + fraction)
        return (negative && digits != "0" ? "-" : "") + digits
    }
}
