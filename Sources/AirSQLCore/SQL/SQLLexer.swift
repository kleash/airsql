/// A token of MySQL or MariaDB SQL. `range` counts UTF-16 code units, as NSString and NSTextView do, so it can colour
/// the editor's text directly.
public struct SQLToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A name or keyword without quotes: SELECT, users, _utf8mb4, 5abc.
        case word
        /// A `quoted name`.
        case quotedName
        /// 'text', "text" (a name under ANSI_QUOTES) or N'text'.
        case string
        /// 42, 1.5, .5e3, 0x1F, X'1F', 0b101, B'101'.
        case number
        /// @name, @'name', @@session.name.
        case variable
        /// An operator or punctuation: ( ) , ; . = <=> := ->> and the like.
        case symbol
        /// -- …, # … or /* … */.
        case comment
        /// /*+ … */, an optimizer hint.
        case hint
        /// /*! or /*M! and its version digits: the server runs the comment's text as code.
        case codeStart
        /// The */ that ends such a comment.
        case codeEnd
    }

    public var kind: Kind
    public var range: Range<Int>
    /// False for a string, quoted name, comment or hint that the text ends inside.
    public var isClosed = true
}

/// MySQL's and MariaDB's lexical rules, followed closely enough that the read-only check sees the statement the server
/// sees (plan §2.6, R4). `--` starts a comment only before a space or a control character (1--1 is arithmetic); `#`
/// and `--` comments end at a line feed. `/*! … */` and `/*M! … */` hold code, whatever their version, since running
/// it is up to the server. Strings take doubled quotes and, unless NO_BACKSLASH_ESCAPES, backslash escapes. A name may
/// start with a digit (5abc, 0x1G), and right after "name." comes a name even when it looks like a number (t.1e5).
/// The whole text is lexed each time (R19): one pass over UTF-16 code units, every SQL symbol being ASCII.
public struct SQLLexer {
    let text: [UInt16]
    let backslashEscapes: Bool
    /// Where the next token is looked for.
    private(set) var position = 0
    /// Executable comments open at `position`: only inside one is */ a token of its own.
    private(set) var openCodeComments = 0
    /// The end of the last token when it was a name, and whether a "." right after it makes the next token a name.
    private var nameEnd = -1
    private var nameFollows = false

    init(_ sql: String, noBackslashEscapes: Bool = false) {
        text = Array(sql.utf16)
        backslashEscapes = !noBackslashEscapes
    }

    /// Every token of `sql`, in order; whitespace is what lies between them.
    public static func tokens(_ sql: String, noBackslashEscapes: Bool = false) -> [SQLToken] {
        var lexer = SQLLexer(sql, noBackslashEscapes: noBackslashEscapes)
        var tokens: [SQLToken] = []
        while let token = lexer.next() { tokens.append(token) }
        return tokens
    }

    /// The text of `range`.
    func string(_ range: Range<Int>) -> String { String(decoding: text[range], as: UTF16.self) }

    /// The text of `range` with ASCII letters in upper case, as MySQL matches keywords and built-in function names (so
    /// ſum stays a name of its own rather than becoming SUM).
    func upper(_ range: Range<Int>) -> String {
        String(decoding: text[range].map { (0x61...0x7A).contains($0) ? $0 - 0x20 : $0 }, as: UTF16.self)
    }

    /// Steps over whitespace, so `position` is where the next token starts.
    mutating func skipSpace() {
        while position < text.count, Self.isSpace(text[position]) { position += 1 }
    }

    /// Carries on from `offset`, as the splitter does after a delimiter.
    mutating func move(to offset: Int) {
        position = offset
        nameEnd = -1
        nameFollows = false
    }

    /// The next token, or nil at the end of the text.
    mutating func next() -> SQLToken? {
        skipSpace()
        guard position < text.count else { return nil }
        let start = position, c = text[start], c1 = at(start + 1), c2 = at(start + 2)
        let follows = nameFollows
        nameFollows = false
        var kind = SQLToken.Kind.symbol, end = start + 1, closed = true

        if follows && Self.isNameChar(c) {
            kind = .word
            end = nameRun(start)
        } else if c == Self.backtick || c == Self.apostrophe || c == Self.doubleQuote {
            kind = c == Self.backtick ? .quotedName : .string
            (end, closed) = quoted(start)
        } else if (c == 0x4E || c == 0x6E) && c1 == Self.apostrophe {  // N'national'
            kind = .string
            (end, closed) = quoted(start + 1)
        } else if (c == 0x58 || c == 0x78 || c == 0x42 || c == 0x62) && c1 == Self.apostrophe {  // X'1F', B'101'
            kind = .number
            end = start + 2
            while end < text.count && text[end] != Self.apostrophe { end += 1 }
            closed = end < text.count
            end = min(end + 1, text.count)
        } else if Self.isDigit(c) {
            (end, kind) = numberOrName(start)
        } else if c == Self.dot {
            if nameEnd == start && Self.isNameChar(c1) {
                nameFollows = true
            } else if Self.isDigit(c1) {
                kind = .number
                end = fraction(start)
            }
        } else if c == Self.at {
            kind = .variable
            (end, closed) = variable(start)
        } else if c == 0x23 || (c == Self.minus && c1 == Self.minus && (c2 <= 0x20 || c2 == 0x7F)) {  // # or "-- "
            kind = .comment
            while end < text.count && text[end] != 0x0A { end += 1 }
        } else if c == Self.slash && c1 == Self.star {
            if c2 == Self.bang || (c2 == 0x4D && at(start + 3) == Self.bang) {  // /*! or /*M!
                kind = .codeStart
                end = start + (c2 == Self.bang ? 3 : 4)
                var digits = 0
                while digits < 6 && Self.isDigit(at(end + digits)) { digits += 1 }
                if digits >= 5 { end += digits }  // the version: 5 digits, or 6 from MariaDB 10
                openCodeComments += 1
            } else {
                kind = c2 == Self.plus ? .hint : .comment
                (end, closed) = commentEnd(start + 2)
            }
        } else if c == Self.star && c1 == Self.slash && openCodeComments > 0 {
            kind = .codeEnd
            end = start + 2
            openCodeComments -= 1
        } else if Self.isNameChar(c) {
            kind = .word
            end = nameRun(start)
        } else {
            end = start + operatorLength(c, c1, c2)
        }

        nameEnd = kind == .word || kind == .quotedName ? end : -1
        position = end
        return SQLToken(kind: kind, range: start..<end, isClosed: closed)
    }

    // MARK: Pieces

    /// The code unit at `i`, or 0 past the end (0 is a control character, as the end of the text is to MySQL).
    private func at(_ i: Int) -> UInt16 { i < text.count ? text[i] : 0 }

    private func nameRun(_ start: Int) -> Int {
        var j = start
        while j < text.count && Self.isNameChar(text[j]) { j += 1 }
        return j
    }

    /// A quoted string or name opening at `open`: a doubled quote stands for itself, and in strings a backslash escapes
    /// the next character unless NO_BACKSLASH_ESCAPES is set.
    private func quoted(_ open: Int) -> (end: Int, closed: Bool) {
        let quote = text[open]
        let escapes = backslashEscapes && quote != Self.backtick
        var j = open + 1
        while j < text.count {
            if text[j] == Self.backslash && escapes {
                j += 2
            } else if text[j] == quote {
                if at(j + 1) != quote { return (j + 1, true) }
                j += 2
            } else {
                j += 1
            }
        }
        return (text.count, false)
    }

    /// The end of a /* comment whose text starts at `from`: the first */, since comments don't nest.
    private func commentEnd(_ from: Int) -> (end: Int, closed: Bool) {
        var j = from
        while j + 1 < text.count {
            if text[j] == Self.star && text[j + 1] == Self.slash { return (j + 2, true) }
            j += 1
        }
        return (text.count, false)
    }

    /// MySQL's reading of text that starts with a digit: 0x1F and 0b101 unless name characters follow, 12 and 1.5,
    /// 1e5 and 1e-5, and otherwise a name (5abc, 0x1G, 1ex), which can call a stored function.
    private func numberOrName(_ start: Int) -> (end: Int, kind: SQLToken.Kind) {
        let p = at(start + 1)
        if text[start] == 0x30 && (p == 0x78 || p == 0x62) {
            var j = start + 2
            while j < text.count && (p == 0x78 ? Self.isHexDigit(text[j]) : text[j] == 0x30 || text[j] == 0x31) { j += 1 }
            if j > start + 2 && !Self.isNameChar(at(j)) { return (j, .number) }
            return (nameRun(start), .word)
        }
        var j = start
        while Self.isDigit(at(j)) { j += 1 }
        if at(j) == 0x65 || at(j) == 0x45, let end = exponentEnd(j) { return (end, .number) }
        if Self.isNameChar(at(j)) { return (nameRun(start), .word) }
        return at(j) == Self.dot ? (fraction(j), .number) : (j, .number)
    }

    /// The end of a number's fraction, from its "." at `dot`: .5, 1., 1.5e3.
    private func fraction(_ dot: Int) -> Int {
        var j = dot + 1
        while Self.isDigit(at(j)) { j += 1 }
        if at(j) == 0x65 || at(j) == 0x45, let end = exponentEnd(j) { return end }
        return j
    }

    /// The end of an exponent whose e is at `e`, when digits follow it (after an optional sign).
    private func exponentEnd(_ e: Int) -> Int? {
        var j = e + 1
        if at(j) == Self.plus || at(j) == Self.minus { j += 1 }
        guard Self.isDigit(at(j)) else { return nil }
        while Self.isDigit(at(j)) { j += 1 }
        return j
    }

    /// @name (letters, digits, . _ $), @'name' in any quotes, or @@name and @@session.name.
    private func variable(_ start: Int) -> (end: Int, closed: Bool) {
        var j = start + 1
        if at(j) == Self.backtick || at(j) == Self.apostrophe || at(j) == Self.doubleQuote { return quoted(j) }
        if at(j) == Self.at { j += 1 }
        while j < text.count && (Self.isNameChar(text[j]) || text[j] == Self.dot) { j += 1 }
        return (j, true)
    }

    private func operatorLength(_ c: UInt16, _ c1: UInt16, _ c2: UInt16) -> Int {
        switch (c, c1) {
        case (0x3C, 0x3D): return c2 == 0x3E ? 3 : 2  // <=> <=
        case (0x2D, 0x3E): return c2 == 0x3E ? 3 : 2  // ->> ->
        case (0x3C, 0x3E), (0x3C, 0x3C), (0x3E, 0x3D), (0x3E, 0x3E), (0x21, 0x3D), (0x3A, 0x3D), (0x7C, 0x7C),
             (0x26, 0x26):
            return 2  // <> << >= >> != := || &&
        default: return 1
        }
    }

    // MARK: Characters

    static let backtick: UInt16 = 0x60, apostrophe: UInt16 = 0x27, doubleQuote: UInt16 = 0x22, backslash: UInt16 = 0x5C
    static let dot: UInt16 = 0x2E, at: UInt16 = 0x40, minus: UInt16 = 0x2D, plus: UInt16 = 0x2B, slash: UInt16 = 0x2F
    static let star: UInt16 = 0x2A, bang: UInt16 = 0x21

    /// MySQL's whitespace: space, tab, line feed, vertical tab, form feed, carriage return.
    static func isSpace(_ c: UInt16) -> Bool { c == 0x20 || (0x09...0x0D).contains(c) }
    static func isDigit(_ c: UInt16) -> Bool { (0x30...0x39).contains(c) }
    static func isHexDigit(_ c: UInt16) -> Bool { isDigit(c) || (0x41...0x46).contains(c) || (0x61...0x66).contains(c) }
    /// Letters, digits, _ and $, and anything beyond ASCII (MySQL reads every multibyte character as part of a name).
    public static func isNameChar(_ c: UInt16) -> Bool {
        c >= 0x80 || c == 0x5F || c == 0x24 || isDigit(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c)
    }
}
