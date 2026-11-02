import Foundation

extension Recon {
    /// The columns both tables can match rows on: the source's primary key, else one of its unique keys, made of whole
    /// NOT NULL columns, with a unique key on the same columns in the target; nil when there is none.
    static func matchingKey(_ left: SchemaTable, _ right: SchemaTable) -> [String]? {
        func usable(_ table: SchemaTable) -> [[String]] {
            table.indexes.sorted { $0.isPrimary && !$1.isPrimary }.compactMap { index in
                guard index.unique, index.parts.allSatisfy({ $0.column != nil && $0.prefixLength == nil }) else { return nil }
                let columns = index.parts.compactMap(\.column)
                return columns.allSatisfy({ table.column($0)?.nullable == false }) ? columns : nil
            }
        }
        let theirs = usable(right).map { Set($0.map { $0.lowercased() }) }
        return usable(left).first { theirs.contains(Set($0.map { $0.lowercased() })) }
    }

    /// The columns whose values are compared: in both tables, not generated (their values follow from the others), not
    /// left out; the key's columns first. Names as the source has them.
    static func comparedColumns(_ left: SchemaTable, _ right: SchemaTable, key: [String],
                                excluded: [String]) -> [ReconColumn] {
        let left = left.columns.filter { column in
            column.generated == nil && right.column(column.name).map { $0.generated == nil } == true
        }
        let keyColumns = key.compactMap { name in left.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        let others = left.filter { column in
            !key.contains { $0.caseInsensitiveCompare(column.name) == .orderedSame }
                && !excluded.contains { $0.caseInsensitiveCompare(column.name) == .orderedSame }
        }
        return (keyColumns + others).map(ReconColumn.init)
    }

    /// A key whose order both servers walk the same way as they compare it: not ENUM or SET (sorted by their position,
    /// compared as text), floats, BIT, JSON or long types.
    static func rangeable(_ key: [ReconColumn], in table: SchemaTable) -> Bool {
        key.allSatisfy { column in
            [.integer, .decimal, .temporal, .text, .binary].contains(column.kind)
                && !["enum", "set"].contains(table.column(column.name)?.dataType.lowercased() ?? "")
        }
    }

    /// The rows of a table only in the source (within its WHERE), which the script inserts into the table it creates;
    /// generated columns left out.
    static func sourceRows(_ table: SchemaTable, source: ReconSide, choice: ReconTableChoice) async throws -> ReconTableData {
        let columns = table.columns.filter { $0.generated == nil }.map(ReconColumn.init)
        let sql = ReconTableSQL(database: source.database, table: table.name, key: [], columns: columns,
                                filter: choice.filter, noBackslashEscapes: source.session.noBackslashEscapes)
        let store = try await ReconQuery.store(source.session, sql.all(limit: ReconDataCompare.maxDifferences + 1))
        var data = ReconTableData(outcome: store.rowCount == 0 ? .same : .different)
        data.columns = columns
        data.sourceRows = store.rowCount
        guard store.rowCount <= ReconDataCompare.maxDifferences else {
            data.outcome = .tooManyDifferences
            return data
        }
        data.missing = (0..<store.rowCount).map { row in ReconRow((0..<columns.count).map { store.bytes(row, $0) }) }
        return data
    }

    /// Compares a table's rows on both sides; returns the comparison and the rows checked and fetched.
    static func compareData(_ left: SchemaTable, _ right: SchemaTable, source: ReconSide, target: ReconSide,
                            choice: ReconTableChoice, estimatedRows: Int,
                            progress: @escaping (ReconDataCompare.Progress) -> Void) async throws
        -> (ReconTableData, Int, Int) {
        let key = matchingKey(left, right) ?? []
        let columns = comparedColumns(left, right, key: key, excluded: choice.excludedColumns)
        guard !columns.isEmpty else {
            return (ReconTableData(outcome: .notCompared("no columns in common")), 0, 0)
        }
        let keyColumns = Array(columns.prefix(key.count))
        func sql(_ side: ReconSide, _ table: String) -> ReconTableSQL {
            ReconTableSQL(database: side.database, table: table, key: keyColumns, columns: columns, filter: choice.filter,
                          noBackslashEscapes: side.session.noBackslashEscapes)
        }
        let compare = ReconDataCompare(source: source.session, target: target.session, sourceSQL: sql(source, left.name),
                                       targetSQL: sql(target, right.name), estimatedRows: estimatedRows,
                                       rangeable: rangeable(keyColumns, in: left), progress: progress)
        let data = key.isEmpty ? try await compare.checksumOnly() : try await compare.run()
        return (data, compare.rowsChecked, compare.rowsFetched)
    }
}
