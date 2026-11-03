import CMariaDB

/// A console result set as the grid shows it (the console result tab of `GridSource`'s embedding notes): every row is
/// in memory, so no cell is ever `.loading`. Read-only for now; very long values are shortened on screen (never a key
/// column's), their whole text kept in the store for copying.
public final class ResultSetSource: GridSource {
    public let store: ResultStore
    public let columns: [GridColumn]
    /// The most characters a cell shows.
    static let shownLimit = 1_000

    public init(_ store: ResultStore) {
        self.store = store
        columns = store.columns.map { column in
            let kind: GridColumn.Kind
            if column.isNumeric { kind = .number } else if column.type == MYSQL_TYPE_JSON { kind = .json } else if column.isBinary {
                kind = .binary
            } else if [MYSQL_TYPE_DATE, MYSQL_TYPE_NEWDATE, MYSQL_TYPE_TIME, MYSQL_TYPE_DATETIME, MYSQL_TYPE_TIMESTAMP,
                        MYSQL_TYPE_YEAR].contains(column.type) {
                kind = .date
            } else {
                kind = .text
            }
            return GridColumn(name: column.name, type: column.typeName, kind: kind, isKey: column.flags & UInt32(PRI_KEY_FLAG) != 0)
        }
    }

    public var rowCount: Int { store.rowCount }

    public func cell(_ row: Int, _ column: Int) -> GridCell {
        guard !store.isNull(row, column) else { return .null }
        let text = store.display(row, column) ?? ""
        guard !columns[column].isKey, text.count > Self.shownLimit else { return .text(text) }
        return .text(String(text.prefix(Self.shownLimit)) + "…")
    }

    /// The whole value, for copying: nil for NULL.
    public func value(_ row: Int, _ column: Int) -> String? {
        store.isNull(row, column) ? nil : store.display(row, column) ?? ""
    }
}

extension ResultStore.Column {
    /// The column's type as the header's second line and agents' replies show it: "int unsigned", "varchar", "datetime".
    public var typeName: String {
        let names: [enum_field_types: String] = [
            MYSQL_TYPE_TINY: "tinyint", MYSQL_TYPE_SHORT: "smallint", MYSQL_TYPE_INT24: "mediumint", MYSQL_TYPE_LONG: "int",
            MYSQL_TYPE_LONGLONG: "bigint", MYSQL_TYPE_DECIMAL: "decimal", MYSQL_TYPE_NEWDECIMAL: "decimal", MYSQL_TYPE_FLOAT: "float",
            MYSQL_TYPE_DOUBLE: "double", MYSQL_TYPE_BIT: "bit", MYSQL_TYPE_DATE: "date", MYSQL_TYPE_NEWDATE: "date",
            MYSQL_TYPE_TIME: "time", MYSQL_TYPE_DATETIME: "datetime", MYSQL_TYPE_TIMESTAMP: "timestamp", MYSQL_TYPE_YEAR: "year",
            MYSQL_TYPE_JSON: "json", MYSQL_TYPE_ENUM: "enum", MYSQL_TYPE_SET: "set", MYSQL_TYPE_GEOMETRY: "geometry",
            MYSQL_TYPE_VARCHAR: "varchar", MYSQL_TYPE_VAR_STRING: isBinary ? "varbinary" : "varchar",
            MYSQL_TYPE_STRING: isBinary ? "binary" : "char", MYSQL_TYPE_TINY_BLOB: isBinary ? "tinyblob" : "tinytext",
            MYSQL_TYPE_BLOB: isBinary ? "blob" : "text", MYSQL_TYPE_MEDIUM_BLOB: isBinary ? "mediumblob" : "mediumtext",
            MYSQL_TYPE_LONG_BLOB: isBinary ? "longblob" : "longtext", MYSQL_TYPE_NULL: "null", MYSQL_TYPE_VECTOR: "vector",
        ]
        let name = names[type] ?? ""
        return isNumeric && flags & UInt32(UNSIGNED_FLAG) != 0 ? name + " unsigned" : name
    }

    /// A number column, right-aligned: DECIMAL, the integers, FLOAT, DOUBLE.
    public var isNumeric: Bool {
        [MYSQL_TYPE_DECIMAL, MYSQL_TYPE_NEWDECIMAL, MYSQL_TYPE_TINY, MYSQL_TYPE_SHORT, MYSQL_TYPE_INT24, MYSQL_TYPE_LONG,
         MYSQL_TYPE_LONGLONG, MYSQL_TYPE_FLOAT, MYSQL_TYPE_DOUBLE].contains(type)
    }
}
