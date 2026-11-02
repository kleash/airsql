import AppKit
import Testing
@testable import AirSQL

// The shortcut map (plan §2.4): every command has one tooltip in the house style, no shortcut is taken twice (but ⌘S,
// which saves a console and applies a table, whichever is enabled), none is one macOS keeps for itself, and the
// standard ones belong to their standard commands.
@MainActor
struct CommandsTests {
    /// A shortcut as one string: modifiers and the key, Shift made explicit.
    private func combo(_ command: Command) -> String {
        command.shortcut
    }

    @Test func noShortcutIsTakenTwice() {
        var owners: [String: [String]] = [:]
        for command in Commands.all where !command.key.isEmpty {
            owners[combo(command), default: []].append(command.title)
        }
        let shared = owners.filter { $0.value.count > 1 }
        // ⌘S: Save in a console, Apply Changes in a table tab (one of them is enabled at a time). F9 and ⌃F9 are hidden
        // second shortcuts of Run All and Run Statement.
        #expect(shared.keys.sorted() == ["⌘S"], "\(shared)")
        #expect(Set(owners["⌘S"] ?? []) == ["Save", "Apply Changes"])
    }

    @Test func noShortcutIsOneMacOSKeeps() {
        // System-wide shortcuts that never reach an app, or that people expect macOS to handle.
        let reserved: Set<String> = ["⌘Space", "⌥⌘Space", "⌃Space", "⌃⌘Space", "⌘⇥", "⌘`", "⇧⌘3", "⇧⌘4", "⇧⌘5", "⇧⌘6",
                                     "⌥⌘D", "⌃⌘Q", "⌥⌘⎋", "⇧⌘Q", "⌥⇧⌘Q", "⇧⌘/", "⌃⌘D", "⌥⌘8", "⌥⌘=", "⌥⌘-", "⌃↑", "⌃↓",
                                     "⌃←", "⌃→", "⌘H", "⌥⌘H", "⌘M", "⌘Q", "⌃⌘F", "⌘,"]
        // The standard ones are taken only by their standard commands.
        let standard: [String: String] = ["⌘H": "Hide AirSQL", "⌥⌘H": "Hide Others", "⌘M": "Minimize", "⌘Q": "Quit AirSQL",
                                          "⌃⌘F": "Enter Full Screen", "⌘,": "Settings…"]
        for command in Commands.all where !command.key.isEmpty {
            let shortcut = combo(command)
            if let owner = standard[shortcut] {
                #expect(command.title == owner, "\(shortcut) belongs to \(owner), not \(command.title)")
            } else {
                #expect(!reserved.contains(shortcut), "\(command.title) takes \(shortcut), which macOS keeps")
            }
        }
        // Set DEFAULT has none (⌥⌘D is the Dock's); ⌘↩ only runs; Commit and Rollback have none.
        #expect(Commands.setDefault.key.isEmpty && Commands.commit.key.isEmpty && Commands.rollback.key.isEmpty)
        #expect(Commands.all.filter { combo($0) == "⌘↩" }.map(\.title) == ["Run Statement"])
        #expect(combo(Commands.runAll) == "⇧⌘↩" && combo(Commands.recordView) == "⌥⌘R")
    }

    @Test func everyCommandSaysWhatItDoes() {
        for command in Commands.all {
            let tip = command.tip
            #expect(!tip.isEmpty, "\(command.title)")
            #expect(!tip.hasSuffix("."), "\(command.title): no full stop")
            #expect(tip.count <= 100, "\(command.title): one short line (\(tip.count))")
            #expect(tip.first?.isUppercase == true, "\(command.title): starts with its verb")
        }
        for (title, tip) in Commands.submenus { #expect(!tip.isEmpty && !tip.hasSuffix("."), "\(title)") }
    }

    @Test func everyDeclaredActionHasACommand() {
        // Each selector of the actions protocol is a command with a title, a tip and (maybe) a shortcut.
        var count: UInt32 = 0
        guard let methods = protocol_copyMethodDescriptionList(AirSQLActions.self, false, true, &count) else {
            Issue.record("no methods")
            return
        }
        defer { free(methods) }
        let actions = Set(Commands.all.map(\.action))
        for index in 0..<Int(count) {
            let selector = methods[index].name!
            #expect(actions.contains(selector), "\(NSStringFromSelector(selector)) has no command")
        }
        #expect(count > 100)
    }
}

/// Each page the Help menu and the "?" buttons open is a page of docs/ (published as the site).
struct DocsTests {
    @Test func everyHelpPageIsInDocs() {
        let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs")
        for page in HelpPage.allCases {
            let path = page.rawValue.components(separatedBy: "#")[0]
            let file = path.isEmpty ? "index.md" : path.replacingOccurrences(of: ".html", with: ".md")
            #expect(FileManager.default.fileExists(atPath: docs.appendingPathComponent(file).path), "\(page): docs/\(file)")
        }
    }
}
