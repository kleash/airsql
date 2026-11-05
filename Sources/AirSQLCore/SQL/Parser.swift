import Foundation

/// A hand-written recursive-descent parser for MySQL and MariaDB statements over `SQLLexer`. It takes any text, as the
/// editor has it mid-word: `parse` always returns a tree for each statement of `SQLSplitter`, with what it could read.
/// SELECT, INSERT, REPLACE, UPDATE, DELETE and the heads of CREATE, ALTER and DROP are read in full; the rest as far as
/// their first word. A false alarm costs more than a miss, so errors come only from grammar this reads completely, and
/// only the first of a statement. Linear in the text and safe off the main thread; it runs nothing and goes nowhere.
public struct SQLParser {
    /// Every statement of `text`, in order.
    public static func parse(_ text: String, noBackslashEscapes: Bool = false) -> [SQLParsedStatement] {
        withDeepStack {
            SQLSplitter.statements(in: text, noBackslashEscapes: noBackslashEscapes).map { read($0, noBackslashEscapes: noBackslashEscapes) }
        }
    }

    /// One statement of `SQLSplitter`.
    public static func parse(_ statement: SQLStatement, noBackslashEscapes: Bool = false) -> SQLParsedStatement {
        withDeepStack { read(statement, noBackslashEscapes: noBackslashEscapes) }
    }

    /// Runs `body`, which recurses over a tree, on a stack of its own: a dispatch queue's 512 KB holds only some 40
    /// brackets in a debug build.
    public static func withDeepStack<T>(_ body: @escaping () -> T) -> T {
        let box = Box<T>(), done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = body()
            done.signal()
        }
        thread.stackSize = 16 << 20
        thread.start()
        done.wait()
        return box.value!
    }

    private final class Box<T> { var value: T? }

    private static func read(_ statement: SQLStatement, noBackslashEscapes: Bool) -> SQLParsedStatement {
        var lexer = SQLLexer(statement.sql, noBackslashEscapes: noBackslashEscapes)
        let offset = statement.range.lowerBound
        var tokens: [Token] = [], hasCode = false, open = false
        while let token = lexer.next() {
            switch token.kind {
            case .comment, .hint: open = open || !token.isClosed
            case .codeStart, .codeEnd: hasCode = true  // what runs depends on the server's version
            default:
                let upper = token.kind == .word || token.kind == .symbol ? lexer.upper(token.range) : ""
                tokens.append(Token(kind: token.kind, range: (token.range.lowerBound + offset)..<(token.range.upperBound + offset), upper: upper,
                                    text: token.kind == .symbol ? upper : lexer.string(token.range)))
                open = open || !token.isClosed
            }
        }
        var parser = SQLParser(tokens: tokens, end: statement.range.upperBound)
        var parsed = parser.statement()
        parsed.range = statement.range
        parsed.end = statement.end
        parsed.query?.extent = statement.range.lowerBound..<max(statement.end, statement.range.upperBound)
        if hasCode || open || parser.gaveUp { parsed.shallow = true }
        parsed.errors = parsed.shallow ? [] : parser.errors
        return parsed
    }

    struct Token {
        var kind: SQLToken.Kind
        var range: Range<Int>
        /// Words and symbols in upper case; "" for the rest, so they match no keyword.
        var upper: String
        var text: String
    }

    let tokens: [Token]
    let end: Int
    var index = 0
    var errors: [SQLSyntaxError] = []
    /// Brackets and prefixes open now; past `depthLimit` the statement is left unread, as the stack is finite.
    var depth = 0
    var gaveUp = false
    static let depthLimit = 200

    private init(tokens: [Token], end: Int) {
        self.tokens = tokens
        self.end = end
    }

    // MARK: Tokens

    var current: Token { index < tokens.count ? tokens[index] : Token(kind: .symbol, range: end..<end, upper: "", text: "") }
    var atEnd: Bool { index >= tokens.count }
    func peek(_ ahead: Int = 1) -> Token {
        index + ahead < tokens.count ? tokens[index + ahead] : Token(kind: .symbol, range: end..<end, upper: "", text: "")
    }
    /// Where the token before this one ended.
    var lastEnd: Int { index > 0 ? tokens[min(index, tokens.count) - 1].range.upperBound : current.range.lowerBound }

    func at(_ word: String) -> Bool { current.upper == word }
    func at(_ words: Set<String>) -> Bool { !current.upper.isEmpty && words.contains(current.upper) }

    @discardableResult mutating func accept(_ word: String) -> Bool {
        guard at(word) else { return false }
        index += 1
        return true
    }

    /// Takes these words only if all of them come next.
    @discardableResult mutating func accept(_ first: String, _ rest: String...) -> Bool {
        guard at(first) else { return false }
        for (offset, word) in rest.enumerated() where peek(offset + 1).upper != word { return false }
        index += rest.count + 1
        return true
    }

    /// Records the first error. Past the end of the text it points at the last token, and a missing ) isn't one:
    /// `ConsoleScript.unclosed` says that already.
    mutating func fail(_ message: String) {
        guard errors.isEmpty else { return }
        let range = atEnd ? (tokens.last?.range ?? end..<end) : current.range
        errors.append(SQLSyntaxError(range: range, message: message))
    }

    @discardableResult mutating func expect(_ word: String, _ message: String? = nil) -> Bool {
        if accept(word) { return true }
        if !(word == ")" && atEnd) { fail(message ?? "Expected \(word)\(foundText)") }
        return false
    }

    /// ", found X", or nothing at the end of the text.
    var foundText: String { atEnd ? "" : ", found \(current.text)" }

    /// Skips brackets from a "(" at `index` to just past its ")".
    mutating func skipBrackets() {
        var level = 0
        while !atEnd {
            if current.kind == .symbol {
                if ["(", "{"].contains(current.upper) { level += 1 }
                if [")", "}"].contains(current.upper) { level -= 1 }
            }
            index += 1
            if level <= 0 { return }
        }
    }

    /// Goes on to `stops` at this bracket level, or the ")" that closes it, or the end.
    mutating func skip(to stops: Set<String>) {
        while !atEnd, !at(stops), !at(")") {
            if at("(") || at("{") { skipBrackets() } else { index += 1 }
        }
    }

    /// Runs `body` one level deeper, or abandons the statement when that's too deep.
    mutating func deeper<T>(_ fallback: T, _ body: (inout SQLParser) -> T) -> T {
        guard depth < Self.depthLimit, !gaveUp else {
            gaveUp = true
            index = tokens.count
            return fallback
        }
        depth += 1
        defer { depth -= 1 }
        return body(&self)
    }

    // MARK: Names

    /// Words a bare name can't be in any version this supports.
    func isName(_ token: Token) -> Bool {
        token.kind == .quotedName || (token.kind == .word && !SQLWords.reserved.contains(token.upper))
    }

    func identifier(_ token: Token) -> SQLIdentifier {
        SQLIdentifier(value: token.kind == .quotedName ? SQLQuote.unquoted(token.text) : token.text, range: token.range,
                      quoted: token.kind == .quotedName)
    }

    /// A name here, or nil with `what` as the error.
    mutating func nameIdentifier(_ what: String) -> SQLIdentifier? {
        guard isName(current) else {
            fail("Expected \(what)\(foundText)")
            return nil
        }
        defer { index += 1 }
        return identifier(current)
    }

    /// After a dot any word is a name, but `o. FROM t` is someone still typing: a keyword apart from the dot isn't.
    func followsDot(_ token: Token) -> Bool {
        isName(token) || (token.kind == .word && token.range.lowerBound == current.range.upperBound)
    }

    /// a.b.c, as far as it goes.
    mutating func dottedName(_ what: String) -> SQLName? {
        guard let first = nameIdentifier(what) else { return nil }
        var parts = [first]
        while at("."), peek().upper != "*" {
            guard followsDot(peek()) else {
                index += 1
                fail("Expected a name after the dot\(foundText)")
                break
            }
            parts.append(identifier(peek()))
            index += 2
        }
        return SQLName(parts: parts)
    }

    /// (a, b, c), from a "(" at `index`. Index parts may have a length or a direction, which are skipped.
    mutating func nameList(_ what: String) -> [SQLIdentifier] {
        var names: [SQLIdentifier] = []
        guard accept("(") else { return names }
        repeat {
            guard let name = nameIdentifier(what) else { break }
            names.append(name)
        } while accept(",")
        if !expect(")") { skip(to: []); accept(")") }
        return names
    }
}
