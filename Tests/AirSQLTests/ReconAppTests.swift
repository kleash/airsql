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

        @Test func compareWindowIsTidyInLightAndDark() {
            var problems: [String] = []
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for size in [ReconWindowController.minimumSize, ReconWindowController.defaultSize] {
                    let place = "compare \(appearance == .aqua ? "light" : "dark") \(Int(size.width))×\(Int(size.height))"
                    func check(_ window: ReconWindowController, _ what: String) {
                        window.window?.contentView?.layoutSubtreeIfNeeded()
                        guard let content = window.window?.contentView else { return }
                        // A table wider and taller than its scroll view shows both overlay scrollers, whose frames AppKit
                        // lets meet in the corner (it draws them short of each other): not text or controls on top of
                        // each other.
                        problems += layoutProblems(content, where: "\(place) \(what)").filter { !$0.hasSuffix("NSScroller and NSScroller overlap") }
                    }
                    check(Self.window(nil, size: size, appearance: appearance), "before a compare")
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
            #expect(window.results.detail.rows.numberOfRows == 15)
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
    /// The whole path against the lab: both sides' databases listed, Compare with its activity, the result shown, and
    /// the sync script in the SQL preview, which runs nothing until approved.
    @Test(.enabled(if: Lab.enabled, "AIRSQL_LAB=1 runs the lab tests")) func comparesThroughTheWindow() async throws {
        let setup = try await ReconLabTests.session(Lab.mariadb114)
        try await ReconLabTests.database(setup, "lane_l8a_ui_src", ReconLabTests.shopSource)
        try await ReconLabTests.database(setup, "lane_l8a_ui_dst", ReconLabTests.shopTarget)
        let lab = SavedConnection(name: "Lab MariaDB", host: "127.0.0.1", port: try #require(Lab.mariadb114.port), user: "airsql")
        ReconWindowController.connect = { saved in
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
        controller.showSyncScript(nil)
        let sheet = try #require(controller.window?.attachedSheet)
        controller.window?.endSheet(sheet)
        try await ReconLabTests.run(setup, ["DROP DATABASE lane_l8a_ui_src", "DROP DATABASE lane_l8a_ui_dst"])
        await setup.close()
    }
}

extension AppTests.ScreenshotTests {
    @Test func compareWindow() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let window = AppTests.ReconAppTests.window(AppTests.ReconAppTests.result(), appearance: appearance)
            window.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
            window.window?.orderFront(nil)
            window.window?.displayIfNeeded()
            let (_, harness) = appWindow(window.model, windows: { [window.window!] })
            let reply = await call(harness, "screenshot", ["target": "window:Compare Production", "scale": 2])
            let image = try #require(reply.image, "\(reply.error ?? "")")
            try #require(image.representation(using: .png, properties: [:]))
                .write(to: Self.folder.appendingPathComponent("compare-\(suffix).png"))
            window.window?.orderOut(nil)
        }
    }
}
