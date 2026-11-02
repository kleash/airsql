/// What the schema cache needs from a database session: run one statement and read its rows as text.
///
/// The schema session's `DBConnection` conforms with a small adapter. Every value comes as the server's text (the text
/// protocol), SQL NULL as nil, and every row comes back: no row cap (the columns of 3,000 tables are tens of thousands
/// of rows). A statement without a result set (`SET`) returns no rows. The cache sends one statement at a time and only
/// from its own background task, so the session needn't serialize them for it.
public protocol SchemaQuerying {
    func rows(_ sql: String) async throws -> [[String?]]
}
