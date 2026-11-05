/// How a kind of word is written.
public enum SQLWordCase: String, Codable, CaseIterable, Sendable {
    case keep, upper, lower

    public func apply(_ word: String) -> String {
        switch self {
        case .keep: return word
        case .upper: return word.uppercased()
        case .lower: return word.lowercased()
        }
    }
}

/// How Format SQL lays SQL out (Settings ▸ Format).
public struct SQLFormatStyle: Codable, Equatable, Sendable {
    /// Where the brackets of a subquery go.
    public enum Brackets: String, Codable, CaseIterable, Sendable { case endOfLine, ownLine, indented }
    /// When a list (SELECT, SET, GROUP BY, ORDER BY) takes a line per item.
    public enum Lists: String, Codable, CaseIterable, Sendable { case oneLine, whenLong, always }

    public var keywords = SQLWordCase.upper
    public var types = SQLWordCase.upper
    public var functions = SQLWordCase.keep
    /// Unquoted tables and columns: on a server whose names have case, keep is the only safe rule.
    public var identifiers = SQLWordCase.keep
    public var aliases = SQLWordCase.keep
    public var indent = 4
    public var lists = Lists.whenLong
    public var lineWidth = 100
    public var commaFirst = false
    /// AND and OR each start a line, or end one.
    public var conditionsOnLines = true
    public var operatorFirst = true
    public var joinsIndented = false
    public var joinOnOwnLine = false
    public var brackets = Brackets.endOfLine
    public var caseOnLines = true
    public var alignColumns = true
    public var rowsOnLines = true
    public var spaceAroundOperators = true
    public var spaceAfterComma = true
    public var spaceInsideBrackets = false
    /// Clause words right-aligned, so their text runs down one column.
    public var river = false

    public init() {}

    /// Styles saved by another version may lack keys; those keep their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T { try container.decodeIfPresent(T.self, forKey: key) ?? fallback }
        let plain = SQLFormatStyle()
        keywords = try value(.keywords, plain.keywords)
        types = try value(.types, plain.types)
        functions = try value(.functions, plain.functions)
        identifiers = try value(.identifiers, plain.identifiers)
        aliases = try value(.aliases, plain.aliases)
        indent = try value(.indent, plain.indent)
        lists = try value(.lists, plain.lists)
        lineWidth = try value(.lineWidth, plain.lineWidth)
        commaFirst = try value(.commaFirst, plain.commaFirst)
        conditionsOnLines = try value(.conditionsOnLines, plain.conditionsOnLines)
        operatorFirst = try value(.operatorFirst, plain.operatorFirst)
        joinsIndented = try value(.joinsIndented, plain.joinsIndented)
        joinOnOwnLine = try value(.joinOnOwnLine, plain.joinOnOwnLine)
        brackets = try value(.brackets, plain.brackets)
        caseOnLines = try value(.caseOnLines, plain.caseOnLines)
        alignColumns = try value(.alignColumns, plain.alignColumns)
        rowsOnLines = try value(.rowsOnLines, plain.rowsOnLines)
        spaceAroundOperators = try value(.spaceAroundOperators, plain.spaceAroundOperators)
        spaceAfterComma = try value(.spaceAfterComma, plain.spaceAfterComma)
        spaceInsideBrackets = try value(.spaceInsideBrackets, plain.spaceInsideBrackets)
        river = try value(.river, plain.river)
    }

    /// The named sets of rules Settings ▸ Format offers.
    public static let presets: [(name: String, style: SQLFormatStyle)] = {
        func style(_ change: (inout SQLFormatStyle) -> Void) -> SQLFormatStyle {
            var style = SQLFormatStyle()
            change(&style)
            return style
        }
        return [
            ("Default", SQLFormatStyle()),
            ("Modern", style { $0.keywords = .lower; $0.types = .lower; $0.functions = .lower; $0.indent = 2; $0.lists = .always; $0.joinsIndented = true }),
            ("River", style { $0.river = true; $0.lists = .always }),
            ("Comma First", style { $0.commaFirst = true; $0.lists = .always }),
            ("Allman", style { $0.brackets = .ownLine; $0.lists = .always; $0.joinOnOwnLine = true }),
            ("Egyptian", style { $0.brackets = .endOfLine; $0.lists = .always; $0.operatorFirst = false }),
            ("Whitesmiths", style { $0.brackets = .indented; $0.lists = .always; $0.joinOnOwnLine = true }),
        ]
    }()
}

/// Format SQL (plan §2.6, R15): lays statements out by `SQLFormatStyle`. Only the whitespace between tokens and the case
/// the style asks for change: literals, comments and executable comments stay exactly as they are, and the result is
/// kept only when `SQLLexer.sameTokens` proves the server reads the same statements. Between `-- @formatter:off` and
/// `-- @formatter:on` nothing changes.
public enum SQLFormatter {
    /// `sql` formatted, or nil when formatting would change more than whitespace and case (it never should).
    public static func format(_ sql: String, noBackslashEscapes: Bool = false, style: SQLFormatStyle = SQLFormatStyle()) -> String? {
        let text = Array(sql.utf16)
        var result: [UInt16] = [], copied = 0, off = false
        func marker(_ units: ArraySlice<UInt16>) {
            let part = String(decoding: units, as: UTF16.self)
            if let last = part.range(of: "@formatter:", options: .backwards) { off = part[last.upperBound...].hasPrefix("off") }
        }
        // An executable comment a ; cuts in two: its second part looks like plain code from here.
        var lexer = SQLLexer(sql, noBackslashEscapes: noBackslashEscapes), code: [Range<Int>] = [], opened = 0
        while let token = lexer.next() {
            if token.kind == .codeStart, lexer.openCodeComments == 1 { opened = token.range.lowerBound }
            if token.kind == .codeEnd, lexer.openCodeComments == 0 { code.append(opened..<token.range.upperBound) }
        }
        if lexer.openCodeComments > 0 { code.append(opened..<text.count) }
        for statement in SQLSplitter.statements(in: sql, noBackslashEscapes: noBackslashEscapes) {
            result += text[copied..<statement.range.lowerBound]
            marker(text[copied..<statement.range.lowerBound])
            let delimiter = String(decoding: text[statement.range.upperBound..<statement.end], as: UTF16.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            marker(text[statement.range])
            if off || code.contains(where: { $0.lowerBound < statement.range.lowerBound && statement.range.lowerBound < $0.upperBound }) {
                result += text[statement.range]
            } else {
                var printer = SQLFormatPrinter(statement.sql, noBackslashEscapes: noBackslashEscapes, style: style,
                                               routine: !(delimiter.isEmpty || delimiter == ";"))
                result += Array(printer.format().utf16)
            }
            copied = statement.range.upperBound
        }
        result += text[copied...]
        let formatted = String(decoding: result, as: UTF16.self)
        return SQLLexer.sameTokens(sql, formatted, noBackslashEscapes: noBackslashEscapes, ignoringCaseOf: caseFree(style)) ? formatted : nil
    }

    /// The words besides the reserved ones whose case this style may change.
    private static func caseFree(_ style: SQLFormatStyle) -> (String) -> Bool {
        if style.identifiers != .keep || style.aliases != .keep { return { _ in true } }
        return { word in
            SQLFormatPrinter.contextKeywords.contains(word) || (style.functions != .keep && SQLFormatPrinter.functions.contains(word))
                || (style.types != .keep && ColumnTypes.type(word.lowercased()) != nil)
        }
    }
}

/// One statement laid out, token by token. Each bracket of a query opens a frame, whose clauses start lines at its column.
struct SQLFormatPrinter {
    /// A bracket, or the statement.
    private struct Frame {
        enum Kind { case query, group, definition }
        var kind: Kind
        /// The column its clauses start at.
        var base: Int
        /// Where its closing bracket goes.
        var closeColumn = 0
        var clause = ""
        /// Where the text of the current clause starts, and so where its next lines do.
        var clauseColumn = 0
        var perLine = false
        var between = false
        /// The token its statement's verb is at: a routine holds many.
        var verb = 0
        /// In a definition: where each column's name ends, in the text and in `out`, for lining up what follows.
        var names: [(token: Int, out: Int)] = []
    }

    static let functions = Set(SQLFunction.all.map(\.name))
    /// Not reserved, so names elsewhere, but keywords where the printer knows they are.
    static let contextKeywords: Set<String> = ["DUPLICATE", "OFFSET", "BEGIN", "END", "COMMIT", "ROLLBACK", "START", "TRANSACTION", "TRUNCATE", "DO", "BY", "UNTIL",
                                                  "ENGINE", "AUTO_INCREMENT", "COMMENT", "CHARSET"]
    private static let startingWords: Set<String> = ["BEGIN", "COMMIT", "ROLLBACK", "START", "TRUNCATE"]
    private static let clauses: Set<String> = ["SELECT", "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "UNION", "SET", "VALUES", "WINDOW", "RETURNING"]
    /// Words before JOIN that start the join's line instead of it.
    private static let joinWords: Set<String> = ["LEFT", "RIGHT", "INNER", "CROSS", "NATURAL", "OUTER", "FULL"]
    private static let operators: Set<String> = ["=", "<", ">", "<=", ">=", "<>", "!=", "<=>", ":=", "+", "-", "/", "%", "*"]
    private static let notColumns: Set<String> = ["CONSTRAINT", "PRIMARY", "KEY", "INDEX", "UNIQUE", "FOREIGN", "CHECK", "FULLTEXT", "SPATIAL", "PERIOD", "LIKE"]

    private var lexer: SQLLexer
    private let text: [UInt16]
    private let style: SQLFormatStyle
    private let routine: Bool
    private let sql: String
    private let noBackslashEscapes: Bool
    private var tokens: [(token: SQLToken, code: Bool)] = []
    private var out: [UInt16] = []
    private var frames = [Frame(kind: .query, base: 0)]
    /// The column of each CASE being read.
    private var cases: [Int] = []
    /// The next token starts a line at this column.
    private var pending: Int?
    private var spaced = false
    /// Where the last token ends in `out`.
    private var tokenEnd = 0
    private var afterDot = false
    /// An UNTIL has closed its REPEAT's block already.
    private var untilClosed = false
    private var names: [Int: SQLSymbol.Kind] = [:]

    init(_ sql: String, noBackslashEscapes: Bool, style: SQLFormatStyle, routine: Bool) {
        self.sql = sql
        self.noBackslashEscapes = noBackslashEscapes
        self.style = style
        self.routine = routine
        lexer = SQLLexer(sql, noBackslashEscapes: noBackslashEscapes)
        text = lexer.text
        while let token = lexer.next() {
            // An executable comment's own tokens, and what is inside it, are left as written.
            let inside = lexer.openCodeComments > 0 || token.kind == .codeEnd
            tokens.append((token, !inside && token.kind != .codeStart))
        }
        if style.identifiers != .keep || style.aliases != .keep {
            for reference in SQLAnalysis(sql, snapshot: nil, database: nil, noBackslashEscapes: noBackslashEscapes).references {
                names[reference.range.lowerBound] = reference.symbol.kind
            }
        }
    }

    private var frame: Frame {
        get { frames[frames.count - 1] }
        set { frames[frames.count - 1] = newValue }
    }

    private func word(_ index: Int) -> String? {
        guard index >= 0, index < tokens.count, tokens[index].token.kind == .word else { return nil }
        return lexer.upper(tokens[index].token.range)
    }

    private func symbol(_ index: Int) -> String? {
        guard index >= 0, index < tokens.count, tokens[index].token.kind == .symbol else { return nil }
        return lexer.string(tokens[index].token.range)
    }

    private func isLineComment(_ index: Int) -> Bool {
        let token = tokens[index].token
        return token.kind == .comment && (token.range.count < 2 || text[token.range.lowerBound] != 0x2F)
    }

    private var column: Int {
        var at = out.count
        while at > 0, out[at - 1] != 0x0A { at -= 1 }
        return out.count - at
    }

    private var lineIndent: Int {
        var start = out.count
        while start > 0, out[start - 1] != 0x0A { start -= 1 }
        var at = start
        while at < out.count, out[at] == 0x20 { at += 1 }
        return at - start
    }

    private mutating func newLine(_ column: Int) {
        // Only what was put after the last token: a comment may end in a space.
        out.removeLast(out.count - tokenEnd)
        if !out.isEmpty { out.append(0x0A) }
        out += Array(repeating: 0x20, count: max(0, column))
    }

    private mutating func space() { if out.last != 0x20, out.last != 0x0A, !out.isEmpty { out.append(0x20) } }

    mutating func format() -> String {
        guard !tokens.isEmpty else { return sql }
        var previousEnd = tokens[0].token.range.lowerBound
        for index in tokens.indices {
            let item = tokens[index]
            let gap = text[previousEnd..<item.token.range.lowerBound]
            if index > 0, !item.code || !tokens[index - 1].code {
                out += gap
            } else {
                if item.code, index == frame.verb, let word = word(index), Self.clauses.contains(word) { _ = clauseStart(word, index) }
                if index > 0 { place(index, gap) }
            }
            write(index)
            if item.code { after(index) }
            previousEnd = item.token.range.upperBound
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// Whitespace before the token at `index`.
    private mutating func place(_ index: Int, _ gap: ArraySlice<UInt16>) {
        let token = tokens[index].token
        let lineBreak = isLineComment(index - 1) || (token.kind == .comment && gap.contains(0x0A))
        if token.kind == .comment, !lineBreak, pending != nil { return space() }
        if lineBreak, pending == nil { pending = frame.perLine ? frame.clauseColumn : frame.clause.isEmpty ? frame.base : frame.base + style.indent }
        if token.kind == .symbol, closes(index) { return }
        if let word = word(index), !afterDot, let column = lineStart(word, index) {
            pending = nil
            newLine(column)
            return
        }
        if let column = pending {
            pending = nil
            newLine(column)
            return
        }
        let afterBracket = symbol(index - 1) == "(" && frame.kind == .group
        if symbol(index - 1) == "," || afterBracket {
            spaced = false
            if afterBracket ? style.spaceInsideBrackets : style.spaceAfterComma { space() }
            return
        }
        if token.kind == .symbol { return placeSymbol(index, gap) }
        if spaced || !gap.isEmpty { space() }
        spaced = false
    }

    /// `)` and `,`, which may start a line; true when placed.
    private mutating func closes(_ index: Int) -> Bool {
        let raw = lexer.string(tokens[index].token.range)
        if raw == ")", frames.count > 1, frame.kind != .group {
            pending = nil
            newLine(frame.closeColumn)
            return true
        }
        if raw == ",", style.commaFirst, frame.kind == .query, frame.perLine {
            pending = nil
            newLine(max(frame.base, frame.clauseColumn - 2))
            return true
        }
        return false
    }

    private mutating func placeSymbol(_ index: Int, _ gap: ArraySlice<UInt16>) {
        let raw = lexer.string(tokens[index].token.range), wasSpaced = spaced
        spaced = false
        switch raw {
        case ",", ";", ".": break
        case ")": if style.spaceInsideBrackets, frame.kind == .group, symbol(index - 1) != "(" { space() }
        default:
            if isBinaryOperator(index) {
                space()
                spaced = true
            } else if wasSpaced || !gap.isEmpty {
                space()
            }
        }
    }

    private func isBinaryOperator(_ index: Int) -> Bool {
        let raw = lexer.string(tokens[index].token.range)
        guard style.spaceAroundOperators, Self.operators.contains(raw), index > 0 else { return false }
        let before = tokens[index - 1].token
        switch before.kind {
        case .number, .string, .quotedName, .variable: return true
        case .word: return !SQLWords.reserved.contains(lexer.upper(before.range)) || symbol(index - 2) == "."
        case .symbol: return lexer.string(before.range) == ")"
        default: return false
        }
    }

    /// The column the word at `index` starts a line at, if it does.
    private mutating func lineStart(_ word: String, _ index: Int) -> Int? {
        if style.caseOnLines, let start = cases.last {
            if word == "WHEN" || word == "ELSE" { return start + style.indent }
            if word == "END" { return start }
        }
        if routine, let column = routineLine(word, index) { return column }
        guard frame.kind == .query else { return nil }
        if word == "AND" || word == "OR" || word == "XOR" {
            if frame.between, word == "AND" {
                frame.between = false
                return nil
            }
            guard style.conditionsOnLines, style.operatorFirst, ["WHERE", "HAVING", "ON"].contains(frame.clause) else { return nil }
            return frame.clause == "ON" ? joinLine : max(frame.base, frame.clauseColumn - word.utf16.count - 1)
        }
        if word == "ON", style.joinOnOwnLine, frame.clause == "JOIN" { return joinLine }
        guard startsLine(word, index), index > frame.verb else { return nil }
        return clauseStart(word, index)
    }

    /// Where a join's ON and its conditions go when they start a line.
    private var joinLine: Int { frame.base + (style.joinsIndented ? 2 : 1) * style.indent }

    /// Sets the frame's clause for the word at `index` and gives the column it starts at.
    private mutating func clauseStart(_ word: String, _ index: Int) -> Int {
        var header = word.utf16.count, at = index
        // The words of a clause's name count: GROUP BY, LEFT OUTER JOIN, UNION ALL.
        while let next = self.word(at + 1), ["GROUP", "ORDER"].contains(word) ? next == "BY" : Self.joinWords.contains(word) ? ["JOIN", "OUTER"].contains(next)
                : word == "UNION" && ["ALL", "DISTINCT"].contains(next) {
            header += next.utf16.count + 1
            at += 1
        }
        let join = word.hasSuffix("JOIN") || Self.joinWords.contains(word)
        let pad = style.river ? max(0, 6 - word.utf16.count) : 0
        let column = frame.base + pad + (join && style.joinsIndented ? style.indent : 0)
        frame.clause = join ? "JOIN" : word
        frame.clauseColumn = column + header + 1
        frame.between = false
        frame.perLine = ["SELECT", "SET", "GROUP", "ORDER", "FROM"].contains(word) && listBreaks(at + 1) || (word == "VALUES" && style.rowsOnLines)
        return column
    }

    /// Whether the list from `index` on takes a line per item.
    private func listBreaks(_ index: Int) -> Bool {
        switch style.lists {
        case .oneLine: return false
        case .always: return true
        case .whenLong: break
        }
        var depth = 0, length = frame.clauseColumn, at = index
        while at < tokens.count {
            let token = tokens[at].token
            if let raw = symbol(at) {
                if raw == "(" { depth += 1 }
                if raw == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
            }
            if depth > 0, word(at) == "SELECT" { return true }
            if depth == 0, let word = word(at), Self.clauses.contains(word) || word.hasSuffix("JOIN") { break }
            if isLineComment(at) { return true }
            length += token.range.count + 1
            at += 1
        }
        return length > style.lineWidth
    }

    /// Whether the word at `index` starts a line: a main clause where it is one, or the first word of a JOIN.
    private func startsLine(_ word: String, _ index: Int) -> Bool {
        let before = self.word(index - 1), first = self.word(frame.verb)
        switch word {
        case "SELECT":
            return !["UNION", "ALL", "DISTINCT", "EXPLAIN", "DESCRIBE", "DESC", "ANALYZE"].contains(before ?? "")
        case "FROM":
            return first != "SHOW" && !["DELETE", "LOW_PRIORITY", "QUICK", "IGNORE"].contains(before ?? "")
        case "SET":
            return ["UPDATE", "INSERT", "REPLACE", "WITH"].contains(first ?? "") && !["CHARACTER", "CHAR"].contains(before ?? "")
        case "VALUES":
            // Not VALUES(column) after = or , in ON DUPLICATE KEY UPDATE.
            guard index > 0, tokens[index - 1].token.kind == .symbol else { return true }
            let symbol = lexer.string(tokens[index - 1].token.range)
            return symbol != "=" && symbol != ","
        case "GROUP":
            return before != "WITHIN"
        case "JOIN", "STRAIGHT_JOIN":
            return !(before.map(Self.joinWords.contains) ?? false)
        case "ON":
            return self.word(index + 1) == "DUPLICATE"
        default:
            if Self.clauses.contains(word) { return true }
            guard Self.joinWords.contains(word) else { return false }
            let next = self.word(index + 1)
            return (next == "JOIN" || next == "OUTER") && !(before.map(Self.joinWords.contains) ?? false)
        }
    }

    // MARK: Routine bodies

    private mutating func openBlock() {
        frames[0].base += style.indent
        pending = frames[0].base
    }

    private mutating func closeBlock() { frames[0].base = max(0, frames[0].base - style.indent) }

    /// The lines of a routine's flow: BEGIN, IF, the loops and their ends.
    private mutating func routineLine(_ word: String, _ index: Int) -> Int? {
        guard frames.count == 1 else { return nil }
        switch word {
        case "BEGIN":
            return frames[0].base
        case "END":
            if untilClosed { untilClosed = false } else { closeBlock() }
            return frames[0].base
        case "ELSE", "ELSEIF":
            closeBlock()
            return frames[0].base
        case "UNTIL":
            closeBlock()
            untilClosed = true
            return frames[0].base
        default:
            return nil
        }
    }

    /// What a word of a routine's flow does to the lines after it.
    // shortcut: a CASE statement's branches are laid out as a CASE expression's, valid but not nested; do it when asked.
    private mutating func routineAfter(_ word: String, _ index: Int) {
        guard frames.count == 1, cases.isEmpty else { return }
        switch word {
        case "BEGIN":
            if self.word(index + 1) == "WORK" { return }
        case "DO", "THEN", "ELSE":
            break
        case "LOOP", "REPEAT":
            if self.word(index - 1) == "END" || symbol(index + 1) == "(" { return }
        default:
            return
        }
        openBlock()
        frame.verb = index + 1
    }

    // MARK: Writing

    private func written(_ index: Int) -> [UInt16] {
        let token = tokens[index].token
        let raw = Array(text[token.range])
        guard tokens[index].code, token.kind == .word else { return raw }
        if afterDot {
            return Array(identifier(token, lexer.string(token.range)).utf16)
        }
        let upper = lexer.upper(token.range)
        let string = lexer.string(token.range)
        if symbol(index + 1) == "(", Self.functions.contains(upper), style.functions != .keep {
            return Array(style.functions.apply(string).utf16)
        }
        if isType(index, upper) { return Array(style.types.apply(string).utf16) }
        if SQLWords.reserved.contains(upper) || isContextKeyword(index, upper) { return Array(style.keywords.apply(string).utf16) }
        return Array(identifier(token, string).utf16)
    }

    private func identifier(_ token: SQLToken, _ word: String) -> String {
        switch names[token.range.lowerBound] {
        case .tableAlias?, .selectAlias?: return style.aliases.apply(word)
        case nil: return Self.queries.contains(self.word(frames[0].verb) ?? "") ? style.identifiers.apply(word) : word
        default: return style.identifiers.apply(word)
        }
    }

    /// Statements where a word that's no keyword is a name (without a schema, the analysis only knows aliases).
    private static let queries: Set<String> = ["SELECT", "WITH", "INSERT", "REPLACE", "UPDATE", "DELETE"]

    private func isContextKeyword(_ index: Int, _ word: String) -> Bool {
        switch word {
        case "DUPLICATE": return self.word(index - 1) == "ON"
        case "OFFSET": return frame.clause == "LIMIT"
        case "END": return !cases.isEmpty || routine
        case "BEGIN", "DO": return routine
        case "BY": return ["GROUP", "ORDER", "PARTITION"].contains(self.word(index - 1) ?? "")
        case "UNTIL": return routine
        // A table's options, and a column's after its name.
        case "ENGINE", "AUTO_INCREMENT", "COMMENT", "CHARSET":
            return frame.kind == .definition ? symbol(index - 1) != "," && symbol(index - 1) != "(" : frames.count == 1 && symbol(index + 1) == "="
        default: return index == frame.verb && Self.startingWords.contains(word)
        }
    }

    /// A column's type: its definition's second word, or after CAST's AS.
    private func isType(_ index: Int, _ word: String) -> Bool {
        guard ColumnTypes.type(word.lowercased()) != nil else { return false }
        if frame.kind == .definition, tokens[index - 1].token.range.upperBound == frame.names.last?.token { return true }
        return self.word(index - 1) == "AS" && frame.kind == .group
    }

    private mutating func write(_ index: Int) {
        let item = tokens[index]
        out += written(index)
        tokenEnd = out.count
        if frame.kind == .definition, item.code, symbol(index - 1) == "(" || symbol(index - 1) == ",",
           item.token.kind == .word || item.token.kind == .quotedName, !Self.notColumns.contains(lexer.upper(item.token.range)) {
            frame.names.append((item.token.range.upperBound, out.count))
        }
    }

    /// What the token at `index` does to what follows.
    private mutating func after(_ index: Int) {
        let token = tokens[index].token
        afterDot = token.kind == .symbol && lexer.string(token.range) == "."
        if token.kind == .symbol { return afterSymbol(index) }
        guard let word = word(index), symbol(index - 1) != "." else { return }
        if routine { routineAfter(word, index) }
        if index == frame.verb, word == "WITH" {
            frame.clause = word
            frame.clauseColumn = frame.base
            frame.perLine = true
        }
        if word == "BETWEEN" { frame.between = true }
        if word == "CASE", self.word(index - 1) != "END" { cases.append(column - 4) }
        if word == "END", !cases.isEmpty, !(routine && ["IF", "LOOP", "WHILE", "REPEAT"].contains(self.word(index + 1) ?? "")) { cases.removeLast() }
        if ["AND", "OR", "XOR"].contains(word), style.conditionsOnLines, !style.operatorFirst, frame.kind == .query,
           ["WHERE", "HAVING", "ON"].contains(frame.clause) {
            pending = frame.clauseColumn
        }
        if word == "ON", frame.clause == "JOIN" { frame.clause = word }
    }

    private mutating func afterSymbol(_ index: Int) {
        let raw = lexer.string(tokens[index].token.range)
        switch raw {
        case "(": open(index)
        case ")": close()
        case ",":
            if frame.kind == .definition {
                pending = frame.base
            } else if frame.kind == .query, frame.perLine, !style.commaFirst {
                pending = frame.clauseColumn
            } else if frame.kind == .query, frame.perLine {
                out.append(0x20)
            }
        case ";":
            if routine, frames.count == 1 {
                pending = frames[0].base
                frame.verb = index + 1
                frame.clause = ""
                frame.perLine = false
            }
        default:
            break
        }
    }

    private mutating func open(_ index: Int) {
        let subquery = word(index + 1) == "SELECT" || word(index + 1) == "WITH"
        if subquery {
            let line = lineIndent
            let inner = line + style.indent
            let close = style.brackets == .indented ? inner : line
            if style.brackets != .endOfLine {
                out.removeLast()
                while out.last == 0x20 { out.removeLast() }
                tokenEnd = out.count
                newLine(close)
                out.append(0x28)
                tokenEnd = out.count
            }
            frames.append(Frame(kind: .query, base: style.brackets == .indented ? inner + style.indent : inner, closeColumn: close))
            frame.clauseColumn = frame.base
            frame.verb = index + 1
            pending = frame.base
        } else if frames.count == 1, word(frame.verb) == "CREATE", isTableBody(index) {
            frames.append(Frame(kind: .definition, base: frame.base + style.indent, closeColumn: frame.base))
            pending = frame.base
        } else {
            frames.append(Frame(kind: .group, base: frame.base, closeColumn: 0))
            spaced = style.spaceInsideBrackets && symbol(index + 1) != ")"
        }
    }

    /// The bracket after CREATE TABLE's name.
    private func isTableBody(_ index: Int) -> Bool {
        guard let table = (frame.verb..<index).first(where: { word($0) == "TABLE" }) else { return false }
        return !(table..<index).contains { symbol($0) == "(" }
    }

    private mutating func close() {
        guard frames.count > 1 else { return }
        let closing = frames.removeLast()
        if closing.kind == .definition, style.alignColumns { align(closing.names.map(\.out)) }
        spaced = false
    }

    /// Lines up what follows the names that end at `ends` of `out`.
    private mutating func align(_ ends: [Int]) {
        func width(_ end: Int) -> Int {
            var at = end
            while at > 0, out[at - 1] != 0x0A { at -= 1 }
            return end - at
        }
        let widest = ends.map(width).max() ?? 0
        for end in ends.reversed() { out.insert(contentsOf: Array(repeating: 0x20, count: widest - width(end)), at: end) }
        tokenEnd = out.count
    }
}
