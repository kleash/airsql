import AirSQLCore
import AppKit

/// Export… (plan §2.9, mockups screen 7): the databases and tables to dump, the content and options, the dump tool
/// (mysqldump or mariadb-dump, or AirSQL's built-in export when there is none), where to save it and extra options;
/// the exact command line; progress by bytes, Cancel.
@MainActor
final class ExportSheet: ToolSheet, NSTextFieldDelegate {
    private let picker = ObjectPicker()
    private let content = popup(DumpRequest.Content.allCases.map(\.title), selected: 0, id: "export.content",
                                tip: "Choose what to export: the tables' structure, their rows, or both", target: nil, action: nil)
    private let snapshot = checkbox("One consistent snapshot (--single-transaction)", id: "export.singleTransaction",
                                    tip: "Read every table as of one moment, without locking them (InnoDB)", on: true, target: nil, action: nil)
    private let hexBlob = checkbox("Binary as hex (--hex-blob)", id: "export.hexBlob",
                                   tip: "Write binary columns as hex, so the file survives any editor or transfer", on: true,
                                   target: nil, action: nil)
    private let gzip = checkbox("Compress with gzip", id: "export.gzip", tip: "Make a smaller .sql.gz file (Restore reads it as is)",
                                on: false, target: nil, action: nil)
    private let dropTable = checkbox("Add DROP TABLE before each table", id: "export.dropTable",
                                     tip: "Make the file replace tables of the same name when it is restored", on: false,
                                     target: nil, action: nil)
    private let objects = checkbox("Views, routines, triggers and events", id: "export.objects",
                                   tip: "Export the databases' views, procedures, functions, triggers and events too", on: true,
                                   target: nil, action: nil)
    private let toolMenu = popup([], selected: 0, id: "export.tool", tip: "Choose the program that writes the dump",
                                 target: nil, action: nil)
    private let fit = label("", font: .systemFont(ofSize: 11.5), wraps: true)
    private let saveTo = label("", font: .systemFont(ofSize: 12.5), truncates: true)
    private let choose = button("Choose…", id: "export.choose", tip: "Choose the file to save the dump in", target: nil, action: nil)
    private let extra = AirSQL.textField("", placeholder: "Optional, for example --skip-triggers", id: "export.extra",
                                  tip: "Add your own options for the dump tool, as you would type them in Terminal")
    private var command: NSTextView?
    private var server: ServerInfo?
    private var tools: [ClientTool] = []
    private var url: URL
    private var extraWords: [String] = []
    private var extraError: String?

    init(model: AppModel, connection: SavedConnection, options: ConnectOptions) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        url = folder.appendingPathComponent(Self.fileName(connection.database.isEmpty ? connection.displayName : connection.database,
                                                          gzip: false))
        super.init(model: model, connection: connection, options: options, width: 840, action: "Export",
                   actionTip: "Write the dump to the file chosen in Save to")
        heading.stringValue = "Export from \(connection.displayName)"
        for control in [content, snapshot, hexBlob, gzip, dropTable, objects, toolMenu] as [NSControl] {
            control.target = self
            control.action = #selector(formChanged(_:))
        }
        choose.target = self
        choose.action = #selector(chooseFile(_:))
        extra.delegate = self
        picker.onChange = { [weak self] in self?.formChanged(nil) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// "shop-2026-11-03-1412.sql".
    static func fileName(_ name: String, gzip: Bool, at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let safe = String(name.map { "/:\\".contains($0) ? "-" : $0 })
        return safe + "-" + formatter.string(from: date) + (gzip ? ".sql.gz" : ".sql")
    }

    // MARK: Form

    override func makeForm() -> NSView {
        let form = Form()
        form.row("Content", [content])
        let options = NSStackView(views: [snapshot, hexBlob, gzip, dropTable, objects])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 4
        form.row("Options", [options]).yPlacement = .top
        form.row("Tool", [toolMenu])
        form.grid.addRow(with: [NSGridCell.emptyContentView, fit]).topPadding = -4
        fit.preferredMaxLayoutWidth = 420
        saveTo.stringValue = SettingsPaneController.shown(url)
        saveTo.toolTip = url.path
        saveTo.setAccessibilityIdentifier("export.saveTo")
        saveTo.lineBreakMode = .byTruncatingMiddle  // a path: its file name stays in sight
        saveTo.widthAnchor.constraint(equalToConstant: 300).isActive = true
        form.row("Save to", [saveTo, choose])
        form.row("Extra options", [extra])
        let grid = form.finish()
        grid.column(at: 1).width = 400
        grid.setContentHuggingPriority(.defaultHigh, for: .vertical)
        toolMenu.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        let columns = NSStackView(views: [picker.view(height: 250), grid])
        columns.alignment = .top
        columns.spacing = 14
        columns.arrangedSubviews[0].widthAnchor.constraint(equalToConstant: 260).isActive = true
        extra.widthAnchor.constraint(equalToConstant: 400).isActive = true
        return columns
    }

    override func makeCodeBox() -> NSView? {
        let (box, text) = codeBox(id: "export.command", tip: "The command AirSQL runs: no password in it, the login is in a private "
                                  + "file only you can read")
        command = text
        return box
    }

    override func extraButtons() -> [NSButton] {
        [button("Copy Command", id: "export.copyCommand", tip: "Copy the command line (it holds no password)", target: self,
                action: #selector(copyCommand(_:)))]
    }

    override func setFormEnabled(_ enabled: Bool) {
        let why = enabled ? nil : "It is running: wait for it, or Stop it"
        for control in [content, snapshot, hexBlob, gzip, dropTable, objects, toolMenu, choose, extra] as [NSControl] {
            control.isEnabled = enabled
            if let why { control.toolTip = why }
        }
        picker.isEnabled = enabled
        if enabled { restoreTips() }
    }

    private func restoreTips() {
        content.toolTip = "Choose what to export: the tables' structure, their rows, or both"
        snapshot.toolTip = "Read every table as of one moment, without locking them (InnoDB)"
        hexBlob.toolTip = "Write binary columns as hex, so the file survives any editor or transfer"
        gzip.toolTip = "Make a smaller .sql.gz file (Restore reads it as is)"
        dropTable.toolTip = "Make the file replace tables of the same name when it is restored"
        objects.toolTip = "Export the databases' views, procedures, functions, triggers and events too"
        toolMenu.toolTip = "Choose the program that writes the dump"
        choose.toolTip = "Choose the file to save the dump in"
        extra.toolTip = "Add your own options for the dump tool, as you would type them in Terminal"
    }

    // MARK: Loading

    override func load() {
        loading("Reading the databases of \(connection.displayName)…")
        let options = self.options, chosen = connection.dumpPath.isEmpty ? model.data.settings.dumpPath : connection.dumpPath
        Task {
            do {
                let session = DBConnection(options: options, role: .tools)
                let server = try await session.connect()
                let names = try await session.rows(PickerNode.databasesSQL).compactMap { $0[0] }
                let tables = try await session.rows(PickerNode.listSQL)
                await session.close()
                let tools = await ClientTools.find(.dump, chosen: chosen)
                let databases = PickerNode.databases(names, tables: tables)
                show(server: server, tools: tools, databases: databases)
            } catch {
                loading(nil)
                status.textColor = .statusBad
                status.stringValue = "Can't read the databases: " + error.localizedDescription
                updateRunButton()
            }
        }
    }

    /// Fills the form once the server, its databases and the tools are known.
    func show(server: ServerInfo?, tools: [ClientTool], databases: [PickerNode]) {
        self.server = server
        self.tools = tools
        let current = connection.database.isEmpty ? (databases.count == 1 ? databases.first?.name : nil) : connection.database
        if let node = databases.first(where: { $0.name == current }) { picker.include(node, true) }
        picker.show(databases, expanding: current)
        toolMenu.removeAllItems()
        for tool in tools {
            toolMenu.addItem(withTitle: tool.title)
            toolMenu.lastItem?.toolTip = tool.path
        }
        toolMenu.addItem(withTitle: "AirSQL (built in)")
        toolMenu.lastItem?.toolTip = "Export with AirSQL itself: no client tools needed"
        let picked = tools.firstIndex { $0.path == connection.dumpPath }
            ?? ClientTools.best(tools, for: server).flatMap { best in tools.firstIndex { $0 == best } }
        toolMenu.selectItem(at: picked ?? tools.count)
        loading(nil)
        formChanged(nil)
    }

    // MARK: Changes

    private var tool: ClientTool? {
        let index = toolMenu.indexOfSelectedItem
        return index >= 0 && index < tools.count ? tools[index] : nil
    }

    @objc private func formChanged(_ sender: Any?) {
        // The tool chosen is kept for the connection (its latest version: nothing else of it is touched).
        if sender as? NSPopUpButton === toolMenu, let tool, var latest = model.connection(connection.id), latest.dumpPath != tool.path {
            latest.dumpPath = tool.path
            model.save(latest)
        }
        let wantsGzip = gzip.state == .on, name = url.lastPathComponent
        if wantsGzip != name.hasSuffix(".gz") {
            let base = name.hasSuffix(".sql.gz") ? String(name.dropLast(3)) : name
            url = url.deletingLastPathComponent().appendingPathComponent(wantsGzip ? base + ".gz" : base)
            saveTo.stringValue = SettingsPaneController.shown(url)
            saveTo.toolTip = url.path
        }
        dropTable.isEnabled = !running && content.indexOfSelectedItem != 2
        hexBlob.isEnabled = !running && tool != nil
        if !running {
            hexBlob.toolTip = tool == nil ? "AirSQL's own export always writes binary columns as hex"
                : "Write binary columns as hex, so the file survives any editor or transfer"
        }
        if let tool {
            let fitness = ClientTools.fit(tool, server: server)
            fit.stringValue = ToolCommand(tool: tool, options: options, server: server).tlsProblem ?? fitness.message
            switch fitness {
            case .good: fit.textColor = .statusOK
            case .warning: fit.textColor = .statusWarning
            case .unusable: fit.textColor = .statusBad
            }
        } else {
            fit.stringValue = tools.isEmpty ? "No mysqldump or mariadb-dump found on this Mac: AirSQL exports with its own code. "
                + "Install MySQL's or MariaDB's client tools to use theirs." : "AirSQL's own export, through this connection."
            fit.textColor = .secondaryLabelColor
        }
        let request = makeRequest()
        let what = request.map { $0.databases.count == 1 ? $0.databases[0] : "\($0.databases.count) databases" }
        heading.stringValue = what.map { "Export \($0) with " + (tool?.name ?? "AirSQL") } ?? "Export from \(connection.displayName)"
        if !running && status.textColor != .statusBad {
            let tables = picker.databases.flatMap(\.tables).filter(\.included)
            status.textColor = .secondaryLabelColor
            status.stringValue = tables.isEmpty ? "" : ObjectPicker.count(tables.count, "table") + " · about "
                + Self.bytes(tables.reduce(0) { $0 + $1.bytes }) + " of data on the server"
        }
        if let tool, let request {
            let argv = ToolCommand(tool: tool, options: options, server: server).dump(request, optionFile: "/private")
            command?.string = ToolCommand.display(argv, optionFile: "/private")
                + (request.gzip ? " | /usr/bin/gzip -c" : "") + " > " + ToolCommand.shellWord(url.path)
        } else {
            command?.string = tool == nil ? "AirSQL writes the SQL itself: CREATE statements, then INSERTs of every row."
                : "Tick the databases or tables to export."
        }
        updateRunButton()
    }

    func controlTextDidChange(_ notification: Notification) {
        do {
            extraWords = try ToolCommand.words(extra.stringValue)
            extraError = nil
        } catch {
            extraWords = []
            extraError = error.localizedDescription
        }
        formChanged(nil)
    }

    /// What the form asks for; nil while nothing is ticked.
    private func makeRequest() -> DumpRequest? {
        let included = picker.included
        guard !included.isEmpty else { return nil }
        var request = DumpRequest(databases: included.map(\.database))
        if included.count == 1, !included[0].all { request.tables = included[0].tables }
        request.content = DumpRequest.Content.allCases[max(0, content.indexOfSelectedItem)]
        request.singleTransaction = snapshot.state == .on
        request.hexBlob = hexBlob.state == .on
        request.gzip = gzip.state == .on
        request.addDropTable = dropTable.state == .on && request.content != .data
        request.objects = objects.state == .on
        request.extra = extraWords
        return request
    }

    override func updateRunButton() {
        guard !running else { return }
        var reason: String?
        let included = picker.included
        if picker.databases.isEmpty {
            reason = "AirSQL couldn't read the databases yet"
        } else if included.isEmpty {
            reason = "Tick the databases or tables to export"
        } else if included.count > 1 && included.contains(where: { !$0.all }) {
            reason = "Several databases are exported whole: tick all of each one's tables, or pick tables of one database"
        } else if let extraError {
            reason = extraError
        } else if let tool {
            if case .unusable(let why) = ClientTools.fit(tool, server: server) { reason = why }
            if let problem = ToolCommand(tool: tool, options: options, server: server).tlsProblem { reason = problem }
        } else if !extraWords.isEmpty {
            reason = "Extra options are for mysqldump and mariadb-dump: AirSQL's own export takes none"
        }
        runButton.isEnabled = reason == nil
        runButton.toolTip = reason ?? "Write the dump to the file chosen in Save to"
    }

    @objc private func chooseFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.directoryURL = url.deletingLastPathComponent()
        panel.message = "Choose where to save the dump."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let chosen = panel.url else { return }
            self.use(chosen)
        }
    }

    /// Saves to `chosen` (the save panel's choice).
    func use(_ chosen: URL) {
        url = chosen
        gzip.state = chosen.pathExtension == "gz" ? .on : .off
        saveTo.stringValue = SettingsPaneController.shown(chosen)
        saveTo.toolTip = chosen.path
        formChanged(nil)
    }

    @objc private func copyCommand(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command?.string ?? "", forType: .string)
    }

    // MARK: Running

    override func run() {
        // The gate (plan §2.8): an export writes a file on this Mac, with a program AirSQL runs.
        guard !AgentGuard.refuses("An export writes a file on this Mac: only the person at the Mac can start one. Leave the "
                                  + "sheet for them, or use run_queries with to_file.") else { return }
        guard let request = makeRequest() else { return }
        let url = self.url, options = self.options
        let tables = picker.databases.flatMap(\.tables).filter(\.included)
        let estimate = tables.reduce(Int64(0)) { $0 + $1.bytes }
        let what = request.databases.count == 1 ? request.databases[0] : "\(request.databases.count) databases"
        let cancellation = begin("Exporting \(what) from \(connection.displayName)")
        let updates = Throttle()
        let tool = self.tool, command = tool.map { ToolCommand(tool: $0, options: options, server: server) }
        Task {
            do {
                let outcome: ToolOutcome
                if let command {
                    outcome = try await ToolRun.dump(command, request, to: url, estimate: estimate > 0 ? estimate : nil,
                                                     cancellation: cancellation) { state in
                        updates.send {
                            let written = Self.bytes(state.bytes) + (estimate > 0 ? " of ≈" + Self.bytes(estimate) : "")
                            self.progress((state.table.map { "Writing \($0) · " } ?? "Writing · ") + written, done: state.bytes,
                                          total: estimate > 0 ? estimate : nil)
                        }
                    }
                } else {
                    outcome = try await ToolRun.export(request, options: options, to: url, cancellation: cancellation) { done, bytes in
                        updates.send {
                            let rows = ObjectPicker.compact(done.rows) + (done.totalRows > 0 ? " of ≈" + ObjectPicker.compact(done.totalRows) : "")
                            self.progress("Writing \(done.table) · \(rows) rows · \(Self.bytes(bytes))", done: done.rows,
                                          total: done.totalRows > 0 ? done.totalRows : nil)
                        }
                    }
                }
                updates.cancel()
                finish("Exported \(what): \(Self.bytes(outcome.bytes)) of SQL in \(url.lastPathComponent).", failed: false)
            } catch {
                updates.cancel()
                finish(error.localizedDescription, failed: true)
            }
        }
    }
}

/// Hands progress to the main thread at most ten times a second, the latest only.
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (@MainActor () -> Void)?
    private var scheduled = false
    private var stopped = false

    func send(_ update: @escaping @MainActor () -> Void) {
        lock.lock()
        latest = update
        let schedule = !scheduled && !stopped
        scheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
            lock.lock()
            scheduled = false
            let update = stopped ? nil : latest
            lock.unlock()
            MainActor.assumeIsolated { update?() }
        }
    }

    func cancel() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}
