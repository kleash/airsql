import Foundation

// How the table editor's text cells write a design's parts and read back what the person typed: lists of names
// ("id, `order date`"), index columns ("email(10), created_at DESC, (lower(name))") and defaults ("NULL", "'paid'",
// "0.00", "CURRENT_TIMESTAMP").
public enum EditorText {
    /// Names separated by commas, each bare when it can be, else in backticks.
    public static func names(_ names: [String]) -> String {
        names.map(name).joined(separator: ", ")
    }

    /// A name as the cells write it: bare when it is a plain word, else quoted.
    public static func name(_ name: String) -> String {
        name.range(of: "^[A-Za-z0-9_$]+$", options: .regularExpression) != nil ? name : SQLQuote.identifier(name)
    }

    /// The names in a list written as `names(_:)` writes it (empty items dropped).
    public static func names(from text: String) -> [String] {
        items(text).map(unquoted).filter { !$0.isEmpty }
    }

    /// db.table or table, each part bare or in backticks.
    public static func qualified(from text: String) -> (database: String?, name: String) {
        var parts: [String] = [], current = "", quoted = false
        for character in text.trimmingCharacters(in: .whitespaces) {
            if character == "`" { quoted.toggle() }
            if character == ".", !quoted {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        parts.append(current)
        let names = parts.map(unquoted)
        return names.count >= 2 ? (names[0], names[1...].joined(separator: ".")) : (nil, names[0])
    }

    /// An index's columns as the Columns cell writes them.
    public static func parts(_ parts: [IndexDesign.Part]) -> String {
        parts.map { part in
            (part.column.map { name($0) + (part.prefixLength.map { "(\($0))" } ?? "") } ?? "(" + (part.expression ?? "") + ")")
                + (part.descending ? " DESC" : "")
        }.joined(separator: ", ")
    }

    /// An index's columns from what the person typed: name, name(10), name DESC, (expression).
    public static func parts(from text: String) throws -> [IndexDesign.Part] {
        try items(text).map { item in
            var item = item
            var descending = false
            for (suffix, down) in [(" DESC", true), (" ASC", false)] where item.uppercased().hasSuffix(suffix) {
                item = String(item.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                descending = down
            }
            if item.hasPrefix("("), item.hasSuffix(")") {
                return IndexDesign.Part(column: nil, expression: String(item.dropFirst().dropLast()), descending: descending)
            }
            var prefix: Int?
            if item.hasSuffix(")"), let open = item.lastIndex(of: "("), !item.hasPrefix("`") || item[..<open].hasSuffix("`") {
                guard let length = Int(item[item.index(after: open)..<item.index(before: item.endIndex)]), length > 0 else {
                    throw DesignError("Write a prefix length as digits, such as email(10)")
                }
                prefix = length
                item = String(item[..<open]).trimmingCharacters(in: .whitespaces)
            }
            let name = unquoted(item)
            guard !name.isEmpty else { throw DesignError("An index column needs a name") }
            return IndexDesign.Part(column: name, prefixLength: prefix, descending: descending)
        }
    }

    /// A column's default as the Default cell writes it: empty for none, NULL, a string quoted, a number bare, an
    /// expression as it is.
    public static func defaultValue(_ value: SchemaDefault, numeric: Bool, noBackslashEscapes: Bool) -> String {
        switch value {
        case .none: return ""
        case .null: return "NULL"
        case .value(let text):
            return numeric && SchemaIntrospection.isNumber(text) ? text : SQLQuote.string(text, noBackslashEscapes: noBackslashEscapes)
        case .expression(let sql): return sql
        }
    }

    /// A default from what the person typed: nothing, NULL, 'quoted text', a number, else an expression.
    public static func defaultValue(from text: String, noBackslashEscapes: Bool) -> SchemaDefault {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return .none }
        if text.uppercased() == "NULL" { return .null }
        if text.hasPrefix("'"), let values = try? TypeSpec.values(text, noBackslashEscapes: noBackslashEscapes), values.count == 1 {
            return .value(values[0])
        }
        if SchemaIntrospection.isNumber(text) { return .value(text) }
        return .expression(text)
    }

    /// The items of a comma-separated list, split outside backticks, quotes and parentheses, trimmed.
    static func items(_ text: String) -> [String] {
        var items: [String] = [], current = "", depth = 0
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "`" || character == "'" || character == "\"" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth = max(0, depth - 1)
            } else if character == ",", depth == 0 {
                items.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        items.append(current)
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A name without its backticks (doubled backticks inside made single), or as it is.
    static func unquoted(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2, text.hasPrefix("`"), text.hasSuffix("`") else { return text }
        return String(text.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`")
    }
}
