/// What a table's or view's row opens to in the navigator's tree: groups of what the schema cache knows of it, so
/// opening one asks the server nothing.
public enum TablePart: String, CaseIterable, Hashable {
    case columns = "Columns", indexes = "Indexes", foreignKeys = "Foreign Keys", checks = "Checks", triggers = "Triggers"

    /// A row of a group.
    public struct Row: Equatable {
        public var name: String
        /// A few words at the row's right end: a column's type, an index's columns, the table a key points to.
        public var note: String
        /// All of it in words, for the tooltip.
        public var about: String
        /// A column of the primary key.
        public var isKey = false
    }

    public func rows(of table: SchemaTable, in database: SchemaDatabase) -> [Row] {
        switch self {
        case .columns: return table.columns.map { Self.row($0, of: table) }
        case .indexes: return table.indexes.map(Self.row)
        case .foreignKeys: return table.foreignKeys.map(Self.row)
        case .checks:
            return table.checks.map { Row(name: $0.name, note: "", about: "\($0.name): \($0.clause)" + ($0.enforced ? "" : ", not enforced")) }
        case .triggers:
            return database.triggers.filter { $0.table == table.name }.map {
                Row(name: $0.name, note: "\($0.timing) \($0.event)".lowercased(), about: "\($0.name): runs \($0.timing) \($0.event)")
            }
        }
    }

    private static func row(_ column: SchemaColumn, of table: SchemaTable) -> Row {
        let key = table.primaryKey?.parts.contains { $0.column == column.name } == true
        var facts = [column.columnType]
        if key { facts.append("primary key") }
        facts.append(column.nullable ? "NULL allowed" : "not NULL")
        if column.autoIncrement { facts.append("auto-increment") }
        switch column.defaultValue {
        case .value(let text), .expression(let text): facts.append("default \(text)")
        case .none, .null: break
        }
        if let generated = column.generated { facts.append("generated from \(generated.expression)") }
        if column.invisible { facts.append("left out of SELECT *") }
        if !column.comment.isEmpty { facts.append("“\(column.comment)”") }
        return Row(name: column.name, note: column.columnType,
                   about: "\(column.name): " + facts.joined(separator: ", "), isKey: key)
    }

    private static func row(_ index: SchemaIndex) -> Row {
        let parts = index.parts.map { part in
            (part.column ?? part.expression ?? "") + (part.prefixLength.map { "(\($0))" } ?? "") + (part.descending ? " DESC" : "")
        }.joined(separator: ", ")
        var facts = [(index.isPrimary ? "primary key" : index.unique ? "unique index" : "index") + " on \(parts)", index.type]
        if !index.visible { facts.append("not used by the optimizer") }
        if !index.comment.isEmpty { facts.append("“\(index.comment)”") }
        return Row(name: index.name, note: parts, about: "\(index.name): " + facts.joined(separator: ", "))
    }

    private static func row(_ key: SchemaForeignKey) -> Row {
        let target = "\(key.referencedDatabase).\(key.referencedTable) (\(key.referencedColumns.joined(separator: ", ")))"
        return Row(name: key.name, note: key.referencedTable,
                   about: "\(key.name): \(key.columns.joined(separator: ", ")) → \(target), on update \(key.onUpdate), on delete \(key.onDelete)")
    }
}
