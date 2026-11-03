import Foundation

/// A collation the server has, and the character set it belongs to.
public struct Collation: Hashable {
    public var name: String
    public var charset: String
    /// The character set's default collation.
    public var isDefault: Bool
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
        let rows = try await source.rows("SELECT ENGINE, TABLE_COLLATION, TABLE_COMMENT, AUTO_INCREMENT, ROW_FORMAT "
                                         + "FROM information_schema.TABLES WHERE TABLE_SCHEMA = " + literal(database)
                                         + " AND TABLE_NAME = " + literal(table))
        guard let row = rows.first, row.count >= 5 else { throw DesignError("\(database).\(table) isn't on the server any more") }
        let options = TableOptions(engine: row[0], collation: row[1], comment: row[2] ?? "", autoIncrement: row[3].flatMap { UInt64($0) },
                                   rowFormat: row[4])
        guard server.flavour == .mariadb else { return (options, []) }
        guard server.atLeast(10, 5, 10) else { return (options, nil) }
        let checks = try await source.rows("SELECT CONSTRAINT_NAME FROM information_schema.CHECK_CONSTRAINTS WHERE CONSTRAINT_SCHEMA = "
                                           + literal(database) + " AND TABLE_NAME = " + literal(table) + " AND LEVEL = 'Column'")
        return (options, Set(checks.compactMap { $0.first ?? nil }))
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
