import CMariaDB
import Foundation

/// A piece of AirSQL's own export: what a file gets, and what another server runs when copying.
public enum SQLPiece: Equatable, Sendable {
    /// A line for people ("Table orders"): files only.
    case comment(String)
    /// A statement, without its delimiter.
    case statement(String)
    /// A routine, trigger or event: its body holds semicolons, so a file puts it between DELIMITER lines.
    case routine(String)

    /// As a file for the mysql client (or Run SQL File) holds it.
    public var fileText: String {
        switch self {
        case .comment(let text): return "-- " + text + "\n"
        case .statement(let sql): return sql + ";\n"
        case .routine(let sql): return "DELIMITER ;;\n" + sql + " ;;\nDELIMITER ;\n"
        }
    }
}

/// Where an export goes: a file (`SQLFileSink`) or another server (Copy to Another Server).
public protocol SQLSink: AnyObject {
    func write(_ piece: SQLPiece) async throws
    /// From the reading session's own thread, inside a stream's batch: may block that thread until written.
    func writeNow(_ pieces: [SQLPiece]) throws
}

/// An export into a file, through gzip when asked (`Runner.Writer`).
public final class SQLFileSink: SQLSink {
    public let writer: Runner.Writer

    public init(_ writer: Runner.Writer) { self.writer = writer }

    public func write(_ piece: SQLPiece) async throws { try writer.write(piece.fileText) }
    public func writeNow(_ pieces: [SQLPiece]) throws { try pieces.forEach { try writer.write($0.fileText) } }
}

/// AirSQL's own SQL export, without client tools (plan §2.9; scope: built-in SQL export, copy straight to another
/// server): the tables' CREATE statements and their rows as INSERTs of about 1 MB, then views (in dependency order),
/// routines, triggers and events, read in one consistent snapshot through a session of its own, as mysqldump would.
/// Values are written by type: numbers as they are, binary as X'…', BIT as b'…', the rest as quoted strings; generated
/// columns are left out of the INSERTs, invisible ones are kept.
public enum SQLExport {
    public struct Progress: Equatable, Sendable {
        public var table: String
        /// Rows written so far, of about `totalRows` (information_schema's estimate).
        public var rows: Int64
        public var totalRows: Int64
    }

    /// The largest INSERT written, in bytes of SQL (mysqldump's net_buffer_length is 1 MB too).
    static let statementSize = 1 << 20

    /// Exports `request` from `source` (a session of its own: its time zone and transaction are set here) into `sink`.
    /// `names` maps each database to the name to create and use; nil writes a file: no CREATE DATABASE or USE for one
    /// database (so it restores into any), each database's own for several.
    public static func run(_ request: DumpRequest, from source: DBConnection, into sink: SQLSink, names: [String: String]? = nil,
                           cancellation: Cancellation, progress: @escaping (Progress) -> Void) async throws {
        let quote = { (text: String) in SQLQuote.string(text, noBackslashEscapes: source.noBackslashEscapes) }
        _ = try await source.query("SET SESSION time_zone = '+00:00'")
        if request.singleTransaction {
            _ = try await source.query("SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ")
            _ = try await source.query("START TRANSACTION WITH CONSISTENT SNAPSHOT")
        }
        let server = source.server.map { ($0.flavor == .mysql ? "MySQL " : "MariaDB ") + $0.version } ?? "the server"
        try await sink.write(.comment("AirSQL export of \(request.databases.joined(separator: ", ")) from \(server)"))
        for statement in ["SET NAMES utf8mb4", "SET TIME_ZONE = '+00:00'", "SET FOREIGN_KEY_CHECKS = 0", "SET UNIQUE_CHECKS = 0",
                          "SET SQL_MODE = 'NO_AUTO_VALUE_ON_ZERO'"] {
            try await sink.write(.statement(statement))
        }
        var done = Progress(table: "", rows: 0, totalRows: 0)
        for database in request.databases {
            // Made current, so SHOW CREATE writes the database's own names without it (views and routines then restore
            // into any database), as mysqldump does.
            _ = try await source.query("USE " + SQLQuote.identifier(database))
            let tables = try await rows(source, "SELECT TABLE_NAME, TABLE_TYPE, TABLE_ROWS FROM information_schema.TABLES "
                                        + "WHERE TABLE_SCHEMA = \(quote(database)) ORDER BY TABLE_NAME")
                .filter { request.tables.isEmpty || request.tables.contains($0[0] ?? "") }
            done.totalRows += tables.reduce(0) { $0 + (Int64($1[2] ?? "") ?? 0) }
            let target = names?[database] ?? database
            // Views and routines name their tables with the database's name: the copy's, when it has another.
            let renamed = { (sql: String) in
                target == database ? sql : sql.replacingOccurrences(of: SQLQuote.identifier(database) + ".",
                                                                    with: SQLQuote.identifier(target) + ".")
            }
            try await sink.write(.comment("Database \(target)"))
            if names != nil || request.databases.count > 1, request.content != .data {
                // "CREATE DATABASE `shop` /*!40100 DEFAULT CHARACTER SET …*/": its options, for the name it gets.
                let create = try await rows(source, "SHOW CREATE DATABASE " + SQLQuote.identifier(database)).first?[1] ?? ""
                let options = create.range(of: SQLQuote.identifier(database)).map { String(create[$0.upperBound...]) } ?? ""
                try await sink.write(.statement("CREATE DATABASE IF NOT EXISTS " + SQLQuote.identifier(target) + options))
            }
            if names != nil || request.databases.count > 1 { try await sink.write(.statement("USE " + SQLQuote.identifier(target))) }
            var views: [(name: String, sql: String)] = []
            for table in tables {
                guard let name = table[0] else { continue }
                if cancellation.isCancelled { throw AirSQLError.cancelled }
                if table[1] == "VIEW" {
                    if request.content != .data, request.objects,
                       let sql = try await rows(source, "SHOW CREATE VIEW " + SQLQuote.identifier(database, name)).first?[1] {
                        views.append((name, renamed(sql)))
                    }
                    continue
                }
                if request.content != .data {
                    try await sink.write(.comment("Table \(name)"))
                    if request.addDropTable { try await sink.write(.statement("DROP TABLE IF EXISTS " + SQLQuote.identifier(name))) }
                    let create = try await rows(source, "SHOW CREATE TABLE " + SQLQuote.identifier(database, name)).first?[1] ?? ""
                    try await sink.write(.statement(create))
                }
                guard request.content != .structure, table[1] != "SEQUENCE" else { continue }
                done.table = name
                progress(done)
                try await copyRows(of: name, in: database, from: source, into: sink, cancellation: cancellation) { count in
                    done.rows += count
                    progress(done)
                }
            }
            guard request.content != .data, request.objects else { continue }
            for view in ordered(views) {
                try await sink.write(.comment("View \(view.name)"))
                if request.addDropTable { try await sink.write(.statement("DROP VIEW IF EXISTS " + SQLQuote.identifier(view.name))) }
                try await sink.write(.statement(view.sql))
            }
            try await writeObjects(of: database, from: source, into: sink, tables: Set(tables.compactMap { $0[0] }),
                                   addDrop: request.addDropTable, renamed: renamed, quote: quote)
        }
        try await sink.write(.statement("SET FOREIGN_KEY_CHECKS = 1"))
        try await sink.write(.statement("SET UNIQUE_CHECKS = 1"))
        if request.singleTransaction { _ = try await source.query("COMMIT") }
    }

    /// Routines, then the exported tables' triggers, then events.
    private static func writeObjects(of database: String, from source: DBConnection, into sink: SQLSink, tables: Set<String>,
                                     addDrop: Bool, renamed: (String) -> String, quote: (String) -> String) async throws {
        let routines = try await rows(source, "SELECT ROUTINE_NAME, ROUTINE_TYPE FROM information_schema.ROUTINES "
                                      + "WHERE ROUTINE_SCHEMA = \(quote(database)) ORDER BY ROUTINE_TYPE, ROUTINE_NAME")
        for routine in routines {
            guard let name = routine[0], let kind = routine[1], kind == "PROCEDURE" || kind == "FUNCTION" else { continue }
            if addDrop { try await sink.write(.statement("DROP \(kind) IF EXISTS " + SQLQuote.identifier(name))) }
            guard let sql = try await rows(source, "SHOW CREATE \(kind) " + SQLQuote.identifier(database, name)).first?[2] else {
                try await sink.write(.comment("\(kind.capitalized) \(name): its definition can't be read with this account"))
                continue
            }
            try await sink.write(.routine(renamed(sql)))
        }
        let triggers = try await rows(source, "SELECT TRIGGER_NAME, EVENT_OBJECT_TABLE FROM information_schema.TRIGGERS "
                                      + "WHERE TRIGGER_SCHEMA = \(quote(database)) ORDER BY EVENT_OBJECT_TABLE, ACTION_ORDER")
        for trigger in triggers where tables.contains(trigger[1] ?? "") {
            guard let name = trigger[0] else { continue }
            if addDrop { try await sink.write(.statement("DROP TRIGGER IF EXISTS " + SQLQuote.identifier(name))) }
            if let sql = try await rows(source, "SHOW CREATE TRIGGER " + SQLQuote.identifier(database, name)).first?[2] {
                try await sink.write(.routine(renamed(sql)))
            }
        }
        let events = try await rows(source, "SELECT EVENT_NAME FROM information_schema.EVENTS WHERE EVENT_SCHEMA = \(quote(database)) "
                                    + "ORDER BY EVENT_NAME")
        for event in events {
            guard let name = event[0] else { continue }
            if addDrop { try await sink.write(.statement("DROP EVENT IF EXISTS " + SQLQuote.identifier(name))) }
            if let sql = try await rows(source, "SHOW CREATE EVENT " + SQLQuote.identifier(database, name)).first?[3] {
                try await sink.write(.routine(renamed(sql)))
            }
        }
    }

    /// The table's rows as INSERTs of about `statementSize` bytes, streamed from the server; `counted` gets each batch's
    /// row count.
    static func copyRows(of table: String, in database: String, from source: DBConnection, into sink: SQLSink,
                         cancellation: Cancellation, counted: @escaping (Int64) -> Void) async throws {
        let quote = { (text: String) in SQLQuote.string(text, noBackslashEscapes: source.noBackslashEscapes) }
        let columns = try await rows(source, "SELECT COLUMN_NAME, EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = "
                                     + "\(quote(database)) AND TABLE_NAME = \(quote(table)) ORDER BY ORDINAL_POSITION")
            .filter { !isGenerated($0[1] ?? "") }.compactMap { $0[0] }
        guard !columns.isEmpty else { return }
        let list = columns.map { SQLQuote.identifier($0) }.joined(separator: ", ")
        let insert = "INSERT INTO \(SQLQuote.identifier(table)) (\(list)) VALUES "
        var pending = ""
        try await source.stream("SELECT \(list) FROM \(SQLQuote.identifier(database, table))", batchRows: 1_000) { store in
            if cancellation.isCancelled { throw AirSQLError.cancelled }
            var ready: [SQLPiece] = []
            for row in 0..<store.rowCount {
                pending += (pending.isEmpty ? insert : ",") + "(" + (0..<store.columns.count).map { literal(store, row, $0) }
                    .joined(separator: ",") + ")"
                if pending.utf8.count >= statementSize {
                    ready.append(.statement(pending))
                    pending = ""
                }
            }
            try sink.writeNow(ready)
            counted(Int64(store.rowCount))
        }
        if !pending.isEmpty { try await sink.write(.statement(pending)) }
    }

    /// information_schema.COLUMNS.EXTRA of a generated column (VIRTUAL GENERATED, STORED GENERATED, MariaDB's PERSISTENT),
    /// not of one whose default is an expression (MySQL's DEFAULT_GENERATED).
    static func isGenerated(_ extra: String) -> Bool {
        let extra = extra.uppercased()
        return extra.contains("VIRTUAL") || extra.contains("STORED GENERATED") || extra.contains("PERSISTENT")
    }

    /// A value as SQL: numbers as the server wrote them, BIT as b'…', binary as X'…', the rest as a quoted string (the
    /// export's own sql_mode keeps backslash escapes).
    static func literal(_ store: ResultStore, _ row: Int, _ column: Int) -> String {
        if store.isNull(row, column) { return "NULL" }
        let info = store.columns[column]
        switch info.type {
        case MYSQL_TYPE_TINY, MYSQL_TYPE_SHORT, MYSQL_TYPE_LONG, MYSQL_TYPE_LONGLONG, MYSQL_TYPE_INT24, MYSQL_TYPE_FLOAT,
             MYSQL_TYPE_DOUBLE, MYSQL_TYPE_DECIMAL, MYSQL_TYPE_NEWDECIMAL, MYSQL_TYPE_YEAR:
            return store.string(row, column) ?? "NULL"
        case MYSQL_TYPE_BIT:
            return SQLQuote.bits((store.bytes(row, column) ?? []).reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        case MYSQL_TYPE_JSON:  // MySQL sends JSON with the binary character set: it is text all the same
            return SQLQuote.string(store.string(row, column) ?? "")
        default:
            if info.isBinary { return SQLQuote.hex(store.bytes(row, column) ?? []) }
            return SQLQuote.string(store.string(row, column) ?? "")
        }
    }

    /// Views after the views they name.
    static func ordered(_ views: [(name: String, sql: String)]) -> [(name: String, sql: String)] {
        var left = views, result: [(name: String, sql: String)] = []
        while !left.isEmpty {
            let next = left.firstIndex { view in
                !left.contains { $0.name != view.name && view.sql.contains(SQLQuote.identifier($0.name)) }
            } ?? 0
            result.append(left.remove(at: next))
        }
        return result
    }

    /// Every row of a statement's result as text (NULL as nil).
    static func rows(_ session: DBConnection, _ sql: String) async throws -> [[String?]] {
        guard let store = try await session.query(sql, rowCap: .max).first?.rows else { return [] }
        return (0..<store.rowCount).map { row in (0..<store.columns.count).map { store.isNull(row, $0) ? nil : store.string(row, $0) } }
    }
}
