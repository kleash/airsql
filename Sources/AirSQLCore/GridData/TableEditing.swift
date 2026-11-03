import Foundation
import os

/// What decides whether a table's rows can be edited, and what Apply runs and checks (plan §2.5, R7).
public enum TableEditing {
    /// The columns that tell the table's rows apart: the primary key, else the first unique key whose columns are all
    /// NOT NULL. Nil with the reason the grid shows when there is none: then the table is read-only.
    public static func key(of table: SchemaTable) -> (columns: [String]?, reason: String?) {
        if table.kind != .table {
            return (nil, "Views are read-only in the grid: open the table the view reads from to edit its rows.")
        }
        let candidates = (table.primaryKey.map { [$0] } ?? []) + table.indexes.filter { $0.unique && !$0.isPrimary }
        for index in candidates {
            let names = index.parts.compactMap(\.column)
            guard !names.isEmpty, names.count == index.parts.count,
                  names.allSatisfy({ name in table.column(name).map { !$0.nullable } == true }) else { continue }
            return (names, nil)
        }
        return (nil, "This table has no primary key, and no unique key on columns that can't be NULL, so AirSQL can't "
                + "tell its rows apart: it is read-only here. Add a primary key in the table editor to edit its rows.")
    }

    /// Engines whose changes a ROLLBACK undoes.
    static let transactional: Set<String> = ["innodb", "xtradb", "rocksdb", "tokudb", "ndb", "ndbcluster"]

    /// What the SQL preview warns about before Apply: a table whose engine can't roll back, and the tables that
    /// deleting rows also changes through ON DELETE CASCADE (and SET NULL), following the cascades.
    public static func warnings(_ table: SchemaTable, database: String, deleting: Bool, in snapshot: SchemaSnapshot) -> [String] {
        var warnings: [String] = []
        if let engine = table.engine, !transactional.contains(engine.lowercased()) {
            warnings.append("\(table.name) uses \(engine), which can't roll back: if a statement fails, the ones before it "
                            + "stay applied.")
        }
        guard deleting else { return warnings }
        var touched: [String] = [], queue = [(database, table.name)], seen: Set<String> = [database + "." + table.name]
        while !queue.isEmpty {
            let (parentDatabase, parent) = queue.removeFirst()
            for child in snapshot.databases {
                for childTable in child.tables {
                    for key in childTable.foreignKeys where key.referencedDatabase == parentDatabase && key.referencedTable == parent {
                        let action = key.onDelete.uppercased()
                        guard action == "CASCADE" || action == "SET NULL" else { continue }
                        let name = child.name + "." + childTable.name
                        guard seen.insert(name).inserted else { continue }
                        touched.append("\(child.name == database ? childTable.name : name) (\(action == "CASCADE" ? "rows deleted" : "set to NULL"))")
                        if action == "CASCADE" { queue.append((child.name, childTable.name)) }
                    }
                }
            }
        }
        if !touched.isEmpty {
            warnings.append("Deleting rows also changes " + touched.joined(separator: ", ") + " through their foreign keys.")
        }
        return warnings
    }
}

/// Apply stopped: a statement changed another number of rows than it should (someone else changed or deleted the
/// row since it was loaded) or the server refused it. Nothing was applied: the transaction was rolled back.
public struct ApplyFailure: LocalizedError {
    public var statement: PendingChanges.Statement
    /// The rows it changed instead, when it ran.
    public var changed: UInt64?
    public var error: Error?

    public var errorDescription: String? {
        if let changed {
            let rows = statement.expectedRows == 1 ? "This row" : "One of these rows"
            return "\(rows) was changed or deleted by someone else since it was loaded (the statement changed \(changed) "
                + "of \(statement.expectedRows)), so nothing was applied. Reload the rows, then apply again."
        }
        let message = (error as? AirSQLError)?.message ?? error?.localizedDescription ?? "The server refused a statement."
        return message + " Nothing was applied."
    }
}

extension PendingChanges {
    /// Runs `statements` in one transaction through `run` (which returns each statement's affected rows): each must
    /// change exactly its rows, else everything rolls back and `ApplyFailure` names the statement.
    public static func apply(_ statements: [Statement], run: (String) async throws -> UInt64) async throws {
        _ = try await run("START TRANSACTION")
        for statement in statements {
            let changed: UInt64
            do {
                changed = try await run(statement.sql)
            } catch {
                _ = try? await run("ROLLBACK")
                throw ApplyFailure(statement: statement, changed: nil, error: error)
            }
            guard changed == UInt64(statement.expectedRows) else {
                _ = try? await run("ROLLBACK")
                throw ApplyFailure(statement: statement, changed: changed, error: nil)
            }
        }
        do {
            _ = try await run("COMMIT")
        } catch {
            _ = try? await run("ROLLBACK")
            throw error
        }
    }

    /// Apply on a session (the connection's data session): UPDATE counts the rows it matched (CLIENT_FOUND_ROWS).
    public static func apply(_ statements: [Statement], on session: DBConnection) async throws {
        try await apply(statements) { sql in try await session.query(sql).last?.affectedRows ?? 0 }
    }
}

/// Pending changes kept on disk while they wait (pending.json next to airsql.json), so a crash or a quit doesn't lose
/// them: by connection, database and table, with the key they address rows by. Thread-safe; written on a background
/// queue after every change.
public final class PendingChangesStore {
    public static let shared = PendingChangesStore(fileURL: Store.directory.appendingPathComponent("pending.json"))

    public struct Saved: Codable, Equatable {
        public var keyColumns: [String]
        public var state: PendingChanges.State
    }

    private static let log = Logger(subsystem: "com.kleash.airsql", category: "pending")
    private let fileURL: URL
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.kleash.airsql.pending")
    private var all: [String: Saved]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private static func key(_ connection: UUID, _ database: String, _ table: String) -> String {
        [connection.uuidString, database, table].joined(separator: "\u{1F}")
    }

    /// The changes left for a table, as `PendingChanges` (nil when none, or when they address rows by another key).
    /// Reads the file the first time: call it off the main thread.
    public func changes(connection: UUID, database: String, table: String, keyColumns: [String]) -> PendingChanges? {
        lock.lock()
        defer { lock.unlock() }
        guard let saved = loaded()[Self.key(connection, database, table)], saved.keyColumns == keyColumns else { return nil }
        return PendingChanges(keyColumns: keyColumns, state: saved.state)
    }

    /// Keeps a table's changes (empty ones: forgets them).
    public func save(_ changes: PendingChanges, connection: UUID, database: String, table: String) {
        lock.lock()
        var everything = loaded()
        everything[Self.key(connection, database, table)] = changes.isEmpty ? nil
            : Saved(keyColumns: changes.keyColumns, state: changes.state)
        all = everything
        lock.unlock()
        queue.async { [self] in write() }
    }

    /// Waits for the writes asked for so far (tests).
    public func flush() { queue.sync {} }

    private func loaded() -> [String: Saved] {
        if let all { return all }
        let read = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: Saved].self, from: $0) }
        all = read ?? [:]
        return all!
    }

    private func write() {
        lock.lock()
        let snapshot = all ?? [:]
        lock.unlock()
        do {
            if snapshot.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Self.log.error("can't save pending.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
