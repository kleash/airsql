import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

// The tree lane: fuzzy names, Quick Open for everything, Select in Tree, the tree's modes and filters.
struct FuzzyTests {
    private func score(_ typed: String, _ name: String) -> Int? { FuzzyName(name).score(FuzzyName.words(typed)) }

    @Test func lettersInOrderMatchAcrossWords() {
        #expect(score("fica", "film_category") != nil)
        #expect(score("oli", "order_lines") != nil)
        #expect(score("ORDERS", "orders") != nil)
        #expect(score("sro", "orders") == nil)
        #expect(score("xyz", "orders") == nil)
        #expect(score("Li ord", "order_lines") != nil)
        #expect(score("li zz", "order_lines") == nil)
    }

    @Test func theBestMatchScoresMost() throws {
        let exact = try #require(score("orders", "orders")), prefix = try #require(score("orders", "orders_old"))
        let inside = try #require(score("orders", "old_orders")), scattered = try #require(score("orders", "o_r_d_e_r_s_x"))
        #expect(exact > prefix && prefix > inside)
        #expect(try #require(score("fc", "film_category")) > #require(score("fc", "offices")))
        #expect(scattered > 0)
        // A capital starts a word as an underscore does.
        #expect(try #require(score("oi", "orderItems")) > #require(score("oi", "orderitems")))
    }
}

struct TreeOptionsTests {
    @Test func aFilterBoxTakesTextOrARegularExpression() {
        #expect(NameFilter("ORD").matches("orders") && !NameFilter("zz").matches("orders"))
        #expect(NameFilter("/^or.*s$/").matches("ORDERS") && !NameFilter("/^rd/").matches("orders"))
        // Not a regular expression yet: it matches as text, so typing never hides everything by accident.
        #expect(NameFilter("/(/").matches("a/(/b") && !NameFilter("/(/").matches("orders"))
        #expect(NameFilter("").matches("orders"))
    }

    @Test func prefixesFoldOnceTheyHaveEnoughNames() {
        #expect(TreeGrouping.prefix(of: "wp_posts") == "wp_" && TreeGrouping.prefix(of: "posts") == nil)
        #expect(TreeGrouping.prefix(of: "_x") == nil && TreeGrouping.prefix(of: "x_") == nil)
        let groups = TreeGrouping.groups(["a", "wp_a", "wp_b", "x_a", "wp_c", "x_b"])
        #expect(groups.map(\.prefix) == [nil, "wp_", nil, nil])
        #expect(groups[1].names == ["wp_a", "wp_b", "wp_c"] && groups[2].names == ["x_a"])
    }

    @Test func hiddenNamesAreNamesOrPatterns() {
        var tree = TreeSettings()
        #expect(!tree.hides("orders"))
        tree.hiddenNames = "tmp_*, Audit"
        #expect(tree.hides("tmp_1") && tree.hides("audit") && !tree.hides("orders"))
    }

    @Test func oldFilesKeepTheDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.tree == TreeSettings() && settings.tree.showsSizes)
        let tree = try JSONDecoder().decode(TreeSettings.self, from: Data(#"{"flat":true}"#.utf8))
        #expect(tree.flat && tree.showsSizes)
        var saved = SavedConnection(name: "x")
        saved.favourites = [DatabaseObject(.view, "d", "v")]
        let back = try JSONDecoder().decode(SavedConnection.self, from: JSONEncoder().encode(saved))
        #expect(back.favourites == saved.favourites)
    }
}

extension AppTests {
    @MainActor @Suite struct TreeTests {
        let id = Fixtures.production.id

        private func quickOpen(_ main: MainWindowController, _ harness: AgentServer) async throws -> QuickOpenSheet {
            #expect(await call(harness, "menu", ["path": "File > Quick Open…"]).error == nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            return try #require(main.window?.attachedSheet?.windowController as? QuickOpenSheet)
        }

        private func type(_ text: String, in sheet: QuickOpenSheet) {
            sheet.field.stringValue = text
            sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        }

        @Test func quickOpenListsTabsRoutinesTriggersAndCommandsFuzzily() async throws {
            let model = testModel(Fixtures.shop)
            let (main, harness) = appWindow(model)
            _ = await openReplayed(model, id)
            main.open(FixtureContent("x"), title: "Scratch pad", connection: nil)
            let sheet = try await quickOpen(main, harness)
            #expect(sheet.shown.first?.name == "Scratch pad" && sheet.shown.first?.place == "Tab")
            type("adcu", in: sheet)
            #expect(sheet.shown.first?.name == "add_customer" && sheet.shown.first?.place.hasPrefix("procedure in airsql_fixture") == true)
            type("Quick Open", in: sheet)
            #expect(!sheet.shown.contains { $0.place.hasPrefix("File") })  // it doesn't list itself
            type("filter sidebar", in: sheet)
            // Off here: no window of these tests is key, so a command says what it does and not its menu.
            #expect(sheet.shown.first?.name == "Filter Sidebar" && sheet.shown.first?.place.hasPrefix("Off: ") == true)
            type("Refresh", in: sheet)
            #expect(sheet.shown.contains { $0.name == "Refresh" })
            sheet.close()
        }

        @Test func anAgentCantRunACommandThroughQuickOpen() async throws {
            let model = testModel(Fixtures.shop)
            let (main, harness) = appWindow(model)
            let sheet = try await quickOpen(main, harness)
            type("Filter Sidebar", in: sheet)
            let item = try #require(sheet.shown.first)
            let notes = AgentGuard.Notes()
            AgentGate.$agent.withValue("Test agent") { AgentGuard.$notes.withValue(notes) { item.open() } }
            #expect(notes.refusal?.contains("the person's") == true)
            sheet.close()
        }

        @Test func selectInTreeFindsTheTabsObjectWithoutChangingTheTab() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            let orders = DatabaseObject(.table, "airsql_fixture", "orders")
            main.openTableData(orders, of: open)
            let tab = try #require(main.selectedTab)
            // A filter that hides it goes.
            main.sidebar.filter.stringValue = "customers"
            main.sidebar.reload()
            main.selectInTree(nil)
            #expect(await eventually(timeout: 5) { main.sidebar.selectedNodes.first?.object == orders })
            #expect(main.sidebar.filter.stringValue.isEmpty)
            #expect(main.selectedTab === tab && main.tabs.count == 1)
            #expect(main.window?.firstResponder === main.sidebar.outline)
        }

        @Test func selectInTreeFromAConsoleFollowsTheCursor() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            open.currentDatabase = "airsql_fixture"
            let tab = main.openConsole(text: "SELECT * FROM airsql_fixture.customers", title: nil, connection: id)
            let console = try #require(tab.content as? ConsoleViewController)
            console.editor.setSelectedRange(NSRange(location: 32, length: 0))
            main.selectInTree(nil)
            #expect(await eventually(timeout: 5) { main.sidebar.selectedNodes.first?.object?.name == "customers" })
            console.editor.setSelectedRange(NSRange(location: 0, length: 0))
            main.selectInTree(nil)
            #expect(await eventually(timeout: 5) { main.sidebar.selectedNodes.first?.kind == .database(id, "airsql_fixture") })
        }

        private func option(_ option: TreeOption) -> NSMenuItem {
            let item = NSMenuItem()
            item.tag = option.rawValue
            return item
        }

        private func names(_ main: MainWindowController, _ kind: SidebarNode.Kind) -> [String] {
            main.sidebar.treeNodes[kind]?.children.compactMap(\.name) ?? []
        }

        @Test func aFlatTreeHasNoGroupsAndStaysOpenAcrossReloads() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            let database = SidebarNode.Kind.database(id, "airsql_fixture")
            main.sidebar.toggleTreeOption(option(.flat))
            #expect(await eventually(timeout: 5) { names(main, database).contains("orders") })
            #expect(main.sidebar.treeNodes[.category(id, "airsql_fixture", .table)] == nil)
            #expect(main.sidebar.treeNodes[database]?.objectCount == open.snapshot.database("airsql_fixture").map {
                $0.tables.count + $0.routines.count + $0.triggers.count + $0.events.count })
            // Selecting it in the tree works without a group above it, and a table opened keeps open.
            let orders = SidebarNode.Kind.object(id, DatabaseObject(.table, "airsql_fixture", "orders"))
            main.sidebar.reveal(orders)
            let row = try #require(main.sidebar.treeNodes[orders])
            #expect(main.sidebar.selectedNodes == [row])
            main.sidebar.outline.expandItem(row)
            main.sidebar.reload()
            #expect(main.sidebar.outline.isItemExpanded(row) && main.sidebar.selectedNodes == [row])
            main.sidebar.toggleTreeOption(option(.flat))
            #expect(await eventually(timeout: 5) { main.sidebar.treeNodes[.category(id, "airsql_fixture", .table)] != nil })
        }

        /// Select in Tree can't show what Favourites Only leaves out, and doesn't take the person's filter for nothing.
        @Test func revealKeepsTheFilterWhenTheRowStaysHidden() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            _ = await openReplayed(model, id)
            let orders = DatabaseObject(.table, "airsql_fixture", "orders")
            #expect(await eventually(timeout: 5) { main.sidebar.treeNodes[.object(id, orders)] != nil })
            main.sidebar.toggleTreeOption(option(.favouritesOnly))
            main.sidebar.filter.stringValue = "zzz"
            main.sidebar.reload()
            #expect(!main.sidebar.reveal(.object(id, orders)))
            #expect(main.sidebar.filter.stringValue == "zzz")
            main.sidebar.toggleTreeOption(option(.favouritesOnly))
            main.sidebar.reload()
            #expect(main.sidebar.reveal(.object(id, orders)) && main.sidebar.filter.stringValue.isEmpty, "only the filter hid it")
        }

        @Test func favouritesStayOnTheConnectionAndCanBeAllTheTreeShows() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            _ = await openReplayed(model, id)
            let orders = DatabaseObject(.table, "airsql_fixture", "orders")
            main.sidebar.toggleTreeOption(option(.favouritesOnly))
            #expect(await eventually(timeout: 5) { main.sidebar.treeNodes[.message(id, "No favourites here: point at an object and click its star")] != nil })
            main.sidebar.toggleTreeOption(option(.favouritesOnly))
            _ = await eventually(timeout: 5) { main.sidebar.treeNodes[.object(id, orders)] != nil }
            main.sidebar.reveal(.object(id, orders))
            main.sidebar.toggleFavourite(nil)
            #expect(model.connection(id)?.favourites == [orders])
            main.sidebar.toggleTreeOption(option(.favouritesOnly))
            #expect(await eventually(timeout: 5) { names(main, .category(id, "airsql_fixture", .table)) == ["orders"] })
            #expect(main.sidebar.treeNodes[.database(id, "airsql other")] == nil)
            #expect(main.sidebar.favouritesButton.state == .on)
            // It opens by itself, to where the favourite is.
            #expect(main.sidebar.outline.row(forItem: main.sidebar.treeNodes[.object(id, orders)]) >= 0)
            main.sidebar.reveal(.object(id, orders))
            main.sidebar.toggleFavourite(nil)
            #expect(model.connection(id)?.favourites.isEmpty == true)
        }

        @Test func kindsNamesAndDatabasesCanBeLeftOut() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            _ = await openReplayed(model, id)
            let sidebar = main.sidebar
            let kindItem = NSMenuItem()
            kindItem.tag = DatabaseObject.Kind.allCases.firstIndex(of: .view) ?? 0
            sidebar.toggleTreeKind(kindItem)
            #expect(await eventually(timeout: 5) { sidebar.treeNodes[.category(id, "airsql_fixture", .view)] == nil })
            sidebar.toggleTreeKind(kindItem)
            model.data.settings.tree.hiddenNames = "order*"
            #expect(await eventually(timeout: 5) { !names(main, .category(id, "airsql_fixture", .table)).contains("orders") })
            model.data.settings.tree.hiddenNames = ""
            _ = await eventually(timeout: 5) { names(main, .category(id, "airsql_fixture", .table)).contains("orders") }
            // The second box narrows the databases, a regular expression too; the first still narrows the objects.
            sidebar.toggleTreeOption(option(.databaseBox))
            #expect(!sidebar.databaseFilter.isHidden)
            sidebar.databaseFilter.stringValue = "/^airsql_f/"
            sidebar.filter.stringValue = "/^ord[a-z]+$/"
            sidebar.reload()
            #expect(sidebar.treeNodes[.database(id, "airsql other")] == nil)
            #expect(names(main, .category(id, "airsql_fixture", .table)) == ["orders"])
            sidebar.toggleTreeOption(option(.databaseBox))
            sidebar.filter.stringValue = ""
            sidebar.reload()
            #expect(sidebar.databaseFilter.isHidden && sidebar.treeNodes[.database(id, "airsql other")] != nil)
            // The connection's database filter follows at once.
            var saved = try #require(model.connection(id))
            saved.databaseFilter = "airsql_fixture"
            model.save(saved)
            #expect(await eventually(timeout: 5) { sidebar.treeNodes[.database(id, "airsql other")] == nil })
            #expect(sidebar.shownDatabases(id)?.hasSuffix(" of \(model.openConnection(id)?.snapshot.databases.count ?? 0)") == true)
        }

        @Test func groupByPrefixFoldsNamesAndSelectingFindsThem() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            model.data.settings.tree.groupsByPrefix = true
            _ = await eventually(timeout: 5) { main.sidebar.treeNodes[.database(id, "airsql_fixture")] != nil }
            main.sidebar.reload()
            // The fixture's tables share no prefix three times: they stay as they are.
            #expect(names(main, .category(id, "airsql_fixture", .table)).contains("orders"))
            #expect(open.snapshot.database("airsql_fixture") != nil)
        }

        @Test func sizesShowOnceTheCacheHasThemAndFollowTabSelectsTheTabsRow() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            open.loadStatistics("airsql_fixture")
            #expect(await eventually(timeout: 5) { open.snapshot.database("airsql_fixture")?.statistics != nil })
            let orders = DatabaseObject(.table, "airsql_fixture", "orders")
            main.sidebar.reveal(.object(id, orders))
            let node = try #require(main.sidebar.treeNodes[.object(id, orders)])
            let cell = try #require(main.sidebar.treeCell(node, in: main.sidebar.outline) as? TreeCell)
            let bytes = try #require(open.snapshot.database("airsql_fixture")?.statistics?["orders"]?.bytes)
            #expect(cell.toolTip?.contains(shortSize(bytes)) == true)
            model.data.settings.tree.followsTab = true
            main.openTableData(orders, of: open)
            main.sidebar.outline.deselectAll(nil)
            let other = main.open(FixtureContent("x"), title: "x", connection: nil)
            let tab = try #require(main.tabs.first { $0.title == "orders" })
            main.select(tab)
            #expect(main.sidebar.selectedNodes == [node] && main.selectedTab === tab)
            main.select(other)
            #expect(main.sidebar.selectedNodes == [node])
        }

        @Test func aTableTabsPageStaysChosenAsTheTreeIsWalked() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            main.sidebar.reveal(.object(id, DatabaseObject(.table, "airsql_fixture", "orders")), showing: true)
            let first = try #require((main.selectedTab?.content as? PreviewContent)?.shown as? TableDataController)
            _ = first.view
            #expect(first.page == .data && first.shownPage == nil && first.statusAccessory != nil)
            let structure = NSMenuItem()
            structure.tag = TablePage.structure.rawValue
            first.showTablePage(structure)
            #expect(first.shownPage is TableEditorController && first.statusAccessory == nil && first.dataPage.isHidden)
            #expect(first.pageSwitch.selectedSegment == 1 && model.data.settings.tree.tablePage == 1)
            // The menus reach the page on show, not the rows behind it.
            #expect(!first.responds(to: Commands.addRow.action) && first.responds(to: Commands.pageData.action))
            #expect(main.supplementalTarget(forAction: Commands.apply.action, sender: nil) as AnyObject? === first.shownPage)
            // The editor's sections work on the page, and it comes back on the one left.
            let page = try #require(first.shownPage as? TableEditorController)
            // A replayed connection has no tools session to read the table with: the sections work all the same.
            #expect(await eventually(timeout: 5) { !page.isBusy })
            #expect(page.before == nil && !page.overlay.isHidden)
            for section in TableEditorController.Section.allCases {
                page.sections.selectedSegment = section.rawValue
                page.sectionChosen(page.sections)
                #expect(page.section == section)
            }
            page.showSection(.partitions)
            #expect(!page.partitionsView.isHidden && page.listColumn.isHidden)
            first.show(.data)
            first.show(.structure)
            #expect(first.shownPage === page && page.section == .partitions)
            page.showSection(.columns)
            // The next table opens on that page and leaves its rows unread.
            main.sidebar.reveal(.object(id, DatabaseObject(.table, "airsql_fixture", "customers")), showing: true)
            let second = try #require((main.selectedTab?.content as? PreviewContent)?.shown as? TableDataController)
            _ = second.view
            #expect(second !== first && second.page == .structure && second.shownPage is TableEditorController)
            #expect(await eventually(timeout: 5) { second.rowsWaiting })
            // A view's Structure is its code; the DDL is read through the schema session.
            let view = try #require(open.snapshot.database("airsql_fixture")?.tables.first { $0.kind == .view })
            main.sidebar.reveal(.object(id, DatabaseObject(.view, "airsql_fixture", view.name)), showing: true)
            let third = try #require((main.selectedTab?.content as? PreviewContent)?.shown as? TableDataController)
            _ = third.view
            #expect(third.shownPage is ObjectEditorController)
            third.show(.ddl)
            #expect(third.shownPage is TextContent && third.pageSwitch.selectedSegment == 2)
            #expect(model.data.settings.tree.tablePage == 1)  // only a choice in the switch or menu stays
        }

        @Test func f1OnATreeRowSaysWhatTheEditorSays() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            let sidebar = main.sidebar
            let orders = DatabaseObject(.table, "airsql_fixture", "orders")
            try await open.schema.loadDetails(["airsql_fixture"])
            sidebar.reveal(.object(id, orders))
            sidebar.quickDocumentation(nil)
            #expect(sidebar.shownTreeNote.hasPrefix("orders\nTable in airsql_fixture"))
            #expect(sidebar.shownTreeNote.contains("customer_id"))
            sidebar.reveal(.object(id, DatabaseObject(.procedure, "airsql_fixture", "add_customer")))
            sidebar.quickDocumentation(nil)
            #expect(sidebar.shownTreeNote.hasPrefix("add_customer\nProcedure in airsql_fixture"))
            sidebar.reveal(.database(id, "airsql_fixture"))
            sidebar.quickDocumentation(nil)
            #expect(sidebar.shownTreeNote.hasPrefix("airsql_fixture\nDatabase · "))
            sidebar.treeNote?.close()
            // A column's row: what a column at the cursor shows.
            let doc = SQLIntentions.documentation(of: orders, column: "customer_id", snapshot: open.snapshot)
            #expect(doc?.title == "customer_id" && doc?.body.contains("In orders") == true)
            #expect(SQLIntentions.documentation(of: DatabaseObject(.trigger, "airsql_fixture", "t"), snapshot: open.snapshot) == nil)
        }

        @Test func f4OnAGroupListsItAndADDLGoesToThePage() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            let sidebar = main.sidebar
            sidebar.reveal(.database(id, "airsql_fixture"))
            sidebar.reveal(.category(id, "airsql_fixture", .view))
            sidebar.openNameData(nil)
            let list = try #require(main.selectedTab?.content as? DatabaseViewController)
            _ = list.view
            #expect(!list.rows.isEmpty && list.rows.allSatisfy { $0.kind == .view })
            let orders = DatabaseObject(.table, "airsql_fixture", "orders")
            main.goToDDL(orders, of: open)
            let table = try #require(main.selectedTab?.content as? TableDataController)
            #expect(table.page == .ddl && table.shownPage is TextContent)
            #expect(model.data.settings.tree.tablePage == 0)  // a look at it isn't a choice
        }

        @Test func theSQLLogDocksOnceAServerIsConnected() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            #expect(!main.logDocked)
            _ = await openReplayed(model, id)
            #expect(await eventually(timeout: 5) { main.logPanel.isViewLoaded && main.logDockHeight == 100 })
            main.window?.layoutIfNeeded()
            #expect(main.logPanel.view.frame.height == 100 && main.logPanel.view.window === main.window)
            main.showSQLLog(nil)
            #expect(!model.data.settings.tree.showsLog && main.logDockHeight == 0)
            main.showSQLLog(nil)
            #expect(main.logDockHeight == 100)
            model.detach(id)
            #expect(await eventually(timeout: 5) { main.logDockHeight == 0 })
        }

        /// The owner's rule: every expandable row toggles on a double-click, but a table, which opens its tab.
        @Test func aDoubleClickTogglesEveryExpandableRowButATable() async throws {
            let folder = ConnectionFolder(name: "Work")
            var connections = Fixtures.shop
            connections[0].folderID = folder.id
            let model = testModel(connections, folders: [folder])
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            try await open.schema.loadDetails(["airsql_fixture"])
            let outline = main.sidebar.outline
            let doubleClick = try #require(outline.doubleAction)
            func press(_ node: SidebarNode) {
                outline.selectRowIndexes([outline.row(forItem: node)], byExtendingSelection: false)
                NSApp.sendAction(doubleClick, to: outline.target, from: outline)
            }
            // Open everything once, down to what a table holds.
            var row = 0
            while row < outline.numberOfRows {
                if let node = outline.item(atRow: row) as? SidebarNode, outline.isExpandable(node), node.database == nil || node.database == "airsql_fixture" {
                    outline.expandItem(node)
                }
                row += 1
            }
            let nodes = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarNode }.filter { outline.isExpandable($0) && $0.kind != .header }
            var kinds = Set<String>()
            // From the bottom up: closing a row hides what's under it from a reload.
            for node in nodes.reversed() where outline.row(forItem: node) >= 0 {
                let wasOpen = outline.isItemExpanded(node)
                if let object = node.object, object.kind.isTableLike {
                    press(node)
                    #expect(await eventually(timeout: 5) { main.tabs.contains { $0.title == object.name && $0.content is TableDataController } }, "\(object.name)")
                    #expect(outline.isItemExpanded(node) == wasOpen, "a table's double-click doesn't open or close it")
                    kinds.insert("table")
                    continue
                }
                press(node)
                #expect(await eventually(timeout: 5) { outline.isItemExpanded(node) != wasOpen }, "\(node.kind)")
                press(node)
                #expect(await eventually(timeout: 5) { outline.isItemExpanded(node) == wasOpen }, "\(node.kind)")
                kinds.insert(String(String(describing: node.kind).prefix { $0 != "(" }))
            }
            #expect(kinds.isSuperset(of: ["table", "folder", "connection", "database", "category", "part"]), "\(kinds)")
        }

        @Test func backAndForwardWalkTheTabsAndSkipClosedOnes() async throws {
            let model = testModel(Fixtures.shop)
            let (main, harness) = appWindow(model)
            let a = main.open(FixtureContent("a"), title: "a", connection: nil)
            let b = main.open(FixtureContent("b"), title: "b", connection: nil)
            let c = main.open(FixtureContent("c"), title: "c", connection: nil)
            #expect(main.canGoBack && !main.canGoForward)
            main.goBack(nil)
            #expect(main.selectedTab === b && main.canGoForward)
            main.goForward(nil)
            #expect(main.selectedTab === c)
            main.select(a)
            #expect(main.recentTabs.map(\.title) == ["a", "c", "b"])
            main.close(c)
            #expect(await eventually(timeout: 5) { main.tabs.count == 2 })
            main.select(b)
            main.goBack(nil)
            #expect(main.selectedTab === a)  // past the closed one
            main.showRecentTabs(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            let sheet = try #require(main.window?.attachedSheet?.windowController as? QuickOpenSheet)
            #expect(sheet.shown.first?.name == "b")
            sheet.close()
        }

        @Test func connectionsMoveUpAndDownByHand() {
            let first = SavedConnection(name: "Alpha"), second = SavedConnection(name: "Beta"), third = SavedConnection(name: "Gamma")
            let model = testModel([first, second, third])
            func order() -> [String] { model.sections(filter: "").flatMap(\.connections).map(\.name) }
            #expect(order() == ["Alpha", "Beta", "Gamma"])
            model.moveConnection(third.id, by: -1)
            #expect(order() == ["Alpha", "Gamma", "Beta"])
            model.moveConnection(first.id, by: -1)  // already first
            #expect(order() == ["Alpha", "Gamma", "Beta"])
            model.moveConnection(first.id, by: 1)
            #expect(order() == ["Gamma", "Alpha", "Beta"])
        }

        @Test func aKeyDropsFromItsTableAndNeverTheTable() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let open = await openReplayed(model, id)
            try await open.schema.loadDetails(["airsql_fixture"])
            let sidebar = main.sidebar
            let orders = DatabaseObject(.table, "airsql_fixture", "orders")
            sidebar.reveal(.object(id, orders))
            let row = try #require(sidebar.treeNodes[.object(id, orders)])
            sidebar.outline.expandItem(row)
            let keys = try #require(sidebar.treeNodes[.part(id, orders, .indexes)])
            sidebar.outline.expandItem(keys)
            let index = try #require(keys.children.first)
            #expect(index.isDroppablePart)
            sidebar.outline.selectRowIndexes([sidebar.outline.row(forItem: index)], byExtendingSelection: false)
            #expect(sidebar.treeMenu(sidebar.selectedNodes).items.contains { $0.title == "Drop…" })
            let columns = try #require(sidebar.treeNodes[.part(id, orders, .columns)])
            sidebar.outline.expandItem(columns)
            let column = try #require(columns.children.first)
            #expect(!column.isDroppablePart)
            sidebar.outline.selectRowIndexes([sidebar.outline.row(forItem: column)], byExtendingSelection: false)
            #expect(!sidebar.treeMenu(sidebar.selectedNodes).items.contains { $0.title == "Drop…" })
        }

        @Test func findInTabsReplacesWithOneUndoAndSavesNothing() async throws {
            let model = testModel(Fixtures.shop)
            let (main, _) = appWindow(model)
            let tab = main.openConsole(text: "SELECT a FROM t;\nSELECT A, b FROM t;", title: "One", connection: nil)
            let console = try #require(tab.content as? ConsoleViewController)
            main.findInFiles(nil)
            let find = try #require(main.selectedTab?.content as? FindInFilesContent)
            find.field.stringValue = "select a"
            find.find(nil)
            #expect(find.hits.map(\.match.line) == [1, 2] && find.hits.first?.title == "One")
            find.replacement.stringValue = "SELECT z"
            find.replaceInTabs(nil)
            #expect(console.text == "SELECT z FROM t;\nSELECT z, b FROM t;")
            let notes = AgentGuard.Notes()
            AgentGate.$agent.withValue("Test agent") { AgentGuard.$notes.withValue(notes) { find.replaceInTabs(nil) } }
            #expect(notes.refusal != nil)
        }
    }
}

struct TreeRowsTextTests {
    @Test func firstRowsCutAtTheServerAndLeaveOutWhatIsntText() {
        func column(_ name: String, _ type: String) -> SchemaColumn {
            SchemaColumn(name: name, dataType: type, columnType: type, nullable: true, defaultValue: .none, autoIncrement: false, onUpdate: nil, generated: nil,
                         invisible: false, isJSON: false, charset: nil, collation: nil, comment: "")
        }
        let read = NavigatorSQL.firstRows(DatabaseObject(.table, "d", "t"), [column("id", "int"), column("photo", "longblob"), column("note", "longtext")])
        #expect(read?.sql == "SELECT LEFT(`id`, 40), LEFT(`note`, 40) FROM `d`.`t` LIMIT 5" && read?.names == ["id", "note"])
        #expect(NavigatorSQL.firstRows(DatabaseObject(.table, "d", "t"), [column("photo", "blob")]) == nil)
        #expect(NavigatorSQL.rowsText(["id", "note"], [["1", nil], ["22", "x"]]) == "id  note\n1   NULL\n22  x")
    }
}

struct TreeSearchTests {
    @Test func matchesCountLinesAndUTF16() {
        let found = TextSearch.matches(of: "ab", in: "é ab\n\n  AB x\nno\nab")
        #expect(found.map(\.line) == [1, 3, 5] && found[0].range == NSRange(location: 2, length: 2) && found[1].preview == "AB x")
        #expect(TextSearch.matches(of: "", in: "x").isEmpty)
    }

    @Test func wholeWordsAreNames() {
        #expect(NavigatorSQL.names("orders", in: "select * from `orders` o") && NavigatorSQL.names("Orders", in: "x.orders;"))
        #expect(!NavigatorSQL.names("orders", in: "select * from orders_old, preorders"))
        #expect(NavigatorSQL.names("orders", in: "preorders, orders"))
    }

    @Test func findModesAndLimits() {
        #expect(NavigatorSQL.contains("a'b", columns: ["c"], noBackslashEscapes: true, match: .init(kind: .exact)) == "`c` = 'a''b'")
        #expect(NavigatorSQL.contains("^a", columns: ["c", "d"], noBackslashEscapes: true, match: .init(kind: .regex)) == "`c` REGEXP '^a' OR `d` REGEXP '^a'")
        let table = DatabaseObject(.table, "d", "t")
        #expect(NavigatorSQL.countContaining("x", in: table, columns: ["c"], noBackslashEscapes: true, match: .init(kind: .exact)) == "SELECT COUNT(*) FROM `d`.`t` WHERE `c` = 'x'")
        #expect(NavigatorSQL.countContaining("x", in: table, columns: ["c"], noBackslashEscapes: true, match: .init(kind: .exact), limit: 10)
                == "SELECT COUNT(*) FROM (SELECT 1 FROM `d`.`t` WHERE `c` = 'x' LIMIT 10) AS matched")
    }

    @Test func partsDropByTheirOwnSQL() {
        let table = DatabaseObject(.table, "d", "t")
        #expect(NavigatorSQL.dropPart(.indexes, "PRIMARY", of: table) == "ALTER TABLE `d`.`t` DROP PRIMARY KEY")
        #expect(NavigatorSQL.dropPart(.indexes, "i`x", of: table) == "ALTER TABLE `d`.`t` DROP INDEX `i``x`")
        #expect(NavigatorSQL.dropPart(.foreignKeys, "f", of: table) == "ALTER TABLE `d`.`t` DROP FOREIGN KEY `f`")
        #expect(NavigatorSQL.dropPart(.checks, "c", of: table) == "ALTER TABLE `d`.`t` DROP CONSTRAINT `c`")
        #expect(NavigatorSQL.dropPart(.columns, "c", of: table) == nil)
        #expect(NavigatorSQL.setComment("it's", of: table, noBackslashEscapes: true) == "ALTER TABLE `d`.`t` COMMENT = 'it''s'")
        #expect(NavigatorSQL.setComment("x", of: DatabaseObject(.procedure, "d", "p"), noBackslashEscapes: true) == "ALTER PROCEDURE `d`.`p` COMMENT 'x'")
    }

    @Test func aUsagesQueryQuotesItsName() {
        let sql = NavigatorSQL.usages(of: "a_b'", noBackslashEscapes: true)
        #expect(sql.contains("LIKE '%a!_b''%' ESCAPE '!'") && sql.contains("information_schema.TRIGGERS"))
    }
}
