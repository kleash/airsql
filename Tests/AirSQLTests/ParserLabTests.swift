import Foundation
import Testing
@testable import AirSQLCore

/// The parser against a real server: what it calls wrong, MariaDB calls wrong too, and what it builds runs. PREPARE
/// only parses and checks, so nothing here runs a statement but the previews' SELECTs.
@Suite(.enabled(if: Lab.enabled), .serialized) struct ParserLabTests {
    func session() async throws -> DBConnection {
        let session = DBConnection(options: DBLab.options(Lab.mariadb114, tls: DBLab.required), role: .main, log: DBLab.log)
        try await session.connect()
        _ = await run("USE \(SQLQuote.identifier(Lab.fixture))", on: session)
        return session
    }

    func run(_ sql: String, on session: DBConnection) async -> ConsoleOutcome {
        await ConsoleRunner.run(SQLSplitter.statements(in: sql)[0], in: sql, on: session, timeout: 0)
    }

    /// 1064 when the server can't parse `sql`.
    func serverError(_ sql: String, on session: DBConnection) async -> Int? {
        let outcome = await run("PREPARE parser_check FROM " + SQLQuote.string(sql), on: session)
        return outcome.error?.code
    }

    @Test func whatTheParserRefusesTheServerRefuses() async throws {
        let session = try await session()
        for sql in ["SELECT FROM t", "SELECT a, FROM t", "SELECT a FROM", "SELECT a FROM WHERE b", "SELECT a FROM t WHERE", "SELECT a FROM t WHERE AND b",
                    "SELECT a FROM t GROUP a", "SELECT a FROM t ORDER BY a WHERE b", "SELECT a FROM t LIMIT 1 ORDER BY a", "SELECT a b c FROM t", "SELECT 1)",
                    "SELECT a FROM t JOIN", "SELECT CASE a THEN 1 END", "SELECT CASE WHEN a THEN 1", "SELECT a IS 1", "SELECT a IN 1", "SELECT a BETWEEN 1",
                    "SELECT INTERVAL 1", "INSERT INTO t", "INSERT INTO t VALUES", "UPDATE t", "UPDATE t SET", "UPDATE t SET a", "DELETE t", "CREATE VIEW v SELECT 1"] {
            #expect(SQLParser.parse(sql)[0].errors.count == 1, "\(sql)")
            let code = await serverError(sql, on: session)
            #expect(code == 1064, "\(sql): \(String(describing: code))")
        }
        await session.close()
    }

    @Test func whatTheServerParsesTheParserDoesToo() async throws {
        let session = try await session()
        for sql in ReadCorpus.all where SQLParser.parse(sql).count == 1 {
            let code = await serverError(sql, on: session)
            let wrong = SQLParser.parse(sql)[0].errors.first?.message
            if code != 1064 { #expect(wrong == nil, "\(sql)") }
        }
        await session.close()
    }

    @Test func aRealSchemaResolvesAndPreviewsRun() async throws {
        let session = try await session()
        let cache = SchemaCache(source: session, includes: { $0 == Lab.fixture })
        try await cache.load()
        try await cache.loadDetails([Lab.fixture])
        let sql = "WITH big AS (SELECT o.customer_id, SUM(i.quantity) AS total FROM orders o JOIN order_items i ON i.order_id = o.id GROUP BY o.customer_id) "
            + "SELECT c.name, b.total FROM customers c JOIN big b ON b.customer_id = c.id ORDER BY b.total DESC"
        #expect(await run(sql, on: session).error == nil)
        let analysis = SQLAnalysis(sql, snapshot: cache.snapshot, database: Lab.fixture)
        #expect(SQLInspections.problems(analysis).isEmpty)
        let write = "UPDATE customers c JOIN orders o ON o.customer_id = c.id SET c.name = 'x' WHERE o.id = 1 ORDER BY c.id"
        let read = SQLAnalysis(write, snapshot: cache.snapshot, database: Lab.fixture)
        let preview = try #require(SQLIntentions.preview(of: read.statements[0], in: read))
        let outcome = await run(preview, on: session)
        #expect(outcome.error == nil, "\(preview)")
        await session.close()
    }
}
