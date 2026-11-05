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
    }
}
