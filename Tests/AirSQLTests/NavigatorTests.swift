import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

// The navigator in the app, its schema replayed from a recording (no server): the tree under a connected connection,
// the filter, what a click shows, the database view, the threshold setting and the SQL shown before a drop.
extension AppTests {
    @MainActor @Suite struct NavigatorTests {
        let id = Fixtures.production.id

        @Test func treeShowsTheSchemaGroupedByKindAndOpensItself() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            await openReplayed(model, id)
            let sidebar = main.sidebar
            let fixture = try #require(sidebar.treeNodes[.database(id, "airsql_fixture")])
            #expect(sidebar.treeNodes[.database(id, "airsql other")] != nil)
            #expect(fixture.children.compactMap(\.name) == ["Tables", "Views", "Sequences", "Procedures", "Functions", "Triggers",
                                                            "Events"])
            let tables = try #require(sidebar.treeNodes[.category(id, "airsql_fixture", .table)])
            #expect(Set(tables.children.compactMap(\.object?.name)) == ["audit", "customers", "log", "order_lines", "orders",
                                                                         "we`ird 'name' ✓"])
            #expect(sidebar.treeNodes[.category(id, "airsql_fixture", .procedure)]?.children.compactMap(\.object?.name) == ["add_customer"])
            #expect(sidebar.treeNodes[.category(id, "airsql_fixture", .trigger)]?.children.count == 2)
            // The tree opened itself under the connection, as it showed for the first time.
            let connection = try #require(sidebar.outline.parent(forItem: fixture))
            #expect(sidebar.outline.isItemExpanded(connection))
            // Dragging a table puts its quoted name on the pasteboard; type-to-find reads the names.
            let weird = try #require(tables.children.first { $0.object?.name == "we`ird 'name' ✓" })
            let writer = sidebar.outlineView(sidebar.outline, pasteboardWriterForItem: weird) as? NSPasteboardItem
            #expect(writer?.string(forType: .string) == "`we``ird 'name' ✓`")
            #expect(sidebar.outlineView(sidebar.outline, typeSelectStringFor: nil, item: weird) == "we`ird 'name' ✓")
            // Disconnect empties it.
            model.detach(id)
            _ = await eventually(timeout: 5) { sidebar.treeNodes.isEmpty }
            #expect(sidebar.treeNodes.isEmpty)
        }

        @Test func filterShowsTheObjectsThatMatchOnConnectedConnections() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            await openReplayed(model, id)
            main.sidebar.filter.stringValue = "order"
            main.sidebar.reload()
            let names = Set(main.sidebar.treeNodes.keys.compactMap { kind -> String? in
                if case .object(_, let object) = kind { return object.name }
                return nil
            })
            #expect(names == ["orders", "order_lines", "order_seq", "order_count", "orders_bi", "orders_au"])
            // Shown and opened: the connection (it has matches), its database and the groups.
            let outline = main.sidebar.outline
            let orders = try #require(main.sidebar.treeNodes[.object(id, DatabaseObject(.table, "airsql_fixture", "orders"))])
            #expect(outline.row(forItem: orders) >= 0)
            // A connection whose name matches keeps its whole tree; others without matches are hidden.
            #expect(main.sidebar.selectedConnectionIDs.isEmpty)
            #expect(sidebarRow(main, "Staging · shop") == nil)
            main.sidebar.filter.stringValue = "Production"
            main.sidebar.reload()
            #expect(main.sidebar.treeNodes[.object(id, DatabaseObject(.table, "airsql_fixture", "customers"))] != nil)
        }

        @Test func aClickOnADatabaseShowsItsTablesWithTheirSizes() async throws {
            let model = testModel(Fixtures.shop)
            let (main, harness) = appWindow(model)
            let open = await openReplayed(model, id)
            let row = try #require(treeRow(main, .database(id, "airsql_fixture")))
            _ = await call(harness, "click", ["x": row.point.0, "y": row.point.1])
            let preview = try #require(main.selectedTab?.content as? PreviewContent)
            let view = try #require(preview.shown as? DatabaseViewController)
            _ = await eventually(timeout: 10) { open.snapshot.database("airsql_fixture")?.statistics != nil && open.loading.isEmpty }
            view.reload()
            #expect(view.rows.count == 8)
            #expect(main.selectedTab?.title == "airsql_fixture")
            // A click on a table shows it in the same tab; a double-click opens a tab of its own.
            let orders = try #require(treeRow(main, .object(id, DatabaseObject(.table, "airsql_fixture", "orders"))))
            _ = await call(harness, "click", ["x": orders.point.0, "y": orders.point.1])
            #expect(main.tabs.count == 1 && main.selectedTab?.title == "orders")
            _ = await call(harness, "click", ["x": orders.point.0, "y": orders.point.1, "count": 2])
            #expect(main.tabs.count == 2 && main.selectedTab?.content is TextContent)
        }

        @Test func aBigServerLoadsADatabasesDetailsWhenItOpens() async throws {
            let model = testModel(Fixtures.shop)
            model.data.settings.detailsTableThreshold = 5
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            #expect(open.schema.tableThreshold == 5 && !open.snapshot.detailsUpfront)
            #expect(open.snapshot.database("airsql_fixture")?.detailsLoaded == false)
            let fixture = try #require(main.sidebar.treeNodes[.database(id, "airsql_fixture")])
            main.sidebar.outline.expandItem(fixture)
            _ = await eventually(timeout: 10) { open.snapshot.database("airsql_fixture")?.detailsLoaded == true }
            #expect(open.snapshot.database("airsql_fixture")?.table("orders")?.columns.isEmpty == false)
        }

        @Test func dropShowsTheSQLAndAsksForTheNameOnProduction() async throws {
            let model = testModel(Fixtures.shop)
            let (main, harness) = appWindow(model)
            await openReplayed(model, id)
            let orders = try #require(treeRow(main, .object(id, DatabaseObject(.table, "airsql_fixture", "orders"))))
            _ = await call(harness, "click", ["x": orders.point.0, "y": orders.point.1])
            _ = await call(harness, "click", ["x": orders.point.0, "y": orders.point.1, "button": "right"])
            #expect(await call(harness, "menu", ["path": "context > Drop…"]).error == nil)
            let sheet = await call(harness, "wait", ["until": "sheet", "text": "DROP TABLE `airsql_fixture`.`orders`", "timeout": 10])
            #expect(sheet.error == nil, "\(sheet.error ?? "")")
            // Production's safety: the table's name must be typed.
            #expect(await element(harness, "preview.confirm", in: "sheet") != nil)
            _ = await call(harness, "press", ["title": "Decline"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        }
    }
}
