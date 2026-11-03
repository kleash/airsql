import AirSQLCore
import AppKit

/// Settings ▸ Client Tools: the mysql (or mariadb) and mysqldump (or mariadb-dump) AirSQL runs for export, restore and
/// Terminal. Empty fields: AirSQL finds them (Homebrew, /usr/local/mysql/bin, MAMP, PATH) and picks the best for each
/// server. Each field says which program and version it found, or why there is none or it can't be used.
final class ClientToolsPane: SettingsPaneController {
    private var fields: [ClientTool.Kind: NSTextField] = [:]
    private var notes: [ClientTool.Kind: NSTextField] = [:]
    private let found = label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, wraps: true)
    private let spinner = NSProgressIndicator()
    private var finding: Task<Void, Never>?

    override func build() {
        for kind in [ClientTool.Kind.client, .dump] {
            let what = kind == .client ? "mysql or mariadb" : "mysqldump or mariadb-dump"
            let field = AirSQL.textField(model.data.settings[keyPath: Self.path(kind)], placeholder: "Found automatically",
                                         id: kind == .client ? "settings.clientPath" : "settings.dumpPath",
                                         tip: "The \(what) program to run; empty: found automatically", width: 300)
            field.target = self
            field.action = #selector(fieldChanged(_:))
            fields[kind] = field
            let choose = action("Choose…", id: kind == .client ? "settings.chooseClient" : "settings.chooseDump",
                                tip: "Choose the \(what) program to use") { [weak self] in self?.choose(kind, what: what) }
            form.row(kind == .client ? "Client" : "Dump tool", [field, choose])
            let note = caption("", width: 400)
            note.setAccessibilityIdentifier(kind == .client ? "settings.clientFound" : "settings.dumpFound")
            notes[kind] = note
            form.grid.addRow(with: [NSGridCell.emptyContentView, note]).topPadding = -4
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let again = action("Find Again", id: "settings.findTools",
                           tip: "Look for client tools again, after installing or updating them") { [weak self] in self?.find() }
        form.row("Found", [again, spinner], caption: "AirSQL looks in Homebrew's folders, /usr/local/mysql/bin, MAMP and your "
            + "PATH, and picks for each server the tools of its family (MariaDB's for MariaDB, MySQL's for MySQL) and release. "
            + "A connection keeps the tool you choose in its Export or Restore sheet.")
        found.preferredMaxLayoutWidth = 400
        found.setAccessibilityIdentifier("settings.toolsFound")
        found.isSelectable = true
        form.grid.addRow(with: [NSGridCell.emptyContentView, found])
        find()
    }

    private static func path(_ kind: ClientTool.Kind) -> WritableKeyPath<AppSettings, String> {
        kind == .client ? \.clientPath : \.dumpPath
    }

    @objc private func fieldChanged(_ sender: NSTextField) {
        guard let kind = fields.first(where: { $0.value === sender })?.key else { return }
        model.data.settings[keyPath: Self.path(kind)] = sender.stringValue.trimmingCharacters(in: .whitespaces)
        find()
    }

    private func choose(_ kind: ClientTool.Kind, what: String) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the \(what) program."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.model.data.settings[keyPath: Self.path(kind)] = url.path
            self.fields[kind]?.stringValue = url.path
            self.find()
        }
    }

    /// Looks for the tools off the main thread and says what each field gets.
    func find() {
        finding?.cancel()
        spinner.startAnimation(nil)
        for note in notes.values {
            note.stringValue = "Looking…"
            note.textColor = .secondaryLabelColor
        }
        let settings = model.data.settings
        finding = Task {
            let clients = await ClientTools.find(.client, chosen: settings.clientPath)
            let dumps = await ClientTools.find(.dump, chosen: settings.dumpPath)
            guard !Task.isCancelled else { return }
            show(clients, kind: .client, chosen: settings.clientPath)
            show(dumps, kind: .dump, chosen: settings.dumpPath)
            let all = (clients + dumps).filter { $0.found && $0.version != nil }
            found.stringValue = all.isEmpty ? "" : all.map { "\($0.title) · \(SettingsPaneController.shown(URL(fileURLWithPath: $0.path)))" }
                .joined(separator: "\n")
            found.toolTip = all.isEmpty ? nil : "The client tools on this Mac"
            spinner.stopAnimation(nil)
            // The notes' lengths changed: the Settings window takes the pane's new height.
            view.layoutSubtreeIfNeeded()
            preferredContentSize = view.fittingSize
        }
    }

    private func show(_ tools: [ClientTool], kind: ClientTool.Kind, chosen: String) {
        guard let note = notes[kind] else { return }
        let names = kind == .client ? "mysql or mariadb" : "mysqldump or mariadb-dump"
        guard let tool = chosen.isEmpty ? ClientTools.best(tools, for: nil) : tools.first else {
            note.stringValue = "No \(names) found. Install MySQL's or MariaDB's client tools (for example with Homebrew) and choose "
                + "Find Again, or choose the program." + (kind == .dump ? " Until then Export uses AirSQL's own." : "")
            note.textColor = .statusBad
            return
        }
        if case .unusable(let why) = ClientTools.fit(tool, server: nil) {
            note.stringValue = why
            note.textColor = .statusBad
        } else {
            note.stringValue = (chosen.isEmpty ? "Found: " : "✓ ") + tool.title + (chosen.isEmpty ? " · " + tool.path : "")
                + " (\(tool.version?.family.title ?? ""))"
            note.textColor = chosen.isEmpty ? .secondaryLabelColor : .statusOK
        }
    }
}
