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

    /// `col1` LIKE '%text%' ESCAPE '!' OR `col2` LIKE …: the rows of a table where any of `columns` contains `text`.
    public static func contains(_ text: String, columns: [String], noBackslashEscapes: Bool) -> String {
        let pattern = SQLQuote.string(containsPattern(text), noBackslashEscapes: noBackslashEscapes)
        return columns.map { "\(SQLQuote.identifier($0)) LIKE \(pattern) ESCAPE '!'" }.joined(separator: " OR ")
    }

    /// How many rows of `table` hold `text` in one of `columns`.
    public static func countContaining(_ text: String, in table: DatabaseObject, columns: [String],
                                       noBackslashEscapes: Bool) -> String {
        "SELECT COUNT(*) FROM \(table.quoted) WHERE " + contains(text, columns: columns, noBackslashEscapes: noBackslashEscapes)
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
