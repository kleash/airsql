import Foundation

// The object editors' forms. The code stays what the object is: a form reads the clauses at its head from the code, and
// writes them back when a field changes, leaving the body as it was typed. Code a form can't read gives no form (nil), and
// is edited as text. shortcut: a comment between the head's clauses goes when a field changes; keep it in the body until
// someone needs it there.

/// The code's tokens without comments, with a place in them.
private struct ClauseReader {
    let code: String
    let units: [UInt16]
    let tokens: [SQLToken]
    var at = 0

    /// Reads from just after `start`.
    init(_ code: String, after start: String.Index, noBackslashEscapes: Bool) {
        self.code = code
        units = Array(code.utf16)
        tokens = SQLLexer.tokens(code, noBackslashEscapes: noBackslashEscapes).filter { $0.kind != .comment }
        let offset = code.utf16.distance(from: code.startIndex, to: start)
        at = tokens.firstIndex { $0.range.lowerBound >= offset } ?? tokens.count
    }

    var isDone: Bool { at >= tokens.count }

    func text(_ token: SQLToken) -> String { String(decoding: units[token.range], as: UTF16.self) }

    /// The word at `offset` from here, uppercased; nil past the end or where something else is.
    func word(_ offset: Int = 0) -> String? {
        guard at + offset < tokens.count, tokens[at + offset].kind == .word else { return nil }
        return text(tokens[at + offset]).uppercased()
    }

    func symbol(_ symbol: String) -> Bool { !isDone && tokens[at].kind == .symbol && text(tokens[at]) == symbol }

    /// Steps over these words, if they come next.
    mutating func take(_ words: String...) -> Bool {
        for (offset, word) in words.enumerated() where self.word(offset) != word { return false }
        at += words.count
        return true
    }

    /// A name, bare or quoted.
    mutating func name() -> String? {
        guard !isDone else { return nil }
        let token = tokens[at]
        guard token.kind == .word || token.kind == .quotedName else { return nil }
        at += 1
        return token.kind == .word ? text(token) : SQLQuote.unquoted(text(token))
    }

    /// The text from the token at `start` up to where the reader is.
    func slice(from start: Int) -> String {
        guard start < at, start < tokens.count else { return "" }
        return String(decoding: units[tokens[start].range.lowerBound..<tokens[at - 1].range.upperBound], as: UTF16.self)
    }

    /// Everything from here on, as it was typed.
    var rest: String { isDone ? "" : String(decoding: units[tokens[at].range.lowerBound...], as: UTF16.self) }

    /// Steps over tokens up to `stop` outside brackets; the text passed.
    mutating func until(_ stop: Set<String>) -> String {
        let start = at
        var depth = 0
        while !isDone {
            if depth == 0, let word = word(), stop.contains(word) { break }
            if symbol("(") { depth += 1 }
            if symbol(")") { depth -= 1 }
            at += 1
        }
        return slice(from: start)
    }

    /// Steps over the brackets here; false when they don't close.
    mutating func skipBrackets() -> Bool {
        var depth = 0
        while !isDone {
            if symbol("(") { depth += 1 }
            if symbol(")") { depth -= 1 }
            at += 1
            if depth == 0 { return true }
        }
        return false
    }

    /// A string's value.
    mutating func string(noBackslashEscapes: Bool) -> String? {
        guard !isDone, tokens[at].kind == .string else { return nil }
        let literal = text(tokens[at])
        at += 1
        guard let quote = literal.first, literal.count >= 2 else { return nil }
        return InsertRows.unescaped(literal, quote: quote, noBackslashEscapes: noBackslashEscapes)
    }
}

/// A procedure's or function's head.
public struct RoutineForm: Equatable {
    public struct Parameter: Equatable {
        /// IN, OUT or INOUT; a function's are "".
        public var mode: String
        public var name: String
        public var type: String

        public init(mode: String, name: String, type: String) {
            self.mode = mode
            self.name = name
            self.type = type
        }
    }

    public static let dataAccess = ["CONTAINS SQL", "NO SQL", "READS SQL DATA", "MODIFIES SQL DATA"]
    private static let typeWords: Set<String> = ["UNSIGNED", "SIGNED", "ZEROFILL", "BINARY", "ASCII", "UNICODE", "PRECISION", "VARYING",
                                                 "CHARSET", "CHARACTER", "COLLATE", "VARCHAR", "VARCHARACTER"]

    public let kind: ObjectKind
    public var name: String
    public var parameters: [Parameter] = []
    /// A function's return type.
    public var returns: String?
    public var deterministic = false
    public var dataAccess = "CONTAINS SQL"
    /// DEFINER or INVOKER.
    public var security = "DEFINER"
    public var comment = ""
    private var head: String
    private var database: String?
    private var body: String

    public init?(_ code: String, noBackslashEscapes: Bool) {
        guard let header = CreateHeader(code), header.kind == .procedure || header.kind == .function else { return nil }
        kind = header.kind
        name = header.name
        head = String(code[..<header.nameRange.lowerBound])
        database = header.database
        var reader = ClauseReader(code, after: header.nameRange.upperBound, noBackslashEscapes: noBackslashEscapes)
        guard reader.symbol("(") else { return nil }
        reader.at += 1
        var depth = 0, start = reader.at
        var pieces: [(Int, Int)] = []
        while true {
            guard !reader.isDone else { return nil }
            if reader.symbol("(") { depth += 1 }
            if reader.symbol(")") {
                if depth == 0 { break }
                depth -= 1
            }
            if reader.symbol(","), depth == 0 {
                pieces.append((start, reader.at))
                start = reader.at + 1
            }
            reader.at += 1
        }
        if start < reader.at { pieces.append((start, reader.at)) }
        let close = reader.at
        for (first, end) in pieces {
            var piece = reader
            piece.at = first
            var mode = ""
            for word in ["INOUT", "IN", "OUT"] where piece.word() == word && piece.at + 1 < end {
                mode = word
                piece.at += 1
                break
            }
            guard let parameter = piece.name(), piece.at < end else { return nil }
            let typeStart = piece.at
            piece.at = end
            parameters.append(Parameter(mode: mode, name: parameter, type: piece.slice(from: typeStart)))
        }
        reader.at = close + 1
        if reader.take("RETURNS") {
            let start = reader.at
            guard reader.word() != nil else { return nil }
            reader.at += 1
            while !reader.isDone {
                if reader.symbol("(") {
                    guard reader.skipBrackets() else { return nil }
                    continue
                }
                guard let word = reader.word(), Self.typeWords.contains(word) else { break }
                reader.at += word == "CHARSET" || word == "COLLATE" ? 2 : word == "CHARACTER" && reader.word(1) == "SET" ? 3 : 1
            }
            returns = reader.slice(from: start)
        }
        while true {
            if reader.take("COMMENT") {
                guard let text = reader.string(noBackslashEscapes: noBackslashEscapes) else { return nil }
                comment = text
            } else if reader.take("LANGUAGE", "SQL") || reader.take("CONTAINS", "SQL") {
                continue
            } else if reader.take("NOT", "DETERMINISTIC") {
                deterministic = false
            } else if reader.take("DETERMINISTIC") {
                deterministic = true
            } else if reader.take("NO", "SQL") {
                dataAccess = "NO SQL"
            } else if reader.take("READS", "SQL", "DATA") {
                dataAccess = "READS SQL DATA"
            } else if reader.take("MODIFIES", "SQL", "DATA") {
                dataAccess = "MODIFIES SQL DATA"
            } else if reader.take("SQL", "SECURITY") {
                guard let word = reader.word(), ["DEFINER", "INVOKER"].contains(word) else { return nil }
                security = word
                reader.at += 1
            } else {
                break
            }
        }
        body = reader.rest
    }

    /// The code with these fields.
    public func code(noBackslashEscapes: Bool) -> String {
        let list = parameters.map { [$0.mode, SQLQuote.identifier($0.name), $0.type].filter { !$0.isEmpty }.joined(separator: " ") }
        var lines = [head + (database.map { SQLQuote.identifier($0, name) } ?? SQLQuote.identifier(name)) + "(" + list.joined(separator: ", ") + ")"
                     + (returns.map { " RETURNS " + $0 } ?? "")]
        if deterministic { lines.append("DETERMINISTIC") }
        if dataAccess != "CONTAINS SQL" { lines.append(dataAccess) }
        if security != "DEFINER" { lines.append("SQL SECURITY " + security) }
        if !comment.isEmpty { lines.append("COMMENT " + SQLQuote.string(comment, noBackslashEscapes: noBackslashEscapes)) }
        return (lines + [body]).joined(separator: "\n")
    }
}

/// A trigger's head: when it fires and on what.
public struct TriggerForm: Equatable {
    public var name: String
    /// BEFORE or AFTER.
    public var timing: String
    /// INSERT, UPDATE or DELETE.
    public var event: String
    public var table: String
    private var head: String
    private var database: String?
    private var tableDatabase: String?
    private var rest: String

    public init?(_ code: String, noBackslashEscapes: Bool) {
        guard let header = CreateHeader(code), header.kind == .trigger else { return nil }
        name = header.name
        head = String(code[..<header.nameRange.lowerBound])
        database = header.database
        var reader = ClauseReader(code, after: header.nameRange.upperBound, noBackslashEscapes: noBackslashEscapes)
        guard let timing = reader.word(), ["BEFORE", "AFTER"].contains(timing), let event = reader.word(1),
              ["INSERT", "UPDATE", "DELETE"].contains(event), reader.word(2) == "ON" else { return nil }
        self.timing = timing
        self.event = event
        reader.at += 3
        guard var table = reader.name() else { return nil }
        if reader.symbol(".") {
            reader.at += 1
            guard let second = reader.name() else { return nil }
            tableDatabase = table
            table = second
        }
        self.table = table
        guard reader.take("FOR", "EACH", "ROW") else { return nil }
        rest = reader.rest
    }

    public func code() -> String {
        head + (database.map { SQLQuote.identifier($0, name) } ?? SQLQuote.identifier(name)) + " " + timing + " " + event + " ON "
            + (tableDatabase.map { SQLQuote.identifier($0, table) } ?? SQLQuote.identifier(table)) + " FOR EACH ROW\n" + rest
    }
}

/// An event's head: its schedule and what happens around it.
public struct EventForm: Equatable {
    public static let units = ["YEAR", "QUARTER", "MONTH", "WEEK", "DAY", "HOUR", "MINUTE", "SECOND", "YEAR_MONTH", "DAY_HOUR", "DAY_MINUTE",
                               "DAY_SECOND", "HOUR_MINUTE", "HOUR_SECOND", "MINUTE_SECOND"]
    public static let states = ["ENABLE", "DISABLE", "DISABLE ON SLAVE"]

    public var name: String
    /// Runs once, at `at`; else every `every` `unit`s.
    public var once = false
    public var at = ""
    public var every = "1"
    public var unit = "DAY"
    public var starts = ""
    public var ends = ""
    /// ON COMPLETION PRESERVE: kept after its last run.
    public var preserve = false
    public var state = "ENABLE"
    public var comment = ""
    private var head: String
    private var database: String?
    private var body: String

    public init?(_ code: String, noBackslashEscapes: Bool) {
        guard let header = CreateHeader(code), header.kind == .event else { return nil }
        name = header.name
        head = String(code[..<header.nameRange.lowerBound])
        database = header.database
        var reader = ClauseReader(code, after: header.nameRange.upperBound, noBackslashEscapes: noBackslashEscapes)
        guard reader.take("ON", "SCHEDULE") else { return nil }
        let clauses: Set<String> = ["STARTS", "ENDS", "ON", "ENABLE", "DISABLE", "COMMENT", "DO"]
        if reader.take("AT") {
            once = true
            at = reader.until(clauses)
        } else if reader.take("EVERY") {
            every = reader.until(Set(Self.units))
            guard let unit = reader.word(), Self.units.contains(unit) else { return nil }
            self.unit = unit
            reader.at += 1
            if reader.take("STARTS") { starts = reader.until(clauses) }
            if reader.take("ENDS") { ends = reader.until(clauses) }
        } else {
            return nil
        }
        if reader.take("ON", "COMPLETION", "NOT", "PRESERVE") {
            preserve = false
        } else if reader.take("ON", "COMPLETION", "PRESERVE") {
            preserve = true
        }
        if reader.take("DISABLE", "ON", "SLAVE") || reader.take("DISABLE", "ON", "REPLICA") {
            state = "DISABLE ON SLAVE"
        } else if reader.take("DISABLE") {
            state = "DISABLE"
        } else if reader.take("ENABLE") {
            state = "ENABLE"
        }
        if reader.take("COMMENT") {
            guard let text = reader.string(noBackslashEscapes: noBackslashEscapes) else { return nil }
            comment = text
        }
        guard reader.take("DO") else { return nil }
        body = reader.rest
    }

    /// A date and time typed bare gets its quotes; anything else is an expression, as written.
    static func moment(_ text: String, noBackslashEscapes: Bool) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2}(:[0-9]{2})?)?$", options: .regularExpression) != nil
        return bare ? SQLQuote.string(text, noBackslashEscapes: noBackslashEscapes) : text
    }

    public func code(noBackslashEscapes: Bool) -> String {
        let moment = { (text: String) in Self.moment(text, noBackslashEscapes: noBackslashEscapes) }
        var schedule = once ? "AT " + moment(at) : "EVERY " + every.trimmingCharacters(in: .whitespaces) + " " + unit
        if !once, !starts.isEmpty { schedule += " STARTS " + moment(starts) }
        if !once, !ends.isEmpty { schedule += " ENDS " + moment(ends) }
        return head + (database.map { SQLQuote.identifier($0, name) } ?? SQLQuote.identifier(name)) + " ON SCHEDULE " + schedule
            + " ON COMPLETION " + (preserve ? "PRESERVE " : "NOT PRESERVE ") + state
            + (comment.isEmpty ? "" : " COMMENT " + SQLQuote.string(comment, noBackslashEscapes: noBackslashEscapes))
            + "\nDO " + body
    }
}

/// A view's head and its CHECK OPTION.
public struct ViewForm: Equatable {
    public static let algorithms = ["UNDEFINED", "MERGE", "TEMPTABLE"]
    public static let checkOptions = ["", "CASCADED", "LOCAL"]

    public var name: String
    public var algorithm = "UNDEFINED"
    /// DEFINER or INVOKER.
    public var security = "DEFINER"
    /// CASCADED or LOCAL; "" for none.
    public var checkOption = ""
    private var create: String
    private var definer: String?
    private var database: String?
    private var body: String

    public init?(_ code: String, noBackslashEscapes: Bool) {
        guard let header = CreateHeader(code), header.kind == .view else { return nil }
        name = header.name
        database = header.database
        create = "CREATE" + (header.orReplace ? " OR REPLACE" : "")
        definer = header.definer.map { String(code[$0]) }
        var reader = ClauseReader(code, after: header.nameRange.upperBound, noBackslashEscapes: noBackslashEscapes)
        let start = reader.at
        var opening = ClauseReader(code, after: code.startIndex, noBackslashEscapes: noBackslashEscapes)
        while opening.at < reader.at {
            if opening.take("ALGORITHM") {
                opening.at += 1  // =
                guard let word = opening.word(), Self.algorithms.contains(word) else { return nil }
                algorithm = word
            } else if opening.take("SQL", "SECURITY") {
                guard let word = opening.word(), ["DEFINER", "INVOKER"].contains(word) else { return nil }
                security = word
            }
            opening.at += 1
        }
        var last = reader.tokens.count
        if reader.tokens[last - 1].kind == .symbol, reader.text(reader.tokens[last - 1]) == ";" { last -= 1 }
        // WITH [CASCADED | LOCAL] CHECK OPTION ends the statement.
        var end = reader
        end.at = last - 2
        if end.word() == "CHECK", end.word(1) == "OPTION" {
            end.at -= 1
            if let word = end.word(), ["CASCADED", "LOCAL"].contains(word) {
                checkOption = word
                end.at -= 1
            } else {
                checkOption = "CASCADED"
            }
            guard end.word() == "WITH" else { return nil }
            last = end.at
        }
        reader.at = last
        body = reader.slice(from: start)
    }

    public func code() -> String {
        [create, "ALGORITHM=" + algorithm, definer, "SQL SECURITY " + security, "VIEW",
         database.map { SQLQuote.identifier($0, name) } ?? SQLQuote.identifier(name), body].compactMap { $0 }.joined(separator: " ")
            + (checkOption.isEmpty ? "" : " WITH " + checkOption + " CHECK OPTION")
    }
}
