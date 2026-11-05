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

extension AppTests {
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
