import AirSQLCore
import AppKit

private let f2 = String(UnicodeScalar(NSF2FunctionKey)!)
private let f3 = String(UnicodeScalar(NSF3FunctionKey)!)
private let f5 = String(UnicodeScalar(NSF5FunctionKey)!)
private let f8 = String(UnicodeScalar(NSF8FunctionKey)!)

extension Command {
    /// Settings ▸ Keys' changes, by `id`.
    static var keymap: [String: KeyBinding] = [:]

    /// Which command a keymap entry is for: its action, tag and default shortcut (a hidden second shortcut shares the rest).
    var id: String { "\(NSStringFromSelector(action))/\(tag)/\(Command.shortcut(key, modifiers))" }

    /// The shortcut in use: the keymap's, else the default.
    var bound: (key: String, modifiers: NSEvent.ModifierFlags) {
        guard let binding = Command.keymap[id] else { return (key, modifiers) }
        return (binding.key, NSEvent.ModifierFlags(rawValue: binding.modifiers))
    }
}

/// Changing the shortcuts of `Commands`: what Settings ▸ Keys does, and its presets.
@MainActor
enum Keymap {
    /// Shortcuts macOS keeps for itself, or that people expect it to handle.
    private static let reserved: Set<String> = ["⌘Space", "⌃Space", "⌃⌘Space", "⌘⇥", "⌘`", "⇧⌘3", "⇧⌘4", "⇧⌘5", "⌃⌘Q", "⌥⌘⎋",
                                                "⇧⌘Q", "⌘H", "⌥⌘H", "⌘M", "⌘Q", "⌘,"]

    /// The commands a person can bind.
    static var commands: [Command] { Commands.all.filter { !$0.title.isEmpty } }

    /// A preset: what differs from AirSQL's own shortcuts.
    struct Preset {
        let name: String
        let changes: [(command: Command, key: String, modifiers: NSEvent.ModifierFlags)]
    }

    static let presets = [
        Preset(name: "AirSQL", changes: []),
        Preset(name: "Like DataGrip", changes: [
            (Commands.duplicateLine, "d", .command), (Commands.deleteLine, "\u{8}", .command), (Commands.formatSQL, "l", [.command, .option]),
            (Commands.toggleCase, "u", [.command, .shift]), (Commands.recentTabs, "e", .command),
        ]),
        Preset(name: "Like HeidiSQL", changes: [
            (Commands.refresh, f5, []), (Commands.formatSQL, f8, .control), (Commands.findNext, f3, []), (Commands.renameTab, f2, .shift),
        ]),
    ]

    /// Why this shortcut can't be used; nil: it can.
    static func refusal(key: String, modifiers: NSEvent.ModifierFlags) -> String? {
        let isFunctionKey = key.unicodeScalars.first.map { (0xF704...0xF726).contains($0.value) } ?? false
        // Menus see only ⌘ and ⌃ keys, function keys and arrows: ⌥ and a letter would type a character.
        let isArrow = key.unicodeScalars.first.map { (0xF700...0xF703).contains($0.value) } ?? false
        if !isFunctionKey, modifiers.intersection([.command, .control]).isEmpty, !(isArrow && modifiers.contains(.option)) {
            return "Add ⌘ or ⌃ to it: without them the key types in the editor"
        }
        let shortcut = Command.shortcut(key, modifiers)
        return reserved.contains(shortcut) ? "macOS keeps \(shortcut) for itself" : nil
    }

    /// `keymap` with `command` on this shortcut (an empty key: none) and the shortcut taken from any other command,
    /// and the titles of those.
    static func binding(_ command: Command, key: String, modifiers: NSEvent.ModifierFlags, in keymap: [String: KeyBinding])
        -> (keymap: [String: KeyBinding], taken: [String]) {
        let current = Command.keymap
        Command.keymap = keymap
        defer { Command.keymap = current }
        var result = keymap
        var taken: [String] = []
        let shortcut = Command.shortcut(key, modifiers)
        if !key.isEmpty {
            for other in commands where other.id != command.id && other.shortcut == shortcut {
                result[other.id] = KeyBinding(key: "", modifiers: 0)
                taken.append(other.title)
            }
        }
        let isDefault = key == command.key && modifiers == command.modifiers
        result[command.id] = isDefault ? nil : KeyBinding(key: key, modifiers: modifiers.rawValue)
        return (result, taken)
    }

    static func keymap(of preset: Preset) -> [String: KeyBinding] {
        preset.changes.reduce(into: [:]) { keymap, change in
            keymap = binding(change.command, key: change.key, modifiers: change.modifiers, in: keymap).keymap
        }
    }

    /// Puts `keymap` to work: every menu is made again, and context menus are made as they open.
    static func apply(_ keymap: [String: KeyBinding]) {
        guard keymap != Command.keymap else { return }
        Command.keymap = keymap
        if NSApp.mainMenu != nil { NSApp.mainMenu = MainMenu.build() }
    }
}
