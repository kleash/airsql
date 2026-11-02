import Foundation
import Testing
@testable import AirSQLCore

/// The schema cache on every server version of the lab (AIRSQL_LAB=1), reading through a schema session.
@Suite(.serialized, .enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
struct SchemaLabTests {
    @Test(arguments: Lab.direct)
    func loadsTheFixtureAndRefreshesAsAFreshLoadWould(_ server: Lab.Server) async throws {
        let session = DBConnection(options: DBLab.options(server), role: .schema, log: DBLab.log)
        try await session.connect()
        let database = "lane_p0_7_schema"
        _ = try await session.query("DROP DATABASE IF EXISTS " + SQLQuote.identifier(database))
        _ = try await session.query("CREATE DATABASE " + SQLQuote.identifier(database))
        let includes = { [Lab.fixture, database].contains($0) }
        let cache = SchemaCache(source: session, includes: includes)
        try await cache.load()
        let fixture = try #require(cache.snapshot.database(Lab.fixture))
        #expect(fixture.table("customers")?.columns.isEmpty == false)
        #expect(fixture.table("customer_order_totals")?.kind == .view)
        #expect(fixture.table("order details") != nil && fixture.table("x`; DROP TABLE nothing; --") != nil)
        #expect(Set(fixture.routines.map(\.name)).isSuperset(of: ["order_total", "greeting", "customer_orders"]))

        _ = try await session.query("CREATE TABLE \(SQLQuote.identifier(database, "t")) (id INT PRIMARY KEY, note TEXT)")
        try await cache.refresh([.table(database: database, name: "t")])
        let fresh = SchemaCache(source: session, includes: includes)
        try await fresh.load()
        #expect(cache.snapshot.database(database)?.table("t")?.columns.map(\.name) == ["id", "note"])
        #expect(cache.snapshot == fresh.snapshot)
        _ = try await session.query("DROP DATABASE " + SQLQuote.identifier(database))
        await session.close()
    }
}
