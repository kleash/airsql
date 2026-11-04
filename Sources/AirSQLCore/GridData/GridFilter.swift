import Foundation

/// A condition on one column (grid-spec §4): a quick filter from a cell or a selection, or the values ticked in a
/// column's list. It runs on the server as SQL (every row, loaded or not) or on the loaded rows (`matches`).
public struct GridCondition: Equatable, Sendable {
    public enum Operator: String, CaseIterable, Sendable {
        case equals, notEquals, less, greater, startsWith, endsWith, contains, isIn, notIn, isNull, isNotNull
    }

    public var column: GridColumn
    public var op: Operator
    /// What the column is compared with: one value for =, <>, <, > and LIKE; any number for IN and NOT IN (nil is
    /// NULL); none for IS NULL and IS NOT NULL.
    public var values: [String?]

    public init(_ column: GridColumn, _ op: Operator, _ values: [String?] = []) {
        self.column = column
        self.op = op
        self.values = values
    }

    /// The condition as SQL: `name` = 'Ann', `price` > 10, `name` LIKE 'An%', `id` IN (1, 2), `note` IS NULL.
    public func sql(noBackslashEscapes: Bool = false) -> String {
        let name = SQLQuote.identifier(column.name), value = values.first ?? nil
        func literal(_ value: String) -> String { column.literal(value, noBackslashEscapes: noBackslashEscapes) }
        func like(_ prefix: String, _ suffix: String) -> String {
            // '!' escapes % and _ in the value (a backslash means something else under NO_BACKSLASH_ESCAPES).
            let text = value ?? ""
            guard text.contains(where: { "%_!".contains($0) }) else {
                return name + " LIKE " + SQLQuote.string(prefix + text + suffix, noBackslashEscapes: noBackslashEscapes)
            }
            let escaped = text.replacingOccurrences(of: "!", with: "!!").replacingOccurrences(of: "%", with: "!%")
                .replacingOccurrences(of: "_", with: "!_")
            return name + " LIKE " + SQLQuote.string(prefix + escaped + suffix, noBackslashEscapes: noBackslashEscapes)
                + " ESCAPE '!'"
        }
        let listed = values.compactMap { $0 }.map(literal).joined(separator: ", ")
        let hasNull = values.contains { $0 == nil }
        switch op {
        case .equals: return value.map { name + " = " + literal($0) } ?? name + " IS NULL"
        case .notEquals: return value.map { name + " <> " + literal($0) } ?? name + " IS NOT NULL"
        case .less: return name + " < " + (value.map(literal) ?? "NULL")
        case .greater: return name + " > " + (value.map(literal) ?? "NULL")
        case .startsWith: return like("", "%")
        case .endsWith: return like("%", "")
        case .contains: return like("%", "%")
        case .isIn:
            if listed.isEmpty { return name + " IS NULL" }
            return hasNull ? "(\(name) IN (\(listed)) OR \(name) IS NULL)" : "\(name) IN (\(listed))"
        case .notIn:
            if listed.isEmpty { return name + " IS NOT NULL" }
            return hasNull ? "(\(name) NOT IN (\(listed)) AND \(name) IS NOT NULL)" : "\(name) NOT IN (\(listed))"
        case .isNull: return name + " IS NULL"
        case .isNotNull: return name + " IS NOT NULL"
        }
    }

    /// Whether a loaded row's value meets the condition, as the server would decide it with a case- and
    /// accent-insensitive collation: NULL equals only NULL here, and <, >, LIKE and NOT IN never match it.
    public func matches(_ value: String?) -> Bool {
        let wanted = values.first ?? nil
        switch op {
        case .equals: return value == wanted
        case .notEquals: return wanted == nil ? value != nil : value != nil && value != wanted
        case .less, .greater:
            guard let value, let wanted else { return false }
            let order = GridSorting.compare(value, wanted, number: column.kind == .number)
            return op == .less ? order == .orderedAscending : order == .orderedDescending
        case .startsWith, .endsWith, .contains:
            guard let value, let wanted else { return false }
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            switch op {
            case .startsWith: return wanted.isEmpty || value.range(of: wanted, options: options.union(.anchored)) != nil
            case .endsWith: return wanted.isEmpty || value.range(of: wanted, options: options.union([.anchored, .backwards])) != nil
            default: return wanted.isEmpty || value.range(of: wanted, options: options) != nil
            }
        case .isIn: return values.contains(value)
        case .notIn: return value != nil && !values.contains(value)
        case .isNull: return value == nil
        case .isNotNull: return value != nil
        }
    }
}

/// The WHERE bar's text and the search box (grid-spec §4).
public enum GridFilter {
    /// The bar's text as a condition: trimmed, without a leading WHERE.
    public static func condition(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 5, text.prefix(5).uppercased() == "WHERE", text.dropFirst(5).first?.isWhitespace == true {
            text = text.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// `condition` added to the filter (⌥-click on a quick filter): (filter) AND condition.
    public static func adding(_ condition: String, to filter: String) -> String {
        let filter = self.condition(filter)
        return filter.isEmpty ? condition : "(\(filter)) AND \(condition)"
    }

    /// The filter without a `condition` that `adding` put there, however many came after it; nil when it isn't there
    /// as `adding` left it (someone typed over it).
    public static func removing(_ condition: String, from filter: String) -> String? {
        let filter = self.condition(filter)
        if filter == condition { return "" }
        if let first = filter.range(of: "(\(condition)) AND ") { return filter.replacingCharacters(in: first, with: "") }
        // (earlier) AND condition: the earlier part, as it was before.
        let tail = ") AND " + condition, tokens = SQLLexer.tokens(filter), text = Array(filter.utf16)
        var open: [Int] = []
        for token in tokens where token.kind == .symbol && token.range.count == 1 {
            if text[token.range.lowerBound] == 40 { open.append(token.range.lowerBound) }
            guard text[token.range.lowerBound] == 41, let start = open.popLast() else { continue }
            let end = token.range.lowerBound + tail.utf16.count
            guard end <= text.count, Array(text[token.range.lowerBound..<end]) == Array(tail.utf16),
                  end == text.count || text[end] == 41 else { continue }
            return String(decoding: text[..<start] + text[(start + 1)..<token.range.lowerBound] + text[end...], as: UTF16.self)
        }
        return nil
    }

    /// Search All Columns on the server, as HeidiSQL builds it: text in any column. Text and JSON columns are matched
    /// with LIKE, numbers and dates cast to text first, and binary columns only by a whole "0x…" value. Nil when no
    /// column can hold the text.
    public static func search(_ text: String, in columns: [GridColumn], noBackslashEscapes: Bool = false) -> String? {
        guard !text.isEmpty else { return nil }
        let pattern = GridCondition(GridColumn(name: ""), .contains, [text]).sql(noBackslashEscapes: noBackslashEscapes)
        let like = String(pattern.dropFirst(SQLQuote.identifier("").count))  // " LIKE '%…%'" with its ESCAPE, if any
        let parts = columns.compactMap { column -> String? in
            let name = SQLQuote.identifier(column.name)
            switch column.kind {
            case .text, .json: return name + like
            case .number, .date: return "CAST(\(name) AS CHAR)" + like
            case .binary: return CopyWriter.hexDigits(text).map { name + " = X'\($0)'" }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " OR ")
    }

    /// Search on the loaded rows: whether any value holds the text (case and accents ignored).
    public static func matches(_ text: String, _ values: [String?]) -> Bool {
        values.contains { $0?.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// Sorting by columns in order (grid-spec §4): ORDER BY on the server, or the loaded rows sorted here.
public enum GridSorting {
    /// "`name` ASC, `price` DESC"; "" for no sort.
    public static func orderBy(_ keys: [TableViewSettings.SortKey]) -> String {
        keys.map { SQLQuote.identifier($0.column) + ($0.ascending ? " ASC" : " DESC") }.joined(separator: ", ")
    }

    /// Two values as a sort sees them: numbers by value in number columns, text without case. NULL comes first, as the
    /// server sorts it ascending.
    public static func compare(_ a: String?, _ b: String?, number: Bool) -> ComparisonResult {
        guard let a, let b else { return a == nil ? (b == nil ? .orderedSame : .orderedAscending) : .orderedDescending }
        if number, let x = Decimal(string: a, locale: Locale(identifier: "en_US_POSIX")),
           let y = Decimal(string: b, locale: Locale(identifier: "en_US_POSIX")) {
            return x == y ? .orderedSame : x < y ? .orderedAscending : .orderedDescending
        }
        return a.compare(b, options: [.caseInsensitive, .numeric])
    }

    /// `rows` sorted by `keys` (columns of `columns`, values from `value`); equal rows keep their order.
    public static func sorted(_ rows: [Int], by keys: [(column: Int, ascending: Bool)], columns: [GridColumn],
                              value: (Int, Int) -> String?) -> [Int] {
        guard !keys.isEmpty else { return rows }
        return rows.enumerated().sorted { left, right in
            for key in keys {
                let order = compare(value(left.element, key.column), value(right.element, key.column),
                                    number: columns[key.column].kind == .number)
                if order != .orderedSame { return key.ascending ? order == .orderedAscending : order == .orderedDescending }
            }
            return left.offset < right.offset
        }.map(\.element)
    }
}

extension GridColumn {
    /// A value as SQL for this column: numbers bare when they read as numbers, BIT digits as b'…', a whole "0x…" in a
    /// binary column as X'…', anything else a quoted string.
    public func literal(_ value: String?, noBackslashEscapes: Bool = false) -> String {
        guard let value else { return "NULL" }
        if kind == .number, CopyWriter.isNumber(value) { return value }
        if type.hasPrefix("bit"), !value.isEmpty, value.allSatisfy({ $0 == "0" || $0 == "1" }) { return "b'\(value)'" }
        if kind == .binary, let digits = CopyWriter.hexDigits(value) { return "X'\(digits)'" }
        return SQLQuote.string(value, noBackslashEscapes: noBackslashEscapes)
    }
}

/// Find and replace in the loaded rows (grid-spec §4): text, or a regular expression, with or without case, whole words
/// only if asked.
public struct GridFind: Equatable {
    public var text: String
    public var matchCase = false
    public var regex = false
    public var wholeWords = false

    public init(_ text: String, matchCase: Bool = false, regex: Bool = false, wholeWords: Bool = false) {
        self.text = text
        self.matchCase = matchCase
        self.regex = regex
        self.wholeWords = wholeWords
    }

    /// The expression it searches with; nil for no text or a regular expression that doesn't parse.
    public var expression: NSRegularExpression? {
        guard !text.isEmpty else { return nil }
        let pattern = regex ? text : NSRegularExpression.escapedPattern(for: text)
        return try? NSRegularExpression(pattern: wholeWords ? "\\b(?:\(pattern))\\b" : pattern,
                                        options: matchCase ? [] : [.caseInsensitive])
    }

    public func matches(_ value: String?, _ expression: NSRegularExpression?) -> Bool {
        guard let value, let expression else { return false }
        return expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// `value` with every match replaced: `replacement` as it is, or as a template ($1) for a regular expression.
    public func replacing(in value: String, with replacement: String, _ expression: NSRegularExpression?) -> String {
        guard let expression else { return value }
        let template = regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        return expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: template)
    }
}
