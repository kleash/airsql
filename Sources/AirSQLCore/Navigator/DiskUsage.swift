import Foundation

/// One row of Disk Usage, of the database view's sizes and of the host page's databases: a database, a table, an index
/// or a partition. A size nobody has read yet is nil.
public struct DiskUsageRow: Hashable {
    public var name: String
    /// What it is, in a few words: "12 tables", an engine, "Index", "Partition".
    public var detail: String
    public var data: Int?
    public var index: Int?
    public var free: Int?
    /// An estimate for InnoDB.
    public var rows: Int?

    public init(name: String, detail: String, data: Int? = nil, index: Int? = nil, free: Int? = nil, rows: Int? = nil) {
        self.name = name
        self.detail = detail
        self.data = data
        self.index = index
        self.free = free
        self.rows = rows
    }

    /// Data plus indexes: the space it holds on purpose. nil until a size is known.
    public var total: Int? { data == nil && index == nil ? nil : (data ?? 0) + (index ?? 0) }
}

/// The figures of Disk Usage, from the statistics the schema cache keeps (`SchemaDatabase.statistics`), and the two
/// reads behind a table's indexes and partitions.
public enum DiskUsage {
    /// Every database of the snapshot. One whose statistics weren't read has no sizes.
    public static func databases(_ snapshot: SchemaSnapshot) -> [DiskUsageRow] {
        snapshot.databases.map { database in
            var row = sum(tables(of: database), name: database.name)
            let count = database.tables.filter { $0.kind != .view }.count
            row.detail = "\(count) table\(count == 1 ? "" : "s")"
            return row
        }
    }

    /// A database's tables and sequences: views take no space.
    public static func tables(of database: SchemaDatabase) -> [DiskUsageRow] {
        database.tables.filter { $0.kind != .view }.map { table in
            let stats = database.statistics?[table.name]
            return DiskUsageRow(name: table.name, detail: table.engine ?? "", data: stats?.dataLength, index: stats?.indexLength,
                                free: stats?.dataFree, rows: stats?.rows)
        }
    }

    /// `rows` added up, as one row. A figure none of them knows stays nil.
    public static func sum(_ rows: [DiskUsageRow], name: String) -> DiskUsageRow {
        func added(_ value: KeyPath<DiskUsageRow, Int?>) -> Int? {
            let known = rows.compactMap { $0[keyPath: value] }
            return known.isEmpty ? nil : known.reduce(0, Self.adding)
        }
        return DiskUsageRow(name: name, detail: "", data: added(\.data), index: added(\.index), free: added(\.free), rows: added(\.rows))
    }

    /// A server's figures can't overflow in practice, but they come from the server: a wrong one mustn't stop the app.
    private static func adding(_ first: Int, _ second: Int) -> Int {
        let (sum, overflow) = first.addingReportingOverflow(second)
        return overflow ? .max : sum
    }

    /// "1.2 GB"; nothing when it isn't known.
    public static func size(_ bytes: Int?) -> String {
        guard let bytes else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false  // 0 KB, not Zero KB
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// "12.5%" of `whole`; nothing when either isn't known or the whole is empty.
    public static func share(_ part: Int?, of whole: Int) -> String {
        guard let part, whole > 0 else { return "" }
        return String(format: "%.1f%%", Double(part) / Double(whole) * 100)
    }

    /// What several selected rows come to, in a line: their totals, and how the largest compares with the smallest.
    public static func summary(_ rows: [DiskUsageRow]) -> String {
        let all = sum(rows, name: "")
        var text = "\(rows.count) selected: \(size(all.total ?? 0)) (\(size(all.data ?? 0)) data, \(size(all.index ?? 0)) indexes), "
            + "\(size(all.free ?? 0)) free, about \((all.rows ?? 0).formatted()) rows"
        let totals = rows.compactMap(\.total).sorted()
        if totals.count > 1, let least = totals.first, let most = totals.last, least > 0 {
            text += String(format: "; the largest is %.1f× the smallest", Double(most) / Double(least))
        }
        return text
    }

    /// A table's partitions (and subpartitions) with their sizes. A table without any has one row, with no name.
    public static func partitionsSQL(_ table: DatabaseObject, noBackslashEscapes: Bool) -> String {
        "SELECT PARTITION_NAME, SUBPARTITION_NAME, PARTITION_METHOD, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH, DATA_FREE "
            + "FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA = "
            + SQLQuote.string(table.database, noBackslashEscapes: noBackslashEscapes) + " AND TABLE_NAME = "
            + SQLQuote.string(table.name, noBackslashEscapes: noBackslashEscapes) + " AND PARTITION_NAME IS NOT NULL "
            + "ORDER BY PARTITION_ORDINAL_POSITION, SUBPARTITION_ORDINAL_POSITION"
    }

    public static func partitions(_ rows: [[String?]]) -> [DiskUsageRow] {
        rows.compactMap { row in
            guard row.count >= 7, let name = row[0] else { return nil }
            func number(_ index: Int) -> Int? { row[index].flatMap { Int($0) } }
            return DiskUsageRow(name: row[1].map { name + " / " + $0 } ?? name,
                                detail: "Partition" + (row[2].map { " (\($0))" } ?? ""), data: number(4), index: number(5),
                                free: number(6), rows: number(3))
        }
    }

    /// What each InnoDB index of a table takes, from the statistics InnoDB keeps in the `mysql` database, which not
    /// every login may read. A partitioned table has a row per partition there, as `name#P#part` (MySQL 8: `#p#`).
    public static func indexSizesSQL(_ table: DatabaseObject, noBackslashEscapes: Bool) -> String {
        "SELECT index_name, SUM(stat_value) * @@innodb_page_size FROM mysql.innodb_index_stats WHERE database_name = "
            + SQLQuote.string(table.database, noBackslashEscapes: noBackslashEscapes)
            + " AND SUBSTRING_INDEX(SUBSTRING_INDEX(table_name, '#P#', 1), '#p#', 1) = "
            + SQLQuote.string(table.name, noBackslashEscapes: noBackslashEscapes)
            + " AND stat_name = 'size' GROUP BY index_name"
    }

    /// What a table's level lists. A partition's size holds its share of the table's rows and every index, so beside
    /// partitions the indexes are named without sizes: the same bytes would count twice.
    public static func parts(indexes: [DiskUsageRow], partitions: [DiskUsageRow]) -> [DiskUsageRow] {
        (partitions.isEmpty ? indexes : indexes.map { DiskUsageRow(name: $0.name, detail: $0.detail) }) + partitions
    }

    /// Rows for the indexes named, with the sizes `rows` gave for them. InnoDB's clustered index is the table's data, so
    /// GEN_CLUST_INDEX, which isn't one anyone made, stays out, and the primary key's size counts as data.
    public static func indexes(_ names: [String], sizes rows: [[String?]]) -> [DiskUsageRow] {
        var sizes: [String: Int] = [:]
        for row in rows where row.count >= 2 {
            // SUM gives a decimal on some servers.
            if let name = row[0], let size = row[1].flatMap({ Double($0) }) { sizes[name] = Int(exactly: size.rounded()) }
        }
        let all = names + sizes.keys.filter { !names.contains($0) && $0 != "GEN_CLUST_INDEX" }.sorted()
        return all.map { name in
            name == "PRIMARY" ? DiskUsageRow(name: name, detail: "Index with rows", data: sizes[name])
                : DiskUsageRow(name: name, detail: "Index", index: sizes[name])
        }
    }
}
