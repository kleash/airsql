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
            // New Database, Find Text and Process List reach the sidebar from anywhere in the window.
            #expect(main.supplementalTarget(forAction: Commands.processList.action, sender: nil) as AnyObject? === sidebar)
            #expect(main.supplementalTarget(forAction: Commands.drop.action, sender: nil) == nil)
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

        @Test func aFilterThatMatchesNothingSaysSoAndHowToClearIt() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            main.sidebar.filter.stringValue = "zzz-nothing"
            main.sidebar.reload()
            let outline = main.sidebar.outline
            let rows = (0..<outline.numberOfRows).compactMap { outline.view(atColumn: 0, row: $0, makeIfNecessary: true) }
            let texts = rows.compactMap { find(NSTextField.self, in: $0)?.stringValue }
            #expect(texts == ["CONNECTIONS", "Nothing matches “zzz-nothing”", "Esc in the filter shows everything"], "\(texts)")
            main.sidebar.filter.stringValue = ""
            main.sidebar.reload()
            #expect(outline.numberOfRows > 3)
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
            #expect(main.tabs.count == 2 && main.selectedTab?.content is TableDataController)
            // Open Data on the same table shows that tab again.
            main.sidebar.openData(nil)
            #expect(main.tabs.count == 2 && main.selectedTab?.content is TableDataController)
        }

        @Test func theDatabaseViewsColumnsFitTheWindowAtItsDefaultSize() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            let view = DatabaseViewController(open, "airsql_fixture")
            main.open(view, title: "airsql_fixture", connection: id)
            main.window?.layoutIfNeeded()
            let visible = try #require(view.table.enclosingScrollView).contentView.bounds.width
            #expect(view.table.frame.width <= visible + 1, "the table is \(view.table.frame.width) wide in \(visible)")
            for column in view.table.tableColumns {
                #expect(column.width >= column.minWidth - 0.5, "\(column.title): \(column.width) < \(column.minWidth)")
            }
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

        /// Every navigator screen and dialog, light and dark, at the window's smallest and usual size: every control says
        /// what it does, and nothing is cut, crosses a rounded edge or overlaps.
        @Test func everyScreenIsExplainedAndTidy() async throws {
            var problems: [String] = []
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for size in [MainWindowController.minimumSize, MainWindowController.defaultSize] {
                    let place = "\(appearance == .aqua ? "light" : "dark") \(Int(size.width))×\(Int(size.height))"
                    problems += try await screens(NSAppearance(named: appearance), size: size, place: place)
                }
            }
            #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
        }

        private func screens(_ look: NSAppearance?, size: NSSize, place: String) async throws -> [String] {
            var problems: [String] = []
            let model = testModel(Fixtures.shop + Fixtures.odd)
            let (main, harness) = appWindow(model, size: size)
            let window = try #require(main.window)
            window.appearance = look
            let open = await openReplayed(model, id)
            func check(_ what: String, _ target: NSWindow) {
                target.appearance = look
                target.contentView?.layoutSubtreeIfNeeded()
                if let content = target.contentView { problems += layoutProblems(content, where: "\(place) \(what)") }
                problems += unexplained([target], where: "\(place) \(what)")
            }
            let database = try #require(treeRow(main, .database(id, "airsql_fixture")))
            _ = treeRow(main, .object(id, DatabaseObject(.table, "airsql_fixture", "we`ird 'name' ✓")))
            _ = await call(harness, "click", ["x": database.point.0, "y": database.point.1])
            _ = await eventually(timeout: 10) { open.loading.isEmpty }
            check("tree and database view", window)
            let list = ProcessListContent(open)
            main.open(list, title: "Processes", connection: id)
            _ = await eventually(timeout: 10) { !list.isRefreshing }
            list.show([ServerProcess(id: 1_234_567, user: String(repeating: "reporting_user_", count: 3), host: "warehouse-0001.example.com:65000",
                                     database: "analytics", command: "Query", time: 86_400, state: "Creating sort index",
                                     info: String(repeating: "SELECT day, COUNT(*) FROM visits GROUP BY day; ", count: 6), queryID: 9)])
            check("process list", window)
            main.open(FindTextContent(open, database: nil), title: "Find Text", connection: id)
            check("find text", window)
            let orders = DatabaseObject(.table, "airsql_fixture", "orders")
            let dialogs: [(String, () -> Void)] = [
                ("new database", { NavigatorActions.newDatabase(AppTests.ScreenshotTests.choices, on: open, window: window) }),
                ("copy table", { NavigatorActions.copyTable(orders, on: open, window: window) }),
                ("bulk editor", { NavigatorActions.bulkEdit([orders], AppTests.ScreenshotTests.choices, on: open, window: window) }),
                ("rename", { NavigatorActions.rename(orders, on: open, window: window) }),
                ("drop", { NavigatorActions.drop([orders], on: open, window: window) }),
            ]
            for (name, show) in dialogs {
                show()
                _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
                if let sheet = window.attachedSheet { check(name, sheet) } else { problems.append("\(place) \(name): no sheet") }
                _ = await call(harness, "press", ["title": "Cancel", "in": "sheet"])
                _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            }
            return problems
        }

        @Test func theKillButtonsSayWhyTheyAreOffUntilAProcessIsSelected() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            let list = ProcessListContent(open)
            main.open(list, title: "Processes", connection: id)
            list.show([ServerProcess(id: 42, user: "app", host: "10.0.0.5:50500", database: "shop", command: "Query", time: 3,
                                     state: "Sending data", info: "SELECT * FROM orders", queryID: 7)])
            let killQuery = try #require(find(NSButton.self, id: "processes.killQuery", in: list.view))
            let killConnection = try #require(find(NSButton.self, id: "processes.killConnection", in: list.view))
            #expect(!killQuery.isEnabled && killQuery.toolTip == "Select a process that is running a statement first")
            #expect(!killConnection.isEnabled && killConnection.toolTip == "Select a process first")
            list.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            #expect(killQuery.isEnabled && killQuery.toolTip == Commands.killQuery.tip)
            #expect(killConnection.isEnabled && killConnection.toolTip == Commands.killConnection.tip)
        }

        @Test func findTextSaysWhatItNeedsAndItsResultsHaveAMenu() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            let findText = FindTextContent(open, database: nil)
            main.open(findText, title: "Find Text", connection: id)
            let go = try #require(find(NSButton.self, id: "find.go", in: findText.view))
            #expect(!go.isEnabled && go.toolTip == "Type the text to find first")
            findText.field.stringValue = "Ada"
            findText.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: findText.field))
            #expect(go.isEnabled && go.toolTip == "Search the tables for the text (Return)")
            // A right-click offers what a double-click does first, then the table's commands; each says what it does.
            let menu = try #require(findText.table.menu)
            #expect(menu.items.map(\.title) == ["Open Matching Rows", "Open Data", "Copy Name"])
            #expect(menu.items.allSatisfy { $0.toolTip?.isEmpty == false && $0.target === findText })
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
            #expect(await call(harness, "press", ["title": "Cancel", "in": "sheet"]).error == nil)
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        }
    }
}
