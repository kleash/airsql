import AirSQLCore
import AppKit

/// The target of Dump with mongodump… and Restore with mongorestore… (Tools menu; a MongoDB connection's, database's and
/// collection's menus in the sidebar): the tree's row while the tree has the focus, else the tab in front's collection,
/// else the window's connection. The tools are the person's own, found where mongosh is.
@MainActor
final class MongoDumpMenu: NSObject, NSMenuItemValidation {
    static let shared = MongoDumpMenu()
    static let downloadPage = URL(string: "https://www.mongodb.com/try/download/database-tools")!

    private var main: MainWindowController? {
        let windows = [NSApp.mainWindow, NSApp.keyWindow].compactMap { $0 } + NSApp.orderedWindows
        return windows.lazy.compactMap { $0.windowController as? MainWindowController }.first
    }

    /// The connection, and the database and collection the command starts on (empty: none).
    func target(in main: MainWindowController) -> MongoCollectionRef? {
        if let focus = main.window?.firstResponder as? NSView, focus.isDescendant(of: main.sidebar.view) { return main.sidebar.mongoAdminRef }
        if let ref = MongoTransferMenu.shared.target(in: main) { return ref }
        return main.activeConnection.flatMap { main.model.openMongo[$0.id] }.map { MongoCollectionRef(open: $0, database: "", collection: "", kind: .collection) }
    }

    /// Why the command can't run now, if it can't.
    func refusal(_ action: Selector?, in main: MainWindowController) -> String? {
        if main.window?.attachedSheet != nil { return "A sheet is open: answer it first" }
        guard let ref = target(in: main) else {
            if let saved = main.selectedConnections.first ?? main.activeConnection, saved.engine == .mongodb, main.model.openMongo[saved.id] == nil {
                return "Connect to \(saved.displayName) first: the tools go through its route with its login"
            }
            return "Select a MongoDB connection, database or collection first"
        }
        let name = ref.open.saved.displayName
        if ref.open.saved.mongoAWS { return MongoToolCommand.awsRefusal }
        if action == Commands.mongoRestore.action, main.model.connection(ref.open.saved.id)?.readOnly ?? ref.open.saved.readOnly {
            return "\(name) is read-only: turn that off in the connection's settings to write to it"
        }
        return nil
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let reason = main.map { refusal(item.action, in: $0) } ?? "Select a MongoDB connection, database or collection first"
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }

    @objc func dumpMongo(_ sender: Any?) { start(.dump) }
    @objc func restoreMongo(_ sender: Any?) { start(.restore) }

    private func start(_ tool: MongoToolCommand.Tool) {
        guard let main, let window = main.window, refusal(tool == .dump ? Commands.mongoDump.action : Commands.mongoRestore.action, in: main) == nil,
              let ref = target(in: main) else { return NSSound.beep() }
        // The gate (plan §2.8): a program AirSQL runs, writing a file or the server, with no gate in front of it.
        guard !AgentGuard.refuses("Only the person at the Mac can run \(tool.rawValue).") else { return }
        Task {
            guard let program = await Task.detached(operation: { MongoToolCommand.find(tool) }).value else {
                return Self.notInstalled(tool, on: window)
            }
            MongoDumpSheet(model: main.model, ref: ref, tool: tool, program: program).show(on: window)
        }
    }

    /// The tools aren't on this Mac: where to get them (AirSQL downloads nothing).
    private static func notInstalled(_ tool: MongoToolCommand.Tool, on window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "\(tool.rawValue) isn't installed"
        alert.informativeText = "AirSQL runs your own MongoDB Database Tools (mongodump and mongorestore) and found none on this Mac. "
            + "Download them from MongoDB's website (mongodb.com/try/download/database-tools) or install them with Homebrew "
            + "(brew install mongodb-database-tools), then try again."
        alert.addButton(withTitle: "OK").toolTip = "Close this message"
        alert.addButton(withTitle: "Open Download Page").toolTip = "Open MongoDB's download page for the Database Tools in your browser"
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { NSWorkspace.shared.open(downloadPage) }
        }
    }

    // MARK: The sidebar's menus

    private static func item(_ command: Command) -> NSMenuItem {
        let item = command.item()
        item.target = shared
        return item
    }

    /// One MongoDB connection's menu: Dump and Restore where SQL's Export… and Restore… are.
    static func replaceExportRestore(in menu: NSMenu, connections: [SavedConnection]) {
        guard connections.count == 1, connections[0].engine == .mongodb else { return }
        for (sql, mongo) in [(Commands.export, Commands.mongoDump), (Commands.restore, Commands.mongoRestore)] {
            guard let index = menu.items.firstIndex(where: { $0.action == sql.action }) else { continue }
            menu.removeItem(at: index)
            menu.insertItem(item(mongo), at: index)
        }
    }

    /// A database's menu in the tree gets Dump and Restore, a collection's Dump.
    static func addItems(to menu: NSMenu, for row: MongoTreeItem) {
        guard row.index == nil else { return }
        menu.addItem(.separator())
        menu.addItem(item(Commands.mongoDump))
        if row.collection == nil { menu.addItem(item(Commands.mongoRestore)) }
    }
}

/// Dump with mongodump… (a database, or one collection, to one .archive.gz) and Restore with mongorestore… (an archive
/// into the server, every database in it as named, or one of them under another name): the exact command, progress by
/// bytes, Stop. The connection's route and login: one server through its socket over a route; the password in a private
/// file for the run. A restore asks first, with the command, the server and what it writes.
@MainActor
final class MongoDumpSheet: ToolSheet, NSTextFieldDelegate {
    private let tool: MongoToolCommand.Tool
    private let program: String
    private let open: OpenMongoConnection
    private let databaseMenu: NSPopUpButton
    private let collectionField: NSTextField
    private let fileLabel = label("", font: .systemFont(ofSize: 12.5), truncates: true)
    private lazy var choose = button("Choose…", id: "mongoDump.choose",
                                     tip: tool == .dump ? "Choose the file to save the dump in" : "Choose the .archive.gz file to restore",
                                     target: self, action: #selector(chooseFile(_:)))
    private let fromField = AirSQL.textField("", placeholder: "The file's database", id: "mongoDump.from",
                                             tip: "Type the name of the database in the file that goes under the new name", width: 260)
    private let intoField = AirSQL.textField("", placeholder: "As named in the file", id: "mongoDump.into",
                                             tip: "Type a database to restore the file's database into; empty keeps every name in the file",
                                             width: 260)
    private let drop = checkbox("Drop each collection first (--drop)", id: "mongoDump.drop",
                                tip: "Delete each of the file's collections on the server, with its documents and indexes, before restoring it",
                                on: false, target: nil, action: nil)
    private let note = label("", font: .systemFont(ofSize: 11.5), wraps: true)
    private var command: NSTextView?
    private lazy var copyButton = button("Copy Command", id: "mongoDump.copyCommand", tip: "Copy the command line (it holds no password)",
                                         target: self, action: #selector(copyCommand(_:)))
    /// The route's socket for the server (nil for Direct), once found; or why it couldn't be.
    private var socket: String?
    private var routeReady: Bool
    private var routeProblem: String?
    /// The dump's file (until one is chosen, in Downloads after the database), or the archive to restore.
    private var file: URL?
    private var fileChosen = false
    private var fileSize: Int64 = 0

    init(model: AppModel, ref: MongoCollectionRef, tool: MongoToolCommand.Tool, program: String) {
        self.tool = tool
        self.program = program
        open = ref.open
        // The login as connected: the user typed at its prompt, the certificate trusted then.
        var saved = model.connection(ref.open.saved.id) ?? ref.open.saved
        saved.user = ref.open.connection.user ?? saved.user
        saved.tls = ref.open.connection.tls
        routeReady = saved.route == .direct
        var names = ref.open.databases?.map(\.name) ?? []
        if !ref.database.isEmpty, !names.contains(ref.database) { names.insert(ref.database, at: 0) }
        databaseMenu = popup(names, selected: max(names.firstIndex(of: ref.database) ?? 0, 0), id: "mongoDump.database",
                             tip: "Choose the database to dump", target: nil, action: nil)
        collectionField = AirSQL.textField(ref.collection, placeholder: "Every collection of the database", id: "mongoDump.collection",
                                           tip: "Type one collection to dump, or leave it empty for the whole database", width: 260)
        // ToolSheet's options are MySQL's client tools': these tools take the connection from `connection` instead.
        super.init(model: model, connection: saved, options: saved.connectOptions(password: "", routeSocket: nil), width: 620,
                   action: tool == .dump ? "Dump" : "Restore…",
                   actionTip: tool == .dump ? "Write the dump to the file chosen in Save to" : "Show what the restore writes, then run it")
        heading.stringValue = tool == .dump ? "Dump from \(saved.displayName) with mongodump" : "Restore into \(saved.displayName) with mongorestore"
        for control in [databaseMenu, drop, unchecked] as [NSControl] {
            control.target = self
            control.action = #selector(formChanged(_:))
        }
        for field in [collectionField, fromField, intoField] { field.delegate = self }
        fileLabel.lineBreakMode = .byTruncatingMiddle  // a path: its file name stays in sight
        fileLabel.setAccessibilityIdentifier("mongoDump.file")
        note.preferredMaxLayoutWidth = 440
        drop.contentTintColor = .statusBad  // destructive: ticked, it shows red
        if tool == .dump { file = defaultFile }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var writes: Bool { tool == .restore }

    override var uncheckedTip: String {
        "Run this once with --tlsInsecure: the connection stays encrypted, but \(tool.rawValue) can't prove which server it reaches"
    }

    // MARK: Form

    override func makeForm() -> NSView {
        let form = Form()
        if tool == .dump {
            form.row("Database", [databaseMenu])
            form.row("Collection", [collectionField])
            form.row("Save to", [fileLabel, choose])
        } else {
            form.row("File", [fileLabel, choose])
            form.row("Into database", [intoField])
            form.row("From database", [fromField], caption: "With a database typed above, only this one of the file's databases is restored, under that name.")
            form.row("Options", [drop])
            form.grid.addRow(with: [NSGridCell.emptyContentView, caption(
                "Without --drop only documents with new _ids are inserted: those whose _id is there already are skipped, not "
                + "replaced. A restore that stops or fails stays partly applied.", width: 440)]).topPadding = -4
        }
        form.row("Tool", [toolNote(note)]).yPlacement = .top
        let grid = form.finish()
        grid.column(at: 1).width = 450
        databaseMenu.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        fileLabel.widthAnchor.constraint(equalToConstant: 340).isActive = true
        return grid
    }

    override func makeCodeBox() -> NSView? {
        let (box, text) = codeBox(id: "mongoDump.command", tip: "The command AirSQL runs: no password in it, the password is in a "
                                  + "private file only you can read, removed when it ends")
        command = text
        return box
    }

    override func extraButtons() -> [NSButton] { [copyButton] }

    override func setFormEnabled(_ enabled: Bool) {
        for control in [databaseMenu, collectionField, choose, fromField, intoField, drop] as [NSControl] { control.isEnabled = enabled }
        if enabled { formChanged(nil) }
    }

    /// Finds the route's socket for the server (it may open its forward), off the main thread.
    override func load() {
        showFile()
        guard !routeReady else { return formChanged(nil) }
        loading("Opening the route to \(connection.displayName)…")
        let (route, saved, primary) = (open.connection.route, connection, open.server.primary)
        Task {
            do {
                socket = try await Task.detached { try MongoShell.socket(route, saved: saved, primary: primary) }.value
            } catch {
                routeProblem = "Couldn't reach the server through the route: " + error.localizedDescription
            }
            routeReady = true
            loading(nil)
            formChanged(nil)
        }
    }

    // MARK: The command

    private var database: String { databaseMenu.titleOfSelectedItem ?? "" }
    private var collection: String { collectionField.stringValue.trimmingCharacters(in: .whitespaces) }
    private var into: String { intoField.stringValue.trimmingCharacters(in: .whitespaces) }
    private var from: String { fromField.stringValue.trimmingCharacters(in: .whitespaces) }
    private var password: String? { connection.mongoX509 ? nil : open.connection.password }

    private var toolCommand: MongoToolCommand {
        let scope = tool == .dump ? MongoToolCommand.dumpScope(database: database, collection: collection.isEmpty ? nil : collection)
            : MongoToolCommand.restoreScope(rename: into.isEmpty ? nil : (from, into), drop: drop.state == .on,
                                            gzip: file?.pathExtension == "gz")
        var command = MongoToolCommand(program: program, saved: connection, socket: socket, scope: scope)
        command.unchecked = unchecked.state == .on
        return command
    }

    /// "shop.orders-2026-11-11-1407.archive.gz" in Downloads.
    private var defaultFile: URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let name = (database.isEmpty ? connection.displayName : database) + (collection.isEmpty ? "" : "." + collection)
        return folder.appendingPathComponent(String(ExportSheet.fileName(name, gzip: false).dropLast(".sql".count)) + ".archive.gz")
    }

    private func showFile() {
        fileLabel.stringValue = file.map(SettingsPaneController.shown) ?? "No file chosen"
        fileLabel.toolTip = file?.path
        fileLabel.textColor = file == nil ? .secondaryLabelColor : .labelColor
    }

    func controlTextDidChange(_ notification: Notification) { formChanged(nil) }

    @objc private func formChanged(_ sender: Any?) {
        guard !running else { return }
        if tool == .dump, !fileChosen {
            file = defaultFile
            showFile()
        }
        fromField.isEnabled = !into.isEmpty
        let command = toolCommand
        unchecked.isHidden = command.tlsProblem == nil
        note.stringValue = command.tlsProblem.map { $0 + " Tick the box to run it once with --tlsInsecure." } ?? program
        note.textColor = command.tlsProblem == nil ? .secondaryLabelColor : unchecked.state == .on ? .statusWarning : .statusBad
        if unchecked.state == .on {
            note.stringValue = "This run won't check the server's certificate: it is encrypted, but \(tool.rawValue) can't prove which server it reaches."
        }
        let path = file.map { ToolCommand.shellWord($0.path) } ?? "‹file›"
        self.command?.string = command.display(password: password != nil) + (tool == .dump ? " > " : " < ") + path
        updateRunButton()
    }

    override func updateRunButton() {
        guard !running else { return }
        var reason: String?
        let command = toolCommand
        if !routeReady {
            reason = "AirSQL is opening the route to the server"
        } else if let routeProblem {
            reason = routeProblem
        } else if tool == .dump, database.isEmpty {
            reason = "Choose a database first"
        } else if tool == .restore, connection.readOnly {
            reason = "\(connection.displayName) is read-only: turn that off in the connection's settings to write to it"
        } else if file == nil {
            reason = "Choose the file to restore first"
        } else if tool == .restore, !into.isEmpty, from.isEmpty {
            reason = "Type the database of the file to restore under the new name"
        } else if let problem = command.tlsProblem, !command.unchecked {
            reason = problem
        }
        runButton.isEnabled = reason == nil
        runButton.toolTip = reason ?? (tool == .dump ? "Write the dump to the file chosen in Save to" : "Show what the restore writes, then run it")
    }

    @objc private func chooseFile(_ sender: Any?) {
        guard let window else { return }
        let panel: NSSavePanel
        if tool == .dump {
            panel = NSSavePanel()
            panel.nameFieldStringValue = file?.lastPathComponent ?? ""
            panel.directoryURL = file?.deletingLastPathComponent()
            panel.message = "Choose where to save the dump."
        } else {
            let openPanel = NSOpenPanel()
            openPanel.canChooseDirectories = false
            openPanel.allowsMultipleSelection = false
            openPanel.message = "Choose an archive mongodump wrote (.archive.gz or .archive)."
            panel = openPanel
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.use(url)
        }
    }

    /// Takes `url` as the dump's file, or the archive to restore (its size read off the main thread, for the progress;
    /// its database guessed from its name).
    func use(_ url: URL) {
        file = url
        fileChosen = true
        showFile()
        if tool == .restore {
            fromField.stringValue = MongoToolCommand.database(inFileName: url.lastPathComponent)
            Task { fileSize = await Task.detached { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }.value }
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
        guard !AgentGuard.refuses("Only the person at the Mac can run \(tool.rawValue).") else { return }
        guard tool == .restore else { return start(file) }
        let server = connection.displayName + " (" + ([MongoURI.join(connection.host, connection.port)] + connection.mongoHosts).joined(separator: ", ") + ")"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restore \(file.lastPathComponent) into \(connection.displayName)?"
        alert.informativeText = "mongorestore writes " + (into.isEmpty ? "every database in the file" : "“\(from)” of the file into “\(into)”")
            + " on \(server)"
            + (drop.state == .on ? ", dropping each of those collections first with its documents and indexes."
               : ". Documents whose _id is there already are skipped.")
            + (unchecked.state == .on ? " The server's certificate isn't checked on this run." : "")
            + "\n\n" + (command?.string ?? "")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.toolTip = "Don't restore: nothing is written"
        cancel.keyEquivalent = "\r"  // the safe answer is the default
        let restore = alert.addButton(withTitle: drop.state == .on ? "Drop and Restore" : "Restore")
        restore.hasDestructiveAction = drop.state == .on
        restore.toolTip = "Run mongorestore with this command now"
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { self.start(file) }
        }
    }

    private func start(_ file: URL) {
        let command = toolCommand, password = self.password, size = fileSize
        if command.unchecked, command.tlsProblem != nil {
            let (text, context) = ("\(tool.rawValue) run without checking the server's certificate (--tlsInsecure)", connection.displayName + " tools")
            DispatchQueue.global(qos: .utility).async { SQLLog.shared.note(text, context: context) }
        }
        let cancellation = begin(tool == .dump ? "Dumping \(database) from \(connection.displayName)"
                                 : "Restoring \(file.lastPathComponent) into \(connection.displayName)")
        let updates = Throttle()
        Task {
            do {
                if tool == .dump {
                    let bytes = try await command.dump(password: password, to: file, cancellation: cancellation) { bytes in
                        updates.send { self.progress("Writing · " + Self.bytes(bytes), done: bytes, total: nil) }
                    }
                    updates.cancel()
                    finish("Dumped \(database): \(Self.bytes(bytes)) in \(file.lastPathComponent).", failed: false)
                } else {
                    let said = try await command.restore(password: password, from: file, cancellation: cancellation) { read in
                        updates.send { self.progress("Read \(Self.bytes(read)) of \(Self.bytes(size))", done: read, total: size) }
                    }
                    updates.cancel()
                    finish("Restored \(file.lastPathComponent)" + (said.map { ": " + $0 } ?? "."), failed: false)
                }
            } catch {
                updates.cancel()
                let stopped = tool == .dump ? "Stopped: no file was written." : "Stopped. What was restored before stays."
                finish(cancellation.isCancelled ? stopped : error.localizedDescription, failed: true)
            }
        }
    }
}
