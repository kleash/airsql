import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// The table tab against the lab (lane L2): paging `fixture.big` (a million rows) on the data session, the status
/// bar's counts, Count Rows Exactly, and the header's details from the result and the schema.
extension AppTests {
    /// A window with the lab's MariaDB 11.8 as Production's open connection.
    func labWindow(_ flavor: String = "mariadb") async throws -> (MainWindowController, AgentServer, Connection) {
        let connection = Connection(options: DBLab.options(DBLab.server(flavor), tls: DBLab.required), log: DBLab.log)
        try await connection.connect()
        ConsoleViewController.openConnection = { $0 == Fixtures.production.id ? connection : nil }
        let model = testModel(Fixtures.shop)
        model.states[Fixtures.production.id] = .connected(server: "MariaDB 11.8")
        let (main, harness) = appWindow(model)
        main.sidebar.select([Fixtures.production.id])
        return (main, harness, connection)
    }

    @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
    func tableTabPagesAMillionRowsAndCountsThem() async throws {
        let (main, harness, connection) = try await labWindow()
        defer { ConsoleViewController.openConnection = { _ in nil } }
        defer { Task { await connection.disconnect() } }

        // Open Table… asks for the name; database.table opens its tab.
        #expect(await call(harness, "menu", ["path": "Data > Open Table…"]).error == nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        _ = await call(harness, "type", ["text": "fixture.big"])
        #expect(await call(harness, "press", ["title": "Open"]).error == nil)
        _ = await call(harness, "wait", ["until": "idle", "timeout": 30])
        let table = try #require(main.selectedTab?.content as? TableDataViewController)
        #expect(main.selectedTab?.title == "big")
        let source = try #require(table.source)
        #expect(source.rowCount == 1_000 && !source.isComplete)
        #expect(source.columns.first?.isKey == true && source.columns.first?.marks.contains(.primary) == true)
        #expect(source.cell(0, 0) == .text("1"))
        let rows = table.viewer.status.rows.stringValue
        #expect(rows.hasPrefix("1,000 of ≈"), "\(rows)")
        #expect(main.statusBar.accessory.arrangedSubviews.first === table.viewer.status)

        // Load More adds the next page with OFFSET.
        let more = await call(harness, "menu", ["path": "Data > Load More"])
        #expect(more.error == nil, "\(more.error ?? "")")
        _ = await call(harness, "wait", ["until": "idle", "timeout": 30])
        #expect(source.rowCount == 2_000 && source.cell(1_999, 0) == .text("2000"))

        // Count Rows Exactly replaces the estimate.
        #expect(await call(harness, "menu", ["path": "Data > Count Rows Exactly"]).error == nil)
        _ = await call(harness, "wait", ["until": "idle", "timeout": 60])
        #expect(table.viewer.status.rows.stringValue == "2,000 of 1,000,000 rows")
        #expect(table.total?.exact == true)
    }

    @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
    func tableTabHeaderShowsTheSchemasDetails() async throws {
        let (main, _, connection) = try await labWindow()
        defer { ConsoleViewController.openConnection = { _ in nil } }
        defer { Task { await connection.disconnect() } }
        let cache = SchemaCache(source: try await connection.session(.schema), includes: { $0 == "fixture" })
        try await cache.load()
        let schema = try #require(cache.snapshot.table("fixture", "orders"))
        let table = main.openTableData(connection: connection, id: Fixtures.production.id, database: "fixture", table: "orders",
                                       filter: "status = 'paid'", schema: schema).content as? TableDataViewController
        #expect(await eventually(timeout: 30) { table?.source != nil && table?.running == nil })
        let columns = try #require(table?.source?.columns)
        #expect(columns.map(\.name) == ["id", "customer_id", "ordered_at", "status", "total", "note"])
        #expect(columns[0].typeLine == "int(11) · auto" || columns[0].typeLine == "int · auto")
        #expect(columns[1].marks == [.foreign, .indexed])
        #expect(columns[3].typeLine.hasSuffix(" · default") && columns[5].marks == [.nullable])
        // A filter has no estimate: the rows loaded, then all of them once a page comes back short.
        let rows = table?.viewer.status.rows.stringValue ?? ""
        #expect(rows.hasSuffix(" rows") && !rows.contains("≈"), "\(rows)")
    }
}
