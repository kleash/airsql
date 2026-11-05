import CMariaDB
import Darwin
import Foundation

/// A piece of AirSQL's own export: what a file gets, and what another server runs when copying.
public enum SQLPiece: Equatable, Sendable {
    /// A line for people ("Table orders"): files only.
    case comment(String)
    /// A statement, without its delimiter.
    case statement(String)
    /// A routine, trigger or event: its body holds semicolons, so a file puts it between DELIMITER lines.
    case routine(String)
    /// What follows belongs to this object, for a folder of files; nil: to no object.
    case object(String?)

    /// As a file for the mysql client (or Run SQL File) holds it.
    public var fileText: String {
        switch self {
        case .comment(let text): return "-- " + text + "\n"
        case .statement(let sql): return sql + ";\n"
        case .routine(let sql): return "DELIMITER ;;\n" + sql + " ;;\nDELIMITER ;\n"
        case .object: return ""
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

/// An export into a folder: a file for each object, each starting with what came before the first object (the session's
/// settings, the database to use), so it restores on its own.
public final class SQLFolderSink: SQLSink {
    private let folder: URL
    private let gzip: Bool
    private let cancellation: Cancellation
    private var prelude: [SQLPiece] = []
    /// What every file starts with, without any one database's CREATE and USE.
    private var settings: [SQLPiece]?
    private var current: (fd: Int32, writer: Runner.Writer)?
    public private(set) var bytes: Int64 = 0

    public init(_ folder: URL, gzip: Bool, cancellation: Cancellation) {
        self.folder = folder
        self.gzip = gzip
        self.cancellation = cancellation
    }

    /// `name` as one file's name: nothing a path would read as a folder or a hidden file.
    public static func fileName(_ name: String) -> String {
        let safe = String(name.map { "/:\\\0".contains($0) ? "_" : $0 })
        return safe.hasPrefix(".") ? "_" + safe.dropFirst() : safe
    }

    public func write(_ piece: SQLPiece) async throws { try writeOne(piece) }
    public func writeNow(_ pieces: [SQLPiece]) throws { try pieces.forEach(writeOne) }

    private func writeOne(_ piece: SQLPiece) throws {
        if case .object(let name) = piece {
            try closeCurrent()
            if let name {
                try open(name)
            } else if let settings {
                prelude = settings
            } else {
                settings = prelude
            }
        } else if let current {
            try current.writer.write(piece.fileText)
        } else {
            prelude.append(piece)
        }
    }

    /// The next free name: two objects can differ only in case, or in what `fileName` replaces.
    private func open(_ name: String) throws {
        let safe = Self.fileName(name), ending = gzip ? ".sql.gz" : ".sql"
        var path = folder.appendingPathComponent(safe + ending).path, copy = 1
        var fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        while fd < 0 && errno == EEXIST {
            copy += 1
            path = folder.appendingPathComponent(safe + "_\(copy)" + ending).path
            fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        }
        guard fd >= 0 else { throw AirSQLError(.other, "Can't write in \(folder.path): \(String(cString: strerror(errno)))") }
        let writer = try Runner.Writer(file: fd, through: gzip ? ["/usr/bin/gzip", "-c"] : nil, cancellation: cancellation)
        current = (fd, writer)
        for piece in prelude { try writer.write(piece.fileText) }
    }

    /// Ends the file being written.
    public func closeCurrent() throws {
        guard let open = current else { return }
        current = nil
        bytes += open.writer.bytes
        let gzip = open.writer.finish()
        close(open.fd)
        if let gzip, gzip.status != 0 { throw AirSQLError(.other, "gzip stopped: " + gzip.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

/// An export kept as text, for the clipboard: small dumps only.
public final class SQLTextSink: SQLSink {
    public private(set) var text = ""
    static let limit = 32 << 20

    public init() {}

    public func write(_ piece: SQLPiece) async throws { try writeNow([piece]) }

    public func writeNow(_ pieces: [SQLPiece]) throws {
        for piece in pieces { text += piece.fileText }
        if text.utf8.count > Self.limit {
            throw AirSQLError(.other, "That's too much for the clipboard (over 32 MB): export to a file instead.")
        }
    }
}

/// An export run on another server as it is read (Copy to Another Server): each statement through the target's session.
public final class SQLServerSink: SQLSink {
    public let session: DBConnection

    public init(_ session: DBConnection) { self.session = session }

    public func write(_ piece: SQLPiece) async throws {
        switch piece {
        case .comment, .object: return
        case .statement(let sql), .routine(let sql): _ = try await session.query(sql)
        }
    }

    /// Blocks the reading session's thread (not one of Swift's) until the target has run `pieces`: the source's rows
    /// wait for the target rather than pile up in memory.
    public func writeNow(_ pieces: [SQLPiece]) throws {
        guard !pieces.isEmpty else { return }
        let done = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        Task {
            do {
                for piece in pieces { try await write(piece) }
            } catch {
                outcome.set(error)
            }
            done.signal()
        }
        done.wait()
        if let error = outcome.error { throw error }
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Error?
        var error: Error? { lock.locked { stored } }
        func set(_ error: Error) { lock.locked { stored = error } }
    }
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
    public static let statementSize = 1 << 20

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
        let server = source.server.map { $0.flavor.title + " " + $0.version } ?? "the server"
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
            let tables = try await source.rows("SELECT TABLE_NAME, TABLE_TYPE, TABLE_ROWS FROM information_schema.TABLES "
                                        + "WHERE TABLE_SCHEMA = \(quote(database)) ORDER BY TABLE_NAME")
                .filter { request.tables.isEmpty || request.tables.contains($0[0] ?? "") }
            done.totalRows += tables.reduce(0) { $0 + (Int64($1[2] ?? "") ?? 0) }
            let target = names?[database] ?? database
            // Objects of several databases can share a name.
            let fileName = { (name: String) in request.databases.count > 1 ? target + "." + name : name }
            let cleaned = { (sql: String) in request.removeDefiner ? withoutDefiner(sql) : sql }
            // Views and routines name their tables with the database's name: the copy's, when it has another.
            let renamed = { (sql: String) in
                target == database ? sql : sql.replacingOccurrences(of: SQLQuote.identifier(database) + ".",
                                                                    with: SQLQuote.identifier(target) + ".")
            }
            try await sink.write(.comment("Database \(target)"))
            try await sink.write(.object(nil))
            let named = names != nil || request.databases.count > 1 || request.createDatabase
            if request.dropDatabase, request.tables.isEmpty, request.content != .data {
                try await sink.write(.statement("DROP DATABASE IF EXISTS " + SQLQuote.identifier(target)))
            }
            if named, request.content != .data {
                // "CREATE DATABASE `shop` /*!40100 DEFAULT CHARACTER SET …*/": its options, for the name it gets.
                let create = try await source.rows("SHOW CREATE DATABASE " + SQLQuote.identifier(database)).first?[1] ?? ""
                let options = create.range(of: SQLQuote.identifier(database)).map { String(create[$0.upperBound...]) } ?? ""
                try await sink.write(.statement("CREATE DATABASE IF NOT EXISTS " + SQLQuote.identifier(target) + options))
            }
            if named { try await sink.write(.statement("USE " + SQLQuote.identifier(target))) }
            var views: [(name: String, sql: String)] = []
            for table in tables {
                guard let name = table[0] else { continue }
                if cancellation.isCancelled { throw AirSQLError.cancelled }
                if table[1] == "VIEW" {
                    if request.content != .data, request.objects,
                       let sql = try await source.rows("SHOW CREATE VIEW " + SQLQuote.identifier(database, name)).first?[1] {
                        views.append((name, renamed(cleaned(sql))))
                    }
                    continue
                }
                try await sink.write(.object(fileName(name)))
                if request.content != .data {
                    try await sink.write(.comment("Table \(name)"))
                    if request.addDropTable { try await sink.write(.statement("DROP TABLE IF EXISTS " + SQLQuote.identifier(name))) }
                    let create = try await source.rows("SHOW CREATE TABLE " + SQLQuote.identifier(database, name)).first?[1] ?? ""
                    try await sink.write(.statement(request.removeAutoIncrement ? withoutAutoIncrement(create) : create))
                }
                guard request.content != .structure, table[1] != "SEQUENCE" else { continue }
                done.table = name
                progress(done)
                if request.wrapInTransactions { try await sink.write(.statement("START TRANSACTION")) }
                if request.dataMode == .deleteInsert { try await sink.write(.statement("DELETE FROM " + SQLQuote.identifier(name))) }
                try await copyRows(of: name, in: database, from: source, into: sink, verb: request.dataMode.verb, size: request.insertSize,
                                   cancellation: cancellation) { count in
                    done.rows += count
                    progress(done)
                }
                if request.wrapInTransactions { try await sink.write(.statement("COMMIT")) }
            }
            guard request.content != .data, request.objects else { continue }
            for view in ordered(views) {
                try await sink.write(.object(fileName(view.name)))
                try await sink.write(.comment("View \(view.name)"))
                if request.addDropTable { try await sink.write(.statement("DROP VIEW IF EXISTS " + SQLQuote.identifier(view.name))) }
                try await sink.write(.statement(view.sql))
            }
            try await writeObjects(of: database, from: source, into: sink, tables: Set(tables.compactMap { $0[0] }),
                                   addDrop: request.addDropTable, renamed: { renamed(cleaned($0)) }, fileName: fileName, quote: quote)
        }
        try await sink.write(.object(nil))
        try await sink.write(.statement("SET FOREIGN_KEY_CHECKS = 1"))
        try await sink.write(.statement("SET UNIQUE_CHECKS = 1"))
        if request.singleTransaction { _ = try await source.query("COMMIT") }
    }

    /// `sql` without its DEFINER clause, so the object takes the account that restores it.
    static func withoutDefiner(_ sql: String) -> String {
        guard let definer = CreateHeader(sql)?.definer else { return sql }
        var text = sql
        let end = text[definer.upperBound...].first == " " ? text.index(after: definer.upperBound) : definer.upperBound
        text.removeSubrange(definer.lowerBound..<end)
        return text
    }

    /// `create` (SHOW CREATE TABLE's) without the table's next AUTO_INCREMENT value, which comes first after the columns.
    static func withoutAutoIncrement(_ create: String) -> String {
        guard let columnsEnd = create.range(of: "\n)", options: .backwards),
              let value = create.range(of: " AUTO_INCREMENT=[0-9]+", options: .regularExpression, range: columnsEnd.upperBound..<create.endIndex)
        else { return create }
        return create.replacingCharacters(in: value, with: "")
    }

    /// Routines, then the exported tables' triggers, then events.
    private static func writeObjects(of database: String, from source: DBConnection, into sink: SQLSink, tables: Set<String>,
                                     addDrop: Bool, renamed: (String) -> String, fileName: (String) -> String,
                                     quote: (String) -> String) async throws {
        let routines = try await source.rows("SELECT ROUTINE_NAME, ROUTINE_TYPE FROM information_schema.ROUTINES "
                                      + "WHERE ROUTINE_SCHEMA = \(quote(database)) ORDER BY ROUTINE_TYPE, ROUTINE_NAME")
        for routine in routines {
            guard let name = routine[0], let kind = routine[1], kind == "PROCEDURE" || kind == "FUNCTION" else { continue }
            try await sink.write(.object(fileName(name)))
            if addDrop { try await sink.write(.statement("DROP \(kind) IF EXISTS " + SQLQuote.identifier(name))) }
            guard let sql = try await source.rows("SHOW CREATE \(kind) " + SQLQuote.identifier(database, name)).first?[2] else {
                try await sink.write(.comment("\(kind.capitalized) \(name): its definition can't be read with this account"))
                continue
            }
            try await sink.write(.routine(renamed(sql)))
        }
        let triggers = try await source.rows("SELECT TRIGGER_NAME, EVENT_OBJECT_TABLE FROM information_schema.TRIGGERS "
                                      + "WHERE TRIGGER_SCHEMA = \(quote(database)) ORDER BY EVENT_OBJECT_TABLE, ACTION_ORDER")
        for trigger in triggers where tables.contains(trigger[1] ?? "") {
            guard let name = trigger[0] else { continue }
            try await sink.write(.object(fileName(name)))
            if addDrop { try await sink.write(.statement("DROP TRIGGER IF EXISTS " + SQLQuote.identifier(name))) }
            if let sql = try await source.rows("SHOW CREATE TRIGGER " + SQLQuote.identifier(database, name)).first?[2] {
                try await sink.write(.routine(renamed(sql)))
            }
        }
        let events = try await source.rows("SELECT EVENT_NAME FROM information_schema.EVENTS WHERE EVENT_SCHEMA = \(quote(database)) "
                                    + "ORDER BY EVENT_NAME")
        for event in events {
            guard let name = event[0] else { continue }
            try await sink.write(.object(fileName(name)))
            if addDrop { try await sink.write(.statement("DROP EVENT IF EXISTS " + SQLQuote.identifier(name))) }
            if let sql = try await source.rows("SHOW CREATE EVENT " + SQLQuote.identifier(database, name)).first?[3] {
                try await sink.write(.routine(renamed(sql)))
            }
        }
    }

    /// The table's rows as INSERTs of about `statementSize` bytes, streamed from the server; `counted` gets each batch's
    /// row count.
    static func copyRows(of table: String, in database: String, from source: DBConnection, into sink: SQLSink, verb: String = "INSERT INTO",
                         size: Int = statementSize, cancellation: Cancellation, counted: @escaping (Int64) -> Void) async throws {
        let quote = { (text: String) in SQLQuote.string(text, noBackslashEscapes: source.noBackslashEscapes) }
        let columns = try await source.rows("SELECT COLUMN_NAME, EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = "
                                     + "\(quote(database)) AND TABLE_NAME = \(quote(table)) ORDER BY ORDINAL_POSITION")
            .filter { !isGenerated($0[1] ?? "") }.compactMap { $0[0] }
        guard !columns.isEmpty else { return }
        let list = columns.map { SQLQuote.identifier($0) }.joined(separator: ", ")
        let insert = "\(verb) \(SQLQuote.identifier(table)) (\(list)) VALUES "
        var pending = ""
        try await source.stream("SELECT \(list) FROM \(SQLQuote.identifier(database, table))", batchRows: 1_000) { store in
            if cancellation.isCancelled { throw AirSQLError.cancelled }
            var ready: [SQLPiece] = []
            for row in 0..<store.rowCount {
                pending += (pending.isEmpty ? insert : ",") + "(" + (0..<store.columns.count).map { literal(store, row, $0) }
                    .joined(separator: ",") + ")"
                if pending.utf8.count >= size {
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
    public static func isGenerated(_ extra: String) -> Bool {
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
}
