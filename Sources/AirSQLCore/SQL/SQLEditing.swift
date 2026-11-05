import Foundation

/// What the editor's SQL-aware commands change, as plain functions of the text. Offsets are UTF-16 code units.
public enum SQLEditing {
    /// `range` of `text` on one line where that keeps its meaning: a line break ending a `--` comment, or inside a string
    /// or a comment, stays. Spaces around a break become one space, none next to a bracket or before a comma.
    public static func joined(_ text: String, _ range: Range<Int>, noBackslashEscapes: Bool = false) -> String {
        let units = Array(text.utf16)
        let tokens = SQLLexer.tokens(text, noBackslashEscapes: noBackslashEscapes)
        func keeps(_ place: Int) -> Bool {
            tokens.contains { token in
                (token.range.lowerBound < place && place < token.range.upperBound)
                    || (token.kind == .comment && token.range.upperBound == place && units[token.range.lowerBound] != 0x2F)
            }
        }
        func isBlank(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0D }
        var result: [UInt16] = [], index = range.lowerBound
        while index < range.upperBound {
            guard units[index] == 0x0A, !keeps(index) else {
                result.append(units[index])
                index += 1
                continue
            }
            while let last = result.last, isBlank(last), result.count > 0 { result.removeLast() }
            index += 1
            // Empty lines in between go too.
            while index < range.upperBound, isBlank(units[index]) || units[index] == 0x0A { index += 1 }
            if index < range.upperBound, !result.isEmpty, result.last != 0x28, units[index] != 0x29, units[index] != 0x2C { result.append(0x20) }
        }
        return String(decoding: result, as: UTF16.self)
    }

    /// The next larger piece of syntax around `selection`: a word or string (first what's in its quotes), a dotted name,
    /// an item of a comma list or a condition, a clause, what's in a pair of brackets, the brackets too, the statement, its delimiter,
    /// then the whole text. Nil when it's all selected.
    public static func grown(_ selection: Range<Int>, in text: String, noBackslashEscapes: Bool = false) -> Range<Int>? {
        let units = Array(text.utf16)
        let tokens = SQLLexer.tokens(text, noBackslashEscapes: noBackslashEscapes)
        var pieces: [Range<Int>] = [0..<units.count]
        for statement in SQLSplitter.statements(in: text, noBackslashEscapes: noBackslashEscapes) {
            pieces += [statement.range, statement.range.lowerBound..<statement.end]
        }
        /// A level of brackets: where its contents, current clause and current item start, and the end of the last token.
        struct Level {
            var open: Int?
            var first: Int?, clause: Int?, item: Int?
            var last = 0
        }
        var levels = [Level(open: nil)]
        func endItem() {
            if let item = levels[levels.count - 1].item { pieces.append(item..<levels[levels.count - 1].last) }
            levels[levels.count - 1].item = nil
        }
        func endClause() {
            endItem()
            if let clause = levels[levels.count - 1].clause { pieces.append(clause..<levels[levels.count - 1].last) }
            levels[levels.count - 1].clause = nil
        }
        func note(_ range: Range<Int>) {
            let top = levels.count - 1
            if levels[top].first == nil { levels[top].first = range.lowerBound }
            if levels[top].clause == nil { levels[top].clause = range.lowerBound }
            if levels[top].item == nil { levels[top].item = range.lowerBound }
            levels[top].last = range.upperBound
        }
        var dotted: Int?  // where the dotted name under way starts
        for (index, token) in tokens.enumerated() where token.kind != .comment && token.kind != .hint {
            pieces.append(token.range)
            if token.kind == .string, token.isClosed, token.range.count >= 2 {
                let quote = units[token.range.lowerBound] == 0x27 || units[token.range.lowerBound] == 0x22 ? 1 : 2  // N'…'
                pieces.append((token.range.lowerBound + quote)..<(token.range.upperBound - 1))
            }
            let isName = token.kind == .word || token.kind == .quotedName
            let isDot = token.kind == .symbol && units[token.range.lowerBound] == SQLLexer.dot
            if isName || isDot, index > 0, tokens[index - 1].range.upperBound == token.range.lowerBound, let start = dotted {
                pieces.append(start..<token.range.upperBound)
            } else {
                dotted = isName ? token.range.lowerBound : nil
            }
            let unit = token.range.count == 1 && token.kind == .symbol ? units[token.range.lowerBound] : 0
            switch unit {
            case 0x28:
                note(token.range)
                levels.append(Level(open: token.range.lowerBound))
            case 0x29 where levels.count > 1:
                endClause()
                let level = levels.removeLast()
                if let first = level.first { pieces.append(first..<level.last) }
                if let open = level.open { pieces.append(open..<token.range.upperBound) }
                note(token.range)
            case 0x2C: endItem()
            case 0x3B:
                while levels.count > 1 { endClause(); levels.removeLast() }
                endClause()
            default:
                let word = token.kind == .word ? String(decoding: units[token.range], as: UTF16.self).uppercased() : ""
                if clauseWords.contains(word) {
                    endClause()
                    note(token.range)
                    levels[levels.count - 1].item = nil  // its first item starts after the word
                } else if word == "AND" || word == "OR" {
                    endItem()
                    levels[levels.count - 1].last = token.range.upperBound
                } else {
                    note(token.range)
                }
            }
        }
        while levels.count > 1 { endClause(); levels.removeLast() }
        endClause()
        return pieces.filter { $0.lowerBound <= selection.lowerBound && selection.upperBound <= $0.upperBound && $0 != selection }
            .min { $0.count < $1.count }
    }

    /// Words that start a clause of a statement.
    private static let clauseWords: Set<String> = ["SELECT", "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "SET", "VALUES", "UNION",
                                                   "JOIN", "LEFT", "RIGHT", "INNER", "CROSS", "ON", "RETURNING"]

    /// Complete Statement: what closes the statement at `caret`: its open brackets and a `;`, if it has none, written at
    /// its end; the caret goes on a new line after it, which is `caret`.
    public static func completed(_ text: String, caret: Int, noBackslashEscapes: Bool = false)
        -> (range: Range<Int>, text: String, caret: Int)? {
        guard let statement = SQLSplitter.statement(at: caret, in: text, noBackslashEscapes: noBackslashEscapes) else { return nil }
        let open = ConsoleScript.unclosed(in: statement.sql, noBackslashEscapes: noBackslashEscapes)
        let units = Array(statement.sql.utf16)
        var closers = ""
        for problem in open.reversed() {
            switch units[problem.range.lowerBound] {
            case 0x28: closers += ")"
            case 0x5B: closers += "]"
            case 0x7B: closers += "}"
            default: return nil  // a string or comment the text leaves open: `)` would land inside it
            }
        }
        let place = statement.range.upperBound
        let added = closers + (statement.end == statement.range.upperBound ? ";" : "")
        return (place..<place, added, statement.end + (added as NSString).length)
    }
}
