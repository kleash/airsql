/// Decides whether a statement can only read (plan §2.8, R4): what an agent's query may be, and what the agent gate lets
/// through without asking. It errs towards refusing. The agent session's READ ONLY transaction, its time limit and the
/// watchdog stay behind it, and a read-only database user is still the hard guarantee.
public enum ReadOnlyClassifier {
    public enum Verdict: Equatable, Sendable {
        case readOnly
        /// Refused, with the reason in plain words.
        case refused(String)
    }

    /// Accepts one statement (a trailing ; is fine): SELECT; WITH … SELECT; SHOW; DESCRIBE and EXPLAIN, but not EXPLAIN
    /// ANALYZE or the plan of a write; and the schema session's `SET SESSION information_schema_stats_expiry = 0`.
    /// Refuses, wherever they are: INTO, locking clauses, optimizer hints, temporary tables, := and sequences, and calls
    /// to anything but `SQLWords.readOnlyFunctions`. Executable comments count as code, whatever their version.
    ///
    /// `noBackslashEscapes`: the session's sql_mode (`DBConnection.noBackslashEscapes`), as for `SQLQuote.string`. It
    /// decides where a string with a backslash before a quote ends ('it\'s'), so it must be the mode of the session
    /// that runs the statement.
    public static func classify(_ sql: String, noBackslashEscapes: Bool) -> Verdict {
        do {
            try check(sql, noBackslashEscapes: noBackslashEscapes)
            return .readOnly
        } catch let refusal as Refusal {
            return .refused(refusal.reason)
        } catch {
            return .refused("\(error)")
        }
    }

    private struct Refusal: Error {
        var reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// A token the server reads as code: `text` is upper case for words, `raw` as written.
    private struct Code {
        var kind: SQLToken.Kind, text: String, raw: String
        func isWord(_ word: String) -> Bool { kind == .word && text == word }
        func isSymbol(_ symbol: String) -> Bool { kind == .symbol && text == symbol }
        /// The name for a message, cut short.
        var name: String { raw.count > 64 ? String(raw.prefix(64)) + "…" : raw }
    }

    private static func check(_ sql: String, noBackslashEscapes: Bool) throws {
        var lexer = SQLLexer(sql, noBackslashEscapes: noBackslashEscapes)
        var tokens: [SQLToken] = []
        while let token = lexer.next() { tokens.append(token) }
        guard !lexer.text.contains(0) else { throw Refusal("It contains a NUL character") }
        // Under ANSI_QUOTES, which MySQL doesn't report to clients, "text" is a name, where a backslash escapes nothing:
        // with one inside, the server could end it elsewhere and run what this check read as a string.
        guard !tokens.contains(where: { [.string, .variable].contains($0.kind) && doubleQuotedWithBackslash($0, lexer) })
        else {
            throw Refusal("Double-quoted text with a backslash in it is a name under ANSI_QUOTES, where the backslash "
                + "escapes nothing; use single quotes")
        }
        guard tokens.allSatisfy(\.isClosed), lexer.openCodeComments == 0 else {
            throw Refusal("A string, quoted name or comment in it isn't closed")
        }
        var code = tokens.filter { ![.comment, .codeStart, .codeEnd].contains($0.kind) }.map { token -> Code in
            let raw = lexer.string(token.range)
            return Code(kind: token.kind, text: token.kind == .word ? lexer.upper(token.range) : raw, raw: raw)
        }
        while code.last?.isSymbol(";") == true { code.removeLast() }
        guard !code.isEmpty else { throw Refusal("There's no statement in it") }
        guard !code.contains(where: { $0.isSymbol(";") }) else {
            throw Refusal("It holds more than one statement; send one at a time")
        }
        guard !code.contains(where: { $0.kind == .hint }) else {
            throw Refusal("Optimizer hints (/*+ … */) can lift the server's limits, such as MAX_EXECUTION_TIME")
        }
        // The schema session asks MySQL 8 for fresh table statistics before reading them (P0-7).
        if code.map(\.text) == ["SET", "SESSION", "INFORMATION_SCHEMA_STATS_EXPIRY", "=", "0"] { return }
        try checkStatement(code)
        try checkClauses(code)
    }

    private static func doubleQuotedWithBackslash(_ token: SQLToken, _ lexer: SQLLexer) -> Bool {
        let text = lexer.text[token.range]
        return text.dropFirst(text.first == SQLLexer.at ? 1 : 0).first == SQLLexer.doubleQuote
            && text.contains(SQLLexer.backslash)
    }

    /// SELECT, WITH … SELECT, SHOW, DESCRIBE and EXPLAIN.
    private static func checkStatement(_ code: [Code]) throws {
        let first = code[0]
        switch first.kind == .word || first.kind == .symbol ? first.text : "" {
        case "SELECT", "WITH", "(": try checkQuery(code, from: 0)
        case "SHOW": break
        case "DESCRIBE", "DESC", "EXPLAIN": try checkExplain(code, from: 1)
        default:
            throw Refusal("\(first.kind == .word ? first.text : "This") isn't a read-only statement; only SELECT, WITH … "
                + "SELECT, SHOW, DESCRIBE and EXPLAIN are")
        }
    }

    /// A query: SELECT, or WITH's list followed by SELECT, either of them inside parentheses.
    private static func checkQuery(_ code: [Code], from start: Int) throws {
        var k = start
        while k < code.count && code[k].isSymbol("(") { k += 1 }
        if k < code.count && code[k].isWord("WITH") {
            k = try commonTableExpressions(code, from: k + 1).end
            while k < code.count && code[k].isSymbol("(") { k += 1 }
            guard k < code.count else { throw Refusal("WITH needs a SELECT after its list") }
            guard code[k].isWord("SELECT") else {
                throw Refusal("Only WITH … SELECT is read-only, not WITH … \(code[k].kind == .word ? code[k].text : code[k].name)")
            }
        } else if !(k < code.count && code[k].isWord("SELECT")) {
            throw Refusal("Only a SELECT can stand in parentheses here")
        }
    }

    /// The end of WITH's list (`[RECURSIVE] name [(columns)] AS (query), …`), which starts at `start`, and where the
    /// names are.
    private static func commonTableExpressions(_ code: [Code], from start: Int) throws -> (end: Int, names: [Int]) {
        let unreadable = Refusal("Its WITH list isn't in a form this check can read")
        var k = start, names: [Int] = []
        if k < code.count && code[k].isWord("RECURSIVE") { k += 1 }
        while true {
            guard k < code.count && (code[k].kind == .word || code[k].kind == .quotedName) else { throw unreadable }
            names.append(k)
            k += 1
            if k < code.count && code[k].isSymbol("(") { k = try closingParenthesis(code, k) + 1 }
            guard k < code.count && code[k].isWord("AS") else { throw unreadable }
            k += 1
            guard k < code.count && code[k].isSymbol("(") else { throw unreadable }
            k = try closingParenthesis(code, k) + 1
            guard k < code.count && code[k].isSymbol(",") else { return (k, names) }
            k += 1
        }
    }

    private static func closingParenthesis(_ code: [Code], _ open: Int) throws -> Int {
        var depth = 0
        for k in open..<code.count {
            if code[k].isSymbol("(") { depth += 1 }
            if code[k].isSymbol(")") { depth -= 1 }
            if depth == 0 { return k }
        }
        throw Refusal("Its parentheses don't match")
    }

    /// EXPLAIN and its synonyms DESCRIBE and DESC: a table's columns, a query's plan or the plan a connection is
    /// running, but not EXPLAIN ANALYZE (it runs the statement) or the plan of a write.
    private static func checkExplain(_ code: [Code], from start: Int) throws {
        var k = start
        options: while k < code.count {
            switch code[k].kind == .word ? code[k].text : "" {
            case "ANALYZE": throw Refusal("EXPLAIN ANALYZE runs the statement it explains")
            case "EXTENDED", "PARTITIONS": k += 1
            case "FORMAT": k += 3  // FORMAT = JSON
            default: break options
            }
        }
        guard k < code.count else { throw Refusal("EXPLAIN needs a table or a SELECT") }
        let next = code[k]
        switch next.kind == .word || next.kind == .symbol ? next.text : "" {
        case "SELECT", "WITH", "(":
            try checkQuery(code, from: k)
        case "INSERT", "UPDATE", "DELETE", "REPLACE":
            throw Refusal("EXPLAIN \(next.text) explains a write; only the plans of SELECT statements are read-only here")
        case "FOR":
            guard k + 3 == code.count, code[k + 1].isWord("CONNECTION"), code[k + 2].kind == .number else {
                throw Refusal("Only EXPLAIN FOR CONNECTION and a connection number is read-only here")
            }
        default:
            // A table, whose name can't be a reserved word (EXPLAIN DROP TABLE t is no table's description).
            guard next.kind == .quotedName || next.kind == .word && !SQLWords.reserved.contains(next.text) else {
                throw Refusal("EXPLAIN needs a table or a SELECT")
            }
        }
    }

    /// What writes, locks or reaches beyond reading, wherever it is: subqueries and executable comments too.
    private static func checkClauses(_ code: [Code]) throws {
        // A common table expression's column list follows its name like a call's arguments, here and in subqueries.
        var cteNames = Set<Int>()
        for k in code.indices where code[k].isWord("WITH") {
            if let list = try? commonTableExpressions(code, from: k + 1) { cteNames.formUnion(list.names) }
        }
        for (k, token) in code.enumerated() {
            let next = k + 1 < code.count ? code[k + 1] : nil, previous = k > 0 ? code[k - 1] : nil
            if token.kind == .word {
                switch token.text {
                case "INTO": throw Refusal("INTO writes the result to a file or to variables")
                case "TEMPORARY": throw Refusal("Temporary tables can be written even in a read-only transaction")
                case "LOCK": throw Refusal("LOCK IN SHARE MODE locks the rows it reads")
                case "FOR" where next?.isWord("UPDATE") == true || next?.isWord("SHARE") == true:
                    throw Refusal("FOR \(next?.text ?? "") locks the rows it reads")
                case "NEXTVAL", "SETVAL": throw Refusal("\(token.text) moves a sequence on")
                case "NEXT" where next?.isWord("VALUE") == true: throw Refusal("NEXT VALUE FOR moves a sequence on")
                default: break
                }
            }
            if token.isSymbol(":=") { throw Refusal("It assigns a variable (:=)") }
            // A call: a name and "(", unless it names a common table expression or an alias (AS name (columns)).
            guard next?.isSymbol("(") == true, !cteNames.contains(k), previous?.isWord("AS") != true else { continue }
            if token.kind == .quotedName || token.kind == .string {
                throw Refusal("It calls a function by a quoted name (\(token.name)), which can reach a stored function")
            }
            guard token.kind == .word else { continue }
            if previous?.isSymbol(".") == true {
                let qualifier = k >= 2 ? code[k - 2].name + "." : ""
                throw Refusal("\(qualifier)\(token.name)() calls a stored function, which can change data")
            }
            if !SQLWords.readOnlyFunctions.contains(token.text) && !SQLWords.beforeParenthesis.contains(token.text) {
                throw Refusal("\(token.name)() isn't on the list of functions read-only queries may call")
            }
        }
    }
}
