import Foundation

/// Which columns of a console result can be edited, and why the others can't (grid-spec §5, R15): a SELECT from one
/// table that includes its key, or an inner join where every table's key is in the result (Apply then shows the SQL
/// preview first). Outer joins, self-joins, grouped, DISTINCT or combined results, subqueries in FROM, and a table
/// whose row shows in more than one result row are read-only, every column with a reason in plain words.
public struct ResultEditing: Equatable {
    /// A table the result's rows come from: where its key is among the result's columns.
    public struct Source: Equatable, Sendable {
        public var database: String
        public var table: String
        /// The key that addresses its rows (`SchemaTable.editingKey`), and the result column holding each part.
        public var key: [String]
        public var keyColumns: [Int]
    }

    public enum Column: Equatable, Sendable {
        /// Edits change `column` of `sources[source]`, in the row its key columns address.
        case editable(source: Int, column: String)
        case readOnly(String)
    }

    public var sources: [Source]
    /// One per result column.
    public var columns: [Column]

    /// Several tables: Apply shows the SQL preview before running anything.
    public var needsPreview: Bool { sources.count > 1 }

    public var isEditable: Bool {
        columns.contains { if case .editable = $0 { return true } else { return false } }
    }

    /// The rules applied to a result: `sql` as it ran, `store` with its columns and rows, the schema cache's snapshot,
    /// and the session's database for columns that don't name theirs.
    public init(sql: String, store: ResultStore, snapshot: SchemaSnapshot, defaultDatabase: String? = nil,
                noBackslashEscapes: Bool = false) {
        sources = []
        if let refusal = Self.statementRefusal(sql, noBackslashEscapes: noBackslashEscapes) {
            columns = Array(repeating: .readOnly(refusal), count: store.columns.count)
            return
        }
        // The tables by alias, in the order their columns first appear.
        var aliases: [String] = [], byAlias: [String: (database: String, table: String, columns: [Int])] = [:]
        for (index, column) in store.columns.enumerated() where !column.originalTable.isEmpty && !column.originalName.isEmpty {
            let database = column.database.isEmpty ? defaultDatabase ?? "" : column.database
            let alias = database + "\u{0}" + column.table
            if byAlias[alias] == nil { aliases.append(alias) }
            byAlias[alias, default: (database, column.originalTable, [])].columns.append(index)
        }
        let tables = aliases.compactMap { byAlias[$0] }
        var reasons = Array(repeating: "Worked out by the query, not a column of a table", count: store.columns.count)
        func refuseAll(_ reason: String) -> [Column] {
            (0..<store.columns.count).map { index in
                tables.contains { $0.columns.contains(index) } ? .readOnly(reason) : .readOnly(reasons[index])
            }
        }
        if let repeated = tables.first(where: { table in tables.filter { $0.database == table.database
            && $0.table.caseInsensitiveCompare(table.table) == .orderedSame }.count > 1 }) {
            columns = refuseAll("\(repeated.table) appears twice in the query (a self-join): edit it in its own tab")
            return
        }
        // Every table needs its key in the result (R15).
        var missing: [String] = []
        for table in tables {
            guard let schema = snapshot.table(table.database, table.table) else {
                missing.append("AirSQL hasn't read the columns of \(table.table) yet")
                continue
            }
            if let refusal = schema.editingRefusal {
                missing.append("\(table.table): \(refusal)")
                continue
            }
            let key = schema.editingKey ?? []
            let positions = key.map { part in
                table.columns.first { store.columns[$0].originalName.caseInsensitiveCompare(part) == .orderedSame }
            }
            guard positions.allSatisfy({ $0 != nil }) else {
                let absent = zip(key, positions).filter { $0.1 == nil }.map { "\(table.table).\($0.0)" }
                missing.append("add " + absent.joined(separator: ", ") + " to the SELECT")
                continue
            }
            sources.append(Source(database: table.database, table: schema.name, key: key, keyColumns: positions.compactMap { $0 }))
            for index in table.columns {
                let name = store.columns[index].originalName
                if let column = schema.column(name) {
                    reasons[index] = column.readOnlyReason ?? ""
                } else {
                    reasons[index] = "AirSQL's copy of \(schema.name) has no column \(name): refresh the schema"
                }
            }
        }
        if !missing.isEmpty {
            sources = []
            let text = missing.joined(separator: "; ")
            columns = refuseAll(tables.count > 1 ? "A joined result can be edited only when every table's key is in it: " + text
                : text.hasPrefix("add ") ? "To edit, " + text : text)
            return
        }
        // Every table has its key, so sources[i] is tables[i].
        columns = (0..<store.columns.count).map { index in
            guard reasons[index].isEmpty, let source = tables.firstIndex(where: { $0.columns.contains(index) }) else {
                return .readOnly(reasons[index])
            }
            return .editable(source: source, column: store.columns[index].originalName)
        }
        markRepeats(store)
    }

    /// A table whose row shows in several result rows (the "one" side of a one-to-many join) is read-only: an edit in
    /// one place would leave the others showing the old value.
    private mutating func markRepeats(_ store: ResultStore) {
        for (number, source) in sources.enumerated() {
            var seen = Set<[[UInt8]?]>()
            let repeats = (0..<store.rowCount).contains { row in
                !seen.insert(source.keyColumns.map { store.bytes(row, $0) }).inserted
            }
            guard repeats else { continue }
            for index in columns.indices {
                if case .editable(number, _) = columns[index] {
                    columns[index] = .readOnly("A \(source.table) row shows in more than one result row here: edit it in its own tab")
                }
            }
        }
    }

    /// Why no column of the statement's result can be edited, from its words: nil for a plain SELECT, inner joins
    /// included.
    public static func statementRefusal(_ sql: String, noBackslashEscapes: Bool) -> String? {
        let units = Array(sql.utf16)
        let code = SQLLexer.tokens(sql, noBackslashEscapes: noBackslashEscapes)
            .filter { ![.comment, .codeStart, .codeEnd, .hint].contains($0.kind) }
            .map { token -> (word: String?, symbol: String?) in
                let text = String(decoding: units[token.range], as: UTF16.self)
                return (token.kind == .word ? text.uppercased() : nil, token.kind == .symbol ? text : nil)
            }
        guard code.first?.word == "SELECT" else { return "Only the results of a plain SELECT can be edited" }
        var depth = 0, inFrom = false
        for (index, token) in code.enumerated() {
            let next: (word: String?, symbol: String?) = index + 1 < code.count ? code[index + 1] : (nil, nil)
            if token.symbol == "(" {
                if inFrom && depth == 0, ["SELECT", "WITH", "VALUES", "TABLE"].contains(next.word ?? "") {
                    return "Results of a subquery in FROM are read-only: edit the table itself"
                }
                depth += 1
            } else if token.symbol == ")" {
                depth -= 1
            }
            guard depth == 0, let word = token.word else { continue }
            switch word {
            case "FROM": inFrom = true
            case "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "WINDOW", "FOR", "LOCK", "INTO": inFrom = false
            default: break
            }
            switch word {
            case "UNION", "INTERSECT", "EXCEPT": return "Combined results (\(word)) are read-only: edit each table on its own"
            case "GROUP", "HAVING": return "Grouped results are read-only: a row stands for many"
            case "DISTINCT", "DISTINCTROW": return "DISTINCT results are read-only: a row may stand for many"
            case "LEFT", "RIGHT":
                // LEFT( and RIGHT( are string functions.
                if next.word == "JOIN" || next.word == "OUTER" {
                    return "Outer joins are read-only: rows on the missing side have nothing to change"
                }
            default: break
            }
        }
        return nil
    }
}
