import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// The Liquibase screens with demo data (no server): Generate Liquibase Changelog with a shop's objects and Save as
/// Changeset, tidy in light and dark, every control explained, the object list's clicks and keys, the menus, appending
/// to a changelog, and (AIRSQL_SCREENSHOTS=1) pictures to compare with mockup screen 9. Settings ▸ Liquibase is in the
/// panes the layout, help and screenshot tests walk.
extension AppTests {
    @MainActor @Suite struct LiquibaseAppTests {
        /// The unit tests' shop, with rows on its tables.
        static var shop: LiquibaseSchema {
            var shop = LiquibaseTests.shop
            for index in shop.objects.indices where shop.objects[index].kind == .table {
                shop.objects[index].rows = [2_400_000, 412_000, 12][index % 3]
            }
            return shop
        }

        /// The sheet with the shop's objects (`fits`: only as many as its list shows without scrolling, as the layout
        /// check sees every row the list lays out).
        static func sheet(on main: MainWindowController, fits: Bool = false) -> LiquibaseSheet {
            main.model.data.settings.liquibase.author = "deploy"
            let sheet = LiquibaseSheet(model: main.model, connection: ToolFixtures.local, options: ToolFixtures.options)
            sheet.show(on: main.window!, loads: false)
            var schema = shop
            if fits { schema.objects.removeAll { [.view, .procedure, .event].contains($0.kind) } }
            sheet.show(schema)
            return sheet
        }

        /// The sheet's object list and its segmented content control.
        static func parts(_ sheet: LiquibaseSheet) throws -> (LiquibaseObjectTable, NSSegmentedControl) {
            let root = try #require(sheet.window?.contentView)
            let views = descendants(of: root)
            return (try #require(views.compactMap { $0 as? LiquibaseObjectTable }.first),
                    try #require(views.compactMap { $0 as? NSSegmentedControl }.first))
        }

        @Test func generateSheetIsTidyAndSaysWhatEachControlDoes() async throws {
            let (main, harness) = ClientToolsAppTests.window()
            var problems: [String] = []
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                main.window?.appearance = NSAppearance(named: appearance)
                let sheet = Self.sheet(on: main, fits: true)
                _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
                for segment in [0, 2] {
                    let (_, content) = try Self.parts(sheet)
                    content.selectedSegment = segment
                    _ = content.target?.perform(content.action, with: content)
                    sheet.window?.contentView?.layoutSubtreeIfNeeded()
                    let place = "Liquibase \(appearance == .aqua ? "light" : "dark") \(segment == 0 ? "DDL" : "DDL + DML")"
                    let root = try #require(sheet.window?.contentView)
                    problems += layoutProblems(root, where: place)
                    problems += unexplained(harness.openSheets(), where: place)
                }
                _ = sheet.begin("Writing a Liquibase changelog of shop")
                sheet.progress("Reading the rows of this_table_name_is_sixty_four_characters_long_the_most_mysql_has · 12 rows", done: 3,
                               total: 14)
                let root = try #require(sheet.window?.contentView)
                root.layoutSubtreeIfNeeded()
                problems += layoutProblems(root, where: "Liquibase running")
                sheet.finish("Stopped.", failed: true)
                sheet.close()
                _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            }
            #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
        }

        @Test func theFormDecidesWhatTheChangelogHolds() throws {
            let (main, _) = ClientToolsAppTests.window()
            let sheet = Self.sheet(on: main)
            defer { sheet.close() }
            let (list, content) = try Self.parts(sheet)
            #expect(sheet.plan().pieces.count == 12 && sheet.runButton.isEnabled)  // "secret" can't be read: left out
            // DDL + DML ticks every included table's rows; unticking a table takes its rows and foreign keys along.
            content.selectedSegment = 2
            _ = content.target?.perform(content.action, with: content)
            #expect(sheet.plan().tables == 3)
            let orders = try #require((0..<list.numberOfRows).first { row in
                (list.view(atColumn: 0, row: row, makeIfNecessary: true) as? PickerCell)?.name.stringValue == "orders"
            })
            list.selectRowIndexes(IndexSet(integer: orders), byExtendingSelection: false)
            let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                      context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false,
                                                      keyCode: 49))
            list.keyDown(with: space)
            let objects = sheet.plan().pieces.map(\.object)
            #expect(!objects.contains("orders") && !objects.contains("fk_orders_customer") && sheet.plan().tables == 2)
            // DML only: just rows, in an order that keeps foreign keys happy; the right-click menu offers rows.
            content.selectedSegment = 1
            _ = content.target?.perform(content.action, with: content)
            #expect(sheet.plan().pieces == [.rows(table: "customers"), .rows(table: "x`; DROP TABLE nothing; --")])
            let menu = try #require(list.menu)
            menu.delegate?.menuNeedsUpdate?(menu)
            #expect(menu.items.map(\.title) == ["Insert Rows", "No Rows"] && menu.items.allSatisfy { $0.toolTip?.isEmpty == false })
        }

        @Test func saveAsChangesetAddsToTheChosenChangelog() async throws {
            let (main, harness) = ClientToolsAppTests.window()
            let file = URL(fileURLWithPath: try scratch()).appendingPathComponent("changelog.sql")
            try "--liquibase formatted sql\n\n--changeset ann:20261101-001-a\nSELECT 1;\n\n--changeset ann:20261101-002-b\nSELECT 2;"
                .write(to: file, atomically: true, encoding: .utf8)
            main.model.data.settings.liquibase.changelog = file.path
            main.model.data.settings.liquibase.author = "deploy"
            let change = ChangeSQL(title: "Change table shop.orders", statements: [
                "ALTER TABLE `shop`.`orders`\n  ADD COLUMN `paid` tinyint(1) NOT NULL DEFAULT 0 AFTER `total`"], connection: UUID())
            ChangesetSheet.show([Liquibase.changeset(change)], heading: "Save “\(change.title)” as a changeset", model: main.model,
                                on: main.window!)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            let sheet = try #require(main.window?.attachedSheet)
            let root = try #require(sheet.contentView)
            let save = try #require(descendants(of: root).compactMap { $0 as? NSButton }.first { $0.title == "Save" })
            #expect(await eventually(timeout: 10) { save.isEnabled })
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                sheet.appearance = NSAppearance(named: appearance)
                #expect(layoutProblems(root, where: "Save as changeset").isEmpty)
            }
            #expect(unexplained(harness.openSheets(), where: "Save as changeset").isEmpty)
            save.performClick(nil)
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            let read = try LiquibaseChangelog(String(contentsOf: file, encoding: .utf8)).changesets
            #expect(read.count == 3 && read[2].author == "deploy" && read[2].id.hasSuffix("-003-orders"))
            #expect(read[2].statements == ["ALTER TABLE `orders`\n  ADD COLUMN `paid` tinyint(1) NOT NULL DEFAULT 0 AFTER `total`"])
            #expect(read[2].rollbackStatements == ["ALTER TABLE `orders` DROP COLUMN `paid`"])
        }

        @Test func theMenusOfferBothCommandsAndSayWhyWhenTheyCant() throws {
            let (main, _) = ClientToolsAppTests.window()
            let menu = MainMenu.build()
            let items = menu.items.flatMap { $0.submenu?.items ?? [] }
            let generate = try #require(items.first { $0.action == Commands.generateLiquibase.action })
            let save = try #require(items.first { $0.action == Commands.saveAsChangeset.action })
            var next = main.nextResponder
            while let current = next, !(current is LiquibaseResponder) { next = current.nextResponder }
            let responder = try #require(next as? LiquibaseResponder)
            #expect(responder.validateMenuItem(generate))
            #expect(!responder.validateMenuItem(save) && save.toolTip == "Open a console tab with the statements to save")
            #expect(SQLPreviewSheet.changesetWriter != nil, "the preview sheet offers Save as Liquibase changeset")
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRSQL_SCREENSHOTS"] == "1"))
        func screenshots() async throws {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let (main, harness) = ClientToolsAppTests.window()
                main.window?.appearance = NSAppearance(named: appearance)
                main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
                main.window?.orderFront(nil)
                let sheet = Self.sheet(on: main)
                let (list, content) = try Self.parts(sheet)
                content.selectedSegment = 2
                _ = content.target?.perform(content.action, with: content)
                list.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
                _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
                try await save(harness, "liquibase-\(suffix)")
                sheet.close()
                _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
                main.model.data.settings.liquibase.changelog = "/Volumes/Projects/shop/db/changelog/2026-11.sql"
                let changesets = Liquibase.changesets(for: Self.shop)
                ChangesetSheet.show(changesets, heading: "Save the sync script for Production · shop as changesets", model: main.model,
                                    on: main.window!)
                _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
                try await Task.sleep(nanoseconds: 500_000_000)  // the changelog is read off the main thread
                try await save(harness, "liquibase-changeset-\(suffix)")
                main.window?.attachedSheet.map { main.window?.endSheet($0) }
                main.window?.orderOut(nil)
            }
        }

        func save(_ harness: AgentServer, _ name: String) async throws {
            let reply = await call(harness, "screenshot", ["target": "main", "scale": 2])
            let image = try #require(reply.image, "\(name): \(reply.error ?? "")")
            let png = try #require(image.representation(using: .png, properties: [:]))
            try png.write(to: ScreenshotTests.folder.appendingPathComponent(name + ".png"))
        }
    }
}

private extension Liquibase {
    /// A few of the shop's changesets, as a compare would hand them over.
    static func changesets(for shop: LiquibaseSchema) -> [LiquibaseChangeset] {
        shop.pieces(.structure, rows: [], settings: LiquibaseSettings()).compactMap { piece in
            if case .changeset(let changeset) = piece { return changeset }
            return nil
        }.prefix(4).map { $0 }
    }
}
