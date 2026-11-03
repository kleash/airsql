import AirSQLCore
import AppKit

/// Settings ▸ Agents: whether AI agents may use AirSQL, each connection's access, the folder their exports go to, and
/// adding AirSQL to Claude Code or Gemini CLI (plan §2.8). Only the person changes these: agents can't.
final class AgentsPane: SettingsPaneController {
    /// Where agents' exports go: inside AirSQL's folder, so macOS asks nothing (R18).
    static var exportFolder: URL { AgentTarget.exportFolder }
    /// The program agents start: this AirSQL's own, with --mcp.
    static var program: String { Bundle.main.executablePath ?? "/Applications/AirSQL.app/Contents/MacOS/AirSQL" }
    /// A throwaway instance's settings folder, which its agents' --mcp must use too.
    static var supportDir: String? { Env.value("SUPPORT_DIR").flatMap { $0.isEmpty ? nil : $0 } }
    /// Where Claude Code's and Gemini CLI's settings are; tests use a scratch folder.
    var home = FileManager.default.homeDirectoryForCurrentUser
    /// Keeps the access rows' targets alive.
    private var accessBindings: [Binding] = []

    override func build() {
        form.row("", [toggle("Allow AI agents to use AirSQL", id: "settings.agentsAllowed",
                             tip: "Off by default: lets Claude Code, Gemini CLI or another MCP client use AirSQL",
                             \.agentsAllowed)],
                 caption: "Agents never see passwords and can't change data: they read within each connection's access "
                    + "below, and propose SQL in console tabs for you to run. Every call is listed in Agent Activity.")
        if let problem = (NSApp.delegate as? AppDelegate)?.agents?.problem {
            form.row("", [caption("Agents can't start: " + problem)])
        }
        form.heading("Access")
        form.row("Connections", [accessList()],
                 caption: "Schema: names and structure. + read: read-only queries within Settings ▸ Safety's row cap and "
                    + "timeout. + analytics: profile, ten times the rows, files. Sample rows: describe shows a few.")
        let folder = label(Self.shown(Self.exportFolder), truncates: true)
        folder.toolTip = Self.shown(Self.exportFolder)
        folder.lineBreakMode = .byTruncatingMiddle
        folder.isSelectable = true
        form.row("Exports", [folder, action("Show in Finder", id: "settings.agentExports",
                                            tip: "Show the folder agents save query results in") { [weak self] in
            self?.reveal(Self.exportFolder)
        }], caption: "Files agents save (with the analytics access) go here, and nowhere else.")
        form.heading("Set up")
        for client in AgentSetup.Client.allCases {
            let id = client == .claudeCode ? "settings.addToClaudeCode" : "settings.addToGeminiCLI"
            form.row(client.title, [action("Add to \(client.title)…", id: id,
                                           tip: "Show the change to \(client.title)'s settings that adds AirSQL, then make it") {
                [weak self] in self?.setUp(client)
            }])
        }
        let command = label(Self.program + " --mcp", font: .monospacedSystemFont(ofSize: 11, weight: .regular), truncates: true)
        command.lineBreakMode = .byTruncatingMiddle
        command.isSelectable = true
        command.toolTip = Self.program + " --mcp"
        command.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        form.row("Other clients", [command, action("Copy", id: "settings.copyMCPCommand",
                                                   tip: "Copy the command MCP clients start AirSQL's server with") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.program + " --mcp", forType: .string)
        }], caption: "Claude Code can also use the AirSQL plugin, and Claude Desktop the airsql.mcpb bundle.")
    }

    // MARK: Access per connection

    /// A row per connection, by name: its access level and the sample rows switch.
    private func accessList() -> NSView {
        let connections = model.data.connections.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        guard !connections.isEmpty else {
            return caption("No connections yet: add one, then choose here what agents may do with it.")
        }
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        for connection in connections {
            let name = label(connection.displayName, truncates: true)
            name.toolTip = connection.displayName
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true
            let level = popup(AgentAccess.allCases.map(\.title),
                              selected: AgentAccess.allCases.firstIndex(of: connection.agentAccess) ?? 0,
                              id: "settings.agentAccess", tip: "Choose what agents may do with \(connection.displayName)",
                              target: nil, action: nil)
            let samples = checkbox("Sample rows", id: "settings.agentSampleRows",
                                   tip: "Let describe show agents a few rows of \(connection.displayName)'s tables",
                                   on: connection.agentSampleRows, target: nil, action: nil)
            samples.isEnabled = connection.agentAccess != .off
            let id = connection.id
            let binding = Binding { [weak self] _ in
                guard let self, var saved = self.model.connection(id), level.indexOfSelectedItem >= 0 else { return }
                saved.agentAccess = AgentAccess.allCases[level.indexOfSelectedItem]
                saved.agentSampleRows = samples.state == .on
                samples.isEnabled = saved.agentAccess != .off
                self.model.save(saved)
            }
            accessBindings.append(binding)
            for control in [level, samples] as [NSControl] {
                control.target = binding
                control.action = #selector(Binding.act(_:))
            }
            grid.addRow(with: [name, level, samples])
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.layoutSubtreeIfNeeded()
        let size = grid.fittingSize
        guard size.height > 150 else { return grid }
        // Many connections: they scroll.
        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: size.width + 16),
            scroll.heightAnchor.constraint(equalToConstant: 150),
            grid.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            grid.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        return scroll
    }

    // MARK: Setup

    /// Shows the exact change to the client's settings, and makes it when the person agrees.
    func setUp(_ client: AgentSetup.Client) {
        let home = self.home, program = Self.program, support = Self.supportDir
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let plan = Result { try AgentSetup.plan(client, home: home, program: program, supportDir: support) }
            DispatchQueue.main.async { self?.confirm(plan) }
        }
    }

    private func confirm(_ plan: Result<AgentSetup.Change, Error>) {
        let alert = NSAlert()
        switch plan {
        case .failure(let error):
            alert.messageText = "AirSQL can't change that file"
            alert.informativeText = error.localizedDescription
            show(alert) { _ in }
        case .success(let change) where change.unchanged:
            alert.messageText = "\(change.client.title) already has AirSQL"
            alert.informativeText = "\(Self.shown(change.file)) starts AirSQL's MCP server as it should. Restart "
                + "\(change.client.title) if it doesn't list AirSQL's tools."
            show(alert) { _ in }
        case .success(let change):
            alert.messageText = "Add AirSQL to \(change.client.title)?"
            alert.informativeText = "AirSQL will set mcpServers ▸ airsql in \(Self.shown(change.file))"
                + (change.before == nil ? "" : ", replacing the entry there now") + ", and keep the old file next to it "
                + "(.airsql-backup). Then restart \(change.client.title)."
            alert.accessoryView = codeView((change.before.map { "Now:\n" + $0 + "\n\nAfter:\n" } ?? "") + change.after)
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            show(alert) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try AgentSetup.apply(change) }
                    DispatchQueue.main.async {
                        guard case .failure(let error) = result else { return }
                        let failed = NSAlert()
                        failed.messageText = "AirSQL couldn't change \(change.file.lastPathComponent)"
                        failed.informativeText = error.localizedDescription
                        self?.show(failed) { _ in }
                    }
                }
            }
        }
    }

    private func show(_ alert: NSAlert, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }

    /// The JSON the change writes, as it will be in the file.
    private func codeView(_ text: String) -> NSView {
        let field = label(text, font: .monospacedSystemFont(ofSize: 11, weight: .regular), wraps: true)
        field.isSelectable = true
        field.preferredMaxLayoutWidth = 420
        field.setAccessibilityIdentifier("agents.setupChange")
        field.frame.size = field.fittingSize
        return field
    }
}
