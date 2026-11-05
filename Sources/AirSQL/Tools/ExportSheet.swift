import AirSQLCore
import AppKit

/// Export… (plan §2.9, mockups screen 7): the databases and tables to dump, the content and options, the dump tool
/// (mysqldump or mariadb-dump, or AirSQL's built-in export when there is none), where it goes (a file, a folder of a
/// file per object, in SQL or a data format, or the clipboard) and extra options; the exact command line; progress by
/// bytes, Cancel.
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
    private let dataMode = popup(DumpRequest.DataMode.allCases.map(\.title), selected: 0, id: "export.dataMode",
                                 tip: "Choose how the rows are written: REPLACE and INSERT IGNORE for rows that may be there already", target: nil, action: nil)
    private let createDatabase = checkbox("Add CREATE DATABASE and USE", id: "export.createDatabase",
                                          tip: "Make the file restore into a database of this name, not the one you choose then", on: false,
                                          target: nil, action: nil)
    private let dropDatabase = checkbox("Add DROP DATABASE first", id: "export.dropDatabase",
                                        tip: "Make the file delete the whole database of this name when it is restored", on: false,
                                        target: nil, action: nil)
    private let removeDefiner = checkbox("Remove DEFINER", id: "export.removeDefiner",
                                         tip: "Leave out who defined views, routines, triggers and events: the account that restores them is used",
                                         on: false, target: nil, action: nil)
    private let removeAutoIncrement = checkbox("Remove AUTO_INCREMENT values", id: "export.removeAutoIncrement",
                                               tip: "Leave out each table's next AUTO_INCREMENT value", on: false, target: nil, action: nil)
    private let wrapInTransactions = checkbox("A transaction per table", id: "export.wrapInTransactions",
                                              tip: "Put each table's rows between START TRANSACTION and COMMIT, which restores InnoDB tables faster",
                                              on: false, target: nil, action: nil)
    private let insertSize = AirSQL.textField("1024", placeholder: "1024", id: "export.insertSize",
                                              tip: "Type the largest size of one INSERT, in KB", width: 70)
    private let output = popup(["One file", "A folder, a file per object", "The clipboard"], selected: 0, id: "export.output",
                               tip: "Choose where the export goes", target: nil, action: nil)
    private let fileFormat = popup(["SQL"] + ExportSheet.dataFormats.map { $0?.title ?? "Excel (.xlsx)" }, selected: 0, id: "export.fileFormat",
                                   tip: "Choose the format of each file: SQL, or a table's rows as data", target: nil, action: nil)
    /// The formats a folder of tables can be in besides SQL: Excel last.
    private static let dataFormats: [CopyFormat?] = [.csv, .tsv, .json, .jsonLines, nil]
    private let toolMenu = popup([], selected: 0, id: "export.tool", tip: "Choose the program that writes the dump",
                                 target: nil, action: nil)
    private let chooseTool = button("Choose…", id: "export.chooseTool", tip: "Choose a mysqldump or mariadb-dump program anywhere on this Mac",
                                    target: nil, action: nil)
    private let fit = label("", font: .systemFont(ofSize: 11.5), wraps: true)
    private let saveTo = label("", font: .systemFont(ofSize: 12.5), truncates: true)
    private let choose = button("Choose…", id: "export.choose", tip: "Choose the file to save the dump in", target: nil, action: nil)
    private let extra = AirSQL.textField("", placeholder: "Optional, for example --skip-triggers", id: "export.extra",
                                  tip: "Add your own options for the dump tool, as you would type them in Terminal")
    private lazy var copyButton = button("Copy Command", id: "export.copyCommand", tip: "Copy the command line (it holds no password)",
                                         target: self, action: #selector(copyCommand(_:)))
    private let reveal = button("Show in Finder", id: "export.reveal", tip: "Show the exported file in Finder", target: nil, action: nil)
    private var exported: URL?
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
        for control in [content, snapshot, hexBlob, gzip, dropTable, objects, toolMenu, unchecked, dataMode, createDatabase, dropDatabase,
                        removeDefiner, removeAutoIncrement, wrapInTransactions, output, fileFormat] as [NSControl] {
            control.target = self
            control.action = #selector(formChanged(_:))
        }
        choose.target = self
        choose.action = #selector(chooseFile(_:))
        reveal.target = self
        reveal.action = #selector(showInFinder(_:))
        reveal.isHidden = true
        chooseTool.target = self
        chooseTool.action = #selector(chooseProgram(_:))
        extra.delegate = self
        insertSize.delegate = self
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
        form.row("Rows as", [dataMode, label("at most", font: .systemFont(ofSize: 12.5)), insertSize, label("KB each", font: .systemFont(ofSize: 12.5))])
        let options = NSStackView(views: [snapshot, hexBlob, gzip, dropTable, objects, createDatabase, dropDatabase, removeDefiner,
                                          removeAutoIncrement, wrapInTransactions])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 4
        form.row("Options", [options]).yPlacement = .top
        form.row("Tool", [toolMenu, chooseTool])
        form.grid.addRow(with: [NSGridCell.emptyContentView, toolNote(fit)]).topPadding = -4
        fit.preferredMaxLayoutWidth = 420
        saveTo.stringValue = SettingsPaneController.shown(url)
        saveTo.toolTip = url.path
        saveTo.setAccessibilityIdentifier("export.saveTo")
        saveTo.lineBreakMode = .byTruncatingMiddle  // a path: its file name stays in sight
        saveTo.widthAnchor.constraint(equalToConstant: 300).isActive = true
        form.row("Output", [output, fileFormat])
        form.row("Save to", [saveTo, choose])
        form.row("Extra options", [extra])
        let grid = form.finish()
        grid.column(at: 1).width = 400
        // Below controls' compression resistance (750): at a tie pop-ups and buttons are squeezed to 20 pt.
        grid.setContentHuggingPriority(.init(749), for: .vertical)
        toolMenu.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        let columns = NSStackView(views: [picker.view(height: 400), grid])
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
        [copyButton, reveal]
    }

    /// What the form's controls say when nothing keeps them off.
    private lazy var ownTips: [NSControl: String] = Dictionary(uniqueKeysWithValues: formControls.map { ($0, $0.toolTip ?? "") })

    private var formControls: [NSControl] {
        [content, snapshot, hexBlob, gzip, dropTable, objects, toolMenu, chooseTool, choose, extra, dataMode, createDatabase, dropDatabase,
         removeDefiner, removeAutoIncrement, wrapInTransactions, insertSize, output, fileFormat]
    }

    override func setFormEnabled(_ enabled: Bool) {
        for control in formControls {
            control.isEnabled = enabled
            control.toolTip = enabled ? ownTips[control] : "It is running: wait for it, or Stop it"
        }
        picker.isEnabled = enabled
        if enabled { fitControls() }
    }

    /// Turns off what doesn't apply to the choices made, saying why.
    private func fitControls() {
        func off(_ controls: [NSControl], _ why: String?) {
            for control in controls where why != nil {
                control.isEnabled = false
                control.toolTip = why
            }
        }
        for control in formControls where control !== hexBlob {
            control.isEnabled = true
            control.toolTip = ownTips[control]
        }
        let included = picker.included, several = included.count > 1, onlySome = included.count == 1 && !included[0].all
        let structure = content.indexOfSelectedItem == 1, dataOnly = content.indexOfSelectedItem == 2
        off([dropTable, objects, createDatabase, dropDatabase, removeDefiner, removeAutoIncrement], dataOnly ? "Off with data only: no CREATE is written" : nil)
        off([dataMode, wrapInTransactions, insertSize], structure ? "Off with structure only: no rows are written" : nil)
        off([createDatabase], several ? "Several databases always say their names" : nil)
        off([dropDatabase], onlySome ? "Off with only some tables ticked: restoring would delete the others" : nil)
        off([dropDatabase], output.indexOfSelectedItem == 1 ? "Off for a folder: restoring each file would delete what the last one restored" : nil)
        off([gzip], output.indexOfSelectedItem == 2 ? "The clipboard holds plain text" : nil)
        off([choose], output.indexOfSelectedItem == 2 ? "The clipboard needs no file" : nil)
        off([fileFormat], output.indexOfSelectedItem == 1 ? nil : "Only a folder has other formats: one file is SQL")
        if dataFormat != nil || wantsExcel {
            let why = "Only SQL files have this option"
            off([content, dataMode, gzip, hexBlob, dropTable, objects, createDatabase, dropDatabase, removeDefiner, removeAutoIncrement,
                 wrapInTransactions, insertSize], why)
        }
    }

    /// The folder a folder export makes: the file's name without its extension.
    private var folder: URL {
        let name = url.lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent(String(name[..<(name.range(of: ".sql", options: .backwards)?.lowerBound ?? name.endIndex)]))
    }

    /// The data format of a folder's files, nil for SQL or Excel.
    private var dataFormat: CopyFormat? {
        let index = fileFormat.indexOfSelectedItem
        return output.indexOfSelectedItem == 1 && index > 0 ? Self.dataFormats[index - 1] : nil
    }

    private var wantsExcel: Bool { output.indexOfSelectedItem == 1 && fileFormat.indexOfSelectedItem == Self.dataFormats.count }

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
        fill(toolMenu, tools: tools, builtIn: Self.builtInTip)
        // Only a tool that can run now is picked for the person, the one kept for the connection first.
        let runnable = ToolCommand.runnable(tools, options: options, server: server)
        let picked = (runnable.first { $0.path == connection.dumpPath } ?? ClientTools.best(runnable, for: server))
            .flatMap { best in tools.firstIndex { $0 == best } }
        toolMenu.selectItem(at: picked ?? tools.count)
        loading(nil)
        formChanged(nil)
    }

    private static let builtInTip = "Export with AirSQL itself: no client tools needed"

    @objc private func chooseProgram(_ sender: Any?) {
        chooseProgram(.dump) { [weak self] in self?.use(tool: $0) }
    }

    /// Adds `tool` (Choose…'s) to the menu and uses it.
    func use(tool: ClientTool) {
        tools.removeAll { $0.path == tool.path }
        tools.insert(tool, at: 0)
        fill(toolMenu, tools: tools, builtIn: Self.builtInTip)
        toolMenu.selectItem(at: 0)
        formChanged(toolMenu)
    }

    // MARK: Changes

    private var tool: ClientTool? {
        let index = toolMenu.indexOfSelectedItem
        return index >= 0 && index < tools.count ? tools[index] : nil
    }

    override var uncheckedTip: String {
        "Run this export once without the check: the connection is encrypted but can't prove it's this server, so the dump and "
            + "the login could be exposed"
    }

    @objc private func formChanged(_ sender: Any?) {
        if sender as? NSPopUpButton === toolMenu { unchecked.state = .off }
        // The tool chosen is kept for the connection (its latest version: nothing else of it is touched).
        if sender as? NSPopUpButton === toolMenu, let tool, var latest = model.connection(connection.id), latest.dumpPath != tool.path {
            latest.dumpPath = tool.path
            model.save(latest)
        }
        let wantsGzip = gzip.state == .on, name = url.lastPathComponent
        if wantsGzip != name.hasSuffix(".gz") {
            let base = name.hasSuffix(".sql.gz") ? String(name.dropLast(3)) : name
            url = url.deletingLastPathComponent().appendingPathComponent(wantsGzip ? base + ".gz" : base)
        }
        let target = output.indexOfSelectedItem == 1 ? folder : url
        saveTo.stringValue = output.indexOfSelectedItem == 2 ? "The clipboard" : SettingsPaneController.shown(target)
        saveTo.toolTip = target.path
        if !running { fitControls() }
        hexBlob.isEnabled = !running && tool != nil && dataFormat == nil && !wantsExcel
        if !running, dataFormat == nil, !wantsExcel {
            hexBlob.toolTip = tool == nil ? "AirSQL's own export always writes binary columns as hex"
                : "Write binary columns as hex, so the file survives any editor or transfer"
        }
        if let tool {
            let fitness = ClientTools.fit(tool, server: server)
            let problem = toolCommand(tool, server: server).tlsProblem
            fit.stringValue = problem ?? fitness.message
            switch fitness {
            case .good: fit.textColor = .statusOK
            case .warning: fit.textColor = .statusWarning
            case .unusable: fit.textColor = .statusBad
            }
            if problem != nil { fit.textColor = .statusBad }
            useBuiltIn.isHidden = problem == nil && fitness.isUsable
            showUnchecked(toolCommand(tool, server: server), note: fit)
        } else {
            useBuiltIn.isHidden = true
            showUnchecked(nil, note: fit)
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
        let onlyBuiltIn = tool == nil ? nil : builtInOnly
        if let onlyBuiltIn {
            fit.stringValue = onlyBuiltIn + " is AirSQL's own export's: \(tool?.name ?? "this tool") can't."
            fit.textColor = .statusBad
            useBuiltIn.isHidden = false
        }
        copyButton.isHidden = tool == nil || request == nil || onlyBuiltIn != nil  // AirSQL's own export has no command to copy
        if let tool, let request, onlyBuiltIn == nil {
            let argv = toolCommand(tool, server: server).dump(request, optionFile: "/private")
            command?.string = ToolCommand.display(argv, optionFile: "/private")
                + (request.gzip ? " | /usr/bin/gzip -c" : "") + " > " + ToolCommand.shellWord(url.path)
        } else {
            command?.string = tool == nil || onlyBuiltIn != nil ? "AirSQL writes the SQL itself: CREATE statements, then INSERTs of every row."
                : "Tick the databases or tables to export."
        }
        updateRunButton()
    }

    /// What the choices made need AirSQL's own export for, in words, nil when a dump tool can do it.
    private var builtInOnly: String? {
        if output.indexOfSelectedItem == 1 { return "A folder of files" }
        if output.indexOfSelectedItem == 2 { return "The clipboard" }
        return makeRequest()?.builtInOnly
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
        request.dataMode = DumpRequest.DataMode.allCases[max(0, dataMode.indexOfSelectedItem)]
        if request.content == .structure { request.dataMode = .insert }
        request.createDatabase = createDatabase.state == .on && included.count == 1 && request.content != .data
        request.dropDatabase = dropDatabase.state == .on && request.tables.isEmpty && request.content != .data && output.indexOfSelectedItem != 1
        request.removeDefiner = removeDefiner.state == .on && request.content != .data
        request.removeAutoIncrement = removeAutoIncrement.state == .on && request.content != .data
        request.wrapInTransactions = wrapInTransactions.state == .on && request.content != .structure
        if request.content != .structure, insertSize.integerValue > 0 { request.insertSize = min(insertSize.integerValue, 1 << 20) << 10 }
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
        } else if tool != nil, let builtInOnly {
            reason = builtInOnly + " is AirSQL's own export's: choose AirSQL (built in) as the tool"
        } else if let tool {
            if case .unusable(let why) = ClientTools.fit(tool, server: server) { reason = why }
            if let problem = toolCommand(tool, server: server).tlsProblem { reason = problem }
        } else if !extraWords.isEmpty {
            reason = "Extra options are for mysqldump and mariadb-dump: AirSQL's own export takes none"
        }
        runButton.isEnabled = reason == nil
        runButton.toolTip = reason ?? (output.indexOfSelectedItem == 2 ? "Put the export on the clipboard" : "Write the dump to the file chosen in Save to")
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

    @objc private func showInFinder(_ sender: Any?) {
        if let exported { NSWorkspace.shared.activateFileViewerSelecting([exported]) }
    }

    // MARK: Running

    override func run() {
        // The gate (plan §2.8): an export writes a file on this Mac, with a program AirSQL runs.
        guard !AgentGuard.refuses("An export writes a file on this Mac: only the person at the Mac can start one. Leave the "
                                  + "sheet for them, or use run_queries with to_file.") else { return }
        guard let request = makeRequest() else { return }
        reveal.isHidden = true
        let folder = self.folder
        let url = self.url, options = self.options
        let tables = picker.databases.flatMap(\.tables).filter(\.included)
        let estimate = tables.reduce(Int64(0)) { $0 + $1.bytes }
        let what = request.databases.count == 1 ? request.databases[0] : "\(request.databases.count) databases"
        let cancellation = begin("Exporting \(what) from \(connection.displayName)")
        let updates = Throttle()
        let tool = self.tool, command = tool.map { toolCommand($0, server: server) }
        logUnchecked(command)
        let outputChoice = output.indexOfSelectedItem
        // Data files: the ticked tables, whichever database.
        let files = dataFormat != nil || wantsExcel ? (format: dataFormat, tables: picker.databases.flatMap { database in
            database.tables.filter { $0.included && !$0.isView }.map { (database: database.name, name: $0.name) }
        }) : nil
        Task {
            do {
                let outcome: ToolOutcome
                let builtInProgress = { (done: SQLExport.Progress, bytes: Int64) in
                    updates.send {
                        let rows = ObjectPicker.compact(done.rows) + (done.totalRows > 0 ? " of ≈" + ObjectPicker.compact(done.totalRows) : "")
                        self.progress("Writing \(done.table) · \(rows) rows · \(Self.bytes(bytes))", done: done.rows,
                                      total: done.totalRows > 0 ? done.totalRows : nil)
                    }
                }
                if outputChoice == 2 {
                    let text = try await ToolRun.exportText(request, options: options, cancellation: cancellation, progress: builtInProgress)
                    updates.cancel()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    finish("Copied \(what): \(Self.bytes(Int64(text.utf8.count))) of SQL on the clipboard.", failed: false)
                    return
                }
                if outputChoice == 1 {
                    let bytes: Int64
                    if let files {
                        bytes = try await TableFiles.export(files.tables, format: files.format, options: options, snapshot: request.singleTransaction,
                                                              to: folder, cancellation: cancellation) { name, rows in
                            updates.send { self.progress("Writing \(name) · \(ObjectPicker.compact(rows)) rows", done: rows, total: nil) }
                        }
                    } else {
                        bytes = try await ToolRun.exportFolder(request, options: options, to: folder, cancellation: cancellation, progress: builtInProgress).bytes
                    }
                    updates.cancel()
                    exported = folder
                    reveal.isHidden = false
                    finish("Exported \(what): \(Self.bytes(bytes)) in \(folder.lastPathComponent).", failed: false)
                    return
                }
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
                    outcome = try await ToolRun.export(request, options: options, to: url, cancellation: cancellation, progress: builtInProgress)
                }
                updates.cancel()
                exported = url
                reveal.isHidden = false
                finish("Exported \(what): \(Self.bytes(outcome.bytes)) of SQL in \(url.lastPathComponent).", failed: false)
            } catch {
                updates.cancel()
                finish(error.localizedDescription, failed: true)
            }
        }
    }
}

/// Tables as data files in a new folder, a file each, in `format` (nil: Excel): streamed through one session and, when
/// asked, one snapshot. A failed or cancelled run leaves no folder.
enum TableFiles {
    static func export(_ tables: [(database: String, name: String)], format: CopyFormat?, options: ConnectOptions, snapshot: Bool, to folder: URL,
                       cancellation: Cancellation, progress: @escaping (String, Int64) -> Void) async throws -> Int64 {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let session = DBConnection(options: options, role: .tools)
        let databases = Set(tables.map(\.database))
        do {
            _ = try await session.connect()
            _ = try await session.query("SET SESSION time_zone = '+00:00'")
            if snapshot {
                _ = try await session.query("SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ")
                _ = try await session.query("START TRANSACTION WITH CONSISTENT SNAPSHOT")
            }
            var copy = CopyOptions(headers: true)
            copy.noBackslashEscapes = session.noBackslashEscapes
            for table in tables {
                let name = SQLFolderSink.fileName(databases.count > 1 ? table.database + "." + table.name : table.name)
                var url = folder.appendingPathComponent(name + "." + (format?.fileExtension ?? "xlsx")), repeated = 1
                while FileManager.default.fileExists(atPath: url.path) {
                    repeated += 1
                    url = folder.appendingPathComponent(name + "_\(repeated)." + (format?.fileExtension ?? "xlsx"))
                }
                // Columns come from the first batch: an empty table's from a query of no rows.
                let sql = "SELECT * FROM " + SQLQuote.identifier(table.database, table.name)
                func start(_ store: ResultStore) throws -> ExportOutput {
                    try ExportOutput(url: url, format: format, columns: ResultSetSource(store).columns, database: table.database,
                                     table: table.name, options: copy)
                }
                var output: ExportOutput?, rows: Int64 = 0
                try await session.stream(sql, batchRows: 5_000) { store in
                    if cancellation.isCancelled { throw AirSQLError.cancelled }
                    guard store.rowCount > 0 else { return }
                    if output == nil { output = try start(store) }
                    try output?.write((0..<store.rowCount).map { row in (0..<store.columns.count).map { TableDataSource.text(store, row, $0) } })
                    rows += Int64(store.rowCount)
                    progress(table.name, rows)
                }
                if output == nil, let store = try await session.query(sql + " LIMIT 0").first?.rows { output = try start(store) }
                try output?.finish()
            }
            await session.close()
            return FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])?.allObjects.compactMap { $0 as? URL }
                .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } ?? 0
        } catch {
            await session.close()
            try? FileManager.default.removeItem(at: folder)
            throw cancellation.isCancelled ? AirSQLError.cancelled : error
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
