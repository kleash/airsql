/// What the schema cache needs from a database session: run one statement and read its rows as text.
///
/// The schema session's `DBConnection` conforms (below). Every value comes as the server's text (the text
/// protocol), SQL NULL as nil, and every row comes back: no row cap (the columns of 3,000 tables are tens of thousands
/// of rows). A statement without a result set (`SET`) returns no rows. The cache sends one statement at a time and only
/// from its own background task, so the session needn't serialize them for it.
public protocol SchemaQuerying {
    func rows(_ sql: String) async throws -> [[String?]]
}

/// The schema session answers the cache's queries: every row (no row cap), each cell as text, nil for NULL.
extension DBConnection: SchemaQuerying {
    public func rows(_ sql: String) async throws -> [[String?]] {
        guard let store = try await query(sql, rowCap: .max).first?.rows else { return [] }
        return (0..<store.rowCount).map { row in (0..<store.columns.count).map { store.string(row, $0) } }
    }
}
