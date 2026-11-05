import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

// The sidebar's keys, empty space and folders, on the window of `InteractionTests.window()`.
extension AppTests.InteractionTests {
    /// The harness walks the chain as AppKit does: a window controller's supplemental target gets what the real menu sends it.
    @Test func theHarnessReachesSupplementalTargets() async throws {
        let (main, harness, _, work) = await Self.window()
        defer { work.end() }
        let console = try #require(main.openConsole(text: "", title: nil, connection: Fixtures.production.id).content as? ConsoleViewController)
        #expect(await eventually(timeout: 5) { main.window?.firstResponder === console.editor })
        #expect(harness.validate(Commands.processList.item(), in: main.window).target === main.sidebar)
    }

    @Test func commandFInTheSidebarGoesToTheFilter() async throws {
        let (main, harness, _, work) = await Self.window()
        defer { work.end() }
        let window = try #require(main.window)
        window.makeFirstResponder(main.sidebar.outline)
        #expect(harness.validate(Commands.find.item(), in: window).target === main.sidebar.outline)
        #expect(harness.validate(Commands.findNext.item(), in: window).enabled == false)
        #expect(await call(harness, "key", ["combo": "cmd+f"]).error == nil)
        #expect((window.firstResponder as? NSText)?.delegate === main.sidebar.filter)
    }

    @Test func theFilterHandsOverToTheList() async throws {
        let (main, _, _, work) = await Self.window()
        defer { work.end() }
        let sidebar = main.sidebar
        main.filterSidebar(nil)
        sidebar.filter.stringValue = "Stag"
        sidebar.reload()
        #expect(sidebar.control(sidebar.filter, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(sidebar.selectedConnectionIDs == [Fixtures.staging.id] && main.window?.firstResponder === sidebar.outline)

        // Return on nothing typed leaves the field's own behaviour; on a match it opens it, as Return in the list does.
        sidebar.filter.stringValue = ""
        sidebar.reload()
        #expect(!sidebar.control(sidebar.filter, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
    }

    @Test func f2OnAConnectionEditsItAndDeleteOnAFolderAsks() async throws {
        let (main, harness, _, work) = await Self.window()
        defer { work.end() }
        let window = try #require(main.window)
        main.sidebar.select([Fixtures.staging.id])
        window.makeFirstResponder(main.sidebar.outline)
        #expect(await call(harness, "key", ["combo": "f2"]).error == nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        #expect(window.attachedSheet != nil)
        _ = await call(harness, "press", ["title": "Cancel", "in": "sheet"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])

        let folder = try #require(folderRowIndex(main, Self.folder.id))
        main.sidebar.outline.selectRowIndexes([folder], byExtendingSelection: false)
        window.makeFirstResponder(main.sidebar.outline)
        #expect(await call(harness, "key", ["combo": "delete"]).error == nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        #expect(window.attachedSheet != nil)
        _ = await call(harness, "press", ["title": "Cancel", "in": "sheet"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
    }

    @Test func aRightClickChoosesWithoutShowingAndTheEmptySpaceHasAMenu() async throws {
        let (main, _, _, work) = await Self.window()
        defer { work.end() }
        let outline = main.sidebar.outline
        let window = try #require(main.window)
        func rightClick(_ point: NSPoint) -> NSMenu? {
            NSEvent.mouseEvent(with: .rightMouseDown, location: outline.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                .flatMap { outline.menu(for: $0) }
        }
        let orders = try #require(treeRow(main, .object(Fixtures.production.id, DatabaseObject(.table, "airsql_fixture", "orders"))))
        let tab = main.selectedTab
        let menu = rightClick(NSPoint(x: outline.rect(ofRow: orders.row).midX, y: outline.rect(ofRow: orders.row).midY))
        #expect(menu?.items.contains { $0.title == "Copy Name" } == true && main.selectedTab === tab, "the tab in front stays")

        let blank = rightClick(NSPoint(x: 20, y: outline.bounds.maxY + 400))
        #expect(blank?.items.map(\.title) == ["New Connection…", "New Folder…"] && main.sidebar.selectedNodes.isEmpty)
    }

    @Test func connectionsMoveToFolders() async throws {
        let (main, _, _, work) = await Self.window()
        defer { work.end() }
        let sidebar = main.sidebar
        await sidebar.reloadSettled()
        main.sidebar.select([Fixtures.staging.id, Fixtures.replica.id])
        let item = Commands.moveToFolder.item()
        item.representedObject = Self.folder.id
        main.moveToFolder(item)
        #expect(main.model.connection(Fixtures.staging.id)?.folderID == Self.folder.id)
        #expect(main.model.connection(Fixtures.replica.id)?.folderID == Self.folder.id)
        main.moveToFolder(Commands.moveToFolder.item())
        #expect(main.model.connection(Fixtures.staging.id)?.folderID == nil)

        // Where a dragged connection lands: a folder, the folder of the row it is over, or outside; never in a tree.
        await sidebar.reloadSettled()
        let folder = try #require(folderRowIndex(main, Self.folder.id).flatMap { sidebar.outline.item(atRow: $0) as? SidebarNode })
        #expect(sidebar.dropRow(on: folder) === folder)
        #expect(sidebar.dropRow(on: nil)?.kind == .header)
        let local = try #require(folder.children.first { $0.connectionID == Fixtures.local.id })
        #expect(sidebar.dropRow(on: local) === folder)
        #expect(sidebar.dropRow(on: SidebarNode(.database(Fixtures.production.id, "airsql_fixture"))) == nil)
    }
}

private extension SidebarController {
    /// After the model's change reached the rows (they reload on the next turn of the main queue).
    func reloadSettled() async {
        await Task.yield()
        reload()
    }
}

// The database view's filter, its empty state, and the empty space of the lists.
extension AppTests.InteractionTests {
    @Test func theDatabaseViewFiltersAndSaysWhatToDo() async throws {
        let (main, _, _, work) = await Self.window()
        defer { work.end() }
        let open = try #require(main.model.openConnection(Fixtures.production.id))
        let view = DatabaseViewController(open, "airsql_fixture")
        main.open(view, title: "airsql_fixture", connection: open.id)
        let all = view.rows.count
        #expect(all > 1)
        view.filter.stringValue = "ORDER"
        view.reload()
        #expect(view.rows.map(\.name).contains("orders") && view.rows.count < all)
        #expect(find(NSTextField.self, id: "database.caption", in: view.view)?.stringValue.hasPrefix("\(view.rows.count) of \(all) ") == true)
        view.filter.stringValue = "nothing has this"
        view.reload()
        #expect(find(NSTextField.self, id: "database.empty", in: view.view)?.isHidden == false)
        #expect(view.contextMenu()?.items.map(\.title) == ["Create Table…", "Disk Usage", "Refresh"])
    }
}

// Tabs: dragging them, the Window menu past nine, and the keys that move the focus.
extension AppTests.InteractionTests {
    @Test func aTabDraggedAlongTheStripMoves() async throws {
        let (main, _, _, work) = await Self.window()
        defer { work.end() }
        for title in ["b", "c"] { main.open(FixtureContent(), title: title, connection: nil) }
        main.window?.layoutIfNeeded()
        let titles = main.tabs.map(\.title)
        let bar = main.tabBar
        bar.clicked(bar.buttons[titles.count - 1], count: 1)
        let target = bar.buttons[0]
        bar.drag(to: target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil))
        #expect(main.tabs.map(\.title) == [titles[titles.count - 1]] + titles.dropLast())
        #expect(main.selectedTab?.title == titles[titles.count - 1])
    }

    @Test func theWindowMenuListsTabsPastNine() async throws {
        let (main, harness, _, work) = await Self.window()
        defer { work.end() }
        while main.tabs.count < 11 { main.open(FixtureContent(), title: "tab \(main.tabs.count + 1)", connection: nil) }
        let menu = try #require(NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu)
        harness.update(menu)
        let listed = menu.items.filter { $0.action == Commands.tab(1).action && !$0.isHidden }
        #expect(listed.count == 11 && listed.last?.title == "tab 11" && listed.last?.keyEquivalent == "")
        // It goes back when the tabs do: the next time it opens the extra items are gone.
        for tab in main.tabs.suffix(2) { main.close(tab) }
        harness.update(menu)
        #expect(menu.items.filter { $0.action == Commands.tab(1).action && !$0.isHidden }.count == 9)
    }

    @Test func keysPutTheFocusInTheTreeEditorAndResults() async throws {
        let (main, _, _, work) = await Self.window()
        defer { work.end() }
        let window = try #require(main.window)
        let console = try #require(main.openConsole(text: "SELECT 1", title: nil, connection: Fixtures.production.id).content as? ConsoleViewController)
        #expect(await eventually(timeout: 5) { window.firstResponder === console.editor })
        main.focusSidebar(nil)
        #expect(window.firstResponder === main.sidebar.outline)
        main.focusEditor(nil)
        #expect(window.firstResponder === console.editor)
        #expect(!main.validateMenuItem(Commands.focusResults.item()), "no result yet")
        #expect(main.validateMenuItem(Commands.focusEditor.item()))
    }

    @Test func aCSVOrSQLGZOpensItsToolNotAConsole() async throws {
        #expect(SQLEditorView.opensInSheet(URL(fileURLWithPath: "/a/rows.CSV")))
        #expect(SQLEditorView.opensInSheet(URL(fileURLWithPath: "/a/dump.sql.gz")))
        #expect(!SQLEditorView.opensInSheet(URL(fileURLWithPath: "/a/notes.gz")) && !SQLEditorView.opensInSheet(URL(fileURLWithPath: "/a/q.sql")))

        // With no connection chosen it says what to do, and opens no tab.
        let (main, harness) = appWindow(testModel([Fixtures.local]))
        await main.openFiles([URL(fileURLWithPath: "/a/rows.csv")]).value
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        #expect(main.window?.attachedSheet != nil && main.tabs.isEmpty)
        _ = await call(harness, "press", ["title": "OK", "in": "sheet"])
    }
}
