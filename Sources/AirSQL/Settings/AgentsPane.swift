import AirSQLCore
import AppKit
import Combine

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
    /// The main window, whose connection editor a double-click in the access list opens; tests give their own.
    var main: () -> MainWindowController? = { (NSApp.delegate as? AppDelegate)?.main }
    private var observers: [AnyCancellable] = []

    override func build() {
        form.row("", [toggle("Allow AI agents to use AirSQL", id: "settings.agentsAllowed",
                             tip: "Let Claude Code, Gemini CLI or another MCP client use AirSQL (off by default)",
                             \.agentsAllowed)],
                 caption: "Agents never see passwords and can't change data: they read within each connection's access "
                    + "below, and propose SQL in console tabs for you to run. Every call is listed in Agent Activity.")
        if let problem = (NSApp.delegate as? AppDelegate)?.agents?.problem {
            form.row("", [caption("Agents can't start: " + problem)])
        }
        form.heading("Access")
        let list = form.row("Connections", [accessList()],
                 caption: "Schema: names and structure. + read: read-only queries within Settings ▸ Safety's row cap and "
                    + "timeout. + analytics: profile, ten times the rows, files. Sample rows: describe shows a few.")
        list.rowAlignment = .none  // the label at the list's top
        list.yPlacement = .top
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
        command.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true  // all of it from /Applications
        form.row("Other clients", [command, action("Copy", id: "settings.copyMCPCommand",
                                                   tip: "Copy the command MCP clients start AirSQL's server with") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.program + " --mcp", forType: .string)
        }], caption: "Claude Code can also use the AirSQL plugin, and Claude Desktop the airsql.mcpb bundle.")
    }

    // MARK: Access per connection

    /// The connections, by name, each with its access level and sample rows switch: a table, so a thousand stay quick.
    /// A double-click opens the connection's settings at its Agents tab; a right-click offers that and the levels.
    private func accessList() -> NSView {
        guard !model.data.connections.isEmpty else {
            return caption("No connections yet: add one, then choose here what agents may do with it.")
        }
        let table = AccessTableView()
        table.dataSource = accessTable
        table.delegate = accessTable
        table.target = accessTable
        table.doubleAction = #selector(AccessTable.editClicked(_:))
        table.owner = accessTable
        accessTable.model = model
        accessTable.edit = { [weak self, weak table] connection in
            self?.main()?.edit(connection, isNew: false, on: table?.window, tab: .agents)
        }
        // A level changed elsewhere (the connection's Agents tab) shows here too.
        observers.append(model.$data.map(\.connections).removeDuplicates().dropFirst().sink { [weak table] _ in
            DispatchQueue.main.async { table?.reloadData() }
        })
        // Access as wide as its pop-up with its longest level, "Schema + read + analytics".
        for (id, title, width) in [("name", "Connection", 130.0), ("access", "Access", 170.0), ("samples", "Sample rows", 100.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.rowHeight = 28
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.stripes = true
        table.allowsColumnReordering = false
        table.setAccessibilityIdentifier("settings.agentAccessList")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let rows = CGFloat(min(model.data.connections.count, 6))
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 436),
            scroll.heightAnchor.constraint(equalToConstant: rows * 30 + 28),
        ])
        return scroll
    }

    private let accessTable = AccessTable()

    /// The access table's rows: made as they scroll into view; each change is saved at once.
    @MainActor final class AccessTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var model: AppModel?

        private var connections: [SavedConnection] {
            (model?.data.connections ?? []).sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        }

        /// Opens a connection's settings at its Agents tab.
        var edit: ((SavedConnection) -> Void)?

        func numberOfRows(in tableView: NSTableView) -> Int { connections.count }

        /// A double-click, or Edit… in a row's menu.
        @objc func editClicked(_ sender: Any?) {
            guard let table = sender as? NSTableView ?? menuTable else { return }
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            if connections.indices.contains(row) { edit?(connections[row]) }
        }

        /// A row's menu: its settings, then its access level and sample rows, as its controls set them.
        func menu(for table: NSTableView) -> NSMenu? {
            guard connections.indices.contains(table.selectedRow) else { return nil }
            let connection = connections[table.selectedRow]
            let menu = NSMenu(title: "Agent Access")
            let edit = menu.addItem(withTitle: Commands.editConnection.title, action: #selector(editClicked(_:)), keyEquivalent: "")
            edit.toolTip = "Open \(connection.displayName)'s settings at its Agents tab"
            menu.addItem(.separator())
            for (index, level) in AgentAccess.allCases.enumerated() {
                let item = menu.addItem(withTitle: level.title, action: #selector(chose(_:)), keyEquivalent: "")
                item.tag = index
                item.state = connection.agentAccess == level ? .on : .off
                item.toolTip = "Let agents have \(level.title) access to \(connection.displayName)"
            }
            menu.addItem(.separator())
            let samples = menu.addItem(withTitle: "Sample Rows", action: #selector(chose(_:)), keyEquivalent: "")
            samples.tag = -1
            samples.state = connection.agentSampleRows ? .on : .off
            samples.toolTip = connection.agentAccess == .off ? "Choose an access other than Off first: agents see nothing of "
                + connection.displayName : "Let describe show agents a few rows of \(connection.displayName)'s tables"
            menu.items.forEach { $0.target = self }
            menu.autoenablesItems = false
            samples.isEnabled = connection.agentAccess != .off
            menuTable = table
            return menu
        }

        private weak var menuTable: NSTableView?

        /// A level or Sample Rows chosen from a row's menu: saves that connection (the list follows the model).
        @objc func chose(_ item: NSMenuItem) {
            guard let model, let row = menuTable?.selectedRow, connections.indices.contains(row) else { return }
            var saved = connections[row]
            if item.tag < 0 { saved.agentSampleRows.toggle() } else { saved.agentAccess = AgentAccess.allCases[item.tag] }
            model.save(saved)
        }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            let connection = connections[row]
            switch column?.identifier.rawValue {
            case "name":
                let name = label(connection.displayName, truncates: true)
                name.toolTip = connection.displayName
                return centred(name)
            case "access":
                let level = popup(AgentAccess.allCases.map(\.title),
                                  selected: AgentAccess.allCases.firstIndex(of: connection.agentAccess) ?? 0,
                                  id: "settings.agentAccess", tip: "Choose what agents may do with \(connection.displayName)",
                                  target: self, action: #selector(changed(_:)))
                level.tag = row
                return centred(level)
            default:
                let samples = checkbox("", id: "settings.agentSampleRows",
                                       tip: connection.agentAccess == .off ? "Choose an access other than Off first: agents see "
                                           + "nothing of \(connection.displayName)"
                                           : "Let describe show agents a few rows of \(connection.displayName)'s tables",
                                       on: connection.agentSampleRows, target: self, action: #selector(changed(_:)))
                samples.isEnabled = connection.agentAccess != .off
                samples.setAccessibilityLabel("Sample rows of \(connection.displayName)")
                samples.tag = row
                return centred(samples)
            }
        }

        /// A cell's control, centred in its row.
        private func centred(_ view: NSView) -> NSView {
            let cell = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                view.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                view.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            ])
            return cell
        }

        /// A row's pop-up or checkbox changed: saves that connection.
        @objc func changed(_ sender: NSControl) {
            guard let model, connections.indices.contains(sender.tag) else { return }
            var saved = connections[sender.tag]
            if let level = sender as? NSPopUpButton, level.indexOfSelectedItem >= 0 {
                saved.agentAccess = AgentAccess.allCases[level.indexOfSelectedItem]
            } else if let box = sender as? NSButton {
                saved.agentSampleRows = box.state == .on
            }
            model.save(saved)
            (sender.enclosingScrollView?.documentView as? NSTableView)?
                .reloadData(forRowIndexes: [sender.tag], columnIndexes: [2])
        }
    }

    /// The access list: a right-click selects the row under the pointer first and opens its menu.
    final class AccessTableView: ContentTable {
        weak var owner: AccessTable?

        override func menu(for event: NSEvent) -> NSMenu? { selectsRow(for: event) ? owner?.menu(for: self) : nil }
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
