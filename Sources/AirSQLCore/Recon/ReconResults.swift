import CMariaDB
import Foundation

/// A console result compared with another result, or with a table's rows (Compare With…): the data compare's matching
/// and values (`ReconTableSQL.same`: numbers, floats and JSON as values), without its checksums, since both sides' rows
/// are in memory.
extension ReconTableData {
    /// The most rows of a table a result is compared with: as many as a console result holds.
    public static let tableRows = 100_000

    /// `first`'s rows against `second`'s, in the columns both have (by name, in `first`'s order), matched on the `key`
    /// columns' exact values (every compared column when `key` is empty, so rows differ only as missing and extra).
    /// Rows sharing a key pair up in the order they come. `missing` (only in `first`), `extra` (only in `second`) and
    /// `changed` keep their result's order. Not compared, saying why, when no columns or a `key` column aren't in both.
    public static func compare(_ first: ResultStore, _ second: ResultStore, key: [String]) -> ReconTableData {
        func index(_ name: String, in columns: [ResultStore.Column]) -> Int? {
            columns.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        // The compared columns: where each is in `first` and in `second`.
        var pairs: [(Int, Int)] = []
        for (column, info) in first.columns.enumerated() where index(info.name, in: first.columns) == column {
            if let other = index(info.name, in: second.columns) { pairs.append((column, other)) }
        }
        guard !pairs.isEmpty else { return ReconTableData(outcome: .notCompared("The two have no columns of the same name.")) }
        var data = ReconTableData(outcome: .same)
        data.columns = pairs.map { pair in
            // MariaDB sends JSON as text: a column either side calls JSON is compared as JSON.
            var column = ReconColumn(first.columns[pair.0])
            if ReconColumn(second.columns[pair.1]).kind == .json { column.kind = .json }
            return column
        }
        var keyed: [Int] = []
        for name in key {
            guard let column = data.columns.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                return ReconTableData(outcome: .notCompared("“\(name)” isn't a column of both, so rows can't be matched on it."))
            }
            keyed.append(column)
        }
        data.key = keyed.map { data.columns[$0].name }
        data.sourceRows = first.rowCount
        data.targetRows = second.rowCount
        let matched = keyed.isEmpty ? Array(pairs.indices) : keyed, compared = pairs.indices.filter { !matched.contains($0) }
        func values(_ store: ResultStore, _ row: Int, _ columns: [Int], first: Bool) -> [[UInt8]?] {
            columns.map { store.bytes(row, first ? pairs[$0].0 : pairs[$0].1) }
        }
        // The second's rows by key, the last first, so popLast takes them in their order.
        var waiting: [[[UInt8]?]: [Int]] = [:]
        for row in (0..<second.rowCount).reversed() { waiting[values(second, row, matched, first: false), default: []].append(row) }
        let all = Array(pairs.indices)
        for row in 0..<first.rowCount {
            guard let other = waiting[values(first, row, matched, first: true)]?.popLast() else {
                data.missing.append(ReconRow(values(first, row, all, first: true)))
                continue
            }
            let differing = compared.filter {
                !ReconTableSQL.same(first.bytes(row, pairs[$0].0), second.bytes(other, pairs[$0].1), data.columns[$0].kind)
            }
            if !differing.isEmpty {
                data.changed.append(ReconRowChange(source: ReconRow(values(first, row, all, first: true)),
                                                   target: ReconRow(values(second, other, all, first: false)), columns: differing))
            }
        }
        data.extra = waiting.values.joined().sorted().map { ReconRow(values(second, $0, all, first: false)) }
        data.outcome = data.differenceCount == 0 ? .same : .different
        return data
    }

    /// `result`'s rows against those of `database`.`table`, read on `session`: the table's columns the result has, at
    /// most `tableRows` rows (more: not compared, saying how to compare fewer).
    public static func compare(_ result: ResultStore, table: String, database: String, on session: DBConnection,
                               key: [String]) async throws -> ReconTableData {
        let name = SQLQuote.identifier(database, table)
        let names = try await ReconQuery.store(session, "SELECT * FROM \(name) LIMIT 0").columns.map(\.name)
        let shared = result.columns.map(\.name).filter { column in
            names.contains { $0.caseInsensitiveCompare(column) == .orderedSame }
        }
        guard !shared.isEmpty else { return ReconTableData(outcome: .notCompared("\(table) has none of the result's columns.")) }
        let rows = try await ReconQuery.store(session, "SELECT " + shared.map { SQLQuote.identifier($0) }.joined(separator: ", ")
                                                 + " FROM \(name) LIMIT \(tableRows + 1)")
        guard rows.rowCount <= tableRows else {
            return ReconTableData(outcome: .notCompared("\(table) has more than \(tableRows.formatted()) rows: compare the result of "
                + "a query with a WHERE instead, or whole tables with Tools ▸ Compare."))
        }
        return compare(result, rows, key: key)
    }
}

extension ReconColumn {
    /// A result's column, its kind from the type the server sent.
    public init(_ column: ResultStore.Column) {
        name = column.name
        switch column.type {
        case MYSQL_TYPE_TINY, MYSQL_TYPE_SHORT, MYSQL_TYPE_INT24, MYSQL_TYPE_LONG, MYSQL_TYPE_LONGLONG: kind = .integer
        case MYSQL_TYPE_DECIMAL, MYSQL_TYPE_NEWDECIMAL: kind = .decimal
        case MYSQL_TYPE_FLOAT, MYSQL_TYPE_DOUBLE: kind = .float
        case MYSQL_TYPE_BIT: kind = .bit
        case MYSQL_TYPE_JSON: kind = .json
        case MYSQL_TYPE_DATE, MYSQL_TYPE_NEWDATE, MYSQL_TYPE_TIME, MYSQL_TYPE_DATETIME, MYSQL_TYPE_TIMESTAMP, MYSQL_TYPE_YEAR:
            kind = .temporal
        case MYSQL_TYPE_TINY_BLOB, MYSQL_TYPE_BLOB, MYSQL_TYPE_MEDIUM_BLOB, MYSQL_TYPE_LONG_BLOB, MYSQL_TYPE_GEOMETRY:
            kind = column.isBinary ? .blob : .longText
        default: kind = column.isBinary ? .binary : .text
        }
    }
}
