/// What a console statement is, for the safety settings' prompts (plan §2.10): whether it may change anything, and the
/// kinds that always ask first (an UPDATE or DELETE without WHERE, DROP, TRUNCATE) with the object they touch.
public enum StatementCheck {
    /// A statement that asks first, whatever the connection.
    public struct Risk: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// UPDATE or DELETE without a WHERE of its own: every row of the table.
            case unboundedWrite
            case drop
            case truncate
        }

        public var kind: Kind
        /// UPDATE, DELETE, DROP or TRUNCATE.
        public var verb: String
        /// What is dropped or emptied: "table", "database", "view"…; "table" for the writes.
        public var objectType: String
        /// The object as written ("shop.orders"; "a, b" for several): what a typed confirmation asks for.
        public var object: String
    }

    /// Statements that change nothing on the server but the session: they never ask, even where every write asks.
    static let sessionVerbs: Set<String> = ["USE", "BEGIN", "START", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE", "HELP"]

    /// Whether the statement may change data, structure or the server's settings: anything but a read (as the
    /// read-only check decides, so it errs towards yes), USE, the transaction statements, and SET of the session's own
    /// variables.
    public static func writes(_ sql: String, noBackslashEscapes: Bool) -> Bool {
        if ReadOnlyClassifier.classify(sql, noBackslashEscapes: noBackslashEscapes) == .readOnly { return false }
        let words = codeWords(sql, noBackslashEscapes: noBackslashEscapes)
        guard let verb = words.first?.text else { return false }
        if sessionVerbs.contains(verb) { return false }
        if verb == "SET" {
            let global: Set<String> = ["GLOBAL", "PERSIST", "PERSIST_ONLY", "PASSWORD", "DEFAULT"]
            return words.contains { global.contains($0.text) || $0.text.hasPrefix("@@GLOBAL.") || $0.text.hasPrefix("@@PERSIST") }
        }
        return true
    }

    /// The prompt-worthy kind of the statement, if it is one.
    public static func risk(_ sql: String, noBackslashEscapes: Bool) -> Risk? {
        var words = codeWords(sql, noBackslashEscapes: noBackslashEscapes)
        // WITH … UPDATE / DELETE: what follows the common table expressions.
        if words.first?.text == "WITH", let main = words.firstIndex(where: {
            $0.depth == 0 && ["SELECT", "UPDATE", "DELETE", "INSERT", "REPLACE"].contains($0.text)
        }) {
            words = Array(words[main...])
        }
        guard let verb = words.first?.text else { return nil }
        let rest = Array(words.dropFirst())
        switch verb {
        case "UPDATE", "DELETE":
            guard !rest.contains(where: { $0.depth == 0 && $0.text == "WHERE" }) else { return nil }
            let skip: Set<String> = ["LOW_PRIORITY", "QUICK", "IGNORE"]
            var start = rest.drop { skip.contains($0.text) }
            if verb == "DELETE", let from = start.firstIndex(where: { $0.text == "FROM" && $0.depth == 0 }),
               start.first?.text == "FROM" {
                start = start[(from + 1)...]
            }
            return Risk(kind: .unboundedWrite, verb: verb, objectType: "table", object: name(Array(start)))
        case "DROP":
            let skip: Set<String> = ["TEMPORARY", "ONLINE", "OFFLINE"]
            let afterSkip = rest.drop { skip.contains($0.text) }
            guard let type = afterSkip.first else { return nil }
            var names = Array(afterSkip.dropFirst())
            if names.count >= 2, names[0].text == "IF", names[1].text == "EXISTS" { names.removeFirst(2) }
            return Risk(kind: .drop, verb: verb, objectType: type.text.lowercased(), object: list(names))
        case "TRUNCATE":
            var names = rest
            if names.first?.text == "TABLE" { names.removeFirst() }
            return Risk(kind: .truncate, verb: verb, objectType: "table", object: name(names))
        default:
            return nil
        }
    }

    /// A word or name the server reads as code (comments left out, executable comments' text kept), with its
    /// parenthesis depth. `text` is upper case for unquoted words and variables; `raw` is as written.
    struct Word {
        var text: String
        var raw: String
        var kind: SQLToken.Kind
        var depth: Int
    }

    static func codeWords(_ sql: String, noBackslashEscapes: Bool) -> [Word] {
        var lexer = SQLLexer(sql, noBackslashEscapes: noBackslashEscapes)
        var words: [Word] = [], depth = 0
        while let token = lexer.next() {
            switch token.kind {
            case .comment, .hint, .codeStart, .codeEnd:
                continue
            case .symbol:
                let raw = lexer.string(token.range)
                if raw == "(" { depth += 1 } else if raw == ")" { depth = max(0, depth - 1) }
                words.append(Word(text: raw, raw: raw, kind: .symbol, depth: depth))
            default:
                let raw = lexer.string(token.range)
                let upper = token.kind == .word || token.kind == .variable
                words.append(Word(text: upper ? lexer.upper(token.range) : raw, raw: raw, kind: token.kind,
                                  depth: depth))
            }
        }
        return words
    }

    /// The (possibly qualified) name the words start with: shop.orders, `my table`.
    private static func name(_ words: [Word]) -> String {
        var result = "", expectName = true
        for word in words {
            if expectName, word.kind == .word || word.kind == .quotedName {
                result += word.raw
                expectName = false
            } else if !expectName, word.raw == "." {
                result += "."
                expectName = true
            } else {
                break
            }
        }
        return result
    }

    /// Names separated by commas, up to anything else (ON, CASCADE, the end).
    private static func list(_ words: [Word]) -> String {
        var names: [String] = [], rest = words[...]
        while true {
            let first = name(Array(rest))
            guard !first.isEmpty else { break }
            names.append(first)
            rest = rest.drop { $0.raw != "," && $0.raw != ";" }
            guard rest.first?.raw == "," else { break }
            rest = rest.dropFirst()
        }
        return names.joined(separator: ", ")
    }
}

extension StatementCheck {
    /// The database a USE statement makes current, its name without quotes; nil for any other statement.
    public static func usedDatabase(_ sql: String, noBackslashEscapes: Bool = false) -> String? {
        let words = codeWords(sql, noBackslashEscapes: noBackslashEscapes)
        guard words.count >= 2, words[0].text == "USE" else { return nil }
        let name = words[1]
        guard name.kind == .quotedName else { return name.kind == .word ? name.raw : nil }
        return SQLQuote.unquoted(name.raw)
    }
}

extension SQLStatement {
    /// A statement that isn't in the console's text (Commit, Rollback, the transaction mode): it has no range.
    public init(sql: String) {
        self.init(range: 0..<0, end: 0, sql: sql)
    }
}
