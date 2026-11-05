import AirSQLCore
import AppKit

/// Settings ▸ Keys: every command with its shortcut. A double-click or Change… records the next keys pressed; a shortcut
/// another command has moves here, and the note says whose it was. Agents can't change this: `AgentGate.personsPart`.
final class KeysPane: SettingsPaneController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let table = NSTableView()
    private let filter = NSSearchField()
    private(set) lazy var note = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, wraps: true)
    private(set) var rows: [Command] = []
    private var recording: Any?

    override func build() {
        let presets = popup(Keymap.presets.map(\.name), selected: 0, id: "settings.keymapPreset",
                            tip: "Choose a starting set of shortcuts: what you changed is replaced", target: self, action: #selector(usePreset(_:)))
        form.row("Start from", [presets])
        filter.placeholderString = "Filter: a command or a key"
        filter.toolTip = "Type part of a command's name, or a key such as ⌘T, to show only those"
        filter.setAccessibilityIdentifier("settings.keysFilter")
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        filter.widthAnchor.constraint(equalToConstant: 380).isActive = true
        form.row("Commands", [filter])
        for (id, title, width) in [("command", "Command", 270.0), ("shortcut", "Shortcut", 100.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(record(_:))
        table.setAccessibilityIdentifier("settings.keys")
        table.menu = NSMenu()
        for (title, tip, action) in [("Change…", "Press the new shortcut next", #selector(record(_:))),
                                     ("Remove", "Take this command's shortcut off", #selector(removeShortcut(_:))),
                                     ("Reset", "Give this command its own shortcut back", #selector(resetShortcut(_:)))] {
            let item = table.menu?.addItem(withTitle: title, action: action, keyEquivalent: "")
            item?.target = self
            item?.toolTip = tip
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 380).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
        form.row("", [scroll])
        form.row("", [action("Change…", id: "settings.keyChange", tip: "Press the new shortcut next") { [weak self] in self?.record(nil) },
                      action("Remove", id: "settings.keyRemove", tip: "Take this command's shortcut off") { [weak self] in self?.removeShortcut(nil) },
                      action("Reset", id: "settings.keyReset", tip: "Give this command its own shortcut back") { [weak self] in self?.resetShortcut(nil) },
                      action("Reset All", id: "settings.keyResetAll", tip: "Give every command its own shortcut back") { [weak self] in self?.save([:]) }])
        note.setAccessibilityIdentifier("settings.keyNote")
        note.widthAnchor.constraint(equalToConstant: 380).isActive = true
        form.row("", [note])
        fill()
    }

    private func fill() {
        let words = filter.stringValue.trimmingCharacters(in: .whitespaces)
        rows = Keymap.commands.filter { words.isEmpty || $0.title.localizedCaseInsensitiveContains(words) || $0.shortcut.contains(words) }
        table.reloadData()
    }

    func controlTextDidChange(_ notification: Notification) { fill() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let command = rows[row], isName = tableColumn?.identifier.rawValue == "command"
        let field = label(isName ? command.title : command.shortcut, font: .systemFont(ofSize: 12.5), truncates: true)
        field.toolTip = isName ? command.tip : "Double-click to change this shortcut"
        return field
    }

    private func save(_ keymap: [String: KeyBinding]) {
        // The menu bar follows through the app's observer; a test window has none, so this pane says it itself.
        model.data.settings.keymap = keymap
        Keymap.apply(model.data.settings.keymap)
        fill()
    }

    @objc private func usePreset(_ sender: NSPopUpButton) {
        guard Keymap.presets.indices.contains(sender.indexOfSelectedItem) else { return }
        save(Keymap.keymap(of: Keymap.presets[sender.indexOfSelectedItem]))
    }

    private var selected: Command? { rows[safe: table.clickedRow >= 0 ? table.clickedRow : table.selectedRow] }

    /// `command` takes these keys, or the note says why not.
    func bind(_ command: Command, key: String, modifiers: NSEvent.ModifierFlags) {
        if let refusal = Keymap.refusal(key: key, modifiers: modifiers) {
            note.stringValue = refusal
            return
        }
        let (keymap, taken) = Keymap.binding(command, key: key, modifiers: modifiers, in: model.data.settings.keymap)
        save(keymap)
        note.stringValue = taken.isEmpty ? "" : "\(Command.shortcut(key, modifiers)) was \(taken.joined(separator: ", "))'s, which now has none."
    }

    /// The next keys pressed become the shortcut; Esc gives up.
    @objc private func record(_ sender: Any?) {
        guard let command = selected, recording == nil else {
            if selected == nil { note.stringValue = "Select a command first." }
            return
        }
        note.stringValue = "Press the shortcut for \(command.title), or Esc to leave it."
        recording = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            self.stopRecording()
            if event.keyCode == 53 {
                self.note.stringValue = ""
            } else {
                let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
                self.bind(command, key: (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "").lowercased(), modifiers: flags)
            }
            return nil
        }
    }

    private func stopRecording() {
        if let recording { NSEvent.removeMonitor(recording) }
        recording = nil
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopRecording()
    }

    @objc private func removeShortcut(_ sender: Any?) {
        guard let command = selected else { return }
        save(Keymap.binding(command, key: "", modifiers: [], in: model.data.settings.keymap).keymap)
    }

    @objc private func resetShortcut(_ sender: Any?) {
        guard let command = selected else { return }
        var keymap = model.data.settings.keymap
        keymap[command.id] = nil
        save(keymap)
    }
}
