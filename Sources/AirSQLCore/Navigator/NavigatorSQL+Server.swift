import Foundation

/// A row of the process list: a connection to the server and what it runs now.
public struct ServerProcess: Hashable {
    public var id: UInt64
    public var user: String
    public var host: String
    public var database: String?
    public var command: String
    /// Seconds in its state.
    public var time: Int
    public var state: String?
    /// The statement it runs, in full; nil when idle.
    public var info: String?
    /// MariaDB's id of the running statement, for KILL QUERY ID: it can't stop the next statement by mistake.
    public var queryID: UInt64?
    /// `info` to show: another session's CREATE USER has its password masked. Kill checks against `info` itself.
    public var shownInfo: String? { info.map { SQLLog.mask($0) } }

    public init(id: UInt64, user: String, host: String, database: String?, command: String, time: Int, state: String?,
                info: String?, queryID: UInt64?) {
        self.id = id
        self.user = user
        self.host = host
        self.database = database
        self.command = command
        self.time = time
        self.state = state
        self.info = info
        self.queryID = queryID
    }
}

/// Finding text in every table of a server, and the process list with its Kill.
extension NavigatorSQL {
    /// The column types Find Text on Server looks in: text, ENUM, SET and JSON (binary columns hold no text).
    public static let textTypes: Set<String> = ["char", "varchar", "tinytext", "text", "mediumtext", "longtext", "enum", "set",
                                                "json"]

    /// `%text%` for LIKE with `!` as its escape character: whatever the sql_mode, `%`, `_` and `!` in the text match
    /// only themselves (a backslash isn't LIKE's escape under NO_BACKSLASH_ESCAPES, so AirSQL names its own).
    public static func containsPattern(_ text: String) -> String {
        var pattern = "%"
        for character in text {
            if character == "!" || character == "%" || character == "_" { pattern.append("!") }
            pattern.append(character)
        }
        return pattern + "%"
    }

    /// Definitions that may name `name` (kind, database, object, definition), wherever the login can read them. The LIKE
    /// narrows them; `names(_:in:)` then checks a whole word.
    public static func usages(of name: String, noBackslashEscapes: Bool) -> String {
        let pattern = SQLQuote.string(containsPattern(name), noBackslashEscapes: noBackslashEscapes)
        func like(_ column: String) -> String { "\(column) LIKE \(pattern) ESCAPE '!'" }
        return "SELECT 'view', TABLE_SCHEMA, TABLE_NAME, VIEW_DEFINITION FROM information_schema.VIEWS WHERE " + like("VIEW_DEFINITION")
            + " UNION ALL SELECT LOWER(ROUTINE_TYPE), ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_DEFINITION FROM information_schema.ROUTINES WHERE " + like("ROUTINE_DEFINITION")
            + " UNION ALL SELECT 'trigger', TRIGGER_SCHEMA, TRIGGER_NAME, ACTION_STATEMENT FROM information_schema.TRIGGERS WHERE " + like("ACTION_STATEMENT")
            + " UNION ALL SELECT 'event', EVENT_SCHEMA, EVENT_NAME, EVENT_DEFINITION FROM information_schema.EVENTS WHERE " + like("EVENT_DEFINITION")
    }

    /// Whether `text` has `name` as a whole word, without case.
    public static func names(_ name: String, in text: String) -> Bool {
        let wordLetters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$"))
        var from = text.startIndex
        while let found = text.range(of: name, options: .caseInsensitive, range: from..<text.endIndex) {
            let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
            let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
            func isWord(_ character: Character?) -> Bool { character?.unicodeScalars.allSatisfy(wordLetters.contains) == true }
            if !isWord(before), !isWord(after) { return true }
            from = found.upperBound
        }
        return false
    }

    /// Drops an index, primary key, foreign key or check from its table.
    public static func dropPart(_ part: TablePart, _ name: String, of table: DatabaseObject, flavour: SchemaServer.Flavour) -> String? {
        let what: String
        switch part {
        case .indexes: what = name == "PRIMARY" ? "PRIMARY KEY" : "INDEX " + SQLQuote.identifier(name)
        case .foreignKeys: what = "FOREIGN KEY " + SQLQuote.identifier(name)
        // MySQL 8.0.16 to 8.0.18 know only DROP CHECK; MariaDB only DROP CONSTRAINT.
        case .checks: what = (flavour == .mysql ? "CHECK " : "CONSTRAINT ") + SQLQuote.identifier(name)
        case .columns, .triggers: return nil
        }
        return "ALTER TABLE \(table.quoted) DROP " + what
    }

    /// Changes a table's or routine's comment.
    public static func setComment(_ comment: String, of object: DatabaseObject, noBackslashEscapes: Bool) -> String {
        let text = SQLQuote.string(comment, noBackslashEscapes: noBackslashEscapes)
        return object.kind == .table ? "ALTER TABLE \(object.quoted) COMMENT = \(text)" : "ALTER \(object.kind.keyword) \(object.quoted) COMMENT \(text)"
    }

    /// How Find Text compares: a column's own collation decides case unless `caseSensitive`.
    public struct TextMatch: Equatable, Sendable {
        public enum Kind: Int, CaseIterable, Sendable {
            case contains, exact, wildcards, regex

            public var title: String {
                switch self {
                case .contains: return "Contains"
                case .exact: return "Is exactly"
                case .wildcards: return "Wildcards (% and _)"
                case .regex: return "Regular expression"
                }
            }
        }

        public var kind = Kind.contains
        public var caseSensitive = false

        public init(kind: Kind = .contains, caseSensitive: Bool = false) {
            self.kind = kind
            self.caseSensitive = caseSensitive
        }
    }

    /// `col1` LIKE '%text%' ESCAPE '!' OR `col2` LIKE …: the rows of a table where any of `columns` matches `text`. Exact
    /// case compares as utf8mb4_bin, whatever the column's character set.
    public static func contains(_ text: String, columns: [String], noBackslashEscapes: Bool, match: TextMatch = TextMatch()) -> String {
        let quote = { SQLQuote.string($0, noBackslashEscapes: noBackslashEscapes) }
        let test: String
        switch match.kind {
        case .contains: test = "LIKE \(quote(containsPattern(text))) ESCAPE '!'"
        case .exact: test = "= " + quote(text)
        case .wildcards: test = "LIKE \(quote(text.replacingOccurrences(of: "!", with: "!!"))) ESCAPE '!'"
        case .regex: test = "REGEXP " + quote(text)
        }
        return columns.map {
            (match.caseSensitive ? "CONVERT(\(SQLQuote.identifier($0)) USING utf8mb4) COLLATE utf8mb4_bin" : SQLQuote.identifier($0)) + " " + test
        }.joined(separator: " OR ")
    }

    /// How many rows of `table` hold `text` in one of `columns`.
    public static func countContaining(_ text: String, in table: DatabaseObject, columns: [String],
                                       noBackslashEscapes: Bool, match: TextMatch = TextMatch(), limit: Int? = nil) -> String {
        let condition = contains(text, columns: columns, noBackslashEscapes: noBackslashEscapes, match: match)
        guard let limit else { return "SELECT COUNT(*) FROM \(table.quoted) WHERE " + condition }
        return "SELECT COUNT(*) FROM (SELECT 1 FROM \(table.quoted) WHERE \(condition) LIMIT \(limit)) AS matched"
    }

    /// Every connection to the server and what it runs (MariaDB adds the statement's id).
    public static func processList(mariaDB: Bool) -> String {
        "SELECT ID, USER, HOST, DB, COMMAND, TIME, STATE, INFO\(mariaDB ? ", QUERY_ID" : "") FROM information_schema.PROCESSLIST "
            + "ORDER BY ID"
    }

    /// Reads the process list's rows (in `processList`'s column order).
    public static func processes(_ rows: [[String?]]) -> [ServerProcess] {
        rows.compactMap { row in
            guard row.count >= 8, let id = row[0].flatMap({ UInt64($0) }) else { return nil }
            return ServerProcess(id: id, user: row[1] ?? "", host: row[2] ?? "", database: row[3], command: row[4] ?? "",
                                 time: row[5].flatMap { Int($0) } ?? 0, state: row[6].flatMap { $0.isEmpty ? nil : $0 },
                                 info: row[7], queryID: row.count > 8 ? row[8].flatMap { UInt64($0) } : nil)
        }
    }

    /// Whether the server answering still runs this statement on this process, as the list showed it: asked right
    /// before Kill Query, so a statement that ended (or a server behind a proxy that isn't the one listed) isn't hit.
    public static func stillRunning(_ process: ServerProcess, noBackslashEscapes: Bool) -> String {
        var sql = "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID = \(process.id) AND INFO = "
            + SQLQuote.string(process.info ?? "", noBackslashEscapes: noBackslashEscapes)
        if let queryID = process.queryID { sql += " AND QUERY_ID = \(queryID)" }
        return sql
    }

    /// Whether this process is still the same connection (its user and host), asked right before Kill Connection.
    public static func stillConnected(_ process: ServerProcess, noBackslashEscapes: Bool) -> String {
        "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID = \(process.id) AND USER = "
            + SQLQuote.string(process.user, noBackslashEscapes: noBackslashEscapes) + " AND HOST = "
            + SQLQuote.string(process.host, noBackslashEscapes: noBackslashEscapes)
    }

    /// Stops the process's statement: on MariaDB by the statement's own id, so the next one is never hit.
    public static func killQuery(_ process: ServerProcess) -> String {
        process.queryID.map { "KILL QUERY ID \($0)" } ?? "KILL QUERY \(process.id)"
    }

    public static func killConnection(_ process: ServerProcess) -> String { "KILL CONNECTION \(process.id)" }
}
