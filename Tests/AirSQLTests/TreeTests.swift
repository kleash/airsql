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
    }
}
