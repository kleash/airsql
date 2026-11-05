import AppKit
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// Keys sent as real events: a test that calls the command can't show that its key reaches it.
extension AppTests {
    @MainActor @Suite struct KeyPathTests {
        private let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        private let f1 = String(UnicodeScalar(NSF1FunctionKey)!)

        /// The Mac's key numbers (US layout).
        private static let keyCodes: [String: CGKeyCode] = {
            var codes: [String: CGKeyCode] = ["\r": 36, "\t": 48, "\u{8}": 51, "{": 33, "}": 30, "+": 24, "*": 28]
            for (index, key) in "asdfhgzxcv_bqweryt123465=97-80]ou[ip_lj'k;\\,/nm.".enumerated() where key != "_" { codes[String(key)] = CGKeyCode(index) }
            for (index, code) in [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].enumerated() {
                codes[String(UnicodeScalar(NSF1FunctionKey + index)!)] = CGKeyCode(code)
            }
            for (key, code) in [(NSLeftArrowFunctionKey, 123), (NSRightArrowFunctionKey, 124), (NSDownArrowFunctionKey, 125), (NSUpArrowFunctionKey, 126)] {
                codes[String(UnicodeScalar(key)!)] = CGKeyCode(code)
            }
            return codes
        }()

        private final class Recorder: NSObject, NSMenuItemValidation {
            var fired: String?
            @objc func hit(_ item: NSMenuItem) { fired = item.title }
            func validateMenuItem(_ item: NSMenuItem) -> Bool { true }
        }

        /// Every shortcut, as a real event, reaches an item of a menu that has them all. (Items answer a recorder: in a test
        /// no window is key, so the app's own would stay off. ⌥↩ and ⇧↩ are their views', tested below: AppKit offers a menu
        /// only ⌘ and ⌃ keys, function keys and arrows.)
        @Test func everyShortcutReachesTheMenu() throws {
            _ = NSApplication.shared
            useAppMenuBar()
            let recorder = Recorder(), menu = NSMenu(), top = NSMenuItem(title: "All", action: nil, keyEquivalent: ""), all = NSMenu(title: "All")
            let keyed = Commands.all.filter { !$0.key.isEmpty && ![Commands.showContextActions.action, Commands.valuePanel.action].contains($0.action) }
            for command in keyed {
                let item = command.item()
                item.title = command.title + command.shortcut
                item.target = recorder
                item.action = #selector(Recorder.hit(_:))
                all.addItem(item)
            }
            top.submenu = all
            menu.addItem(top)
            let saved = NSApp.mainMenu
            NSApp.mainMenu = menu
            defer { NSApp.mainMenu = saved }
            // Those with ⌘ always reach it, and each key takes a tenth of a second here.
            for command in keyed where !command.modifiers.contains(.command) {
                recorder.fired = nil
                let key = command.key.lowercased(), code = try #require(Self.keyCodes[key], "\(command.title)")
                var flags: CGEventFlags = []
                if command.modifiers.contains(.command) { flags.insert(.maskCommand) }
                if command.modifiers.contains(.control) { flags.insert(.maskControl) }
                if command.modifiers.contains(.option) { flags.insert(.maskAlternate) }
                if command.modifiers.contains(.shift) || key != command.key || "{}+*".contains(key) { flags.insert(.maskShift) }
                // Built from a keyboard event, never posted: AppKit reads the keyboard's own data, as for a real key.
                let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
                event.flags = flags
                NSApp.sendEvent(try #require(NSEvent(cgEvent: event)))
                #expect(recorder.fired?.hasSuffix(command.shortcut) == true, "\(command.title) \(command.shortcut), got \(recorder.fired ?? "nothing")")
            }
        }

        /// A letter with ⌥ alone would be typed; with an arrow it reaches the menu.
        @Test func keysThatCouldNeverFireAreRefused() {
            #expect(Keymap.refusal(key: "g", modifiers: .option) != nil)
            #expect(Keymap.refusal(key: "g", modifiers: [.option, .control]) == nil)
            #expect(Keymap.refusal(key: up, modifiers: .option) == nil)
        }

        @Test func optionReturnOpensTheContextActions() async throws {
            let (main, _, console) = try await ConsoleAppTests.console()
            let editor = try #require(console.editor)
            main.window?.makeFirstResponder(editor)
            editor.setText("-- x")  // nothing to do here: a note, not a menu that would wait for a click
            editor.setSelectedRange(NSRange(location: 4, length: 0))
            editor.shownNote = ""
            press(main.window, "\r", code: 36, .option)
            #expect(await eventually(timeout: 5) { editor.shownNote.hasPrefix("Nothing to Do Here") })
            #expect(editor.string == "-- x", "no line break")
            editor.notePopover?.close()
        }

        /// No menu item takes the keys that select to the start of the text.
        @Test func shiftCommandUpIsTheEditors() async throws {
            let (main, _, console) = try await ConsoleAppTests.console()
            let editor = try #require(console.editor)
            main.window?.makeFirstResponder(editor)
            editor.setText("ab\ncd")
            editor.setSelectedRange(NSRange(location: 4, length: 0))
            press(main.window, up, code: 126, [.command, .shift, .function, .numericPad])
            #expect(editor.selectedRange() == NSRange(location: 0, length: 4))
        }

        @Test func shiftReturnInTheGridOpensTheValuePanel() async throws {
            let (main, _, tab) = try await GridDataAppTests.tab(session: FakeTableSession())
            main.window?.makeFirstResponder(tab.grid)
            let before = tab.viewer.valuePanel != nil
            press(main.window, "\r", code: 36, .shift)
            #expect((tab.viewer.valuePanel != nil) != before)
        }
    }
}
