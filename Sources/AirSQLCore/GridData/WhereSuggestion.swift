import Foundation

/// What the WHERE bar suggests at the caret as you type: columns, then an operator, then the column's values, then AND
/// or OR. The console's `SQLCompletion` works on whole statements; a condition is only ever one of these places.
public enum WhereSuggestion {
    public enum Place: Equatable {
        case names, operators, joiners, nothing
        case value(column: Int)
    }

    private static let comparisons: Set<String> = ["=", "<>", "!=", "<", ">", "<=", ">=", "<=>"]
    private static let operators = ["=", "<>", "<", ">", "<=", ">=", "LIKE", "NOT LIKE", "IN (", "NOT IN (", "IS NULL", "IS NOT NULL",
                                    "BETWEEN"]

    /// Where the caret is in `text`, and the word a suggestion replaces (UTF-16 offsets, empty between words).
    public static func place(_ text: String, caret: Int, columns: [String], noBackslashEscapes: Bool = false)
        -> (place: Place, word: Range<Int>) {
        let tokens = SQLLexer.tokens(text, noBackslashEscapes: noBackslashEscapes), units = Array(text.utf16)
        let lower = columns.map { $0.lowercased() }
        func raw(_ token: SQLToken) -> String { String(decoding: units[token.range], as: UTF16.self).lowercased() }
        func column(_ token: SQLToken?) -> Int? {
            guard let token else { return nil }
            if token.kind == .word { return lower.firstIndex(of: raw(token)) }
            return token.kind == .quotedName ? lower.firstIndex(of: String(raw(token).dropFirst().dropLast())) : nil
        }
        if tokens.contains(where: { $0.kind == .comment && $0.range.lowerBound < caret && caret <= $0.range.upperBound }) {
            return (.nothing, caret..<caret)
        }
        let code = tokens.filter { $0.kind != .comment }
        let word = code.first { token in
            guard token.range.lowerBound < caret, caret <= token.range.upperBound else { return false }
            if token.kind == .word || token.kind == .number { return true }
            return (token.kind == .string || token.kind == .quotedName) && (!token.isClosed || caret < token.range.upperBound)
        }
        let start = word?.range.lowerBound ?? caret, replaced = start..<caret
        var before = code.filter { $0.range.upperBound <= start }
        /// The column before an operator, past a NOT.
        func columnBefore(_ tokens: [SQLToken]) -> Int? {
            column(tokens.last.flatMap { raw($0) == "not" ? tokens.dropLast().last : $0 })
        }
        guard let last = before.popLast() else { return (.names, replaced) }
        switch (last.kind, raw(last)) {
        case (.symbol, let symbol) where comparisons.contains(symbol):
            return (columnBefore(before).map { .value(column: $0) } ?? .nothing, replaced)
        case (.symbol, "("), (.symbol, ","):
            // Inside IN (…): the values; a bare ( starts a condition.
            var depth = 0, list = before
            if raw(last) == "(" { list.append(last) }
            while let token = list.popLast() {
                if raw(token) == ")" { depth += 1 } else if raw(token) == "(" {
                    if depth == 0 { break }
                    depth -= 1
                }
            }
            if list.last.map(raw) == "in", let found = columnBefore(Array(list.dropLast())) { return (.value(column: found), replaced) }
            return (raw(last) == "(" ? .names : .nothing, replaced)
        case (.symbol, ")"), (.string, _), (.number, _):
            return (.joiners, replaced)
        case (.word, "and"), (.word, "or"):
            return (.names, replaced)
        case (.word, "not"):
            return (column(before.last) == nil ? .names : .operators, replaced)
        case (.word, "like"):
            return (columnBefore(before).map { .value(column: $0) } ?? .nothing, replaced)
        case (.word, "null"), (.word, "true"), (.word, "false"):
            return (.joiners, replaced)
        default:
            return (column(last) == nil ? .nothing : .operators, replaced)
        }
    }

    /// What to offer at `place` for the `word` typed so far, the best first. `values`: the column's sample, when read.
    public static func items(_ place: Place, word: String, columns: [GridColumn], values: [String?]? = nil,
                             noBackslashEscapes: Bool = false) -> [CompletionItem] {
        let typed = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "`'\""))
        func keywords(_ words: [String]) -> [CompletionItem] {
            words.filter { $0.lowercased().hasPrefix(typed) }.map { word in
                // A space to go on typing, or to bring up what comes next.
                CompletionItem(kind: .keyword, text: word.hasSuffix("(") ? word : word + " ", label: word, detail: "")
            }
        }
        switch place {
        case .nothing: return []
        case .joiners: return keywords(["AND", "OR"])
        case .operators: return keywords(operators)
        case .names:
            let names = columns.filter { $0.name.lowercased().contains(typed) || typed.isEmpty }
                .sorted { $0.name.lowercased().hasPrefix(typed) && !$1.name.lowercased().hasPrefix(typed) }
                .map { column -> CompletionItem in
                    let plain = column.name.first.map { $0.isLetter || $0 == "_" } == true
                        && column.name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
                    return CompletionItem(kind: .column, text: (plain ? column.name : SQLQuote.identifier(column.name)) + " ",
                                          label: column.name, detail: column.type)
                }
            return names + keywords(["NOT"])
        case .value(let index):
            let column = columns[index]
            let found = (values ?? []).compactMap { $0 }.filter { typed.isEmpty || $0.lowercased().contains(typed) }.map { value in
                CompletionItem(kind: .value, text: column.kind == .number ? value : SQLQuote.string(value, noBackslashEscapes: noBackslashEscapes),
                               label: value, detail: "")
            }
            return found + (column.kind == .date ? keywords(["NOW()", "CURDATE()"]) : [])
        }
    }
}
