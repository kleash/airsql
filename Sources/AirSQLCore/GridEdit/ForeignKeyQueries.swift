import Foundation

/// A foreign key's drop-down (searched, so a big table is never listed whole) and its related rows both ways (⌘↓), as
/// SQL built from the schema cache. Names go through SQLQuote.identifier and values through `ColumnType.literal`, so
/// nothing in a cell or a search can change the statement. Virtual foreign keys work the same once added to a copy of
/// the snapshot's `SchemaTable.foreignKeys`.
public enum ForeignKeyQueries {
    /// Rows related to a row, in one table: where to show them and the filter that finds them.
    public struct Related: Equatable, Sendable {
        public var database: String
        public var table: String
        /// The foreign key's name, for the menu ("orders_customer").
        public var foreignKey: String
        /// The filter for the table's WHERE bar, such as "`customer_id` = 12".
        public var condition: String
        /// The whole statement: SELECT * FROM … WHERE condition.
        public var sql: String
    }

    /// The first foreign key the column is part of.
    public static func foreignKey(of column: String, in table: SchemaTable) -> SchemaForeignKey? {
        table.foreignKeys.first { $0.columns.contains { $0.caseInsensitiveCompare(column) == .orderedSame } }
    }

    /// The column shown beside a key ("Ada Lovelace (12)") until the person chooses another: the referenced table's
    /// first text column outside the key.
    public static func defaultLabel(_ referenced: SchemaTable, key: [String]) -> String? {
        referenced.columns.first { column in
            if case .text = ColumnType(column).kind { return !key.contains(column.name) }
            return false
        }?.name
    }

    /// How a drop-down row reads: "label (key)", the key's parts separated by commas; the key alone without a label.
    public static func display(label: String?, key: [String]) -> String {
        let id = key.joined(separator: ", ")
        guard let label, !label.isEmpty else { return id }
        return "\(label) (\(id))"
    }

    /// The drop-down's query: the referenced key's columns, then the label. A search matches the label anywhere in it,
    /// or a one-column key equal to the text when the text is a value of the key's type. Ordered by the label when a
    /// B-tree index starts with it, otherwise by the key (an index), so no big table is sorted whole for the first page.
    public static func lookup(_ key: SchemaForeignKey, referenced: SchemaTable, label: String?, search: String,
                              limit: Int = 100, context: EditContext) -> String {
        let keyNames = key.referencedColumns.map(SQLQuote.identifier)
        let labelName = label.flatMap { $0.isEmpty || key.referencedColumns.contains($0) ? nil : SQLQuote.identifier($0) }
        var sql = "SELECT " + (keyNames + [labelName].compactMap { $0 }).joined(separator: ", ") + " FROM "
            + SQLQuote.identifier(key.referencedDatabase, key.referencedTable)
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let pattern = SQLQuote.string("%" + likeEscaped(text) + "%", noBackslashEscapes: context.noBackslashEscapes)
                + " ESCAPE '!'"
            var conditions = labelName.map { [$0 + " LIKE " + pattern] } ?? []
            if key.referencedColumns.count == 1, let column = referenced.column(key.referencedColumns[0]),
               let literal = try? ColumnType(column).literal(text, context) {
                conditions.append(keyNames[0] + " = " + literal)
            }
            if conditions.isEmpty { conditions.append(keyNames[0] + " LIKE " + pattern) }
            sql += " WHERE " + conditions.joined(separator: " OR ")
        }
        let labelIndexed = label.map { name in
            referenced.indexes.contains { $0.type == "BTREE" && $0.parts.first?.column == name }
        } ?? false
        sql += " ORDER BY " + (labelIndexed ? labelName.map { [$0] } ?? keyNames : keyNames).joined(separator: ", ")
        return sql + " LIMIT \(max(1, limit))"
    }

    /// The row a row refers to through `key` (child to parent). `table` is the row's own table and `row` its values as
    /// the server sent them, by column name. Throws when a key column is missing from the row or NULL (no row then).
    public static func referenced(by key: SchemaForeignKey, from table: SchemaTable, row: [String: [UInt8]?],
                                  context: EditContext) throws -> Related {
        let pairs = try zip(key.columns, key.referencedColumns).map { column, referencedColumn -> String in
            guard let schemaColumn = table.column(column), let stored = row[column] else {
                throw EditError("The result has no \(column), which the foreign key \(key.name) needs")
            }
            guard let stored else { throw EditError("\(column) is NULL, so it refers to no row") }
            return SQLQuote.identifier(referencedColumn) + " = " + ColumnType(schemaColumn).literal(stored: stored, context)
        }
        let condition = pairs.joined(separator: " AND ")
        return Related(database: key.referencedDatabase, table: key.referencedTable, foreignKey: key.name,
                       condition: condition, sql: "SELECT * FROM " + SQLQuote.identifier(key.referencedDatabase, key.referencedTable)
                        + " WHERE " + condition)
    }

    /// The rows that refer to a row (parent to children): one entry per foreign key, in any database whose details are
    /// loaded, that points at `table`; a key whose referenced values are missing from the row or NULL has none.
    public static func referencing(database: String, table: SchemaTable, row: [String: [UInt8]?], snapshot: SchemaSnapshot,
                                   context: EditContext) -> [Related] {
        let caseless = snapshot.server?.caselessNames == true
        func same(_ a: String, _ b: String) -> Bool { caseless ? a.caseInsensitiveCompare(b) == .orderedSame : a == b }
        var related: [Related] = []
        for childDatabase in snapshot.databases {
            for child in childDatabase.tables {
                for key in child.foreignKeys where same(key.referencedDatabase, database) && same(key.referencedTable, table.name) {
                    let pairs = zip(key.columns, key.referencedColumns).map { column, referencedColumn -> String? in
                        guard let parentColumn = table.column(referencedColumn), let stored = row[referencedColumn] ?? nil
                        else { return nil }
                        return SQLQuote.identifier(column) + " = " + ColumnType(parentColumn).literal(stored: stored, context)
                    }
                    guard pairs.allSatisfy({ $0 != nil }) else { continue }
                    let condition = pairs.compactMap { $0 }.joined(separator: " AND ")
                    related.append(Related(database: childDatabase.name, table: child.name, foreignKey: key.name, condition: condition,
                                           sql: "SELECT * FROM " + SQLQuote.identifier(childDatabase.name, child.name)
                                            + " WHERE " + condition))
                }
            }
        }
        return related
    }

    /// The labels of the referenced rows whose one-column key has these values: `SELECT key, label … WHERE key IN (…)`.
    /// Nil for a composite key, or when no value fits the key's type.
    public static func labels(_ key: SchemaForeignKey, referenced: SchemaTable, label: String, values: [String],
                              context: EditContext) -> String? {
        guard key.referencedColumns.count == 1, let column = referenced.column(key.referencedColumns[0]) else { return nil }
        let type = ColumnType(column)
        let literals = values.compactMap { try? type.literal($0, context) }
        guard !literals.isEmpty else { return nil }
        let name = SQLQuote.identifier(column.name)
        return "SELECT \(name), \(SQLQuote.identifier(label)) FROM " + SQLQuote.identifier(key.referencedDatabase, key.referencedTable)
            + " WHERE \(name) IN (" + literals.joined(separator: ", ") + ")"
    }

    /// Text for a LIKE pattern with ESCAPE '!': the wildcards % and _, and ! itself, match only themselves. ('!' rather
    /// than a backslash, which NO_BACKSLASH_ESCAPES would turn into an ordinary character.)
    static func likeEscaped(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if character == "!" || character == "%" || character == "_" { escaped.append("!") }
            escaped.append(character)
        }
        return escaped
    }
}

extension SchemaSnapshot {
    /// A copy with virtual foreign keys (by database and table) added to its tables' own.
    public func adding(_ virtualKeys: [String: [String: [SchemaForeignKey]]]) -> SchemaSnapshot {
        guard !virtualKeys.isEmpty else { return self }
        var copy = self
        for index in copy.databases.indices {
            guard let tables = virtualKeys[copy.databases[index].name] else { continue }
            for table in copy.databases[index].tables.indices {
                copy.databases[index].tables[table].foreignKeys += tables[copy.databases[index].tables[table].name] ?? []
            }
        }
        return copy
    }
}
