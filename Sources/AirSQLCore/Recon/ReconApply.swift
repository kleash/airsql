import Foundation

/// A sync script's rows: INSERT for rows only in the source, UPDATE (only the columns that differ) for rows in both,
/// DELETE for rows only in the target. Each statement says how many rows it must change.
extension ReconScriptBuilder {
    private func columns(_ table: ReconObject) -> (data: ReconTableData, key: [ReconColumn])? {
        guard let data = table.data, data.outcome == .different else { return nil }
        return (data, Array(data.columns.prefix(data.key.count)))
    }

    private func literal(_ value: [UInt8]?, _ column: ReconColumn) -> String {
        ReconTableSQL.literal(value, column.kind, noBackslashEscapes: result.target.noBackslashEscapes)
    }

    func inserts(_ table: ReconObject) -> [ReconStep] {
        guard let (data, _) = columns(table), !data.missing.isEmpty else { return [] }
        let names = data.columns.map { q($0.name) }.joined(separator: ", ")
        return stride(from: 0, to: data.missing.count, by: Self.batchRows).map { start in
            let rows = data.missing[start..<min(start + Self.batchRows, data.missing.count)]
            let values = rows.map { row in
                "(" + zip(row.values, data.columns).map { literal($0, $1) }.joined(separator: ", ") + ")"
            }
            return step(.data, table, "INSERT INTO \(q(table.targetName)) (\(names)) VALUES\n" + values.joined(separator: ",\n"),
                        rows: rows.count)
        }
    }

    func updates(_ table: ReconObject) -> [ReconStep] {
        guard let (data, key) = columns(table) else { return [] }
        return data.changed.map { change in
            let set = change.columns.map { q(data.columns[$0].name) + " = " + literal(change.source.values[$0], data.columns[$0]) }
            let match = ReconTableSQL.match([key.indices.map { change.target.values[$0] ?? [] }], key: key,
                                            noBackslashEscapes: result.target.noBackslashEscapes)
            return step(.data, table, "UPDATE \(q(table.targetName)) SET " + set.joined(separator: ", ") + " WHERE " + match,
                        rows: 1)
        }
    }

    func deletes(_ table: ReconObject) -> [ReconStep] {
        guard let (data, key) = columns(table), !data.extra.isEmpty else { return [] }
        return stride(from: 0, to: data.extra.count, by: Self.batchRows).map { start in
            let rows = data.extra[start..<min(start + Self.batchRows, data.extra.count)]
            let match = ReconTableSQL.match(rows.map { row in key.indices.map { row.values[$0] ?? [] } }, key: key,
                                            noBackslashEscapes: result.target.noBackslashEscapes)
            return step(.data, table, "DELETE FROM \(q(table.targetName)) WHERE " + match,
                        destructive: "deletes rows only the target has", rows: rows.count)
        }
    }
}

/// Running a sync script went wrong.
public struct ReconApplyError: LocalizedError {
    public var statement: String
    public var expected: Int
    public var changed: UInt64

    public var errorDescription: String? {
        "A statement changed \(changed) rows instead of \(expected), so the data changes were rolled back: the target "
            + "changed since the compare. Compare again, then sync."
    }
}

extension ReconResult {
    /// Runs the sync script (as `runnable` lists it) on a session of the target, the one way a script runs: only
    /// after the person approved it in the SQL preview. Each data statement must change exactly its rows; otherwise,
    /// or on any error inside the data transaction, it rolls back. Structure steps commit as they run (DDL can't be
    /// rolled back). `progress` gets the number of statements done.
    public func apply(destructive: Bool, on session: DBConnection, progress: @escaping (Int) -> Void) async throws {
        var inTransaction = false
        for (index, statement) in runnable(destructive: destructive).enumerated() {
            do {
                try Task.checkCancellation()
                if statement.sql == "START TRANSACTION" { inTransaction = true }
                let changed = try await session.query(statement.sql).last?.affectedRows ?? 0
                if let expected = statement.expectedRows, changed != UInt64(expected) {
                    throw ReconApplyError(statement: statement.sql, expected: expected, changed: changed)
                }
                if statement.sql == "COMMIT" { inTransaction = false }
            } catch {
                if inTransaction { _ = try? await session.query("ROLLBACK") }
                throw error
            }
            progress(index + 1)
        }
    }
}
