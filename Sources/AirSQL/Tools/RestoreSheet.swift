import AirSQLCore
import AppKit

/// Restore… and Run SQL File… (plan §2.9): a .sql or .sql.gz file run into a chosen database, with your mysql or mariadb
/// client or with AirSQL itself; stop at the first error or go on; progress by bytes of the file read, Cancel. Before it
/// runs, the file is checked for the databases it really writes to, and the SQL preview asks when that or the database
/// having tables calls for it (Settings ▸ Safety).
@MainActor
final class RestoreSheet: ToolSheet {
    private let fileLabel = label("No file chosen", font: .systemFont(ofSize: 12.5), color: .secondaryLabelColor, truncates: true)
    private let fileInfo = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor)
    private let choose = button("Choose…", id: "restore.choose", tip: "Choose the .sql or .sql.gz file to run", target: nil, action: nil)
    private let databaseMenu = popup([], selected: 0, id: "restore.database", tip: "Choose the database the file runs in",
                                     target: nil, action: nil)
    private let stopOnError = NSButton(radioButtonWithTitle: "Stop at the first error", target: nil, action: nil)
    private let goOn = NSButton(radioButtonWithTitle: "Go on past errors and count them (--force)", target: nil, action: nil)
    private let toolMenu = popup([], selected: 0, id: "restore.tool", tip: "Choose the program that runs the file", target: nil,
                                 action: nil)
    private let fit = label("", font: .systemFont(ofSize: 11.5), wraps: true)
    private var command: NSTextView?
    private let builtInFirst: Bool
    private var server: ServerInfo?
    private var tools: [ClientTool] = []
    private var file: URL?
    private var fileSize: Int64 = 0

    init(model: AppModel, connection: SavedConnection, options: ConnectOptions, builtIn: Bool) {
        builtInFirst = builtIn
        super.init(model: model, connection: connection, options: options, width: 640, action: builtIn ? "Run" : "Restore",
                   actionTip: "Run the file's statements in the chosen database")
        heading.stringValue = (builtIn ? "Run a SQL file on " : "Restore into ") + connection.displayName
        choose.target = self
        choose.action = #selector(chooseFile(_:))
        stopOnError.state = .on
        stopOnError.toolTip = "End at the first statement that fails; what ran before it stays"
        goOn.toolTip = "Run every statement, skipping those that fail, and say how many failed"
        stopOnError.setAccessibilityIdentifier("restore.stopOnError")
        goOn.setAccessibilityIdentifier("restore.continue")
        for control in [databaseMenu, stopOnError, goOn, toolMenu] as [NSControl] {
            control.target = self
            control.action = #selector(formChanged(_:))
        }
        fileLabel.setAccessibilityIdentifier("restore.file")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Form

    override func makeForm() -> NSView {
        let form = Form()
        form.row("File", [fileLabel, choose])
        form.grid.addRow(with: [NSGridCell.emptyContentView, fileInfo]).topPadding = -4
        form.row("Database", [databaseMenu])
        let errors = NSStackView(views: [stopOnError, goOn])
        errors.orientation = .vertical
        errors.alignment = .leading
        errors.spacing = 4
        form.row("On error", [errors]).yPlacement = .top
        form.row("Tool", [toolMenu])
        form.grid.addRow(with: [NSGridCell.emptyContentView, fit]).topPadding = -4
        fit.preferredMaxLayoutWidth = 460
        let grid = form.finish()
        grid.column(at: 1).width = 470
        return grid
    }

    override func makeCodeBox() -> NSView? {
        let (box, text) = codeBox(id: "restore.command", tip: "What runs: no password in it, the login is in a private file only you "
                                  + "can read")
        command = text
        return box
    }

    override func extraButtons() -> [NSButton] {
        [button("Copy Command", id: "restore.copyCommand", tip: "Copy the command line (it holds no password)", target: self,
                action: #selector(copyCommand(_:)))]
    }

    override func setFormEnabled(_ enabled: Bool) {
        for control in [choose, databaseMenu, stopOnError, goOn, toolMenu] as [NSControl] {
            control.isEnabled = enabled
        }
        let why = "It is running: wait for it, or Stop it"
        choose.toolTip = enabled ? "Choose the .sql or .sql.gz file to run" : why
        databaseMenu.toolTip = enabled ? "Choose the database the file runs in" : why
        toolMenu.toolTip = enabled ? "Choose the program that runs the file" : why
    }

    // MARK: Loading

    override func load() {
        loading("Reading the databases of \(connection.displayName)…")
        let options = self.options, chosen = connection.clientPath.isEmpty ? model.data.settings.clientPath : connection.clientPath
        Task {
            do {
                let session = DBConnection(options: options, role: .tools)
                let server = try await session.connect()
                let names = try await session.query(PickerNode.databasesSQL).first?.rows
                await session.close()
                let tools = await ClientTools.find(.client, chosen: chosen)
                show(server: server, tools: tools, databases: (0..<(names?.rowCount ?? 0)).compactMap { names?.string($0, 0) })
            } catch {
                loading(nil)
                status.textColor = .statusBad
                status.stringValue = "Can't read the databases: " + error.localizedDescription
                updateRunButton()
            }
        }
    }

    /// Fills the form once the server, its databases and the tools are known.
    func show(server: ServerInfo?, tools: [ClientTool], databases: [String]) {
        self.server = server
        self.tools = tools
        databaseMenu.removeAllItems()
        databaseMenu.addItems(withTitles: databases)
        for item in databaseMenu.itemArray { item.toolTip = "Run the file in \(item.title)" }
        databaseMenu.selectItem(withTitle: connection.database)
        if databaseMenu.indexOfSelectedItem < 0, !databases.isEmpty { databaseMenu.selectItem(at: 0) }
        toolMenu.removeAllItems()
        for tool in tools {
            toolMenu.addItem(withTitle: tool.title)
            toolMenu.lastItem?.toolTip = tool.path
        }
        toolMenu.addItem(withTitle: "AirSQL (built in)")
        toolMenu.lastItem?.toolTip = "AirSQL runs the statements itself: no client tools needed"
        let picked = tools.firstIndex { $0.path == connection.clientPath }
            ?? ClientTools.best(tools, for: server).flatMap { best in tools.firstIndex { $0 == best } }
        toolMenu.selectItem(at: builtInFirst ? tools.count : picked ?? tools.count)
        loading(nil)
        formChanged(nil)
    }

    // MARK: Changes

    private var tool: ClientTool? {
        let index = toolMenu.indexOfSelectedItem
        return index >= 0 && index < tools.count ? tools[index] : nil
    }

    private var database: String { databaseMenu.titleOfSelectedItem ?? "" }

    @objc private func formChanged(_ sender: Any?) {
        if sender is NSButton, let radio = sender as? NSButton {
            stopOnError.state = radio === goOn ? .off : .on
            goOn.state = radio === goOn ? .on : .off
        }
        if sender as? NSPopUpButton === toolMenu, let tool, connection.clientPath != tool.path {
            var changed = connection
            changed.clientPath = tool.path
            model.save(changed)
        }
        if let tool {
            let fitness = ClientTools.fit(tool, server: server)
            fit.stringValue = ToolCommand(tool: tool, options: options, server: server).tlsProblem ?? fitness.message
            switch fitness {
            case .good: fit.textColor = .statusOK
            case .warning: fit.textColor = .statusWarning
            case .unusable: fit.textColor = .statusBad
            }
            let argv = ToolCommand(tool: tool, options: options, server: server).restore(into: database,
                                                                                       continueOnError: goOn.state == .on,
                                                                                       optionFile: "/private")
            let source = file.map { ToolCommand.shellWord($0.path) } ?? "‹file›"
            let compressed = file?.pathExtension == "gz"
            command?.string = (compressed ? "/usr/bin/gzip -dc " + source + " | " : "")
                + ToolCommand.display(argv, optionFile: "/private") + (compressed ? "" : " < " + source)
        } else {
            fit.stringValue = tools.isEmpty ? "No mysql or mariadb found on this Mac: AirSQL runs the statements itself."
                : "AirSQL runs the statements itself, one at a time, through this connection."
            fit.textColor = .secondaryLabelColor
            command?.string = "AirSQL splits the file into statements and runs each in “\(database)”."
        }
        updateRunButton()
    }

    override func updateRunButton() {
        guard !running else { return }
        var reason: String?
        if databaseMenu.numberOfItems == 0 {
            reason = "AirSQL couldn't read the databases yet"
        } else if file == nil {
            reason = "Choose the file to run first"
        } else if let tool {
            if case .unusable(let why) = ClientTools.fit(tool, server: server) { reason = why }
            if let problem = ToolCommand(tool: tool, options: options, server: server).tlsProblem { reason = problem }
        }
        runButton.isEnabled = reason == nil
        runButton.toolTip = reason ?? "Run the file's statements in “\(database)”"
    }

    @objc private func chooseFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .sql or .sql.gz file."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.use(url)
        }
    }

    /// Takes `url` as the file to run (its size read off the main thread).
    func use(_ url: URL) {
        file = url
        fileLabel.stringValue = SettingsPaneController.shown(url)
        fileLabel.toolTip = url.path
        fileLabel.textColor = .labelColor
        Task {
            let size = await Task.detached { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }.value
            fileSize = size
            fileInfo.stringValue = Self.bytes(size) + (url.pathExtension == "gz" ? ", gzip-compressed" : "")
        }
        formChanged(nil)
    }

    @objc private func copyCommand(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command?.string ?? "", forType: .string)
    }

    // MARK: Running

    override func run() {
        guard let file, let window else { return }
        let database = self.database, options = self.options
        let cancellation = begin("Checking \(file.lastPathComponent)")
        let updates = Throttle()
        Task {
            let scan: DumpScan
            do {
                // The file's own USE, CREATE DATABASE, DROP DATABASE and GTID_PURGED, before anything runs.
                scan = try await DumpScan.scan(file, cancellation: cancellation) { read, size in
                    updates.send {
                        self.progress("Checking \(file.lastPathComponent) for the databases it writes to", done: read, total: size)
                    }
                }
                updates.cancel()
            } catch {
                updates.cancel()
                finish(cancellation.isCancelled ? "Stopped: nothing has run." : "Can't read the file: " + error.localizedDescription,
                       failed: true)
                return
            }
            let target = scan.target(picked: database)
            let tables = await Self.tableCount(target, options: options)
            idle()
            var warnings = scan.warnings(picked: database)
            if tables > 0 {
                warnings.append("“\(target)” has \(ObjectPicker.count(tables, "table")) already: the file's tables replace those "
                    + "of the same name, and its rows are added to the others.")
            }
            let safety = model.data.safety(for: connection)
            guard connection.colour == .production || (safety.askBeforeRiskyRestore && !warnings.isEmpty) else {
                start(file, database: database)
                return
            }
            let notable = scan.findings.map { finding -> String in
                switch finding.kind {
                case .use: return "USE " + SQLQuote.identifier(finding.database ?? "")
                case .createDatabase: return "CREATE DATABASE " + SQLQuote.identifier(finding.database ?? "")
                case .dropDatabase: return "DROP DATABASE " + SQLQuote.identifier(finding.database ?? "")
                case .gtidPurged: return "SET @@GLOBAL.GTID_PURGED = …"
                }
            }
            var request = SQLPreviewRequest(change: ChangeSQL(title: "Restore \(file.lastPathComponent)",
                                                              statements: notable.isEmpty ? ["USE " + SQLQuote.identifier(target)] : notable,
                                                              connection: connection.id),
                                            heading: "Run \(file.lastPathComponent) in \(target)?",
                                            caption: "\(Self.bytes(fileSize)) of SQL runs on \(connection.displayName) with "
                                                + (tool?.title ?? "AirSQL") + (goOn.state == .on ? ", going on past errors." : ", stopping at the first error.")
                                                + (notable.isEmpty ? "" : " These are the file's statements that choose where it writes."))
            request.actionTitle = builtInFirst ? "Run" : "Restore"
            request.warnings = warnings
            request.destructive = !warnings.isEmpty
            SQLPreviewSheet.show(request, connection: connection, on: window) { result in
                if result.approved { self.start(file, database: database) } else { self.updateRunButton() }
            }
        }
    }

    /// How many tables `database` has (0 when it can't tell).
    static func tableCount(_ database: String, options: ConnectOptions) async -> Int {
        let session = DBConnection(options: options, role: .tools)
        defer { Task { await session.close() } }
        guard (try? await session.connect()) != nil else { return 0 }
        let sql = "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = "
            + SQLQuote.string(database, noBackslashEscapes: session.noBackslashEscapes)
        let rows = try? await session.query(sql).first?.rows
        return Int(rows?.string(0, 0) ?? "") ?? 0
    }

    private func start(_ file: URL, database: String) {
        let command = tool.map { ToolCommand(tool: $0, options: options, server: server) }, options = self.options
        let continueOnError = goOn.state == .on
        let cancellation = begin("Running \(file.lastPathComponent) in \(database)")
        let updates = Throttle()
        let report = { (state: ToolProgress) in
            updates.send {
                let errors = state.errors == 0 ? "" : " · " + ObjectPicker.count(state.errors, "error")
                self.progress("Read " + Self.bytes(state.bytes) + " of " + Self.bytes(state.total ?? 0) + errors,
                              done: state.bytes, total: state.total)
            }
        }
        Task {
            do {
                let outcome: ToolOutcome
                if let command {
                    outcome = try await ToolRun.restore(command, file: file, into: database, continueOnError: continueOnError,
                                                        cancellation: cancellation, progress: report)
                } else {
                    let session = DBConnection(options: options, role: .tools)
                    defer { Task { await session.close() } }
                    _ = try await session.connect()
                    outcome = try await SQLScript.run(file, in: database, on: session, continueOnError: continueOnError,
                                                      cancellation: cancellation, progress: report)
                }
                updates.cancel()
                let errors = outcome.errors == 0 ? "" : " \(ObjectPicker.count(outcome.errors, "statement")) failed; the last: "
                    + (outcome.lastError ?? "")
                finish("Ran \(file.lastPathComponent) in \(database).\(errors)", failed: outcome.errors > 0)
            } catch {
                updates.cancel()
                finish(cancellation.isCancelled ? "Stopped. What ran before stays." : error.localizedDescription, failed: true)
            }
        }
    }
}
