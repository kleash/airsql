extension SQLLexer {
    /// True when `formatted` holds the same tokens as `original`, in the same order, and splits into the same
    /// statements: the proof that the formatter changed only whitespace and keyword case (plan §2.6, R15). Only
    /// reserved words may change case (`SQLWords.reserved`: they can't be names, unless after a dot as in shop.order);
    /// names, literals, comments, executable comments and DELIMITER lines must stay exactly as they were. Comparing the
    /// statements too catches a changed delimiter that tokens alone would miss (DELIMITER ;; and DELIMITER ; ;).
    public static func sameTokens(_ original: String, _ formatted: String, noBackslashEscapes: Bool = false) -> Bool {
        func tokens(_ sql: String) -> [String] {
            var lexer = SQLLexer(sql, noBackslashEscapes: noBackslashEscapes)
            var result: [String] = [], afterDot = false
            while let token = lexer.next() {
                var text = lexer.string(token.range)
                let upper = lexer.upper(token.range)
                if token.kind == .word && !afterDot && lexer.openCodeComments == 0 && SQLWords.reserved.contains(upper) {
                    text = upper
                }
                result.append("\(token.kind) \(text)")
                afterDot = token.kind == .symbol && text == "."
            }
            return result
        }
        func statements(_ sql: String) -> [[String]] {
            SQLSplitter.statements(in: sql, noBackslashEscapes: noBackslashEscapes).map { tokens($0.sql) }
        }
        return tokens(original) == tokens(formatted) && statements(original) == statements(formatted)
    }
}
