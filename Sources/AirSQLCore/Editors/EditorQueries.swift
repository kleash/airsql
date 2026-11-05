import Foundation

/// A collation the server has, and the character set it belongs to.
public struct Collation: Hashable {
    public var name: String
    public var charset: String
    /// The character set's default collation.
    public var isDefault: Bool
}

/// A partition of a table, as the server counts it (subpartitions are listed by their own names).
public struct TablePartition: Equatable {
    public var name: String
    public var method: String
    public var expression: String
    public var values: String
    public var rows: String
    public var size: Int?
}

/// What the editors read beyond the schema cache, on the editor's own session: a table's options and column checks, the
/// collations and engines to choose from, and who the person is on the server.
public enum EditorQueries {
    /// A table's options, and on MariaDB the names of the checks written in its columns' definitions (nil before 10.5.10,
    /// which doesn't say: there a column's check is the one named after it).
    public static func table(_ database: String, _ table: String, server: SchemaServer, from source: SchemaQuerying)
        async throws -> (options: TableOptions, columnChecks: Set<String>?) {
        let literal = { (text: String) in SQLQuote.string(text, noBackslashEscapes: server.noBackslashEscapes) }
        // MySQL 8 otherwise answers from statistics up to a day old (the next AUTO_INCREMENT among them).
        if server.flavour == .mysql, server.atLeast(8) { _ = try await source.rows("SET SESSION information_schema_stats_expiry = 0") }
        let rows = try await source.rows("SELECT ENGINE, TABLE_COLLATION, TABLE_COMMENT, AUTO_INCREMENT, ROW_FORMAT, CREATE_OPTIONS "
                                         + "FROM information_schema.TABLES WHERE TABLE_SCHEMA = " + literal(database)
                                         + " AND TABLE_NAME = " + literal(table))
        guard let row = rows.first, row.count >= 5 else { throw DesignError("\(database).\(table) isn't on the server any more") }
        var options = TableOptions(engine: row[0], collation: row[1], comment: row[2] ?? "", autoIncrement: row[3].flatMap { UInt64($0) },
                                   rowFormat: row[4])
        if row.count > 5, row[5]?.lowercased().contains("partitioned") == true {
            let create = try await source.rows("SHOW CREATE TABLE " + SQLQuote.identifier(database, table)).first
            options.partitioning = create.flatMap { $0.count > 1 ? $0[1] : nil }.flatMap { partitionClause($0, noBackslashEscapes: server.noBackslashEscapes) }
        }
        guard server.flavour == .mariadb else { return (options, []) }
        guard server.atLeast(10, 5, 10) else { return (options, nil) }
        let checks = try await source.rows("SELECT CONSTRAINT_NAME FROM information_schema.CHECK_CONSTRAINTS WHERE CONSTRAINT_SCHEMA = "
                                           + literal(database) + " AND TABLE_NAME = " + literal(table) + " AND LEVEL = 'Column'")
        return (options, Set(checks.compactMap { $0.first ?? nil }))
    }

    /// The PARTITION BY clause of SHOW CREATE TABLE's text: MySQL wraps it in a version comment, and a table comment may
    /// say the same words.
    static func partitionClause(_ create: String, noBackslashEscapes: Bool) -> String? {
        guard let close = create.range(of: "\n)") else { return nil }
        var tail = String(create[close.upperBound...]).replacingOccurrences(of: "/*!50100 ", with: "")
            .replacingOccurrences(of: "/*!50500 ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.hasSuffix("*/") { tail = String(tail.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let text = Array(tail.utf16)
        let words = SQLLexer.tokens(tail, noBackslashEscapes: noBackslashEscapes).filter { $0.kind == .word }
        let word = { (token: SQLToken) in String(decoding: text[token.range], as: UTF16.self).uppercased() }
        guard let at = words.indices.dropLast().first(where: { word(words[$0]) == "PARTITION" && word(words[$0 + 1]) == "BY" }) else {
            return nil
        }
        return String(decoding: text[words[at].range.lowerBound...], as: UTF16.self)
    }

    /// A partitioned table's partitions, in order.
    public static func partitions(_ database: String, _ table: String, server: SchemaServer, from source: SchemaQuerying) async throws
        -> [TablePartition] {
        let literal = { (text: String) in SQLQuote.string(text, noBackslashEscapes: server.noBackslashEscapes) }
        let rows = try await source.rows("SELECT PARTITION_NAME, SUBPARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, "
                                         + "TABLE_ROWS, DATA_LENGTH + INDEX_LENGTH FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA = "
                                         + literal(database) + " AND TABLE_NAME = " + literal(table)
                                         + " ORDER BY PARTITION_ORDINAL_POSITION, SUBPARTITION_ORDINAL_POSITION")
        return rows.compactMap { row in
            guard row.count >= 7, let name = row[1] ?? row[0] else { return nil }
            return TablePartition(name: name, method: row[2] ?? "", expression: row[3] ?? "", values: row[4] ?? "", rows: row[5] ?? "",
                                  size: row[6].flatMap { Int($0) })
        }
    }

    /// Every collation, by name (MariaDB 10.10 and later: each character set's own names of the UCA 14 collations).
    public static func collations(server: SchemaServer, from source: SchemaQuerying) async throws -> [Collation] {
        let sql = server.flavour == .mariadb && server.atLeast(10, 10)
            ? "SELECT FULL_COLLATION_NAME, CHARACTER_SET_NAME, IS_DEFAULT FROM information_schema.COLLATION_CHARACTER_SET_APPLICABILITY"
            : "SELECT COLLATION_NAME, CHARACTER_SET_NAME, IS_DEFAULT FROM information_schema.COLLATIONS"
        return try await source.rows(sql).compactMap { row -> Collation? in
            guard row.count >= 3, let name = row[0], let charset = row[1] else { return nil }
            return Collation(name: name, charset: charset, isDefault: row[2]?.uppercased() == "YES")
        }.sorted { $0.name < $1.name }
    }

    /// The storage engines tables can use here, the default first.
    public static func engines(from source: SchemaQuerying) async throws -> [String] {
        let rows = try await source.rows("SELECT ENGINE, SUPPORT FROM information_schema.ENGINES WHERE SUPPORT IN ('YES', 'DEFAULT')")
        return rows.compactMap { row -> (String, Bool)? in
            guard row.count >= 2, let name = row[0] else { return nil }
            return (name, row[1] == "DEFAULT")
        }.sorted { ($0.1 ? 0 : 1, $0.0.lowercased()) < ($1.1 ? 0 : 1, $1.0.lowercased()) }.map(\.0)
    }

    /// The account the server knows the person as (user@host), as DEFINER takes it.
    public static func currentAccount(from source: SchemaQuerying) async throws -> String? {
        try await source.rows("SELECT CURRENT_USER()").first?.first ?? nil
    }
}
