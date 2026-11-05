/// One statement of a script. The console splits scripts on the client and sends statements one at a time, since
/// multi-statements stay off (plan §2.6).
public struct SQLStatement: Equatable, Sendable {
    /// The statement without the whitespace and comments around it or its delimiter, in UTF-16 offsets.
    public var range: Range<Int>
    /// Just after its delimiter, or `range.upperBound` when it has none.
    public var end: Int
    /// The text of `range`: what the server is sent.
    public var sql: String
}

/// Splits a script as the mysql client does: on `;`, or on the delimiter a DELIMITER line sets (as mysqldump writes
/// around routines and triggers). A DELIMITER line counts only where a statement may start, as the first thing on its
/// line; its argument is the next word. The delimiter is found anywhere outside strings, quoted names and comments,
/// even inside a word (END$$) and inside executable comments, whose text is code.
public enum SQLSplitter {
    public static func statements(in sql: String, noBackslashEscapes: Bool = false) -> [SQLStatement] {
        var lexer = SQLLexer(sql, noBackslashEscapes: noBackslashEscapes)
        let text = lexer.text
        var delimiter: [UInt16] = [0x3B]
        var statements: [SQLStatement] = []
        var first: Int?, last = 0

        func delimiterStarts(at i: Int) -> Bool {
            i + delimiter.count <= text.count && text[i..<(i + delimiter.count)].elementsEqual(delimiter)
        }
        /// Ends the statement under way (if it has any code) with a delimiter that ends at `end`, and carries on there.
        func finish(_ end: Int) {
            if let first {
                statements.append(SQLStatement(range: first..<last, end: end, sql: lexer.string(first..<last)))
            }
            first = nil
            lexer.move(to: end)
        }

        while true {
            lexer.skipSpace()
            let start = lexer.position
            if first == nil, let (newDelimiter, lineEnd) = delimiterLine(text, at: start) {
                if !newDelimiter.isEmpty { delimiter = newDelimiter }
                lexer.move(to: lineEnd)
                continue
            }
            if delimiterStarts(at: start) {
                finish(start + delimiter.count)
                continue
            }
            guard let token = lexer.next() else { break }
            switch token.kind {
            case .comment, .hint:
                continue
            case .string, .quotedName:
                break
            default:
                // Look for the delimiter inside the token too, up to a quote (X'…', @'…' quote what follows).
                var i = token.range.lowerBound + 1
                while i < token.range.upperBound && !Self.isQuote(text[i]) && !delimiterStarts(at: i) { i += 1 }
                if i < token.range.upperBound && delimiterStarts(at: i) {
                    if first == nil { first = token.range.lowerBound }
                    last = i
                    finish(i + delimiter.count)
                    continue
                }
            }
            if first == nil { first = token.range.lowerBound }
            last = token.range.upperBound
        }
        if let first {
            statements.append(SQLStatement(range: first..<last, end: last, sql: lexer.string(first..<last)))
        }
        return statements
    }

    /// The statement ⌘↩ runs with the caret at `caret` (a UTF-16 offset): the one the caret is in, or right after up to
    /// the end of its delimiter. Between statements, the one before while the caret is still on its line, otherwise
    /// the next one (or the last, at the end of the script).
    public static func statement(at caret: Int, in sql: String, noBackslashEscapes: Bool = false, of known: [SQLStatement]? = nil) -> SQLStatement? {
        let all = known ?? statements(in: sql, noBackslashEscapes: noBackslashEscapes), text = Array(sql.utf16)
        let caret = min(max(caret, 0), text.count)
        if let hit = all.first(where: { $0.range.lowerBound <= caret && caret <= $0.end }) { return hit }
        let before = all.last { $0.end < caret }, after = all.first { $0.range.lowerBound > caret }
        if let before, !text[before.end..<caret].contains(0x0A) { return before }
        return after ?? before
    }

    /// A DELIMITER line at `start`: the new delimiter (empty when none is given) and the end of the line. Nil unless
    /// DELIMITER and a space or tab are the first thing on the line.
    static func delimiterLine(_ text: [UInt16], at start: Int) -> (delimiter: [UInt16], lineEnd: Int)? {
        var b = start - 1
        while b >= 0 && text[b] != 0x0A && SQLLexer.isSpace(text[b]) { b -= 1 }
        let keyword = Array("DELIMITER".utf16)
        guard b < 0 || text[b] == 0x0A, start + keyword.count < text.count,
              text[start..<(start + keyword.count)].map({ (0x61...0x7A).contains($0) ? $0 - 0x20 : $0 }) == keyword,
              text[start + keyword.count] == 0x20 || text[start + keyword.count] == 0x09
        else { return nil }
        var i = start + keyword.count
        while i < text.count && (text[i] == 0x20 || text[i] == 0x09) { i += 1 }
        var j = i
        while j < text.count && !SQLLexer.isSpace(text[j]) { j += 1 }
        var lineEnd = j
        while lineEnd < text.count && text[lineEnd] != 0x0A { lineEnd += 1 }
        return (Array(text[i..<j]), lineEnd)
    }

    private static func isQuote(_ c: UInt16) -> Bool {
        c == SQLLexer.apostrophe || c == SQLLexer.doubleQuote || c == SQLLexer.backtick
    }
}
