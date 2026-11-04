import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// The table tab against the lab: paging `fixture.big` (a million rows) on the data session, the status bar's counts,
/// Count Rows Exactly, the header's details from the schema, and Column Summary on the server.
extension AppTests {
    /// A window with a table tab on `table` of the lab's MariaDB 11.8 `fixture`, once its first rows are shown.
    func labTableTab(_ table: String, filter: String? = nil) async throws -> (MainWindowController, AgentServer, TableDataController) {
        let connection = Connection(options: DBLab.options(DBLab.server("mariadb")), log: DBLab.log)
        let schema = SchemaCache(source: try await connection.session(.schema), includes: { $0 == "fixture" })
        try await schema.load()
        let saved = SavedConnection(name: "Lab MariaDB 11.8", host: "127.0.0.1", user: "airsql")
        let model = testModel([saved])
        model.states[saved.id] = .connected(server: "MariaDB 11.8")
        let (main, harness) = appWindow(model)
        let context = EditorContext(connection: saved, sessions: connection, schema: schema)
        main.openTableData(table, database: "fixture", context: context, condition: filter)
        let tab = try #require(main.selectedTab?.content as? TableDataController)
        main.window?.layoutIfNeeded()
        _ = await eventually(timeout: 30) { tab.source != nil && tab.loading == nil }
        return (main, harness, tab)
    }

    @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
    func tableTabPagesAMillionRowsAndCountsThem() async throws {
        let (main, harness, table) = try await labTableTab("big")
        defer { Task { await table.context.sessions.disconnect() } }
        #expect(main.selectedTab?.title == "big")
        let source = try #require(table.source)
        #expect(source.rowCount == 1_000 && source.hasMore)
        #expect(source.columns.first?.isKey == true && source.columns.first?.marks.contains(.primary) == true)
        #expect(source.cell(0, 0) == .text("1"))
        let rows = table.viewer.status.rows.stringValue
        #expect(rows.hasPrefix("1,000 of about "), "\(rows)")
        #expect(main.statusBar.accessory.arrangedSubviews.first === table.viewer.status)

        // Load More adds the next page with OFFSET.
        let more = await call(harness, "menu", ["path": "Data > Load More"])
        #expect(more.error == nil, "\(more.error ?? "")")
        _ = await eventually(timeout: 30) { table.loading == nil && source.rowCount == 2_000 }
        #expect(source.rowCount == 2_000 && source.cell(1_999, 0) == .text("2000"))

        // Count Rows Exactly replaces the estimate.
        #expect(await call(harness, "menu", ["path": "Data > Count Rows Exactly"]).error == nil)
        _ = await eventually(timeout: 60) { table.total?.exact == true }
        #expect(table.viewer.status.rows.stringValue.hasPrefix("2,000 of 1,000,000 rows"))
    }

    @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
    func tableTabHeaderShowsTheSchemasDetails() async throws {
        let (_, _, table) = try await labTableTab("orders", filter: "status = 'paid'")
        defer { Task { await table.context.sessions.disconnect() } }
        let columns = try #require(table.source?.columns)
        #expect(columns.map(\.name) == ["id", "customer_id", "ordered_at", "status", "total", "note"])
        #expect(columns[0].typeLine == "int(11) · auto" || columns[0].typeLine == "int · auto")
        #expect(columns[1].marks == [.foreign, .indexed])
        #expect(columns[3].typeLine.hasSuffix(" · default") && columns[5].marks == [.nullable])
        // A filter has no estimate: the rows loaded, then all of them once a page comes back short.
        let rows = table.viewer.status.rows.stringValue
        #expect(rows.contains(" rows") && !rows.contains("about"), "\(rows)")
    }

    @Test func columnSummaryOfAResultCountsTheRowsInMemory() async throws {
        let source = FakeGridSource(rows: 60, columns: 6)
        let (_, harness, content) = viewerWindow(source)
        content.viewer.grid.selection.selectColumn(5)
        #expect(await call(harness, "menu", ["path": "Data > Column Summary…"]).error == nil)
        let summary = try #require(content.viewer.summaryShown?.summary)
        #expect(summary == ColumnSummary(values: (0..<60).map { source.value($0, 5) }))
    }

    @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
    func columnSummaryOfATableIsCountedOnTheServerAndFiltersByAValue() async throws {
        let (_, harness, table) = try await labTableTab("big")
        defer { Task { await table.context.sessions.disconnect() } }
        let viewer = table.viewer
        viewer.grid.selection.select(GridPosition(row: 0, column: 4))
        #expect(await call(harness, "menu", ["path": "Data > Column Summary…"]).error == nil)
        #expect(await eventually(timeout: 60) { viewer.summaryShown?.summary != nil })
        let summary = try #require(viewer.summaryShown?.summary)
        #expect(summary.distinct == 5 && summary.nulls == 0 && summary.rows == 1_000_000)
        #expect(Set(summary.top.compactMap(\.value)) == ["red", "green", "blue", "cyan", "magenta"])
        #expect(summary.top.map(\.count).reduce(0, +) == 1_000_000)
        // A value clicked filters the rows by it, on the server.
        viewer.summaryShown?.choose?("cyan")
        #expect(table.bar.filterText == "`category` = 'cyan'")
        _ = await eventually(timeout: 30) { table.loading == nil && table.source?.filter == "`category` = 'cyan'" }
        #expect(table.source.map { source in (0..<source.rowCount).allSatisfy { source.value($0, 4) == "cyan" } } == true)
    }
}
