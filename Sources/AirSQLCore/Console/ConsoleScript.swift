import Foundation

/// A place in the text to underline in red, and what to say about it on hover. UTF-16 offsets, as NSTextView's.
public struct SQLProblem: Equatable, Sendable {
    public var range: Range<Int>
    public var message: String

    public init(range: Range<Int>, message: String) {
        self.range = range
        self.message = message
    }
}

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

    /// The statement at the caret and all those after it.
    public static func statements(from caret: Int, in text: String, noBackslashEscapes: Bool) -> [SQLStatement] {
        let all = SQLSplitter.statements(in: text, noBackslashEscapes: noBackslashEscapes)
        guard let first = SQLSplitter.statement(at: caret, in: text, noBackslashEscapes: noBackslashEscapes) else { return [] }
        return all.filter { $0.range.lowerBound >= first.range.lowerBound }
    }

    /// The smallest query in brackets around the caret: a SELECT or WITH right after an opening bracket, up to its partner.
    public static func subquery(at caret: Int, in text: String, noBackslashEscapes: Bool) -> SQLStatement? {
        let utf16 = Array(text.utf16)
        let tokens = SQLLexer.tokens(text, noBackslashEscapes: noBackslashEscapes).filter { $0.kind != .comment && $0.kind != .hint }
        var open: [Int] = []
        for (index, token) in tokens.enumerated() where token.kind == .symbol && token.range.count == 1 {
            if utf16[token.range.lowerBound] == 0x28 { open.append(index) }
            guard utf16[token.range.lowerBound] == 0x29, let start = open.popLast(), start + 1 < index,
                  tokens[start].range.upperBound <= caret, caret <= token.range.lowerBound, tokens[start + 1].kind == .word else { continue }
            let first = tokens[start + 1].range
            guard ["SELECT", "WITH"].contains(String(decoding: utf16[first], as: UTF16.self).uppercased()) else { continue }
            let range = first.lowerBound..<tokens[index - 1].range.upperBound
            return SQLStatement(range: range, end: range.upperBound, sql: String(decoding: utf16[range], as: UTF16.self))
        }
        return nil
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

    /// What the text leaves open, found without a server: the opening of a quote or comment it ends inside, and brackets
    /// without a partner in their statement. At most `unclosedLimit`, for a script that's broken all the way down.
    public static func unclosed(in text: String, noBackslashEscapes: Bool) -> [SQLProblem] {
        let tokens = SQLLexer.tokens(text, noBackslashEscapes: noBackslashEscapes)
        let utf16 = Array(text.utf16)
        var problems: [SQLProblem] = []
        func add(_ token: SQLToken, length: Int = 1, _ message: String) {
            problems.append(SQLProblem(range: token.range.lowerBound..<(token.range.lowerBound + length), message: message))
        }
        var code: [SQLToken] = []
        for token in tokens {
            switch token.kind {
            case .codeStart: code.append(token)
            case .codeEnd: code.removeLast()
            case .comment, .hint: if !token.isClosed { add(token, length: 2, "This comment has no closing */") }
            case .quotedName: if !token.isClosed { add(token, "This name has no closing `") }
            default: if !token.isClosed { add(token, "This text has no closing quote") }
            }
        }
        for token in code { add(token, length: 2, "This comment has no closing */") }

        let closers: [UInt16: UInt16] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]
        func name(_ unit: UInt16) -> String { String(decoding: [unit], as: UTF16.self) }
        var next = 0
        for statement in SQLSplitter.statements(in: text, noBackslashEscapes: noBackslashEscapes) {
            var open: [SQLToken] = []
            while next < tokens.count, tokens[next].range.lowerBound < statement.range.upperBound {
                let token = tokens[next]
                next += 1
                guard token.kind == .symbol, token.range.count == 1, token.range.lowerBound >= statement.range.lowerBound
                else { continue }
                let unit = utf16[token.range.lowerBound]
                if closers[unit] != nil {
                    open.append(token)
                } else if let opener = closers.first(where: { $0.value == unit })?.key {
                    if let last = open.last, utf16[last.range.lowerBound] == opener {
                        open.removeLast()
                    } else {
                        add(token, "This \(name(unit)) has no opening \(name(opener))")
                    }
                }
            }
            for token in open {
                let unit = utf16[token.range.lowerBound]
                add(token, "This \(name(unit)) has no closing \(name(closers[unit] ?? unit))")
            }
        }
        return Array(problems.prefix(unclosedLimit))
    }

    static let unclosedLimit = 100

    /// Where an error in `statement` points, in the whole text: the token at the server's "near '…' at line N", the
    /// statement's last token for near '', or the name in an unknown column or table error. `message` is the server's
    /// text, `shown` what the underline says. Nil when the error names no place, or `statement` isn't in the text.
    public static func problem(_ message: String, shown: String, statement: SQLStatement,
                               noBackslashEscapes: Bool) -> SQLProblem? {
        guard !statement.range.isEmpty else { return nil }
        let tokens = SQLLexer.tokens(statement.sql, noBackslashEscapes: noBackslashEscapes)
        let token = nearToken(message, in: statement.sql, tokens: tokens) ?? namedToken(message, in: statement.sql, tokens: tokens)
        return token.map {
            SQLProblem(range: ($0.range.lowerBound + statement.range.lowerBound)..<($0.range.upperBound + statement.range.lowerBound),
                       message: shown)
        }
    }

    private static let nearPattern = try! NSRegularExpression(pattern: #"near '(.*)' at line ([0-9]+)\s*$"#,
                                                              options: .dotMatchesLineSeparators)
    private static let namePattern = try! NSRegularExpression(pattern: #"\b(?:Unknown column|Unknown table|Table) '([^']+)'"#)

    private static func nearToken(_ message: String, in sql: String, tokens: [SQLToken]) -> SQLToken? {
        let whole = NSRange(message.startIndex..., in: message)
        guard let match = nearPattern.firstMatch(in: message, range: whole), let near = Range(match.range(at: 1), in: message),
              let number = Range(match.range(at: 2), in: message).flatMap({ Int(message[$0]) }) else { return nil }
        let code = tokens.filter { $0.kind != .comment }
        if near.isEmpty { return code.last }
        // The near text is the rest of the statement from the token, cut to some 80 characters, on line N or after.
        let text = sql as NSString
        var from = 0
        for _ in 1..<max(number, 1) {
            let newline = text.range(of: "\n", range: NSRange(location: from, length: text.length - from))
            guard newline.location != NSNotFound else { break }
            from = NSMaxRange(newline)
        }
        var found = text.range(of: String(message[near]), range: NSRange(location: from, length: text.length - from))
        if found.location == NSNotFound { found = text.range(of: String(message[near])) }
        guard found.location != NSNotFound else { return nil }
        return code.first { $0.range.upperBound > found.location }
    }

    // shortcut: the first token with the name, which may be another table's column of that name; the server gives no
    // place for these, so a finer answer would need the query's scopes.
    private static func namedToken(_ message: String, in sql: String, tokens: [SQLToken]) -> SQLToken? {
        guard let match = namePattern.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let quoted = Range(match.range(at: 1), in: message),
              let name = message[quoted].split(separator: ".").last?.lowercased() else { return nil }
        let text = Array(sql.utf16)
        return tokens.first { token in
            guard token.kind == .word || token.kind == .quotedName else { return false }
            let word = String(decoding: text[token.range], as: UTF16.self)
            return (token.kind == .word ? word : String(word.dropFirst().dropLast())).lowercased() == name
        }
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
