import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

@Suite struct ScriptFilesTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func listsFoldersFirstAndOnlyWhatOpens() throws {
        let top = try folder()
        defer { try? FileManager.default.removeItem(at: top) }
        try FileManager.default.createDirectory(at: top.appendingPathComponent("z sub"), withIntermediateDirectories: true)
        for name in ["b10.sql", "b2.sql", "dump.sql.gz", "photo.png", ".hidden.sql"] {
            try Data().write(to: top.appendingPathComponent(name))
        }
        #expect(ScriptFiles.entries(in: top).map(\.url.lastPathComponent) == ["z sub", "b2.sql", "b10.sql", "dump.sql.gz"])
        #expect(ScriptFiles.entries(in: top.appendingPathComponent("missing")).isEmpty)
    }

    @Test func aFolderRunsItsScriptsInOrderDeepOnes() throws {
        let top = try folder()
        defer { try? FileManager.default.removeItem(at: top) }
        let sub = top.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for url in [top.appendingPathComponent("2.sql"), top.appendingPathComponent("notes.txt"), sub.appendingPathComponent("1.sql")] {
            try Data().write(to: url)
        }
        #expect(ScriptFiles.scripts(in: top).map(\.lastPathComponent) == ["1.sql", "2.sql"])
    }

    @Test func scratchFilesNumberOnAndNeverOverwrite() throws {
        let top = try folder()
        defer { try? FileManager.default.removeItem(at: top) }
        let first = try ScriptFiles.newScratch(in: top), second = try ScriptFiles.newScratch(in: top)
        #expect(first.lastPathComponent == "scratch 1.sql" && second.lastPathComponent == "scratch 2.sql")
        try FileManager.default.removeItem(at: first)
        #expect(try ScriptFiles.newScratch(in: top).lastPathComponent == "scratch 3.sql")
        #expect(ScriptFiles.isScratch(second, in: top))
        #expect(!ScriptFiles.isScratch(top.deletingLastPathComponent().appendingPathComponent("x.sql"), in: top))
    }

    @Test func aDefaultConsoleKeepsItsFileAndStaysOutOfTheList() throws {
        let top = try folder()
        defer { try? FileManager.default.removeItem(at: top) }
        let id = UUID(), url = try ScriptFiles.defaultConsole(of: id, in: top)
        try Data("SELECT 1".utf8).write(to: url)
        #expect(try ScriptFiles.defaultConsole(of: id, in: top) == url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "SELECT 1")
        #expect(ScriptFiles.entries(in: top).isEmpty)
        #expect(ScriptFiles.isScratch(url, in: top))
    }
}

@Suite struct AgentRequestTests {
    @Test func aRequestNamesTheTabAndAsksForAProposal() {
        let text = AgentRequest.explain.prompt(tab: "T1", title: "Query 1", connection: "shop", lines: 3...5)
        #expect(text.contains("tab T1") && text.contains("lines 3 to 5") && text.contains("open_in_console"))
        #expect(AgentRequest.fix.prompt(tab: "T", title: "Q", connection: "c", lines: 2...2).contains("at line 2"))
        #expect(AgentRequest.write.prompt(tab: "T", title: "Q", connection: "c", lines: nil, wish: "all orders").contains("all orders"))
    }
}

extension AppTests {
    @MainActor @Suite struct KeymapTests {
        init() { _ = NSApplication.shared }

        @Test func aChangedShortcutReachesMenusAndTheShortcutsList() {
            defer { Keymap.apply([:]) }
            useAppMenuBar()
            let keymap = Keymap.binding(Commands.newQuery, key: "y", modifiers: [.command, .control], in: [:]).keymap
            Keymap.apply(keymap)
            #expect(Commands.newQuery.shortcut == "⌃⌘Y" && Commands.newQuery.tipWithShortcut.hasSuffix("(⌃⌘Y)"))
            #expect(Commands.newQuery.item().keyEquivalent == "y")
            let file = NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu
            #expect(file?.items.first { $0.action == Commands.newQuery.action }?.keyEquivalent == "y")
        }

        @Test func takingAShortcutLeavesItsOwnerWithoutAndADefaultIsNotStored() {
            let (keymap, taken) = Keymap.binding(Commands.newQuery, key: "n", modifiers: .command, in: [:])
            #expect(taken == [Commands.newConnection.title])
            #expect(keymap[Commands.newConnection.id]?.key == "")
            let back = Keymap.binding(Commands.newQuery, key: Commands.newQuery.key, modifiers: Commands.newQuery.modifiers, in: [:])
            #expect(back.keymap.isEmpty && back.taken.isEmpty)
        }

        @Test func aPlainKeyOrOneMacOSKeepsIsRefused() {
            #expect(Keymap.refusal(key: "k", modifiers: []) != nil)
            #expect(Keymap.refusal(key: "k", modifiers: .shift) != nil)
            #expect(Keymap.refusal(key: "q", modifiers: .command) != nil)
            #expect(Keymap.refusal(key: String(UnicodeScalar(NSF5FunctionKey)!), modifiers: []) == nil)
        }

        @Test func everyPresetLeavesNoShortcutTakenTwice() {
            defer { Keymap.apply([:]) }
            for preset in Keymap.presets {
                Keymap.apply(Keymap.keymap(of: preset))
                let shortcuts = Commands.all.map(\.shortcut).filter { !$0.isEmpty && $0 != "⌘S" }
                #expect(Set(shortcuts).count == shortcuts.count, "\(preset.name)")
            }
        }

        @Test func thePaneBindsAndAnAgentCannot() throws {
            defer { Keymap.apply([:]) }
            let model = testModel()
            let pane = KeysPane(model: model)
            _ = pane.view
            pane.bind(Commands.formatSQL, key: "y", modifiers: [.command, .control])
            #expect(Commands.formatSQL.shortcut == "⌃⌘Y")
            #expect(pane.rows.count == Keymap.commands.count)
            var changed = model.data
            changed.settings.keymap = [:]
            #expect(AgentGate.personOnlyChange(from: model.data, to: changed) != nil)
        }
    }

    @MainActor @Suite struct WorkspaceAppTests {
        private func scripts() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-attached-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("SELECT 1;\n".utf8).write(to: url.appendingPathComponent("one.sql"))
            return url
        }

        @Test func attachingShowsTheFolderAndADoubleClickOpensAFile() async throws {
            let folder = try scripts()
            defer { try? FileManager.default.removeItem(at: folder) }
            let (main, _) = appWindow(testModel([Fixtures.local]))
            main.attach([folder])
            await main.sidebar.files.reload().value
            #expect(main.sidebar.filesShown)
            let files = main.sidebar.files
            #expect(files.roots.map(\.url.lastPathComponent).contains(folder.lastPathComponent))
            let root = try #require(files.roots.last)
            #expect(files.outline.isItemExpanded(root))
            let row = files.outline.row(forItem: root.children?.first)
            files.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            files.openChosen(nil)
            #expect(await eventually(timeout: 5) { main.tabs.count == 1 })
            #expect(main.tabs.first?.title == "one.sql")
            #expect(files.chosen.first?.url.lastPathComponent == "one.sql")
        }

        @Test func aDetachedFolderLeavesThePanelAndStaysOnDisk() async throws {
            let folder = try scripts()
            defer { try? FileManager.default.removeItem(at: folder) }
            let (main, _) = appWindow(testModel())
            main.attach([folder])
            await main.sidebar.files.reload().value
            let files = main.sidebar.files
            files.outline.selectRowIndexes(IndexSet(integer: files.outline.row(forItem: files.roots.last)), byExtendingSelection: false)
            files.detachFolder(nil)
            #expect(main.model.data.settings.tree.attachedFolders.isEmpty)
            await files.reload().value
            #expect(files.roots.count == 1)
            #expect(FileManager.default.fileExists(atPath: folder.path))
        }

        @Test func aFileOpensInTheDatabaseItWasLastUsedIn() async throws {
            let folder = try scripts()
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("one.sql")
            let (main, _) = appWindow(testModel([Fixtures.local, Fixtures.staging]))
            main.sidebar.select([Fixtures.local.id])
            await main.openFiles([url]).value
            let console = try #require(main.tabs.first?.content as? ConsoleViewController)
            #expect(console.chosenDatabase == nil)
            console.chosenDatabase = "shop"
            let (again, _) = appWindow(testModel([Fixtures.local, Fixtures.staging]))
            await again.openFiles([url]).value
            #expect((again.tabs.first?.content as? ConsoleViewController)?.chosenDatabase == "shop")
            console.setConnection(Fixtures.staging.id)  // another server's database means nothing here
            #expect(ConsoleViewController.rememberedDatabase(of: url) == nil)
        }

        @Test func aScratchFileClosesWithoutAskingAndKeepsItsText() async throws {
            let (main, _) = appWindow(testModel([Fixtures.local]))
            main.newScratchFile(nil)
            #expect(await eventually(timeout: 5) { main.tabs.count == 1 })
            let tab = try #require(main.tabs.first), console = try #require(tab.content as? ConsoleViewController)
            let url = try #require(console.fileURL)
            defer { try? FileManager.default.removeItem(at: url) }
            console.editor.replace(NSRange(location: 0, length: 0), with: "SELECT 2")
            main.close(tab)
            #expect(await eventually(timeout: 5) { main.tabs.isEmpty })
            #expect(try String(contentsOf: url, encoding: .utf8) == "SELECT 2")
        }

        @Test func twoTabsShowSideBySideAndTheFocusChoosesTheSelectedOne() throws {
            let (main, _) = appWindow(testModel())
            let first = FixtureContent("one"), second = FixtureContent("two"), third = FixtureContent("three")
            let a = main.open(first, title: "A", connection: nil), b = main.open(second, title: "B", connection: nil)
            let c = main.open(third, title: "C", connection: nil)
            main.select(a)
            main.splitRight(nil)
            #expect(main.splitPanes?.left === a && main.splitPanes?.right === b)
            #expect(first.view.window === main.window && second.view.window === main.window)
            #expect(main.contentKind == "tab")

            // The focus on the other side makes its tab the selected one.
            let field = NSTextField()
            second.view.addSubview(field)
            main.window?.makeFirstResponder(field)
            main.followFocus()
            #expect(main.selectedTab === b)

            // Another tab takes the side in use.
            main.select(c)
            #expect(main.splitPanes?.left === a && main.splitPanes?.right === c)
            #expect(third.view.window === main.window && second.view.window == nil)

            main.close(c)
            #expect(main.splitPanes == nil && first.view.window != nil && main.selectedTab != nil)
        }

        @Test func aLoneTabSplitsWithANewQueryAndPressedAgainShowsOne() {
            let (main, _) = appWindow(testModel([Fixtures.local]))
            let content = FixtureContent()
            let tab = main.open(content, title: "A", connection: Fixtures.local.id)
            main.splitRight(nil)
            #expect(main.tabs.count == 2 && main.splitPanes?.left === tab)
            #expect(main.splitPanes?.right.content is ConsoleViewController)
            main.splitRight(nil)
            #expect(main.splitPanes == nil && main.selectedTab === tab && content.view.window === main.window)
            #expect(main.tabs[1].content.view.window == nil)
        }

        @Test func aBookmarkStaysOnItsLineThroughEdits() {
            let (main, _) = appWindow(testModel())
            let console = ConsoleViewController(model: main.model, connection: nil, text: "one\ntwo\nthree\n", fileURL: nil)
            main.open(console, title: "Q", connection: nil)
            let editor: SQLEditorView = console.editor
            editor.setSelectedRange(NSRange(location: 5, length: 0))
            editor.toggleBookmark(nil)
            #expect(editor.bookmarks == [4])
            editor.replace(NSRange(location: 0, length: 0), with: "-- first\n")
            #expect(editor.bookmarks == [13])
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.nextBookmark(nil)
            #expect(editor.selectedRange().location == 13)
            editor.previousBookmark(nil)  // the only one: it wraps round to itself
            #expect(editor.selectedRange().location == 13)
            editor.replace(NSRange(location: 9, length: 8), with: "")  // the line goes, and its mark
            #expect(editor.bookmarks.isEmpty)
        }

        @Test func askingAnAgentHoldsNoSQLAndNeedsAgentsToSeeTheConnection() throws {
            var saved = Fixtures.local
            saved.agentAccess = .off
            let model = testModel([saved])
            let (main, _) = appWindow(model)
            let console = ConsoleViewController(model: model, connection: saved.id, text: "SELECT 'secret-literal'", fileURL: nil)
            main.open(console, title: "Q", connection: saved.id)
            let item = Commands.askAgent.item()
            #expect(!console.askAgentVerdict(item).0)
            model.data.settings.agentsAllowed = true
            #expect(console.askAgentVerdict(item).1.contains("can't see"))
            saved.agentAccess = .schemaRead
            model.save(saved)
            #expect(console.askAgentVerdict(item).0)
            #expect(!console.askAgentVerdict(Commands.askAgentFix.item()).0)
            console.askAgent(item)
            let copied = try #require(NSPasteboard.general.string(forType: .string))
            #expect(copied.contains(try #require(console.tab?.id.uuidString)) && !copied.contains("secret-literal"))
        }

        @Test func aConnectionKeepsOneDefaultConsole() async throws {
            let (main, _) = appWindow(testModel([Fixtures.local]))
            main.sidebar.select([Fixtures.local.id])
            main.sidebarSelectionChanged()
            main.openDefaultConsole(nil)
            #expect(await eventually(timeout: 5) { main.tabs.first?.title == Fixtures.local.displayName + " console" })
            main.openDefaultConsole(nil)
            try await Task.sleep(for: .milliseconds(100))
            #expect(main.tabs.count == 1)
        }

        @Test func aPinnedTabGoesLeftAndCloseAllLeavesIt() throws {
            let (main, _) = appWindow(testModel())
            _ = main.open(FixtureContent("a"), title: "A", connection: nil)
            let b = main.open(FixtureContent("b"), title: "B", connection: nil)
            main.togglePinTab(nil)
            #expect(main.tabs.first === b && b.pinned)
            main.closeAllTabs(nil)
            #expect(main.tabs.count == 1 && main.tabs.first === b)
            main.setPinned(false, b)
            main.closeAllTabs(nil)
            #expect(main.tabs.isEmpty)
        }

        // MARK: Several windows

        /// One transaction on a shared session, with tabs on it in two windows: Quit lists it once from either window,
        /// closing one tab doesn't ask about it while the other stays, and it survives the tab's move.
        @Test(.enabled(if: Lab.enabled, "Lab: AIRSQL_LAB=1 ./test.sh"))
        func aSharedTransactionIsOneAcrossWindows() async throws {
            let (main, harness, first, connection) = try await ConsoleRunAppTests.labConsole()
            defer { ConsoleViewController.openConnection = { _ in nil } }
            let setup = try await connection.toolsSession()
            let database = "lane_workspace_windows"
            for sql in ["DROP DATABASE IF EXISTS \(database)", "CREATE DATABASE \(database)", "CREATE TABLE \(database).t (id INT PRIMARY KEY)"] {
                _ = try await setup.query(sql)
            }
            var saved = try #require(main.model.connection(Fixtures.production.id))
            saved.sharedQuerySession = true
            main.model.save(saved)
            let window = main.anotherWindow()
            keptWindows.append(window)
            let tab = window.openConsole(text: "", title: "Other", connection: Fixtures.production.id)
            let second = try #require(tab.content as? ConsoleViewController)
            #expect(first.sessionKey == second.sessionKey)
            first.setTransactionMode(ConsoleRunAppTests.manualItem())
            _ = await call(harness, "wait", ["until": "idle", "timeout": 20])
            first.editor.setText("INSERT INTO \(database).t VALUES (1);")
            first.editor.setSelectedRange(NSRange(location: 0, length: 0))
            first.runStatement(nil)
            if main.window?.attachedSheet != nil { _ = await call(harness, "press", ["title": "Run"]) }
            #expect(await eventually(timeout: 20) { first.running == nil && first.session?.inTransaction == true })
            #expect(second.session === first.session)

            let lines = window.unfinishedWork().filter { $0.hasPrefix("A transaction") }
            #expect(lines.count == 1, "\(lines)")
            #expect(window.unfinishedWork() == main.unfinishedWork())

            window.moveTabToNewWindow(nil)
            let third = try #require(main.model.windows.last)
            keptWindows.append(third)
            third.window?.orderOut(nil)  // the real display isn't the tests'
            #expect(third.tabs.first === tab && second.session?.inTransaction == true)

            // The other tab stays open on the session, so closing this one leaves the transaction to it, without asking.
            var closed = false
            third.close(tab) { closed = true }
            #expect(await eventually(timeout: 5) { closed })
            #expect(first.session?.inTransaction == true)
            first.rollback(nil)
            #expect(await eventually(timeout: 10) { first.session?.inTransaction == false })
            _ = try await setup.query("DROP DATABASE \(database)")
            await connection.disconnect()
        }

        @Test func quitAsksAboutEveryWindow() async throws {
            let (main, _, tab) = try await GridDataAppTests.tab(session: FakeTableSession())
            let front = main.anotherWindow()
            keptWindows.append(front)
            tab.grid.selection.select(GridPosition(row: 0, column: 2))
            tab.setCellDefault(nil)
            #expect(front.unfinishedWork() == ["orders on Local: 1 pending change, kept for the next time you open the table"])
            tab.revertAllChanges(nil)
        }

        @Test func aFileOpenInOneWindowShowsThereNotInASecondTab() async throws {
            let folder = try scripts()
            defer { try? FileManager.default.removeItem(at: folder) }
            let model = testModel([Fixtures.local])
            let (first, _) = appWindow(model)
            let second = first.anotherWindow()
            keptWindows.append(second)
            let url = folder.appendingPathComponent("one.sql")
            await first.openFiles([url]).value
            await second.openFiles([url]).value
            #expect(first.tabs.count == 1 && second.tabs.isEmpty)
        }

        /// There's one Find in Tabs and Files, whichever window asks: the same goes for the host page, Users, Disk Usage and
        /// the process list.
        @Test func aTabThereIsOneOfShowsInTheWindowThatHasIt() throws {
            let model = testModel()
            let (first, _) = appWindow(model)
            first.findInFiles(nil)
            let other = FixtureContent("other")
            first.open(other, title: "Other", connection: nil)
            let second = first.anotherWindow()
            keptWindows.append(second)
            second.findInFiles(nil)
            #expect(second.tabs.isEmpty && first.tabs.count == 2 && first.selectedTab?.content is FindInFilesContent)
        }

        @Test func aTabMovesWithItsContentAndTheFirstWindowFollows() throws {
            let model = testModel()
            let (first, _) = appWindow(model)
            let content = FixtureContent("moves"), stays = FixtureContent("stays")
            let a = first.open(stays, title: "A", connection: nil), b = first.open(content, title: "B", connection: nil)
            first.moveTabToNewWindow(nil)
            let second = try #require(model.windows.last)
            keptWindows.append(second)
            second.window?.orderOut(nil)  // the real display isn't the tests'
            #expect(model.windows.count == 2 && first.tabs.count == 1 && first.selectedTab === a)
            #expect(second.tabs.first === b && content.view.window === second.window)
            #expect(second.window?.isExcludedFromWindowsMenu == false)
            second.moveTabToNextWindow(nil)
            #expect(first.tabs.count == 2 && second.tabs.isEmpty && first.selectedTab === b)
        }

        @Test func closingAWindowAsksItsTabsAndTheLastOneStays() throws {
            let model = testModel()
            let (first, _) = appWindow(model)
            let second = first.anotherWindow()
            keptWindows.append(second)
            let refuses = FixtureContent("keeps")
            refuses.closes = false
            second.open(refuses, title: "A", connection: nil)
            #expect(second.windowShouldClose(try #require(second.window)) == false)
            #expect(model.windows.count == 2, "a tab that says no keeps its window")
            refuses.closes = true
            _ = second.windowShouldClose(try #require(second.window))
            #expect(model.windows.count == 1 && model.windows.first === first)
            #expect(first.windowShouldClose(try #require(first.window)) == true)
            #expect(model.windows.count == 1, "the last window hides and keeps its tabs")
        }

        @Test func everyWindowComesBackAfterARelaunch() async throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-windows-\(UUID().uuidString).json")
            defer {
                try? FileManager.default.removeItem(at: url)
                ConsoleDocuments.shared.fileURL = ConsoleTabStore.fileURL
            }
            ConsoleDocuments.shared.fileURL = url
            let model = testModel([Fixtures.local])
            let (first, _) = appWindow(model)
            let second = first.anotherWindow()
            keptWindows.append(second)
            first.openConsole(text: "SELECT 'first'", title: "One", connection: nil)
            second.openConsole(text: "SELECT 'second'", title: "Two", connection: nil)
            ConsoleDocuments.shared.main = first
            ConsoleDocuments.shared.saveNow()

            let again = testModel([Fixtures.local])
            let (relaunched, _) = appWindow(again)
            ConsoleDocuments.shared.restore(into: relaunched)
            await ConsoleDocuments.shared.restoring?.value
            keptWindows += again.windows
            #expect(again.windows.count == 2)
            #expect(again.windows.map { $0.tabs.map(\.title) } == [["One"], ["Two"]])
            again.windows.last?.window?.orderOut(nil)
        }

        @Test func agentsSeeQueryTabsInEveryWindow() throws {
            var saved = Fixtures.local
            saved.agentAccess = .schemaRead
            let model = testModel([saved])
            let (first, _) = appWindow(model)
            let second = first.anotherWindow()
            keptWindows.append(second)
            let service = AgentService(model: model, main: first)
            first.openConsole(text: "SELECT 1", title: "One", connection: saved.id)
            second.openConsole(text: "SELECT 2", title: "Two", connection: saved.id)
            #expect(service.consoleTabs().count == 2)
            #expect(second.agents === service)
        }
    }
}
