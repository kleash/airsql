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
            #expect(view.rows.filter(\.kind.isTableLike).count == 8)
            #expect(main.selectedTab?.title == "airsql_fixture")
            // A click on a table shows it in the same tab; a double-click gives it a tab of its own.
            let orders = try #require(treeRow(main, .object(id, DatabaseObject(.table, "airsql_fixture", "orders"))))
            _ = await call(harness, "click", ["x": orders.point.0, "y": orders.point.1])
            #expect(main.tabs.count == 1 && main.selectedTab?.title == "orders")
            _ = await call(harness, "click", ["x": orders.point.0, "y": orders.point.1, "count": 2])
            // It takes over from the preview: no second tab of the same table.
            #expect(await eventually(timeout: 5) { main.tabs.count == 1 })
            #expect(main.selectedTab?.content is TableDataController)
            // Open Data on the same table shows that tab again.
            main.sidebar.openData(nil)
            #expect(main.tabs.count == 1 && main.selectedTab?.content is TableDataController)
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

        @Test func newOnAGroupMakesOneOfItsKindAndSaysWhyNotOtherwise() async throws {
            let id = Fixtures.production.id
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            _ = await openReplayed(model, id)
            let outline = main.sidebar.outline
            let fixture = try #require(main.sidebar.treeNodes[.database(id, "airsql_fixture")])
            outline.expandItem(fixture)
            func select(_ kind: SidebarNode.Kind) throws {
                let row = outline.row(forItem: try #require(main.sidebar.treeNodes[kind]))
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let new = Commands.createObject.item()

            try select(.database(id, "airsql_fixture"))
            #expect(main.validateEditorItem(new)?.enabled == false)
            #expect(main.validateEditorItem(new)?.reason?.isEmpty == false)

            try select(.category(id, "airsql_fixture", .view))
            #expect(main.validateEditorItem(new)?.enabled == true)
            main.createObject(new)
            #expect(await eventually(timeout: 5) { main.selectedTab?.content is ObjectEditorController })

            try select(.category(id, "airsql_fixture", .table))
            main.createObject(new)
            #expect(await eventually(timeout: 5) { main.selectedTab?.content is TableEditorController })
        }

        /// A click previews at once; arrow keys wait for the row they stop on.
        @Test func arrowingThroughTheTreeReadsOnlyTheRowItStopsOn() async throws {
            let id = Fixtures.production.id
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            let outline = main.sidebar.outline
            let first = try #require(open.snapshot.database("airsql_fixture")?.tables.map(\.name).sorted().first)
            let start = try #require(treeRow(main, .object(id, DatabaseObject(.table, "airsql_fixture", first)))?.row)
            outline.selectRowIndexes(IndexSet(integer: start), byExtendingSelection: false)
            let shown = main.selectedTab?.title
            #expect(shown != nil)
            // The arrow as the run loop hands it over: the current event while the outline takes it.
            let arrow = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: main.window?.windowNumber ?? 0, context: nil,
                                                      characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                                                      isARepeat: false, keyCode: 125))
            for _ in 0..<2 {
                NSApp.postEvent(arrow, atStart: true)
                let event = try #require(NSApp.nextEvent(matching: .keyDown, until: .distantFuture, inMode: .default, dequeue: true))
                outline.keyDown(with: event)
            }
            // The rest of the run's selections aren't arrow keys.
            let other = try #require(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
            NSApp.postEvent(other, atStart: true)
            _ = NSApp.nextEvent(matching: .applicationDefined, until: .distantFuture, inMode: .default, dequeue: true)
            let stopped = try #require(outline.item(atRow: start + 2) as? SidebarNode)
            #expect(outline.selectedRow == start + 2)
            #expect(main.selectedTab?.title == shown, "nothing read yet")
            guard case .object(_, let object) = stopped.kind else { throw AirSQLError(.other, "not an object") }
            #expect(await eventually(timeout: 5) { main.selectedTab?.title == object.name })
        }

        @Test func theProcessListSortsFiltersAndHidesSleepers() async throws {
            let id = Fixtures.production.id
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            let list = ProcessListContent(open)
            main.open(list, title: "Processes", connection: id)
            _ = await eventually(timeout: 10) { !list.isRefreshing }
            func process(_ id: UInt64, _ user: String, _ command: String, time: Int) -> ServerProcess {
                ServerProcess(id: id, user: user, host: "h", database: nil, command: command, time: time, state: nil,
                              info: command == "Sleep" ? nil : "SELECT \(id)", queryID: nil)
            }
            list.show([process(1, "ann", "Sleep", time: 900), process(2, "bob", "Query", time: 9),
                       process(3, "cid", "Query", time: 100)])
            list.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

            // Time compares as a number, and the header's first click puts the longest first.
            let time = try #require(list.table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("time")))
            list.table.sortDescriptors = [try #require(time.sortDescriptorPrototype)]
            #expect(list.processes.map(\.id) == [1, 3, 2])
            #expect(list.selected.map(\.id) == [2], "the selection follows its row")

            list.hideSleeping.state = .on
            list.hideSleeping.sendAction(list.hideSleeping.action, to: list.hideSleeping.target)
            #expect(list.processes.map(\.id) == [3, 2])
            list.filter.stringValue = "SELECT 3"
            list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            #expect(list.processes.map(\.id) == [3])

            list.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            list.copy(nil)
            #expect(NSPasteboard.general.string(forType: .string)?.hasPrefix("3\tcid\th") == true)
        }

        @Test func commandCCopiesTheNamesOfTheRowsSelected() async throws {
            let id = Fixtures.production.id
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            _ = await openReplayed(model, id)
            let copy = Commands.copy.item()
            main.sidebar.select([id])
            #expect(main.sidebar.validateMenuItem(copy))
            main.sidebar.copy(nil)
            #expect(NSPasteboard.general.string(forType: .string) == Fixtures.production.displayName)
            let row = try #require(treeRow(main, .object(id, DatabaseObject(.table, "airsql_fixture", "orders")))?.row)
            main.sidebar.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            main.sidebar.copy(nil)
            #expect(NSPasteboard.general.string(forType: .string) == "`orders`")
        }

        @Test func quickOpenFindsTablesAndConnectionsByPartOfTheirName() async throws {
            let id = Fixtures.production.id
            let model = testModel(Fixtures.shop)
            let (main, harness) = appWindow(model)
            _ = await openReplayed(model, id)
            #expect(await call(harness, "menu", ["path": "File > Quick Open…"]).error == nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            let sheet = try #require(main.window?.attachedSheet?.windowController as? QuickOpenSheet)
            #expect(sheet.shown.contains { $0.place == "Connection" } && sheet.shown.contains { $0.name == "orders" })
            sheet.field.stringValue = "ORDERS"
            sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            #expect(sheet.shown.first?.name == "orders" && sheet.table.selectedRow == 0)
            let editor = NSTextView()
            #expect(sheet.control(sheet.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            #expect(await eventually(timeout: 5) { main.window?.attachedSheet == nil && main.tabs.contains { $0.title == "orders" } })
            #expect(main.selectedTab?.content is TableDataController)
        }

        @Test func aDoubleClickOnADatabaseOpensItAndAnotherClosesIt() async throws {
            let id = Fixtures.production.id
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            let fixture = try #require(main.sidebar.treeNodes[.database(id, "airsql_fixture")])
            main.sidebar.treeDoubleClicked(fixture)
            #expect(await eventually(timeout: 5) { main.sidebar.outline.isItemExpanded(fixture) })
            #expect(open.currentDatabase == "airsql_fixture")
            main.sidebar.treeDoubleClicked(fixture)
            #expect(await eventually(timeout: 5) { !main.sidebar.outline.isItemExpanded(fixture) })
        }

        /// A connected connection opens and closes on a double-click (and Return), and stays as it was left over a reload.
        @Test func aDoubleClickOnAConnectedConnectionOpensAndClosesItsTree() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            _ = await openReplayed(model, id)
            let sidebar = main.sidebar, outline = sidebar.outline
            sidebar.select([id])
            let row = try #require(outline.item(atRow: outline.selectedRow) as? SidebarNode)
            #expect(row.connectionID == id && outline.isItemExpanded(row))
            let doubleClick = try #require(outline.doubleAction)
            NSApp.sendAction(doubleClick, to: outline.target, from: outline)
            #expect(await eventually(timeout: 5) { !outline.isItemExpanded(row) })
            sidebar.reload()
            #expect(!outline.isItemExpanded(row))
            NSApp.sendAction(doubleClick, to: outline.target, from: outline)
            #expect(await eventually(timeout: 5) { outline.isItemExpanded(row) })
        }

        /// A table's row opens to what the schema cache knows of it, with no query, and stays open over a reload.
        @Test func aTableOpensToItsColumnsIndexesAndKeys() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            let sidebar = main.sidebar, outline = sidebar.outline
            let orders = DatabaseObject(.table, "airsql_fixture", "orders")
            _ = try #require(treeRow(main, .object(id, orders)))
            let table = try #require(sidebar.treeNodes[.object(id, orders)])
            #expect(outline.isExpandable(table) && table.children.isEmpty)  // nothing is made until it opens
            outline.expandItem(table)
            let schema = try #require(open.snapshot.database("airsql_fixture")?.table("orders"))
            let columns = try #require(sidebar.treeNodes[.part(id, orders, .columns)])
            #expect(table.children.first === columns && columns.children.compactMap(\.name) == schema.columns.map(\.name))
            #expect(table.children.contains { $0.name == "Indexes" } && table.children.contains { $0.name == "Foreign Keys" })
            // The key's column says so, in the icon's flag and in words.
            let key = try #require(schema.primaryKey?.parts.first?.column)
            let keyRow = try #require(columns.children.first { $0.name == key })
            #expect(keyRow.detail?.isKey == true && keyRow.detail?.about.contains("primary key") == true)

            // A reload keeps it open with the same column selected, its rows made again from the new snapshot.
            outline.expandItem(columns)
            outline.selectRowIndexes([outline.row(forItem: keyRow)], byExtendingSelection: false)
            sidebar.reload()
            let kept = try #require(sidebar.treeNodes[.detail(id, orders, .columns, key)])
            #expect(outline.row(forItem: kept) >= 0 && sidebar.selectedNodes.first === kept)

            // A column's row copies its name, opens its table, and reaches nothing that changes the table.
            #expect(sidebar.selectedObjects.isEmpty)
            sidebar.dropObject(nil)
            #expect(main.window?.attachedSheet == nil)
            sidebar.copy(nil)
            #expect(NSPasteboard.general.string(forType: .string) == "`\(key)`")
            sidebar.treeDoubleClicked(kept)
            #expect(await eventually(timeout: 5) { main.selectedTab?.title.contains("orders") == true })
            #expect(sidebar.treeMenu([kept]).items.compactMap { $0.isSeparatorItem ? nil : $0.title }
                    == ["Open Structure", "Open Data", "Copy Name", "Copy Name Without Quotes", "Find Where Used…"])

            // A group's Expand All stops at the tables: it doesn't open them, or the tree would drown in columns.
            let tables = try #require(sidebar.treeNodes[.category(id, "airsql_fixture", .table)])
            outline.collapseItem(tables)
            outline.selectRowIndexes([outline.row(forItem: tables)], byExtendingSelection: false)
            sidebar.expandAll(nil)
            #expect(outline.isItemExpanded(tables))
            let customers = try #require(tables.children.first { $0.name == "customers" })
            #expect(!outline.isItemExpanded(customers))
        }

        /// A view has columns only.
        @Test func aViewOpensToItsColumnsOnly() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            let sidebar = main.sidebar
            let view = try #require(open.snapshot.database("airsql_fixture")?.tables.first { $0.kind == .view })
            let parts = sidebar.tableParts(id, DatabaseObject(.view, "airsql_fixture", view.name))
            #expect(parts.compactMap(\.name) == ["Columns"])
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

        @Test func findTextResultsSortByTheirHeadersAndKeepTheSelection() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            let findText = FindTextContent(open, database: nil)
            main.open(findText, title: "Find Text", connection: id)
            findText.matches = [("a", 9), ("c", 100), ("b", 20)].map {
                FindTextContent.Match(table: DatabaseObject(.table, "shop", $0.0), columns: ["x"], rows: $0.1)
            }
            findText.table.reloadData()
            findText.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            let rows = try #require(findText.table.tableColumn(withIdentifier: .init("rows"))?.sortDescriptorPrototype)
            #expect(!rows.ascending, "the most matches first")
            findText.table.sortDescriptors = [rows]
            #expect(findText.matches.map(\.rows) == [100, 20, 9], "as numbers, not text")
            #expect(findText.table.selectedRow == 0, "the selected match moved with its row")
            findText.table.sortDescriptors = [NSSortDescriptor(key: "table", ascending: true)]
            #expect(findText.matches.map(\.table.name) == ["a", "b", "c"])
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

        /// The current database is one per connection: a double-click in the tree, the toolbar's database pop-up and New
        /// Query from a database's menu all make it current, and the tree, the toolbar and the console show the same one.
        @Test func theTreeTheToolbarAndTheConsoleShareTheCurrentDatabase() async throws {
            let model = testModel(Fixtures.shop)
            model.states[id] = .connected(server: "MariaDB 11.8.3")
            let (main, harness) = appWindow(model)
            let open = await openReplayed(model, id)
            let popup = main.toolbarController.databasePopup
            let fixture = try #require(treeRow(main, .database(id, "airsql_fixture")))
            _ = await call(harness, "click", ["x": fixture.point.0, "y": fixture.point.1, "count": 2])
            #expect(open.currentDatabase == "airsql_fixture" && popup.title == "airsql_fixture" && popup.isEnabled)
            // The pop-up lists the cached databases, the current one chosen.
            #expect(popup.itemTitles == ["airsql other", "airsql_fixture"] && popup.titleOfSelectedItem == "airsql_fixture")
            #expect(popup.lastItem?.toolTip == "Run this query tab's statements in airsql_fixture from now on")
            // As choosing it does (the harness doesn't reach the toolbar's pop-ups).
            popup.menu?.performActionForItem(at: popup.indexOfItem(withTitle: "airsql other"))
            #expect(open.currentDatabase == "airsql other" && popup.title == "airsql other")
            let other = try #require(main.openConsole(text: "", title: nil, connection: id).content as? ConsoleViewController)
            #expect(other.database == "airsql other")
            _ = await eventually { main.window?.firstResponder === other.editor }  // the console takes the focus as it shows
            // New Query from a database's menu: a console in that database, which is current now.
            _ = await call(harness, "click", ["x": fixture.point.0, "y": fixture.point.1, "button": "right"])
            #expect(await call(harness, "menu", ["path": "context > New Query"]).error == nil)
            let console = try #require(main.selectedTab?.content as? ConsoleViewController)
            #expect(console !== other && console.connectionID == id && console.database == "airsql_fixture")
            #expect(open.currentDatabase == "airsql_fixture" && other.database == "airsql_fixture")
            #expect(popup.title == "airsql_fixture")
        }

        /// Generate SELECT, INSERT and UPDATE (the tree's and the database view's menus) open a console tab with the
        /// statement built from the cached columns; Run… stays off for what isn't a procedure or function.
        @Test func generateOpensAConsoleTabWithTheStatement() async throws {
            let model = testModel(Fixtures.shop)
            let (main, harness) = appWindow(model)
            let open = await openReplayed(model, id)
            let orders = try #require(treeRow(main, .object(id, DatabaseObject(.table, "airsql_fixture", "orders"))))
            _ = await call(harness, "click", ["x": orders.point.0, "y": orders.point.1, "button": "right"])
            #expect(await call(harness, "menu", ["path": "context > Generate UPDATE"]).error == nil)
            #expect(await eventually { main.selectedTab?.content is ConsoleViewController })
            let console = try #require(main.selectedTab?.content as? ConsoleViewController)
            #expect(console.connectionID == id && console.text == "UPDATE `airsql_fixture`.`orders`\n"
                    + "SET `customer_id` = ?, `region` = ?, `number` = ?, `total` = ?, `parent_id` = ?\nWHERE `id` = ?;\n")
            #expect(console.messagesView.messages.last?.text.hasPrefix("Press Run to fill in each value") == true)
            // The database view's table menu does the same.
            let view = DatabaseViewController(open, "airsql_fixture")
            main.open(view, title: "airsql_fixture", connection: id)
            let row = try #require(view.rows.firstIndex { $0.name == "log" })
            view.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            view.generateSelect(nil)
            #expect(await eventually { (main.selectedTab?.content as? ConsoleViewController)?.text == "SELECT `at`, `message`\nFROM `airsql_fixture`.`log`;\n" })
            let trigger = try #require(main.sidebar.treeNodes[.category(id, "airsql_fixture", .trigger)]?.children.first)
            main.sidebar.outline.expandItem(main.sidebar.treeNodes[.category(id, "airsql_fixture", .trigger)])
            main.sidebar.outline.selectRowIndexes(IndexSet(integer: main.sidebar.outline.row(forItem: trigger)), byExtendingSelection: false)
            let run = Commands.runRoutine.item()
            #expect(!main.sidebar.validateMenuItem(run) && run.toolTip == "Select one procedure or function first")
        }
    }
}
