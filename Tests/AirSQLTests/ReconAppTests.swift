import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// The compare window: tidy in light and dark at its smallest and usual sizes, every control explained, the objects
/// list answering single, double and right clicks, and (AIRSQL_SCREENSHOTS=1) its pictures for the mockup comparison.
extension AppTests {
    @MainActor @Suite struct ReconAppTests {
        static func bytes(_ text: String?) -> [UInt8]? { text.map { Array($0.utf8) } }

        /// A result like the mockup's: Production · shop against Staging · shop, with long and odd names.
        static func result() -> ReconResult {
            var result = ReconResult(source: ReconEnd(name: "Production", database: "shop", version: "8.4.13"),
                                     target: ReconEnd(name: "Staging", database: "shop", version: "11.8.9-MariaDB"),
                                     options: ReconOptions())
            result.duration = 14.2
            result.rowsChecked = 12_600_000
            result.rowsFetched = 50_400
            var orders = ReconObject(kind: .table, name: "orders", status: .different)
            orders.parts = [ReconPart(kind: .column, name: "currency", change: .added,
                                      definition: "`currency` char(3) NOT NULL DEFAULT 'EUR'", after: "total", detail: "added"),
                            ReconPart(kind: .index, name: "ix_status_created", change: .added,
                                      definition: "KEY `ix_status_created` (`status`,`created_at`)", detail: "added")]
            orders.sourceDDL = """
                CREATE TABLE `orders` (
                  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
                  `customer_id` int unsigned NOT NULL,
                  `status` enum('new','paid','shipped','refunded') NOT NULL,
                  `total` decimal(12,2) NOT NULL,
                  `currency` char(3) NOT NULL DEFAULT 'EUR',
                  `created_at` timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
                  PRIMARY KEY (`id`),
                  KEY `ix_status_created` (`status`,`created_at`),
                  KEY `ix_customer` (`customer_id`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
                """
            orders.targetDDL = """
                CREATE TABLE `orders` (
                  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
                  `customer_id` int unsigned NOT NULL,
                  `status` enum('new','paid','shipped','refunded') NOT NULL,
                  `total` decimal(12,2) NOT NULL,
                  `created_at` timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
                  PRIMARY KEY (`id`),
                  KEY `ix_customer` (`customer_id`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci
                """
            var gifts = ReconObject(kind: .table, name: "gift_cards", status: .onlyInSource)
            gifts.sourceDDL = "CREATE TABLE `gift_cards` (\n  `code` varchar(20) NOT NULL,\n  PRIMARY KEY (`code`)\n) ENGINE=InnoDB"
            var customers = ReconObject(kind: .table, name: "customers", status: .different)
            customers.parts = [ReconPart(kind: .options, name: "collation", change: .changed, definition: "COLLATE=utf8mb4_bin",
                                         detail: "default collation utf8mb4_general_ci → utf8mb4_bin")]
            var products = ReconObject(kind: .table, name: "products", status: .same)
            var data = ReconTableData(outcome: .different)
            data.key = ["id"]
            data.columns = [ReconColumn(name: "id", kind: .integer), ReconColumn(name: "name", kind: .text),
                            ReconColumn(name: "price", kind: .decimal), ReconColumn(name: "colour", kind: .text)]
            data.changed = (1...12).map { index in
                ReconRowChange(source: ReconRow([bytes("\(index)"), bytes("Product \(index) — עברית 😀"), bytes("19.90"), nil]),
                               target: ReconRow([bytes("\(index)"), bytes("Product \(index) — עברית 😀"), bytes("17.50"), nil]),
                               columns: [2])
            }
            data.missing = (13...15).map { ReconRow([bytes("\($0)"), bytes(String(repeating: "Long name ", count: 25)), bytes("5.00"), bytes("red")]) }
            products.data = data
            var coupons = ReconObject(kind: .table, name: "coupons_with_a_name_that_is_sixty_four_characters_long_exactly_x", status: .same)
            var missing = ReconTableData(outcome: .different)
            missing.key = ["code"]
            missing.columns = [ReconColumn(name: "code", kind: .text)]
            missing.missing = (1...1_269).map { ReconRow([bytes(String(format: "C-%05d", $0))]) }
            coupons.data = missing
            var matches = (1...27).map { ReconObject(kind: .table, name: "table_\($0)", status: .same) }
            matches[0].data = ReconTableData(outcome: .same)
            var view = ReconObject(kind: .view, name: "paid_orders", status: .different)
            view.sourceDDL = "CREATE VIEW `paid_orders` AS select `id` from `orders` where `status` = 'paid'"
            view.targetDDL = "CREATE VIEW `paid_orders` AS select `id` from `orders` where `status` in ('paid','shipped')"
            result.objects = [orders, gifts, customers, products, coupons, view] + matches
            return result
        }

        static func window(_ result: ReconResult?, size: NSSize = ReconWindowController.defaultSize,
                           appearance: NSAppearance.Name = .aqua) -> ReconWindowController {
            _ = NSApplication.shared
            _ = TestEnvironment.isolated
            useAppMenuBar()
            let controller = ReconWindowController(model: testModel(Fixtures.shop))
            keptWindows.append(controller)
            controller.window?.appearance = NSAppearance(named: appearance)
            controller.window?.orderFront(nil)
            controller.window?.setFrame(NSRect(origin: NSPoint(x: -22000, y: -22000), size: size), display: false)
            controller.source.choose(Fixtures.production, database: "shop")
            controller.target.choose(Fixtures.staging, database: "shop")
            if let result { controller.show(result) }
            controller.window?.layoutIfNeeded()
            return controller
        }

        @Test func theWindowStaysAtItsMinimumSize() {
            let controller = Self.window(Self.result(), size: ReconWindowController.minimumSize)
            #expect(controller.window?.frame.width == ReconWindowController.minimumSize.width)
        }

        @Test func theListOpensWideEnoughForTheNames() throws {
            let controller = Self.window(Self.result())
            let list = controller.results.list
            #expect(try #require(list.enclosingScrollView).frame.width >= 300)
            func needed(_ field: NSTextField) throws -> CGFloat {
                try #require(field.cell).cellSize(forBounds: NSRect(x: 0, y: 0, width: .greatestFiniteMagnitude, height: field.bounds.height)).width
            }
            var starts: Set<CGFloat> = []
            defer { #expect(starts.count == 1, "the names line up: \(starts)") }
            for row in 0..<list.numberOfRows {
                guard let cell = list.view(atColumn: 0, row: row, makeIfNecessary: true) as? ReconObjectCell else { continue }
                cell.layoutSubtreeIfNeeded()
                starts.insert(cell.name.frame.minX)
                // What differs stays whole beside a long name: the name gives way first.
                #expect(try needed(cell.what) <= cell.what.bounds.width + 1, "\(cell.what.stringValue) is cut beside \(cell.name.stringValue)")
                // The 64-character name is shortened at any sensible width (its tooltip has it).
                guard !cell.name.stringValue.hasPrefix("coupons_with") else { continue }
                let needed = try #require(cell.name.cell).cellSize(forBounds: NSRect(x: 0, y: 0, width: .greatestFiniteMagnitude,
                                                                                    height: cell.name.bounds.height)).width
                #expect(needed <= cell.name.bounds.width + 1, "\(cell.name.stringValue): needs \(needed), has \(cell.name.bounds.width)")
            }
        }

        @Test func theTablesSheetTicksWithADoubleClickAndItsMenu() throws {
            let controller = Self.window(Self.result())
            controller.showTables(nil)
            let sheet = try #require(controller.window?.attachedSheet?.windowController as? ReconTablesSheet)
            let content = try #require(sheet.window?.contentView)
            let table = try #require(find(NSTableView.self, id: "reconTables.list", in: content))
            func ticked(_ row: Int) -> Bool { (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSButton)?.state == .on }
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            #expect(ticked(0))
            let doubleAction = try #require(table.doubleAction)
            NSApp.sendAction(doubleAction, to: table.target, from: table)
            #expect(!ticked(0))
            let menu = try #require(table.menu)
            #expect(menu.items.map(\.title) == ["Compare", "Leave Out"])
            #expect(menu.items.allSatisfy { $0.toolTip?.isEmpty == false })
            let compare = try #require(menu.items[0].action)
            NSApp.sendAction(compare, to: menu.items[0].target, from: menu.items[0])
            #expect(ticked(0))
            controller.window?.endSheet(sheet.window!)
        }

        @Test func compareWindowIsTidyInLightAndDark() {
            var problems: [String] = []
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for size in [ReconWindowController.minimumSize, ReconWindowController.defaultSize] {
                    let place = "compare \(appearance == .aqua ? "light" : "dark") \(Int(size.width))×\(Int(size.height))"
                    func check(_ window: ReconWindowController, _ what: String) {
                        window.window?.contentView?.layoutSubtreeIfNeeded()
                        guard let content = window.window?.contentView else { return }
                        problems += layoutProblems(content, where: "\(place) \(what)")
                    }
                    let before = Self.window(nil, size: size, appearance: appearance)
                    check(before, "before a compare")
                    // The content takes the window's height rather than forcing its own (a stack of fixed-height views
                    // once shrank the window to its bars). A screen lower than the window (CI's) holds it to its own height.
                    before.window?.layoutIfNeeded()
                    let room = min(size.height, NSScreen.main?.visibleFrame.height ?? size.height)
                    #expect((before.window?.frame.height ?? 0) >= room - 1, "\(place): \(before.window?.frame.height ?? 0)")
                    let window = Self.window(Self.result(), size: size, appearance: appearance)
                    check(window, "structure")
                    for (row, object) in window.results.objects.enumerated() where ["products", "gift_cards", "paid_orders"].contains(object.name) {
                        window.results.list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                        window.results.detail.tabs.selectedSegment = object.data == nil ? 0 : 1
                        window.results.update()
                        check(window, object.name)
                    }
                }
            }
            #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
        }

        @Test func everyControlSaysWhatItDoes() {
            let before = Self.window(nil)
            let after = Self.window(Self.result())
            var missing = unexplained([before.window!], where: "compare before") + unexplained([after.window!], where: "compare after")
            after.results.detail.tabs.selectedSegment = 1
            after.results.list.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
            missing += unexplained([after.window!], where: "compare data")
            missing += unexplained(after.results.list.menu!, path: ["list"])
            #expect(missing.isEmpty, "\(missing)")
            #expect(after.toolbarItems.compare.toolTip == "This build of AirSQL can't open connections yet"
                    || ReconWindowController.connect != nil)
        }

        /// A side whose connection isn't connected connects it as the main window does (the Connector, its prompts and
        /// errors on the compare window), instead of saying to connect first.
        @Test func aSideConnectsItsConnectionItself() async throws {
            let closed = SavedConnection(name: "Closed port", host: "127.0.0.1", port: 1, user: "nobody")
            let model = testModel([closed])
            ReconWindowController.connect = { saved, window in try await model.connector.connection(saved.id, on: window) }
            defer { ReconWindowController.connect = nil }
            let controller = ReconWindowController(model: model)
            keptWindows.append(controller)
            controller.window?.setFrameOrigin(NSPoint(x: -22000, y: -22000))
            controller.source.choose(closed)
            #expect(await eventually(timeout: 5) { model.states[closed.id] != nil }, "choosing the connection connects it")
            // Nothing listens on port 1: the connect fails, says why on the compare window, and the side can't list.
            #expect(await eventually(timeout: 20) { controller.source.databases.placeholderString == "Couldn't connect" })
            #expect(controller.source.databases.toolTip?.hasPrefix("Couldn't list the databases: ") == true)
            if case .failed? = model.states[closed.id] {} else { Issue.record("\(String(describing: model.states[closed.id]))") }
            #expect(await eventually(timeout: 5) { controller.window?.attachedSheet != nil }, "the connect error shows")
            if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet) }
        }

        @Test func theListAnswersSingleDoubleAndRightClicks() throws {
            let window = Self.window(Self.result())
            let list = window.results.list
            // Differences first: only on one side, then structure, then data, then what matches.
            #expect(window.results.objects.prefix(4).map(\.name) == ["gift_cards", "customers", "orders", "paid_orders"])
            list.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
            let script = try #require(window.results.detail.script.documentView as? NSTextView).string
            #expect(script.contains("ADD COLUMN `currency` char(3) NOT NULL DEFAULT 'EUR' AFTER `total`"))
            let products = try #require(window.results.objects.firstIndex { $0.name == "products" })
            list.selectRowIndexes(IndexSet(integer: products), byExtendingSelection: false)
            #expect(window.results.detail.tabs.selectedSegment == 0)
            window.results.detail.show(window.results.objects[products], result: window.result!, data: true)
            // The rows that differ in the grid: the 3 only in the source (added), then the 12 changed, their price marked
            // with both values in its tooltip.
            let rows = try #require(window.results.detail.rows)
            let diff = try #require(rows.source as? DiffSource)
            #expect(rows.grid.rowCount == 15 && rows.grid.accessibilityIdentifier() == "recon.rows")
            #expect((0..<15).map { diff.mark($0, 0) } == Array(repeating: .inserted, count: 3) + Array(repeating: .none, count: 12))
            #expect(diff.mark(3, 2) == .edited && diff.note(3, 2) == "Staging has 17.50; Production has 19.90" && diff.note(3, 1) == nil)
            #expect(diff.columns.map(\.isKey) == [true, false, false, false])
            // Its menu is the grid's (copy formats, Export Rows…, the viewer's), every item in the menu bar; the
            // selected rows copy under their columns' names.
            let rowMenu = try #require(rows.viewer.dataGrid(rows.grid, menuFor: .row(0)))
            #expect(["Copy", "Copy with Headers", "Export Rows…", "Record View"].allSatisfy(rowMenu.items.map(\.title).contains),
                    "\(rowMenu.items.map(\.title))")
            rows.grid.selection.selectRow(0)
            window.window?.makeFirstResponder(rows.grid)
            rows.viewer.copyWithHeaders(nil)
            let copied = NSPasteboard.general.string(forType: .string)?.components(separatedBy: "\n") ?? []
            #expect(copied == ["id\tname\tprice\tcolour", "13\t" + String(repeating: "Long name ", count: 25) + "\t5.00\tred", ""],
                    "\(copied)")
            let menu = try #require(list.menu)
            menu.delegate?.menuNeedsUpdate?(menu)
            #expect(menu.items.map(\.title) == ["Copy", "Copy Sync Script", "Leave Out of Next Compare"])
            let menuBar = MainMenu.build()
            for item in menu.items {
                #expect(menuBar.items.contains { $0.submenu?.items.contains { $0.action == item.action } == true }, "\(item.title)")
            }
            window.leaveOutOfCompare(nil)
            #expect(window.options.choice("products").included == false)
        }
    }
}

extension AppTests.ReconAppTests {
    /// A side whose connection isn't connected connects it through the Connector: the server's certificate, which macOS
    /// doesn't know, asks for trust on the compare window, then the side lists the databases.
    @Test(.enabled(if: Lab.enabled, "AIRSQL_LAB=1 runs the lab tests")) func aSideConnectsAndAsksForTrustOnTheCompareWindow() async throws {
        var mysql = SavedConnection(name: "MySQL 8.4", host: "127.0.0.1", port: Lab.mysql84.port, user: Lab.airsql.user)
        mysql.tls = TLSOptions(mode: .verifyIdentity)
        let model = testModel([mysql])
        model.setSavedPassword(mysql.id.uuidString, Lab.airsql.password)
        ReconWindowController.connect = { saved, window in try await model.connector.connection(saved.id, on: window) }
        defer {
            ReconWindowController.connect = nil
            model.connector.disconnect(mysql.id)
        }
        let controller = ReconWindowController(model: model)
        keptWindows.append(controller)
        let window = try #require(controller.window)
        // Ordered in, as the harness acts only in visible windows, then moved off the screen.
        window.orderFront(nil)
        window.setFrameOrigin(NSPoint(x: -22000, y: -22000))
        let harness = AgentServer(main: nil, model: model, windows: { [window] })
        controller.source.choose(mysql)
        #expect(await eventually(timeout: 30) { window.attachedSheet != nil }, "the Trust sheet shows on the compare window")
        // Pressed as the harness does: performClick's event tracking can end the test process.
        let trust = await call(harness, "press", ["title": "Trust"])
        #expect(trust.error == nil, "\(trust.error ?? "")")
        #expect(await eventually(timeout: 30) { controller.source.databases.numberOfItems > 0 })
        #expect(model.states[mysql.id] == .connected(server: "MySQL " + Lab.mysql84.version), "\(String(describing: model.states[mysql.id]))")
    }

    /// The whole path against the lab: both sides' databases listed, Compare with its activity, the result shown, and
    /// the sync script in a console tab marked "sync script", whose Run shows the SQL preview, which runs nothing until
    /// approved.
    @Test(.enabled(if: Lab.enabled, "AIRSQL_LAB=1 runs the lab tests")) func comparesThroughTheWindow() async throws {
        let setup = try await ReconLabTests.session(Lab.mariadb114)
        try await ReconLabTests.database(setup, "lane_l8a_ui_src", ReconLabTests.shopSource)
        try await ReconLabTests.database(setup, "lane_l8a_ui_dst", ReconLabTests.shopTarget)
        let lab = SavedConnection(name: "Lab MariaDB", host: "127.0.0.1", port: Lab.mariadb114.port, user: "airsql")
        ReconWindowController.connect = { saved, _ in
            Connection(options: ConnectOptions(name: saved.name, host: saved.host, port: saved.port ?? 3306, user: saved.user,
                                               password: Lab.airsql.password, tls: TLSOptions(mode: .off)),
                       log: ReconLabTests.log)
        }
        defer { ReconWindowController.connect = nil }
        let model = testModel([lab])
        let controller = ReconWindowController(model: model)
        keptWindows.append(controller)
        controller.window?.setFrameOrigin(NSPoint(x: -22000, y: -22000))
        controller.source.choose(lab, database: "lane_l8a_ui_src")
        controller.target.choose(lab, database: "lane_l8a_ui_dst")
        let listed = Date() + 10
        while controller.source.databases.numberOfItems == 0, Date() < listed { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect((0..<controller.source.databases.numberOfItems).contains {
            controller.source.databases.itemObjectValue(at: $0) as? String == "lane_l8a_ui_dst"
        })
        #expect(controller.compareBlocked == nil)
        controller.refresh(nil)
        #expect(controller.isRunning && !model.activity.isIdle)
        let done = Date() + 60
        while controller.isRunning, Date() < done { try await Task.sleep(nanoseconds: 50_000_000) }
        let result = try #require(controller.result)
        #expect(model.activity.isIdle)
        #expect(controller.results.objects.first?.name == "gift_cards")
        #expect(result.object(.table, "customers")?.data?.differenceCount == 4)
        let (main, _) = appWindow(model)
        controller.main = main
        controller.showSyncScript(nil)
        main.window?.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        let console = try #require(main.selectedTab?.content as? ConsoleViewController)
        #expect(main.selectedTab?.title == "Sync script · lane_l8a_ui_dst" && !console.editor.isEditable)
        #expect(console.text.hasPrefix("USE `lane_l8a_ui_dst`;"))
        console.runAll(nil)
        let sheet = try #require(controller.window?.attachedSheet)
        controller.window?.endSheet(sheet)
        try await ReconLabTests.run(setup, ["DROP DATABASE lane_l8a_ui_src", "DROP DATABASE lane_l8a_ui_dst"])
        await setup.close()
    }
}

extension AppTests.ReconAppTests {
    /// Compare With… on a console result: the sheet offers the other results (the nearest first) with the result's key
    /// to match rows on; the rows that differ open next to the result in a tab of their own, in the grid, which can be
    /// exported but not compared again.
    @Test func aResultComparesWithAnotherInATabOfItsOwn() async throws {
        let (main, harness, console) = try await AppTests.ConsoleAppTests.console()
        let columns = [("id", ReconResultsTests.ints), ("name", ReconResultsTests.text)]
        console.addResult(ReconResultsTests.store(columns, [["1", "pen"], ["2", "ink"], ["3", "cap"]]), title: "Before", summary: "")
        console.addResult(ReconResultsTests.store(columns, [["1", "pen"], ["2", "INK"], ["4", "pad"]]), title: "After", summary: "")
        console.selectResult(console.resultTabs[1])
        let compare = Commands.compareResult.item()
        #expect(console.validateMenuItem(compare))
        let menu = console.resultMenu()
        #expect(menu.items.first { $0.action == compare.action }?.target === console)
        console.compareResult(nil)
        let sheet = try #require(main.window?.attachedSheet?.contentView)
        let with = try #require(find(NSPopUpButton.self, id: "compare.with", in: sheet))
        let keys = try #require(find(NSPopUpButton.self, id: "compare.key", in: sheet))
        #expect(with.itemTitles == ["Results", "Before · 3 × 2"] && with.titleOfSelectedItem == "Before · 3 × 2")
        #expect(keys.itemTitles == ["id (the key)", "id", "name", "Every column"] && keys.indexOfSelectedItem == 0)
        let missing = unexplained([try #require(main.window?.attachedSheet)], where: "compare with")
            + unexplained(try #require(with.menu), path: ["with"]) + unexplained(try #require(keys.menu), path: ["key"])
        #expect(missing.isEmpty, "\(missing)")
        #expect(await call(harness, "press", ["title": "Compare"]).error == nil)
        #expect(await eventually(timeout: 10) { console.resultTabs.count == 3 })
        let tab = try #require(console.selectedResult)
        #expect(console.resultTabs.map(\.title) == ["Before", "After", "After ↔ Before"] && tab.label == "After ↔ Before · 3 × 2")
        #expect(tab.summary == "1 row the same · matched on id")
        guard case .diff(let diff) = tab.content else {
            Issue.record("not a diff: \(tab.content)")
            return
        }
        #expect((0..<3).map { diff.mark($0, 1) } == [.inserted, .deleted, .edited] && diff.note(2, 1) == "Before has ink; After has INK")
        let grid = try #require(tab.view as? ResultGridView)
        #expect(find(NSTextField.self, id: "grid.legend", in: grid)?.stringValue == "● 1 only in After    ● 1 only in Before    ● 1 changed")
        #expect(!console.validateMenuItem(compare) && compare.toolTip == "This tab is a comparison already: show one of the results to compare it")
        #expect(console.validateMenuItem(Commands.exportResult.item()) && console.statusAccessory === grid.viewer.status)
    }
}
