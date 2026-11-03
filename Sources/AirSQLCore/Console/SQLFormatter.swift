/// Format SQL (plan §2.6, R15): reserved words in upper case and each main clause on a line of its own, nothing else.
/// Only the whitespace between tokens and the case of reserved words change: literals, names, comments, executable
/// comments and statements under a DELIMITER of their own (routine bodies) stay exactly as they are, and the result is
/// kept only when `SQLLexer.sameTokens` proves the server reads the same statements.
public enum SQLFormatter {
    /// `sql` formatted, or nil when formatting would change more than whitespace and case (it never should).
    public static func format(_ sql: String, noBackslashEscapes: Bool = false) -> String? {
        let text = Array(sql.utf16)
        var result: [UInt16] = [], copied = 0
        for statement in SQLSplitter.statements(in: sql, noBackslashEscapes: noBackslashEscapes) {
            result += text[copied..<statement.range.lowerBound]
            let delimiter = String(decoding: text[statement.range.upperBound..<statement.end], as: UTF16.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if delimiter.isEmpty || delimiter == ";" {
                result += Array(formatStatement(statement.sql, noBackslashEscapes: noBackslashEscapes).utf16)
            } else {
                result += text[statement.range]
            }
            copied = statement.range.upperBound
        }
        result += text[copied...]
        let formatted = String(decoding: result, as: UTF16.self)
        return SQLLexer.sameTokens(sql, formatted, noBackslashEscapes: noBackslashEscapes) ? formatted : nil
    }

    /// Words that start a clause on a new line, outside parentheses.
    static let clauses: Set<String> = ["SELECT", "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "UNION", "SET",
                                       "VALUES", "WINDOW", "RETURNING"]
    /// Words before JOIN that start the join's line instead of it.
    static let joinWords: Set<String> = ["LEFT", "RIGHT", "INNER", "CROSS", "NATURAL", "OUTER", "FULL"]

    /// One statement: whitespace between tokens becomes one space, or a line break before a main clause; whitespace
    /// that holds a line break after a -- or # comment keeps one. Where there was no space, none is added. Inside an
    /// executable comment nothing changes at all.
    static func formatStatement(_ sql: String, noBackslashEscapes: Bool) -> String {
        var lexer = SQLLexer(sql, noBackslashEscapes: noBackslashEscapes)
        let text = lexer.text
        var tokens: [(token: SQLToken, code: Bool)] = []
        while let token = lexer.next() {
            // An executable comment's own tokens, and what is inside it, are left as written.
            let inside = lexer.openCodeComments > 0 || token.kind == .codeEnd
            tokens.append((token, !inside && token.kind != .codeStart))
        }
        guard !tokens.isEmpty else { return sql }
        var out: [UInt16] = [], depth = 0, afterDot = false
        var previousEnd = tokens[0].token.range.lowerBound
        for (index, item) in tokens.enumerated() {
            let token = item.token
            let gap = text[previousEnd..<token.range.lowerBound]
            let raw = Array(text[token.range])
            let upper = lexer.upper(token.range)
            let previous = index > 0 ? tokens[index - 1] : nil
            let lineComment = previous.map { $0.token.kind == .comment && ($0.token.range.count < 2
                || text[$0.token.range.lowerBound] != 0x2F) } ?? false
            if index > 0 {
                let keep = !item.code || !(previous?.code ?? true)
                if keep || gap.isEmpty {
                    out += gap
                } else if lineComment || (token.kind == .comment && gap.contains(0x0A)) {
                    out += [0x0A]
                } else if token.kind == .word && depth == 0 && !afterDot && startsLine(upper, tokens, index, lexer) {
                    out += [0x0A]
                } else {
                    out += [0x20]
                }
            }
            if item.code && token.kind == .word && !afterDot && SQLWords.reserved.contains(upper) {
                out += Array(upper.utf16)
            } else {
                out += raw
            }
            if item.code && token.kind == .symbol {
                if raw == [0x28] { depth += 1 } else if raw == [0x29] { depth = max(0, depth - 1) }
            }
            afterDot = token.kind == .symbol && raw == [0x2E]
            previousEnd = token.range.upperBound
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// Whether the word at `index` starts a line: a main clause where it is one, or the first word of a JOIN.
    private static func startsLine(_ word: String, _ tokens: [(token: SQLToken, code: Bool)], _ index: Int,
                                   _ lexer: SQLLexer) -> Bool {
        func wordAt(_ i: Int) -> String? {
            guard i >= 0, i < tokens.count, tokens[i].token.kind == .word else { return nil }
            return lexer.upper(tokens[i].token.range)
        }
        let before = wordAt(index - 1), verb = wordAt(0)
        switch word {
        case "SELECT":
            return !["UNION", "ALL", "DISTINCT", "EXPLAIN", "DESCRIBE", "DESC", "ANALYZE"].contains(before ?? "")
        case "FROM":
            return verb != "SHOW" && !["DELETE", "LOW_PRIORITY", "QUICK", "IGNORE"].contains(before ?? "")
        case "SET":
            return ["UPDATE", "INSERT", "REPLACE"].contains(verb ?? "") && !["CHARACTER", "CHAR"].contains(before ?? "")
        case "VALUES":
            // Not VALUES(column) after = or , in ON DUPLICATE KEY UPDATE.
            guard index > 0, tokens[index - 1].token.kind == .symbol else { return true }
            let symbol = lexer.string(tokens[index - 1].token.range)
            return symbol != "=" && symbol != ","
        case "GROUP":
            return before != "WITHIN"
        case "JOIN", "STRAIGHT_JOIN":
            return !(before.map(joinWords.contains) ?? false)
        default:
            if clauses.contains(word) { return true }
            guard joinWords.contains(word) else { return false }
            let next = wordAt(index + 1)
            return (next == "JOIN" || next == "OUTER") && !(before.map(joinWords.contains) ?? false)
        }
    }
}
