import Foundation

/// describe: tables and views in detail, several per call.
extension AgentTarget {
    /// Sample rows describe shows when the person allows them for the connection.
    static let sampleRows = 5

    public func describe(_ arguments: [String: Any]) async throws -> [String: Any] {
        try require(.schema)
        let asked = arguments["objects"] as? [String] ?? []
        guard !asked.isEmpty else { throw AirSQLError(.other, "describe needs objects: table or view names.") }
        let fallback = (arguments["database"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? database
        let wanted = asked.map { Self.split($0) }.map { (database: $0.database ?? fallback, name: $0.name) }
        let before = try await snapshot()
        let databaseNames = Set(wanted.compactMap { $0.database }.compactMap { before.database($0)?.name })
        if !databaseNames.isEmpty, let schema {
            for database in try await databases(databaseNames.sorted()) where database.statistics == nil {
                try? await schema.loadStatistics(database.name)
            }
        }
        let snapshot = schema?.snapshot ?? before
        var objects: [[String: Any]] = [], missing: [String] = []
        var found: [(SchemaDatabase, SchemaTable)] = []
        for (item, text) in zip(wanted, asked) {
            if let name = item.database, let database = snapshot.database(name), let table = snapshot.table(name, item.name) {
                found.append((database, table))
            } else {
                missing.append(text)
            }
        }
        try await AgentReadOnly.session(try await session(), timeout: timeout) { runner in
            for (database, table) in found {
                var object = Self.detail(table, in: database, snapshot: snapshot)
                object["ddl"] = try await create(table, in: database.name, runner)
                if saved.agentSampleRows, table.kind != .sequence {
                    let sql = "SELECT * FROM " + SQLQuote.identifier(database.name, table.name) + " LIMIT \(Self.sampleRows)"
                    if let rows = try await runner.run(sql, written: false, rowCap: Self.sampleRows)?.rows {
                        object["sample"] = ["columns": AgentFormat.columns(rows).names, "rows": AgentFormat.json(rows, limit: 200)]
                    }
                }
                objects.append(object)
            }
        }
        return ["connection": saved.displayName, "objects": objects, "missing": missing]
    }

    /// A table's structure, keys both ways, triggers and statistics, as JSON.
    static func detail(_ table: SchemaTable, in database: SchemaDatabase, snapshot: SchemaSnapshot) -> [String: Any] {
        var object: [String: Any] = ["database": database.name, "name": table.name, "kind": table.kind.rawValue,
                                     "comment": table.comment]
        if let engine = table.engine { object["engine"] = engine }
        object["columns"] = table.columns.map { column -> [String: Any] in
            var entry: [String: Any] = ["name": column.name, "type": column.columnType, "nullable": column.nullable]
            switch column.defaultValue {
            case .value(let value): entry["default"] = value
            case .expression(let expression): entry["default"] = expression
            case .null: entry["default"] = NSNull()
            case .none: break
            }
            if column.autoIncrement { entry["autoIncrement"] = true }
            if let generated = column.generated { entry["generated"] = generated.expression }
            if let update = column.onUpdate { entry["onUpdate"] = update }
            if column.invisible { entry["invisible"] = true }
            if !column.comment.isEmpty { entry["comment"] = column.comment }
            return entry
        }
        if let primary = table.primaryKey { object["primaryKey"] = primary.parts.compactMap(\.column) }
        object["indexes"] = table.indexes.filter { !$0.isPrimary }.map { index -> [String: Any] in
            ["name": index.name, "unique": index.unique, "type": index.type,
             "columns": index.parts.map { $0.column ?? "(" + ($0.expression ?? "") + ")" }]
        }
        object["foreignKeys"] = table.foreignKeys.map { key -> [String: Any] in
            ["name": key.name, "columns": key.columns, "referencedDatabase": key.referencedDatabase,
             "referencedTable": key.referencedTable, "referencedColumns": key.referencedColumns,
             "onUpdate": key.onUpdate, "onDelete": key.onDelete]
        }
        var referencedBy: [[String: Any]] = []
        for other in snapshot.databases where other.detailsLoaded {
            for child in other.tables {
                for key in child.foreignKeys where key.referencedTable == table.name && key.referencedDatabase == database.name {
                    referencedBy.append(["database": other.name, "table": child.name, "name": key.name,
                                         "columns": key.columns, "referencedColumns": key.referencedColumns])
                }
            }
        }
        object["referencedBy"] = referencedBy
        object["checks"] = table.checks.map { ["name": $0.name, "clause": $0.clause] }
        object["triggers"] = database.triggers.filter { $0.table == table.name }
            .map { ["name": $0.name, "timing": $0.timing, "event": $0.event] }
        if let statistics = database.statistics?[table.name] {
            var entry: [String: Any] = [:]
            entry["rowsEstimate"] = statistics.rows
            entry["dataBytes"] = statistics.dataLength
            entry["indexBytes"] = statistics.indexLength
            entry["autoIncrement"] = statistics.autoIncrement
            entry["updated"] = statistics.updateTime
            object["statistics"] = entry
        }
        return object
    }

    /// `db.table`, `` `db`.`my table` `` or `table`: dots inside backquotes belong to the name.
    static func split(_ text: String) -> (database: String?, name: String) {
        var parts: [String] = [""], quoted = false
        var characters = Array(text.trimmingCharacters(in: .whitespaces))[...]
        while let character = characters.popFirst() {
            if character == "`" {
                if quoted, characters.first == "`" {
                    parts[parts.count - 1].append("`")
                    characters.removeFirst()
                } else {
                    quoted.toggle()
                }
            } else if character == ".", !quoted {
                parts.append("")
            } else {
                parts[parts.count - 1].append(character)
            }
        }
        return parts.count >= 2 ? (parts[parts.count - 2], parts[parts.count - 1]) : (nil, parts[0])
    }
}
