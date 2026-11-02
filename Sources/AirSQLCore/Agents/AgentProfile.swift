import Foundation

/// profile and explain.
extension AgentTarget {
    /// Columns profile takes when the call names none, and most common values per column.
    static let profileColumns = 40
    static let topValues = 5

    /// Column statistics of a table, computed on the server: one statement for the counts, minimums, maximums and
    /// averages of every column, then one per column for its most common values. A `where` condition is the agent's
    /// own SQL, so those statements are classified like any other.
    public func profile(_ arguments: [String: Any], progress: @escaping AgentProgress = { _, _, _ in }) async throws
        -> [String: Any] {
        try require(.schemaReadAnalytics)
        let named = Self.split(arguments["table"] as? String ?? "")
        let databaseName = named.database ?? (arguments["database"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? database
        guard let databaseName, !named.name.isEmpty else {
            throw AirSQLError(.other, "profile needs a table, and a database when there is no current one.")
        }
        let database = try await databases([databaseName]).first
        guard let database, let table = database.table(named.name) ?? schema?.snapshot.table(database.name, named.name) else {
            throw AirSQLError(.notFound, "No table “\(named.name)” in “\(databaseName)” on “\(saved.displayName)”.")
        }
        let wanted = arguments["columns"] as? [String] ?? []
        if let unknown = wanted.first(where: { name in table.column(name) == nil }) {
            throw AirSQLError(.notFound, "No column “\(unknown)” in “\(table.name)”.")
        }
        let columns = wanted.isEmpty ? Array(table.columns.prefix(Self.profileColumns)) : wanted.compactMap { table.column($0) }
        let condition = (arguments["where"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = condition.map { !$0.isEmpty } ?? false
        let from = " FROM " + SQLQuote.identifier(database.name, table.name) + (filtered ? " WHERE " + condition! : "")

        var selects = ["COUNT(*)"]
        for column in columns {
            let name = SQLQuote.identifier(column.name), kind = Self.kind(column)
            selects += ["COUNT(\(name))", kind == .opaque ? "NULL" : "COUNT(DISTINCT \(name))",
                        kind == .opaque ? "NULL" : "MIN(\(name))", kind == .opaque ? "NULL" : "MAX(\(name))",
                        kind == .number ? "AVG(\(name))" : "NULL"]
        }
        let steps = Double(1 + columns.count)
        return try await AgentReadOnly.session(try await session(), timeout: timeout) { runner in
            progress(0, steps, "Counting")
            guard let counts = try await runner.run("SELECT " + selects.joined(separator: ", ") + from, written: filtered)?.rows,
                  counts.rowCount == 1 else { throw AirSQLError(.other, "The server returned no counts.") }
            let total = Int(counts.string(0, 0) ?? "") ?? 0
            var stats: [[String: Any]] = []
            for (index, column) in columns.enumerated() {
                let base = 1 + index * 5
                let present = Int(counts.string(0, base) ?? "") ?? 0
                var entry: [String: Any] = ["name": column.name, "type": column.columnType, "nulls": total - present]
                if let distinct = counts.string(0, base + 1).flatMap({ Int($0) }) { entry["distinct"] = distinct }
                entry["min"] = AgentFormat.cell(counts, 0, base + 2, limit: 200)
                entry["max"] = AgentFormat.cell(counts, 0, base + 3, limit: 200)
                if Self.kind(column) == .number { entry["average"] = AgentFormat.cell(counts, 0, base + 4, limit: 200) }
                let distinct = entry["distinct"] as? Int ?? 0
                if Self.kind(column) != .opaque, Self.kind(column) != .text, distinct > 0, distinct < present {
                    progress(Double(1 + index), steps, "Common values of \(column.name)")
                    let name = SQLQuote.identifier(column.name)
                    let sql = "SELECT \(name), COUNT(*)" + from + " GROUP BY \(name) ORDER BY 2 DESC, 1 LIMIT \(Self.topValues)"
                    if let top = try await runner.run(sql, written: filtered, rowCap: Self.topValues)?.rows {
                        entry["top"] = (0..<top.rowCount).map { row in
                            ["value": AgentFormat.cell(top, row, 0, limit: 200), "count": Int(top.string(row, 1) ?? "") ?? 0]
                        }
                    }
                }
                stats.append(entry)
            }
            var reply: [String: Any] = ["connection": saved.displayName, "database": database.name, "table": table.name,
                                        "rows": total, "columns": stats]
            if filtered { reply["where"] = condition }
            return reply
        }
    }

    /// What profile computes for a column: averages for numbers, no common values for long text, only counts for what
    /// can't be compared (BLOB, JSON, geometry).
    enum ColumnKind { case number, value, text, opaque }

    static func kind(_ column: SchemaColumn) -> ColumnKind {
        let type = column.dataType.lowercased()
        if ["tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal", "numeric", "float", "double",
            "real"].contains(type) { return .number }
        if column.isJSON || type.hasSuffix("blob") || ["json", "geometry", "point", "linestring", "polygon", "multipoint",
                                                       "multilinestring", "multipolygon", "geometrycollection"].contains(type) {
            return .opaque
        }
        return type.hasSuffix("text") ? .text : .value
    }

    /// The server's plan for one read-only statement; the statement itself doesn't run.
    public func explain(_ arguments: [String: Any]) async throws -> [String: Any] {
        try require(.schemaRead)
        var sql = (arguments["sql"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while sql.hasSuffix(";") { sql = String(sql.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !sql.isEmpty else { throw AirSQLError(.other, "explain needs sql: one statement.") }
        try AgentReadOnly.check(sql)
        let statement = (arguments["format"] as? String == "json" ? "EXPLAIN FORMAT=JSON " : "EXPLAIN ") + sql
        let database = (arguments["database"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? self.database
        return try await AgentReadOnly.session(try await session(), timeout: timeout) { runner in
            if let database { _ = try await runner.run("USE " + SQLQuote.identifier(database), written: false) }
            guard let rows = try await runner.run(statement, written: true, rowCap: 1_000)?.rows else {
                throw AirSQLError(.other, "The server returned no plan.")
            }
            return ["connection": saved.displayName, "columns": AgentFormat.columns(rows).names,
                    "rows": AgentFormat.json(rows, limit: Self.replyBudget)]
        }
    }
}
