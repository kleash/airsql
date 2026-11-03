import Darwin
import Foundation

/// How a changelog came out.
public struct LiquibaseOutcome: Equatable, Sendable {
    public var changesets = 0
    public var rows: Int64 = 0
    public var bytes: Int64 = 0
}

/// How far writing a changelog is: changesets written, and the table whose rows are being read.
public struct LiquibaseProgress: Equatable, Sendable {
    public var changesets = 0
    public var total = 0
    public var table = ""
    public var rows: Int64 = 0
    public var totalRows: Int64 = 0
}

extension LiquibaseSchema {
    /// Reads `database` through `session` (one of its own: it is made to use the database, in UTC as the rows are
    /// read) with SHOW CREATE for each object `include` keeps; one this login can't read gets an empty definition.
    public static func read(_ database: String, from session: DBConnection,
                            include: @escaping (Object.Kind, String) -> Bool = { _, _ in true },
                            progress: @escaping (Int, Int) -> Void = { _, _ in }) async throws -> LiquibaseSchema {
        _ = try await session.query("SET SESSION time_zone = '+00:00'")
        // Made current, so SHOW CREATE names the database's own objects without it: the changelog runs in any database.
        _ = try await session.query("USE " + SQLQuote.identifier(database))
        let cache = SchemaCache(source: session, includes: { $0 == database })
        try await cache.load()
        try await cache.loadDetails([database])
        try await cache.loadStatistics(database)
        guard let found = cache.snapshot.database(database) else {
            throw AirSQLError(.other, "There is no database \(database), or this login can't see it")
        }
        var wanted: [(Object.Kind, String, Int)] = []
        for table in found.tables {
            let kind: Object.Kind = table.kind == .view ? .view : table.kind == .sequence ? .sequence : .table
            wanted.append((kind, table.name, kind == .table || kind == .view || kind == .sequence ? 1 : 2))
        }
        wanted += found.routines.map { (Object.Kind(rawValue: $0.kind.rawValue) ?? .procedure, $0.name, 2) }
        wanted += found.triggers.map { (Object.Kind.trigger, $0.name, 2) }
        wanted += found.events.map { (Object.Kind.event, $0.name, 3) }
        wanted = wanted.filter { include($0.0, $0.1) }
        var objects: [Object] = []
        for (done, (kind, name, column)) in wanted.enumerated() {
            progress(done, wanted.count)
            try Task.checkCancellation()
            var object = Object(kind: kind, name: name, create: try await showCreate(session, kind, name, column: column))
            if kind == .table, let table = found.table(name) {
                object.references = table.foreignKeys.filter { $0.referencedDatabase == database && $0.referencedTable != name }
                    .map(\.referencedTable)
                object.columns = table.columns.filter { $0.generated == nil }.map(\.name)
                object.key = rowKey(table)
                object.rows = Int64(found.statistics?[name]?.rows ?? 0)
            }
            objects.append(object)
        }
        progress(wanted.count, wanted.count)
        return LiquibaseSchema(database: database, objects: objects)
    }

    /// The columns rows are read in order of: the primary key, else a unique key of NOT NULL columns; none without.
    static func rowKey(_ table: SchemaTable) -> [String] {
        let unique = table.indexes.first { index in
            index.unique && !index.parts.isEmpty && index.parts.allSatisfy { part in
                part.column.flatMap { table.column($0) }.map { !$0.nullable } ?? false
            }
        }
        return (table.primaryKey ?? unique)?.parts.compactMap(\.column) ?? []
    }

    private static func showCreate(_ session: DBConnection, _ kind: Object.Kind, _ name: String, column: Int) async throws -> String {
        do {
            let rows = try await session.rows("SHOW CREATE \(kind.rawValue.uppercased()) " + SQLQuote.identifier(name))
            return rows.first.flatMap { $0.count > column ? $0[column] : nil } ?? ""
        } catch let error as AirSQLError where error.kind != .cancelled && error.kind != .disconnected {
            return ""  // this login may not read it (a routine of another definer): left out
        }
    }

    /// The changelog as the sheet previews it: what will be written, with each table's rows stood in for by a line
    /// saying how many there are about to be (they are read when it is saved).
    public func preview(_ pieces: [LiquibasePiece], settings: LiquibaseSettings, date: Date = Date()) -> String {
        let numbered = Self.numbered(pieces, settings: settings, date: date)
        return ([LiquibaseChangelog.header + "\n"] + zip(pieces, numbered).map { piece, changeset in
            guard case .rows(let table) = piece else { return changeset.text(settings.delimiter) }
            let estimate = objects.first { $0.name == table && $0.kind == .table }?.rows ?? 0
            return "--changeset \(changeset.author):\(changeset.id)\n-- The rows of \(table) (about \(estimate)) are read when you save: "
                + "INSERTs of \(LiquibaseSchema.batchRows) rows each, in key order\n"
        }).joined(separator: "\n")
    }

    /// Rows per INSERT in a data changeset.
    public static let batchRows = 100

    static func numbered(_ pieces: [LiquibasePiece], settings: LiquibaseSettings, date: Date) -> [LiquibaseChangeset] {
        Liquibase.numbered(pieces.map { piece in
            switch piece {
            case .changeset(let changeset): return changeset
            case .rows(let table): return LiquibaseChangeset(object: table + "-rows", statements: [])
            }
        }, settings: settings, date: date)
    }

    /// Writes the changelog of `pieces` to `url` (a file; a folder in the folder layout), each changeset checked first,
    /// reading a table's rows through `session` when it comes to them: in key order, `filters`' WHERE condition by
    /// table, in INSERTs of `batchRows` rows. A table without rows gets no changeset.
    public func write(_ pieces: [LiquibasePiece], settings: LiquibaseSettings, filters: [String: String] = [:], to url: URL,
                      from session: DBConnection?, date: Date = Date(), cancellation: Cancellation,
                      progress: @escaping (LiquibaseProgress) -> Void = { _ in }) async throws -> LiquibaseOutcome {
        let numbered = Self.numbered(pieces, settings: settings, date: date)
        let rows = pieces.contains { if case .rows = $0 { return true } else { return false } }
        if rows, let session {
            // Every table's rows as of one moment, in UTC as the changesets write them.
            for statement in ["SET SESSION time_zone = '+00:00'", "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ",
                              "START TRANSACTION WITH CONSISTENT SNAPSHOT"] {
                _ = try await session.query(statement)
            }
        }
        let files = try LiquibaseFiles(url, layout: settings.layout)
        var outcome = LiquibaseOutcome(), state = LiquibaseProgress(total: pieces.count)
        do {
            for (piece, changeset) in zip(pieces, numbered) {
                if cancellation.isCancelled { throw AirSQLError.cancelled }
                switch piece {
                case .changeset:
                    let text = try changeset.checkedText(settings.delimiter)
                    try files.begin(changeset)
                    try files.write(text)
                    outcome.changesets += 1
                case .rows(let name):
                    guard let session, let table = objects.first(where: { $0.name == name && $0.kind == .table }) else { continue }
                    state.table = name
                    state.totalRows += table.rows
                    progress(state)
                    let rows = try await writeRows(table, changeset, filter: filters[name], files: files, session: session,
                                                   cancellation: cancellation) { count in
                        state.rows += count
                        progress(state)
                    }
                    if rows > 0 { outcome.changesets += 1 }
                    outcome.rows += rows
                }
                state.changesets += 1
                progress(state)
            }
            if rows, let session { _ = try await session.query("COMMIT") }
            outcome.bytes = try files.finish()
            return outcome
        } catch {
            if rows, let session { _ = try? await session.query("ROLLBACK") }
            files.discard()
            throw cancellation.isCancelled ? AirSQLError.cancelled : error
        }
    }

    /// One table's rows as a changeset, written as they stream in; begun only once there is a first row.
    private func writeRows(_ table: Object, _ changeset: LiquibaseChangeset, filter: String?, files: LiquibaseFiles,
                           session: DBConnection, cancellation: Cancellation,
                           counted: @escaping (Int64) -> Void) async throws -> Int64 {
        guard !table.columns.isEmpty else { return 0 }
        let q = SQLQuote.identifier, list = table.columns.map { q($0) }.joined(separator: ", ")
        var sql = "SELECT \(list) FROM \(SQLQuote.identifier(database, table.name))"
        if let filter = filter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty { sql += " WHERE (\(filter))" }
        if !table.key.isEmpty { sql += " ORDER BY " + table.key.map { q($0) }.joined(separator: ", ") }
        let insert = "INSERT INTO \(q(table.name)) (\(list)) VALUES\n"
        let head = "--changeset \(changeset.author):\(changeset.id)\n" + Liquibase.sessionHead().map { $0 + ";\n" }.joined()
        var batch: [String] = [], total: Int64 = 0
        func flush() throws {
            guard !batch.isEmpty else { return }
            if total == Int64(batch.count) {
                try files.begin(changeset)
                try files.write(head)
            }
            try files.write(insert + batch.joined(separator: ",\n") + ";\n")
            batch = []
        }
        try await session.stream(sql, batchRows: 1_000) { store in
            if cancellation.isCancelled { throw AirSQLError.cancelled }
            for row in 0..<store.rowCount {
                batch.append("(" + (0..<store.columns.count).map { SQLExport.literal(store, row, $0) }.joined(separator: ",") + ")")
                total += 1
                if batch.count == Self.batchRows { try flush() }
            }
            counted(Int64(store.rowCount))
        }
        try flush()
        if total > 0 { try files.write(Liquibase.sessionTail + ";\n") }
        return total
    }
}

/// Where a changelog is written: one file, or a folder with a file per changeset and the master changelog that
/// includes them in order. Everything is written under hidden names first and takes its own once complete, so a run
/// that fails or is stopped leaves nothing behind.
final class LiquibaseFiles {
    private let target: URL
    private let layout: LiquibaseSettings.Layout
    /// The hidden file (one file) or folder (inside the folder) written first.
    private let staging: URL
    private var fd: Int32 = -1
    private var writer: Runner.Writer?
    private var files: [String] = []
    private var bytes: Int64 = 0

    init(_ target: URL, layout: LiquibaseSettings.Layout) throws {
        self.target = target
        self.layout = layout
        let tag = UUID().uuidString.prefix(6)
        if layout == .oneFile {
            staging = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(tag).part")
            try open(staging)
            try write(LiquibaseChangelog.header + "\n")
        } else {
            staging = target.appendingPathComponent(".airsql-\(tag).part")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        }
    }

    /// Starts a changeset: a blank line before it, or (folder layout) a file of its own.
    func begin(_ changeset: LiquibaseChangeset) throws {
        guard layout == .folder else { return try write("\n") }
        let name = Liquibase.fileName(changeset)
        files.append(name)
        try open(staging.appendingPathComponent(name))
        try write(LiquibaseChangelog.header + "\n\n")
    }

    func write(_ text: String) throws {
        guard let writer else { return }
        try writer.write(text)
    }

    /// Puts everything in place; the bytes written.
    func finish() throws -> Int64 {
        closeFile()
        if layout == .oneFile {
            try move(staging, to: target)
        } else {
            try Liquibase.master(files).write(to: staging.appendingPathComponent(Liquibase.masterName), atomically: false, encoding: .utf8)
            for name in files + [Liquibase.masterName] {
                try move(staging.appendingPathComponent(name), to: target.appendingPathComponent(name))
            }
            try? FileManager.default.removeItem(at: staging)
        }
        return bytes
    }

    func discard() {
        closeFile()
        try? FileManager.default.removeItem(at: staging)
    }

    private func open(_ url: URL) throws {
        closeFile()
        fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw AirSQLError(.other, "Can't write in \(url.deletingLastPathComponent().path): \(String(cString: strerror(errno)))")
        }
        writer = try Runner.Writer(file: fd, through: nil, cancellation: Cancellation())
    }

    private func closeFile() {
        if let writer { bytes += writer.bytes }
        writer = nil
        if fd >= 0 { close(fd) }
        fd = -1
    }

    private func move(_ from: URL, to: URL) throws {
        guard rename(from.path, to.path) == 0 else {
            throw AirSQLError(.other, "Can't save \(to.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }
}
