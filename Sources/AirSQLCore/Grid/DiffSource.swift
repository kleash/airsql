import Foundation

/// Two sides' rows matched by key, as the grid shows them (`GridSource`'s diff): the compare window's rows that differ,
/// and a console result compared with another result or a table. First the rows only the first side has (`.inserted`:
/// a sync would add them to the second), then those only the second has (`.deleted`), then those both have with other
/// values (`.edited` on the cells that differ). Cells show the first side's values; a changed cell's note gives both.
public final class DiffSource: GridSource {
    public let data: ReconTableData
    public let columns: [GridColumn]
    /// The two sides as people know them ("Production" and "Staging", "Result 2" and "Result 1").
    public let names: (first: String, second: String)
    /// The most characters a cell shows (never a key column's): copying takes the whole value.
    static let shownLimit = 1_000

    /// `columns`: how the grid shows each of `data.columns` (a result's types); nil: from the compare's kinds.
    public init(_ data: ReconTableData, names: (first: String, second: String), columns: [GridColumn]? = nil) {
        self.data = data
        self.names = names
        self.columns = data.columns.enumerated().map { index, compared in
            let key = data.key.contains(compared.name)
            var column = columns?[index] ?? GridColumn(name: compared.name, kind: compared.gridKind)
            // The key icon marks what rows were matched on.
            column.isKey = key
            if key { column.marks.insert(.primary) } else { column.marks.remove(.primary) }
            return column
        }
    }

    public var rowCount: Int { data.differenceCount }

    /// The row as shown (the second side's for a row only it has), and what changed in it.
    private func entry(_ row: Int) -> (values: ReconRow, change: ReconRowChange?) {
        let missing = data.missing.count, extra = data.extra.count
        if row < missing { return (data.missing[row], nil) }
        if row < missing + extra { return (data.extra[row - missing], nil) }
        let change = data.changed[row - missing - extra]
        return (change.source, change)
    }

    public func mark(_ row: Int, _ column: Int) -> GridMark {
        let missing = data.missing.count, extra = data.extra.count
        if row < missing { return .inserted }
        if row < missing + extra { return .deleted }
        return data.changed[row - missing - extra].columns.contains(column) ? .edited : .none
    }

    public func bytes(_ row: Int, _ column: Int) -> [UInt8]? { entry(row).values.values[column] }

    public func value(_ row: Int, _ column: Int) -> String? {
        entry(row).values.text(column, kind: data.columns[column].kind)
    }

    /// The value, shortened past `shownLimit` characters: a long BLOB isn't turned into megabytes of hex at every draw.
    public func cell(_ row: Int, _ column: Int) -> GridCell {
        guard let bytes = bytes(row, column) else { return .null }
        let kind = data.columns[column].kind
        if columns[column].isKey { return .text(value(row, column) ?? "") }
        if [.binary, .blob, .bit].contains(kind) {
            let shown = Self.shownLimit / 2
            return .text((ReconRow([Array(bytes.prefix(shown))]).text(0, kind: kind) ?? "") + (bytes.count > shown ? "…" : ""))
        }
        let text = String(decoding: bytes.prefix(4 * Self.shownLimit), as: UTF8.self)
        guard text.count > Self.shownLimit || bytes.count > 4 * Self.shownLimit else { return .text(text) }
        return .text(String(text.prefix(Self.shownLimit)) + "…")
    }

    /// A changed cell's two values: "Staging has 17.50; Production has 19.90".
    public func note(_ row: Int, _ column: Int) -> String? {
        guard let change = entry(row).change, change.columns.contains(column) else { return nil }
        let kind = data.columns[column].kind
        func shown(_ values: ReconRow) -> String { values.text(column, kind: kind).map { String($0.prefix(300)) } ?? "NULL" }
        return "\(names.second) has \(shown(change.target)); \(names.first) has \(shown(change.source))"
    }
}

extension ReconColumn {
    /// How the grid shows the column's values.
    var gridKind: GridColumn.Kind {
        switch kind {
        case .integer, .decimal, .float: return .number
        case .bit, .binary, .blob: return .binary
        case .json: return .json
        case .temporal: return .date
        case .text, .longText: return .text
        }
    }
}
