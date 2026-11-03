import Foundation

/// Reports a long call's progress: done of total, with a short message.
public typealias AgentProgress = (_ done: Double, _ total: Double?, _ message: String?) -> Void

/// get_schema, describe and the schema resource: the schema cache's snapshot, with CREATE statements and sample rows
/// read on the agent session.
extension AgentTarget {
    /// About this much text per reply (characters): what doesn't fit comes as names only.
    static let replyBudget = 120_000

    public func getSchema(_ arguments: [String: Any], progress: @escaping AgentProgress = { _, _, _ in }) async throws
        -> [String: Any] {
        try require(.schema)
        let databases = try await databases(arguments["databases"] as? [String])
        let hash = SchemaHash.of(databases)
        var reply: [String: Any] = ["connection": saved.displayName, "hash": hash, "unchanged": false]
        if let previous = arguments["if_changed_from"] as? String, previous == hash {
            reply["unchanged"] = true
            return reply
        }
        let ddl = arguments["format"] as? String == "ddl"
        var budget = Self.replyBudget, entries: [[String: Any]] = [], cut: [String] = []
        let total = Double(databases.reduce(0) { $0 + $1.tables.count })
        var done = 0.0
        for database in databases {
            var entry: [String: Any] = ["name": database.name, "hash": database.hash, "tables": database.tables.count,
                                        "details": database.detailsLoaded]
            var namesOnly = database
            namesOnly.detailsLoaded = false
            var text = AgentFormat.compact(namesOnly)
            if database.detailsLoaded {
                let full = ddl ? try await createStatements(database, budget: budget) { count in
                    progress(done + Double(count), total, "CREATE statements of \(database.name)")
                } : AgentFormat.compact(database)
                if full.count <= budget {
                    text = full
                } else {
                    entry["details"] = false
                    cut.append(database.name)
                }
            }
            done += Double(database.tables.count)
            if text.count <= budget {
                entry["text"] = text
                budget -= text.count
            } else {
                entry["details"] = false  // not even the names fit: the count only
            }
            entries.append(entry)
        }
        reply["databases"] = entries
        let notLoaded = databases.filter { !$0.detailsLoaded }.map(\.name)
        var notes: [String] = []
        if !cut.isEmpty { notes.append("Too big for one reply, so names only: " + cut.joined(separator: ", ") + ".") }
        if !notLoaded.isEmpty { notes.append("Names only until asked for by name: " + notLoaded.joined(separator: ", ") + ".") }
        if !notes.isEmpty { reply["note"] = notes.joined(separator: " ") + " Name databases in get_schema, or tables in describe." }
        return reply
    }

    /// Columns a search_columns reply lists at most.
    static let searchLimit = 500

    /// search_columns: the columns whose name (and data type) match, read from the schema cache, so no statement runs on
    /// the agent session. A pattern without * or ? matches part of a name; a type without them, the whole data type.
    public func searchColumns(_ arguments: [String: Any]) async throws -> [String: Any] {
        try require(.schema)
        let pattern = (arguments["pattern"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else {
            throw AirSQLError(.other, "search_columns needs a pattern: part of a column's name, or a name with * and ?.")
        }
        let name = pattern.contains(where: { $0 == "*" || $0 == "?" }) ? pattern : "*" + pattern + "*"
        let type = (arguments["type"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let databases = try await databases(arguments["databases"] as? [String])
        var columns: [[String: Any]] = [], capped = false
        search: for database in databases where database.detailsLoaded {
            for table in database.tables {
                let primary = table.primaryKey?.parts.compactMap(\.column) ?? []
                for column in table.columns where fnmatch(name, column.name, FNM_CASEFOLD) == 0
                    && (type.isEmpty || fnmatch(type, column.dataType, FNM_CASEFOLD) == 0) {
                    guard columns.count < Self.searchLimit else {
                        capped = true
                        break search
                    }
                    var entry: [String: Any] = ["database": database.name, "table": table.name, "column": column.name,
                                                "type": column.columnType, "nullable": column.nullable]
                    if primary.contains(column.name) { entry["primaryKey"] = true }
                    if table.kind != .table { entry["kind"] = table.kind.rawValue }
                    columns.append(entry)
                }
            }
        }
        var reply: [String: Any] = ["connection": saved.displayName, "columns": columns, "capped": capped]
        var notes: [String] = []
        if capped { notes.append("More than \(Self.searchLimit) columns match: narrow the pattern, add a type or name databases.") }
        let notLoaded = databases.filter { !$0.detailsLoaded }.map(\.name)
        if !notLoaded.isEmpty {
            notes.append("Not searched, as their columns aren't loaded yet: " + notLoaded.joined(separator: ", ")
                         + ". Name them in databases to search them.")
        }
        if !notes.isEmpty { reply["note"] = notes.joined(separator: " ") }
        return reply
    }

    /// The schema resource's text: every database but the system ones, compact.
    public func schemaText() async throws -> String {
        try require(.schema)
        let reply = try await getSchema([:])
        var parts = ["-- \(saved.displayName) · schema hash \(reply["hash"] as? String ?? "")"]
        for database in reply["databases"] as? [[String: Any]] ?? [] {
            let name = AgentFormat.name(database["name"] as? String ?? "")
            parts.append("-- database \(name) · hash \(database["hash"] as? String ?? "")\n" + (database["text"] as? String ?? ""))
        }
        if let note = reply["note"] as? String { parts.append("-- " + note) }
        return parts.joined(separator: "\n\n")
    }

    /// The databases named (their details loaded), or every database but the system ones.
    func databases(_ names: [String]?) async throws -> [SchemaDatabase] {
        var snapshot = try await snapshot()
        guard let names, !names.isEmpty else {
            return snapshot.databases.filter { !AgentFormat.systemDatabases.contains($0.name.lowercased()) }
        }
        if let missing = names.first(where: { snapshot.database($0) == nil }) {
            throw AirSQLError(.notFound, "No database “\(missing)” on “\(saved.displayName)”.")
        }
        let found = names.compactMap { snapshot.database($0)?.name }
        if let schema, found.contains(where: { snapshot.database($0)?.detailsLoaded == false }) {
            try await schema.loadDetails(found)
            snapshot = schema.snapshot
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }.compactMap { snapshot.database($0) }
    }

    /// The CREATE statements of a database's tables, views and sequences, while they fit in `budget`.
    private func createStatements(_ database: SchemaDatabase, budget: Int, progress: (Int) -> Void) async throws -> String {
        try await AgentReadOnly.session(try await session(), timeout: timeout) { runner in
            var text = ""
            for (index, table) in database.tables.enumerated() {
                progress(index)
                guard let statement = try await create(table, in: database.name, runner) else { continue }
                if text.count + statement.count > budget { return text + statement }  // too big: the caller cuts it
                text += statement + ";\n\n"
            }
            return text
        }
    }

    /// A table's, view's or sequence's CREATE statement.
    func create(_ table: SchemaTable, in database: String, _ runner: AgentReadOnly.Runner) async throws -> String? {
        let kind = table.kind == .view ? "VIEW" : table.kind == .sequence ? "SEQUENCE" : "TABLE"
        let result = try await runner.run("SHOW CREATE \(kind) " + SQLQuote.identifier(database, table.name), written: false)
        return result?.rows.flatMap { $0.rowCount > 0 ? $0.string(0, 1) : nil }
    }
}
