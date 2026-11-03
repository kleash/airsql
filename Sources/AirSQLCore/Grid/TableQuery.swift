import Foundation

/// The statements a table tab runs on the data session (plan §2.5): its rows a page at a time (`LIMIT … OFFSET …`),
/// filtered by the WHERE bar's condition and sorted by the grid's sort, and their count, estimated or exact.
public struct TableQuery: Equatable {
    public var database: String
    public var table: String
    /// A WHERE condition as typed, without "WHERE"; "" for every row.
    public var filter: String
    public var sort: [TableViewSettings.SortKey]

    public init(database: String, table: String, filter: String = "", sort: [TableViewSettings.SortKey] = []) {
        self.database = database
        self.table = table
        self.filter = filter
        self.sort = sort
    }

    /// A table named as typed in Open Table: `table`, `database.table`, or either part in backticks (which may hold
    /// dots); `table` alone is in `database`. Nil when it names no table, or no database is known.
    public init?(name: String, database current: String?) {
        var parts: [String] = [], part = "", quoted = false, wasQuoted = false
        var characters = name.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        while let character = characters.popFirst() {
            if character == "`" {
                if quoted, characters.first == "`" {
                    part.append(characters.removeFirst())
                } else {
                    quoted.toggle()
                    wasQuoted = true
                }
            } else if character == ".", !quoted, parts.isEmpty {
                parts.append(part)
                part = ""
                wasQuoted = false
            } else {
                part.append(character)
            }
        }
        parts.append(wasQuoted ? part : part.trimmingCharacters(in: .whitespaces))
        guard !quoted, let table = parts.last, !table.isEmpty else { return nil }
        let database = parts.count == 2 ? parts[0] : current
        guard let database, !database.isEmpty else { return nil }
        self.init(database: database, table: table)
    }

    private var from: String {
        let condition = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        // A newline before the closing parenthesis, so a condition ending in a -- comment can't swallow it.
        return " FROM \(SQLQuote.identifier(database, table))" + (condition.isEmpty ? "" : " WHERE (\(condition)\n)")
    }

    /// `limit` rows from row `offset` on.
    public func page(limit: Int, offset: Int) -> String {
        let order = sort.map { SQLQuote.identifier($0.column) + ($0.ascending ? "" : " DESC") }.joined(separator: ", ")
        return "SELECT *" + from + (order.isEmpty ? "" : " ORDER BY " + order) + " LIMIT \(max(0, limit)) OFFSET \(max(0, offset))"
    }

    /// The exact number of rows (Count Rows Exactly).
    public var count: String { "SELECT COUNT(*)" + from }

    /// The server's estimate of the table's rows (InnoDB's is a guess), for the status bar's "≈".
    public func estimate(noBackslashEscapes: Bool) -> String {
        "SELECT TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA = "
            + SQLQuote.string(database, noBackslashEscapes: noBackslashEscapes) + " AND TABLE_NAME = "
            + SQLQuote.string(table, noBackslashEscapes: noBackslashEscapes)
    }
}

extension GridColumn {
    /// Adds what a table's schema says to a column of its rows: the full type ("varchar(120)"), the key marks
    /// (primary, foreign, unique, indexed), auto-increment, a default, generated, NULL allowed, and the comment.
    /// `isKey` becomes the key that addresses a row: the primary key, else the first unique key whose columns are all
    /// NOT NULL.
    public mutating func describe(_ table: SchemaTable) {
        guard let column = table.column(name) else { return }
        func has(_ index: SchemaIndex) -> Bool {
            index.parts.contains { $0.column?.caseInsensitiveCompare(column.name) == .orderedSame }
        }
        type = column.columnType
        comment = column.comment
        var marks: Marks = column.nullable ? .nullable : []
        if column.autoIncrement { marks.insert(.autoIncrement) }
        if column.generated != nil { marks.insert(.generated) }
        if column.defaultValue != .none, column.defaultValue != .null, column.generated == nil { marks.insert(.hasDefault) }
        for index in table.indexes where has(index) {
            marks.insert(index.isPrimary ? .primary : index.unique ? .unique : .indexed)
        }
        if table.foreignKeys.contains(where: { $0.columns.contains { $0.caseInsensitiveCompare(column.name) == .orderedSame } }) {
            marks.insert(.foreign)
        }
        self.marks = marks
        let key = table.primaryKey ?? table.indexes.first { index in
            index.unique && index.parts.allSatisfy { part in part.column.flatMap { table.column($0) }.map { !$0.nullable } ?? false }
        }
        isKey = key.map(has) ?? false
    }

    /// The header's second line: the type, then "auto", "default" or "generated", then "null" when NULL is allowed.
    public var typeLine: String {
        var words = type.isEmpty ? [] : [type]
        if marks.contains(.autoIncrement) { words.append("auto") }
        if marks.contains(.generated) { words.append("generated") }
        if marks.contains(.hasDefault) { words.append("default") }
        if marks.contains(.nullable) { words.append("null") }
        return words.joined(separator: " · ")
    }

    /// The header's tooltip after what a click does: the type in words, the keys, the comment.
    public var details: String {
        var facts: [String] = []
        if marks.contains(.primary) { facts.append("primary key") }
        if marks.contains(.unique) { facts.append("unique key") }
        if marks.contains(.foreign) { facts.append("foreign key") }
        if marks.contains(.indexed) { facts.append("indexed") }
        if marks.contains(.autoIncrement) { facts.append("auto-increment") }
        if marks.contains(.generated) { facts.append("generated, read-only") }
        if marks.contains(.hasDefault) { facts.append("has a default") }
        if marks.contains(.nullable) { facts.append("NULL allowed") }
        let first = ([name] + (type.isEmpty ? [] : [type])).joined(separator: " · ")
        return ([first] + (facts.isEmpty ? [] : [facts.joined(separator: ", ")]) + (comment.isEmpty ? [] : ["“\(comment)”"]))
            .joined(separator: "\n")
    }
}
