import Foundation

/// Paste into `IN (…)`: several copied values (a column or row of a grid, Excel, a text file) become a SQL list. Every
/// value is quoted, since MySQL converts '7' for a number column and keeps its index while a bare number against a text
/// column doesn't; numbers stay bare only when the schema cache says the column on the left is a number.
public enum SQLInPaste {
    /// What to write instead of `clipboard` when it is pasted over `selection` of `text`; nil: paste it as it is, because
    /// the place isn't the brackets of an IN, or the clipboard isn't several values.
    public static func edit(pasting clipboard: String, into text: String, selection: Range<Int>, snapshot: SchemaSnapshot? = nil,
                            database: String? = nil, noBackslashEscapes: Bool = false) -> (range: Range<Int>, text: String)? {
        let tokens = SQLLexer.tokens(text, noBackslashEscapes: noBackslashEscapes)
        let units = Array(text.utf16)
        guard let brackets = bracket(tokens, units, selection) else { return nil }
        let code = tokens.indices.filter { isCode(tokens[$0]) }
        // A subquery goes in as the SQL it is, whichever side of the paste it is on.
        if let first = code.first(where: { $0 > brackets.open }), first != brackets.close,
           startsQuery(String(decoding: units[tokens[first].range], as: UTF16.self)) { return nil }
        let numeric = leftIsNumeric(tokens, units, code, brackets.open, text, selection.lowerBound, snapshot, database, noBackslashEscapes)
        guard let list = list(clipboard, numeric: numeric, noBackslashEscapes: noBackslashEscapes) else { return nil }

        var range = selection, written = list
        let inside = (brackets.open + 1)..<(brackets.close ?? tokens.count)
        if let before = tokens[inside].lastIndex(where: { isCode($0) && $0.range.upperBound <= selection.lowerBound }) {
            if units[tokens[before].range.lowerBound] != comma {
                // Right after the value (bar spaces), not after a comment that may run to the end of its line.
                if tokens[inside].last(where: { $0.range.upperBound <= selection.lowerBound }) == tokens[before] {
                    range = tokens[before].range.upperBound..<selection.upperBound
                }
                written = ", " + written
            } else if tokens[before].range.upperBound == selection.lowerBound {
                written = " " + written
            }
        }
        // An unclosed bracket's end isn't known, so what follows may not belong to the list.
        if brackets.close != nil, let after = tokens[inside].first(where: { isCode($0) && $0.range.lowerBound >= selection.upperBound }),
           units[after.range.lowerBound] != comma {
            written += after.range.lowerBound == selection.upperBound ? ", " : ","
        }
        return (range, written)
    }

    /// The clipboard as the text of a list, nil when it holds fewer than two values.
    static func list(_ clipboard: String, numeric: Bool, noBackslashEscapes: Bool) -> String? {
        let trimmed = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = SQLLexer.tokens(trimmed, noBackslashEscapes: noBackslashEscapes), units = Array(trimmed.utf16)
        func text(_ range: Range<Int>) -> String { String(decoding: units[range], as: UTF16.self) }
        // A column of single words may well start with Table or Values: a query has more on one of its lines.
        if let first = tokens.first, first.kind == .word, startsQuery(text(first.range)),
           trimmed.split(whereSeparator: \.isNewline).contains(where: { $0.contains { $0.isWhitespace } }) { return nil }
        var values: [String]
        if let items = listItems(tokens, units), items.count > 1 {
            // Written as a list already, on one line or several: it stays. Plain numbers still go through the rule above.
            if items.contains(where: { $0.kind == .string }) { return text(0..<items[items.count - 1].range.upperBound) }
            values = items.map { text($0.range) }
        } else if trimmed.rangeOfCharacter(from: separators) != nil {
            // A comma inside a cell or a line is the value's own (12 High St, Leeds), but for one that ends the line.
            values = trimmed.components(separatedBy: separators).map { $0.trimmingCharacters(in: .whitespaces) }
                .map { $0.hasSuffix(",") ? String($0.dropLast()) : $0 }
        } else if tokens.allSatisfy(\.isClosed) {
            // CSV: a comma in quotes is the value's own.
            var start = 0
            values = []
            for token in tokens where token.kind == .symbol && units[token.range.lowerBound] == comma {
                values.append(text(start..<token.range.lowerBound))
                start = token.range.upperBound
            }
            values.append(text(start..<units.count))
        } else {
            values = trimmed.components(separatedBy: ",")
        }
        values = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard values.count > 1 else { return nil }
        return values.map { value in
            if numeric && CopyWriter.isNumber(value) { return value }
            return isQuoted(value, noBackslashEscapes) ? value : SQLQuote.string(value, noBackslashEscapes: noBackslashEscapes)
        }.joined(separator: ", ")
    }

    private static let separators = CharacterSet(charactersIn: "\r\n\t")

    /// `tokens` as strings and numbers between commas (one may end them), or nil.
    private static func listItems(_ tokens: [SQLToken], _ units: [UInt16]) -> [SQLToken]? {
        var items: [SQLToken] = []
        for (index, token) in tokens.enumerated() {
            if index % 2 == 0 {
                guard token.kind == .string || token.kind == .number, token.isClosed else { return nil }
                items.append(token)
            } else if units[token.range.lowerBound] != comma {
                return nil
            }
        }
        return items
    }

    private static func isQuoted(_ value: String, _ noBackslashEscapes: Bool) -> Bool {
        let tokens = SQLLexer.tokens(value, noBackslashEscapes: noBackslashEscapes)
        return tokens.count == 1 && tokens[0].kind == .string && tokens[0].isClosed
    }

    private static func startsQuery(_ word: String) -> Bool { ["SELECT", "WITH", "VALUES", "TABLE"].contains(word.uppercased()) }

    private static let comma = UInt16(UInt8(ascii: ","))

    private static func isCode(_ token: SQLToken) -> Bool { token.kind != .comment && token.kind != .hint }

    /// The tokens (by index) of the IN brackets that are the innermost around both ends of `selection`. An unclosed
    /// bracket (no `close`) lasts to the end of its statement.
    private static func bracket(_ tokens: [SQLToken], _ units: [UInt16], _ selection: Range<Int>) -> (open: Int, close: Int?)? {
        var stack: [Int] = []
        var pairs: [(open: Int, close: Int?, end: Int)] = []
        for (index, token) in tokens.enumerated() {
            // Inside a string, a comment or any other token is no place for a list; a line comment runs up to its line's end.
            func holds(_ place: Int) -> Bool {
                token.range.lowerBound < place && (place < token.range.upperBound || !token.isClosed
                    || (token.kind == .comment && place == token.range.upperBound && units[token.range.lowerBound] != 0x2F))
            }
            if holds(selection.lowerBound) || holds(selection.upperBound) { return nil }
            guard token.kind == .symbol, token.range.count == 1 else { continue }
            switch units[token.range.lowerBound] {
            case 0x28:
                stack.append(pairs.count)
                pairs.append((index, nil, units.count))
            case 0x29:
                if let open = stack.popLast() { (pairs[open].close, pairs[open].end) = (index, token.range.lowerBound) }
            case 0x3B:
                for open in stack { pairs[open].end = token.range.lowerBound }
                stack = []
            default: break
            }
        }
        func around(_ place: Int) -> Int? { pairs.last { tokens[$0.open].range.upperBound <= place && place <= $0.end }?.open }
        guard let open = around(selection.lowerBound), open == around(selection.upperBound),
              let word = tokens[..<open].last(where: isCode), word.kind == .word,
              String(decoding: units[word.range], as: UTF16.self).uppercased() == "IN" else { return nil }
        return (open, pairs.first { $0.open == open }?.close)
    }

    /// Whether the name left of the IN at `open` is a number column in every table of the statement that has it.
    private static func leftIsNumeric(_ tokens: [SQLToken], _ units: [UInt16], _ code: [Int], _ open: Int, _ text: String, _ caret: Int,
                                      _ snapshot: SchemaSnapshot?, _ database: String?, _ noBackslashEscapes: Bool) -> Bool {
        guard let snapshot, let bracketAt = code.firstIndex(of: open) else { return false }
        func raw(_ place: Int) -> String? {
            place >= 0 ? String(decoding: units[tokens[code[place]].range], as: UTF16.self) : nil
        }
        var name = bracketAt - 2  // the IN is right before the bracket
        if raw(name)?.uppercased() == "NOT" { name -= 1 }
        guard name >= 0, [.word, .quotedName].contains(tokens[code[name]].kind), let column = raw(name).map(SQLQuote.unquoted) else { return false }
        let qualifier = raw(name - 1) == "." ? raw(name - 2).map(SQLQuote.unquoted) : nil
        guard let statement = SQLSplitter.statement(at: caret, in: text, noBackslashEscapes: noBackslashEscapes) else { return false }
        let analysis = SQLAnalysis(statement.sql, snapshot: snapshot, database: database, noBackslashEscapes: noBackslashEscapes)
        let found = (analysis.scope(at: caret - statement.range.lowerBound)?.visibleSources ?? [])
            .filter { source in qualifier.map { $0.caseInsensitiveCompare(source.name) == .orderedSame } ?? true }
            .compactMap { $0.table?.column(column) }
        return !found.isEmpty && found.allSatisfy { ColumnTypes.type($0.dataType)?.numeric ?? false }
    }
}
