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
            return GridColumn(name: column.name, type: column.table.isEmpty ? "" : "from " + column.table, kind: kind,
                              isKey: column.flags & UInt32(PRI_KEY_FLAG) != 0)
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
    /// A number column, right-aligned: DECIMAL, the integers, FLOAT, DOUBLE.
    public var isNumeric: Bool {
        [MYSQL_TYPE_DECIMAL, MYSQL_TYPE_NEWDECIMAL, MYSQL_TYPE_TINY, MYSQL_TYPE_SHORT, MYSQL_TYPE_INT24, MYSQL_TYPE_LONG,
         MYSQL_TYPE_LONGLONG, MYSQL_TYPE_FLOAT, MYSQL_TYPE_DOUBLE].contains(type)
    }
}
