import Foundation
import os

/// What Apply warns about first (plan §2.5, R7). Whether a table's rows can be edited at all: `SchemaTable.editingKey`.
public enum TableEditing {
    /// Engines whose changes a ROLLBACK undoes.
    static let transactional: Set<String> = ["innodb", "xtradb", "rocksdb", "tokudb", "ndb", "ndbcluster"]

    /// What the SQL preview says about Apply's check for someone else's change; `reading` is what it compares with.
    public static func applyCaption(reading: String, unchecked: [String]) -> String {
        let caption = "They run in one transaction. If someone else changed a cell you edited or deleted a row since "
            + "\(reading), nothing is applied."
        guard !unchecked.isEmpty else { return caption }
        return caption + " Edits to " + unchecked.joined(separator: ", ") + " aren't checked: FLOAT, TIMESTAMP, JSON, spatial, "
            + "zero-date and very long values don't compare exactly, so these overwrite what is there now."
    }

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

/// Apply stopped: a statement changed another number of rows than it should (someone else changed an edited cell or
/// deleted the row since it was loaded) or the server refused it. Nothing was applied: the transaction was rolled back.
public struct ApplyFailure: LocalizedError {
    public var statement: PendingChanges.Statement
    /// The rows it changed instead, when it ran.
    public var changed: UInt64?
    public var error: Error?
    /// The column whose value was refused before anything ran (`PendingChanges.statements`' `typed` check).
    public var column: String?

    public var errorDescription: String? {
        if let changed {
            let rows = statement.expectedRows == 1 ? "This row" : "One of these rows"
            return "\(rows) was changed or deleted by someone else since it was loaded (the statement changed \(changed) "
                + "of \(statement.expectedRows)), so nothing was applied. Revert the change, reload the rows, then make it again."
        }
        let message = error?.localizedDescription ?? "The server refused a statement."
        return message + " Nothing was applied."
    }
}

extension ApplyFailure {
    /// The column of `table` the failure is about, for the grid to focus its cell: the one a value was refused for,
    /// else one the server's error names ("Data too long for column 'note'", "Column 'name' cannot be null", "Field
    /// 'id' doesn't have a default value", "… FOREIGN KEY (`owner`) …"), or the first column of the unique key a
    /// duplicate value broke. Nil when it names none of the table's columns.
    public func column(in table: SchemaTable) -> String? {
        if let column { return column }
        guard let error = error as? AirSQLError else { return nil }
        return Self.column(named: error.details.isEmpty ? error.message : error.details, in: table)
    }

    static func column(named text: String, in table: SchemaTable) -> String? {
        // The quoted name after `word`; of `db`.`table`.`column` (MariaDB's), the last part.
        func name(after word: String) -> String? {
            guard let start = text.range(of: word)?.upperBound else { return nil }
            var rest = text[start...], last: String?
            while let quote = rest.first, quote == "'" || quote == "`" || quote == "\"" {
                guard let end = rest.dropFirst().firstIndex(of: quote) else { break }
                last = String(rest[rest.index(after: rest.startIndex)..<end])
                rest = rest[rest.index(after: end)...]
                guard rest.first == "." else { break }
                rest = rest.dropFirst()
            }
            return last
        }
        for word in ["for column ", "Column ", "Field ", "generated column ", "Unknown column ", "FOREIGN KEY ("] {
            if let found = name(after: word), let column = table.column(found) { return column.name }
        }
        // MySQL 8 names the key with its table: 'orders.email'.
        guard let key = name(after: "for key ").map({ $0.split(separator: ".").last.map(String.init) ?? $0 }),
              let index = table.indexes.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) else { return nil }
        return index.parts.first?.column.flatMap { table.column($0)?.name }
    }
}

extension PendingChanges {
    /// Runs `statements` in one transaction through `run` (which returns each statement's affected rows): each must
    /// change exactly its rows, else everything rolls back and `ApplyFailure` names the statement. `inOpenTransaction`:
    /// they join the transaction already open and stay uncommitted; a savepoint takes back only their own.
    public static func apply(_ statements: [Statement], inOpenTransaction: Bool = false, run: (String) async throws -> UInt64) async throws {
        let undo = inOpenTransaction ? "ROLLBACK TO SAVEPOINT airsql_apply" : "ROLLBACK"
        _ = try await run(inOpenTransaction ? "SAVEPOINT airsql_apply" : "START TRANSACTION")
        for statement in statements {
            let changed: UInt64
            do {
                changed = try await run(statement.sql)
            } catch {
                _ = try? await run(undo)
                throw ApplyFailure(statement: statement, changed: nil, error: error)
            }
            guard changed == UInt64(statement.expectedRows) else {
                _ = try? await run(undo)
                throw ApplyFailure(statement: statement, changed: changed, error: nil)
            }
        }
        guard !inOpenTransaction else { return }
        do {
            _ = try await run("COMMIT")
        } catch {
            _ = try? await run("ROLLBACK")
            throw error
        }
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
