import Foundation

/// The console's view of its text (plan §2.6): which statements a run sends, the line a statement starts on, where an
/// error points, and the name a result tab takes from the comment above its query. Offsets are UTF-16, as NSTextView's.
public enum ConsoleScript {
    /// What a run sends: the statements of `selection` when it holds any code (offsets in the whole text), else every
    /// statement (`all`), else the one at the caret.
    public static func statements(in text: String, selection: Range<Int>?, caret: Int, all: Bool,
                                  noBackslashEscapes: Bool) -> [SQLStatement] {
        if let selection, !selection.isEmpty {
            let utf16 = Array(text.utf16)
            let lower = min(selection.lowerBound, utf16.count), upper = min(selection.upperBound, utf16.count)
            let part = String(decoding: utf16[lower..<upper], as: UTF16.self)
            return SQLSplitter.statements(in: part, noBackslashEscapes: noBackslashEscapes).map { statement in
                SQLStatement(range: (statement.range.lowerBound + lower)..<(statement.range.upperBound + lower),
                             end: statement.end + lower, sql: statement.sql)
            }
        }
        if all { return SQLSplitter.statements(in: text, noBackslashEscapes: noBackslashEscapes) }
        return SQLSplitter.statement(at: caret, in: text, noBackslashEscapes: noBackslashEscapes).map { [$0] } ?? []
    }

    /// The line (from 1) that the UTF-16 offset is on.
    public static func line(of offset: Int, in text: String) -> Int {
        var line = 1
        for (index, unit) in text.utf16.enumerated() {
            if index >= offset { break }
            if unit == 0x0A { line += 1 }
        }
        return line
    }

    /// The line of the whole text that an error in `statement` points to: the server says "… at line 3" counting from
    /// the statement's first line (the tag AirSQL puts in front of it adds no line). Nil when it names no line.
    public static func errorLine(_ message: String, statement: SQLStatement, in text: String) -> Int? {
        guard let match = message.range(of: #"at line ([0-9]+)\s*$"#, options: .regularExpression),
              let number = Int(message[match].filter(\.isNumber)), number >= 1 else { return nil }
        return line(of: statement.range.lowerBound, in: text) + number - 1
    }

    /// The comment right above `statement`, after the statement before it (which ends at `after`), as a result tab's
    /// name: "-- Top customers by paid orders" gives "Top customers by paid orders". Its first line, at most 60
    /// characters; nil when there is no comment there.
    public static func title(of statement: SQLStatement, in text: String, after: Int, noBackslashEscapes: Bool) -> String? {
        let utf16 = Array(text.utf16)
        let lower = max(0, min(after, statement.range.lowerBound)), upper = min(statement.range.lowerBound, utf16.count)
        guard lower < upper else { return nil }
        let gap = String(decoding: utf16[lower..<upper], as: UTF16.self)
        // The last comment, after anything in the gap that isn't one (a DELIMITER line, say), on a line of its own: not
        // the one at the end of the statement before ("SELECT 1; -- one").
        var comment: SQLToken?
        let tokens = SQLLexer.tokens(gap, noBackslashEscapes: noBackslashEscapes)
        for token in tokens { comment = token.kind == .comment ? token : nil }
        guard let comment else { return nil }
        var start = lower + comment.range.lowerBound - 1
        while start >= 0, utf16[start] == 0x20 || utf16[start] == 0x09 { start -= 1 }
        guard start < 0 || utf16[start] == 0x0A || utf16[start] == 0x0D else { return nil }
        var body = String(decoding: Array(gap.utf16)[comment.range], as: UTF16.self)
        if body.hasPrefix("--") { body.removeFirst(2) } else if body.hasPrefix("#") { body.removeFirst() } else {
            body = String(body.dropFirst(2))
            if body.hasSuffix("*/") { body.removeLast(2) }
        }
        let first = body.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*-#"))) }
            .first { !$0.isEmpty }
        guard let first else { return nil }
        return first.count > 60 ? String(first.prefix(59)) + "…" : first
    }
}
