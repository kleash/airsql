import CMariaDB
import Foundation

/// What agents read, sized for their context: the compact schema (one line per table) and result rows as JSON or CSV.
public enum AgentFormat {
    /// Longer values are cut in replies (files keep them whole).
    public static let cellLimit = 2_000
    /// The system databases, left out of a whole-server schema.
    static let systemDatabases: Set<String> = ["information_schema", "mysql", "performance_schema", "sys"]

    // MARK: The compact schema

    /// A database as compact text: a line per table, view and sequence with its columns, keys and indexes, then its
    /// routines, triggers and events. Without details (not loaded yet): the names only.
    static func compact(_ database: SchemaDatabase) -> String {
        var lines: [String] = []
        for table in database.tables {
            guard database.detailsLoaded else { continue }
            lines.append(compact(table, in: database.name))
        }
        if !database.detailsLoaded {
            for kind in [SchemaTable.Kind.table, .view, .sequence] {
                let names = database.tables.filter { $0.kind == kind }.map { name($0.name) }
                if !names.isEmpty { lines.append("\(kind.rawValue)s: " + names.joined(separator: ", ")) }
            }
        }
        if !database.routines.isEmpty {
            lines.append("routines: " + database.routines.map { routine in
                "\(routine.kind.rawValue) \(name(routine.name))" + (routine.returns.map { " → \($0)" } ?? "")
            }.joined(separator: ", "))
        }
        if !database.triggers.isEmpty {
            lines.append("triggers: " + database.triggers.map {
                "\(name($0.name)) (\($0.timing) \($0.event) on \(name($0.table)))"
            }.joined(separator: ", "))
        }
        if !database.events.isEmpty {
            lines.append("events: " + database.events.map { name($0.name) }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// One table: `name: col type PK AI, col type NULL ='x' → other.id; UNIQUE(a, b); KEY(c) -- comment`.
    static func compact(_ table: SchemaTable, in database: String) -> String {
        let primary = table.primaryKey?.parts.compactMap(\.column) ?? []
        let singleForeign = Dictionary(table.foreignKeys.filter { $0.columns.count == 1 }.map { ($0.columns[0], $0) }) { a, _ in a }
        let columns = table.columns.map { column -> String in
            var text = name(column.name) + " " + column.columnType
            if primary == [column.name] { text += " PK" }
            if column.autoIncrement { text += " AI" }
            if column.nullable { text += " NULL" }
            if let generated = column.generated {
                text += " AS (\(generated.expression))" + (generated.stored ? " STORED" : "")
            } else {
                switch column.defaultValue {
                case .value(let value): text += " =" + SQLQuote.string(value)
                case .expression(let expression): text += " =" + expression
                case .none, .null: break
                }
            }
            if let update = column.onUpdate { text += " ON UPDATE " + update }
            if let key = singleForeign[column.name] { text += " → " + reference(key, from: database) }
            return text
        }
        var parts = [columns.joined(separator: ", ")]
        if primary.count > 1 { parts.append("PK(" + primary.map(name).joined(separator: ", ") + ")") }
        for key in table.foreignKeys where key.columns.count > 1 {
            parts.append("FK(" + key.columns.map(name).joined(separator: ", ") + ") → " + reference(key, from: database))
        }
        for index in table.indexes where !index.isPrimary {
            let kind = index.unique ? "UNIQUE" : ["FULLTEXT", "SPATIAL"].contains(index.type) ? index.type : "KEY"
            parts.append(kind + "(" + index.parts.map { $0.column.map(name) ?? "(" + ($0.expression ?? "") + ")" }
                .joined(separator: ", ") + ")")
        }
        let prefix = table.kind == .table ? "" : table.kind.rawValue + " "
        let comment = table.comment.isEmpty ? "" : " -- " + String(table.comment.prefix(100))
        return prefix + name(table.name) + ": " + parts.joined(separator: "; ") + comment
    }

    private static func reference(_ key: SchemaForeignKey, from database: String) -> String {
        let table = (key.referencedDatabase == database ? "" : name(key.referencedDatabase) + ".") + name(key.referencedTable)
        return key.referencedColumns.count == 1 ? table + "." + name(key.referencedColumns[0])
            : table + "(" + key.referencedColumns.map(name).joined(separator: ", ") + ")"
    }

    /// A name as SQL takes it: bare when it is a plain word, else quoted.
    static func name(_ name: String) -> String {
        let plain = name.first.map { $0 == "_" || ($0.isASCII && $0.isLetter) } == true
            && name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
        return plain ? name : SQLQuote.identifier(name)
    }

    // MARK: Rows

    /// A cell for a reply: text (cut at `cellLimit`), or null.
    static func cell(_ rows: ResultStore, _ row: Int, _ column: Int, limit: Int? = cellLimit) -> Any {
        guard let text = rows.display(row, column) else { return NSNull() }
        guard let limit, text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    /// The columns' names and types.
    static func columns(_ rows: ResultStore) -> (names: [String], types: [String]) {
        (rows.columns.map(\.name), rows.columns.map(typeName))
    }

    /// The rows (the first `count`) as arrays of text or null.
    public static func json(_ rows: ResultStore, count: Int? = nil, limit: Int? = cellLimit) -> [[Any]] {
        (0..<min(count ?? rows.rowCount, rows.rowCount)).map { row in
            (0..<rows.columns.count).map { cell(rows, row, $0, limit: limit) }
        }
    }

    /// The rows (the first `count`) as CSV (RFC 4180), after a header line unless `header` is false. NULL is an empty
    /// field, the empty string "".
    static func csv(_ rows: ResultStore, count: Int? = nil, header: Bool = true, limit: Int? = cellLimit) -> String {
        var lines: [String] = header ? [rows.columns.map { csvField($0.name) }.joined(separator: ",")] : []
        for row in 0..<min(count ?? rows.rowCount, rows.rowCount) {
            lines.append((0..<rows.columns.count).map { column in
                (cell(rows, row, column, limit: limit) as? String).map(csvField) ?? ""
            }.joined(separator: ","))
        }
        return lines.map { $0 + "\r\n" }.joined()
    }

    static func csvField(_ text: String) -> String {
        guard text.isEmpty || text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A column type's name, as the server's protocol gives it.
    static func typeName(_ column: ResultStore.Column) -> String {
        switch column.type {
        case MYSQL_TYPE_TINY: return "tinyint"
        case MYSQL_TYPE_SHORT: return "smallint"
        case MYSQL_TYPE_INT24: return "mediumint"
        case MYSQL_TYPE_LONG: return "int"
        case MYSQL_TYPE_LONGLONG: return "bigint"
        case MYSQL_TYPE_DECIMAL, MYSQL_TYPE_NEWDECIMAL: return "decimal"
        case MYSQL_TYPE_FLOAT: return "float"
        case MYSQL_TYPE_DOUBLE: return "double"
        case MYSQL_TYPE_BIT: return "bit"
        case MYSQL_TYPE_DATE, MYSQL_TYPE_NEWDATE: return "date"
        case MYSQL_TYPE_TIME, MYSQL_TYPE_TIME2: return "time"
        case MYSQL_TYPE_DATETIME, MYSQL_TYPE_DATETIME2: return "datetime"
        case MYSQL_TYPE_TIMESTAMP, MYSQL_TYPE_TIMESTAMP2: return "timestamp"
        case MYSQL_TYPE_YEAR: return "year"
        case MYSQL_TYPE_JSON: return "json"
        case MYSQL_TYPE_ENUM: return "enum"
        case MYSQL_TYPE_SET: return "set"
        case MYSQL_TYPE_GEOMETRY: return "geometry"
        case MYSQL_TYPE_NULL: return "null"
        case MYSQL_TYPE_TINY_BLOB, MYSQL_TYPE_MEDIUM_BLOB, MYSQL_TYPE_LONG_BLOB, MYSQL_TYPE_BLOB:
            return column.isBinary ? "blob" : "text"
        case MYSQL_TYPE_STRING: return column.isBinary ? "binary" : "char"
        default: return column.isBinary ? "varbinary" : "varchar"
        }
    }
}
