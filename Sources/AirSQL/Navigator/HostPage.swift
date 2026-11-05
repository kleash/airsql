import AirSQLCore
import AppKit

/// The host page (scope "server"): what a server holds and does, shown when a connected connection is clicked: its
/// databases with their sizes, variables, status counters, processes and what kinds of statement it runs. Variables and
/// status are read on a session of its own. Nothing here writes but Edit Variable, which Read-only and Production refuse.
@MainActor
final class HostContent: NSViewController, TabContent, NSMenuItemValidation {
    enum Pane: Int, CaseIterable {
        case databases, variables, status, processes, commands

        var title: String { ["Databases", "Variables", "Status", "Processes", "Command Statistics"][rawValue] }
        var tip: String {
            ["List the server's databases with their sizes", "List the server's variables, session and global side by side",
             "List the server's status counters, with their rates since it started", "List what every connection is running",
             "Show how much of each kind of statement the server has run"][rawValue]
        }
    }

    let open: OpenConnection
    private(set) var pane: Pane
    private let heading = label("", font: .systemFont(ofSize: 15, weight: .semibold), truncates: true)
    let properties = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    private let spinner = NSProgressIndicator()
    private let holder = NSView()
    let tabs = NSSegmentedControl()
    private lazy var readSizes = button("Read Sizes", id: "host.readSizes", tip: "Read the sizes of the selected databases, or of all of them",
                                        target: self, action: #selector(refresh(_:)))
    private(set) lazy var stopSizes = button("Stop", id: "host.stopSizes", tip: "Stop reading sizes; what was read stays", target: self,
                                             action: #selector(stopReading(_:)))
    private lazy var diskUsage = button("Disk Usage", id: "host.diskUsage", tip: Commands.diskUsage.tip, target: nil,
                                        action: Commands.diskUsage.action)
    private(set) lazy var edit = button("Edit…", id: "host.editVariable", tip: Commands.editVariable.tip, target: self,
                                        action: #selector(editVariable(_:)))
    private(set) lazy var databases = HostList(
        name: "Databases",
        columns: [
            .init(id: "name", title: "Name", width: 170, tip: "The database"),
            .init(id: "bar", title: "Space", width: 120, tip: "Its data, indexes and free space, against the largest", bar: true),
            .init(id: "size", title: "Size", width: 72, numeric: true, tip: "Its data plus its indexes, once read"),
            .init(id: "tables", title: "Tables", width: 54, numeric: true, tip: "How many tables and sequences"),
            .init(id: "views", title: "Views", width: 54, numeric: true, tip: "How many views"),
            .init(id: "routines", title: "Routines", width: 60, numeric: true, tip: "How many procedures and functions"),
            .init(id: "triggers", title: "Triggers", width: 60, numeric: true, tip: "How many triggers"),
            .init(id: "events", title: "Events", width: 54, numeric: true, tip: "How many events"),
            .init(id: "updated", title: "Last Change", width: 130, tip: "When a table's rows last changed, where the engine keeps it"),
            .init(id: "collation", title: "Collation", width: 140, tip: "How its text compares and sorts by default"),
        ],
        sort: NSSortDescriptor(key: "name", ascending: true), accessories: [readSizes, stopSizes, diskUsage])
    private(set) lazy var variables = HostList(
        name: "Variables",
        columns: [
            .init(id: "name", title: "Name", width: 260, tip: "The variable"),
            .init(id: "session", title: "Session", width: 240, tip: "What a new session here starts with; each query tab has its own"),
            .init(id: "global", title: "Global", width: 240, tip: "The server's value, which new sessions take"),
            .init(id: "differs", title: "Differs", width: 60, tip: "Marks a session value that isn't the server's"),
        ],
        sort: NSSortDescriptor(key: "name", ascending: true), accessories: [edit])
    private(set) lazy var status = HostList(
        name: "Status",
        columns: [
            .init(id: "name", title: "Name", width: 300, tip: "The counter"),
            .init(id: "value", title: "Value", width: 180, numeric: true, tip: "What it stands at"),
            .init(id: "hour", title: "Per Hour", width: 110, numeric: true, tip: "Its average per hour since the server started"),
            .init(id: "second", title: "Per Second", width: 110, numeric: true, tip: "Its average per second since the server started"),
        ],
        sort: NSSortDescriptor(key: "name", ascending: true))
    private(set) lazy var commands = HostList(
        name: "Command Statistics",
        columns: [
            .init(id: "name", title: "Statement", width: 240, tip: "The kind of statement"),
            .init(id: "bar", title: "Share", width: 200, tip: "Its part of every statement counted", bar: true),
            .init(id: "count", title: "Count", width: 110, numeric: true, tip: "How many ran since the server started"),
            .init(id: "hour", title: "Per Hour", width: 100, numeric: true, tip: "Its average per hour"),
            .init(id: "second", title: "Per Second", width: 100, numeric: true, tip: "Its average per second"),
            .init(id: "percent", title: "%", width: 70, numeric: true, tip: "Its part of every statement counted"),
        ],
        sort: NSSortDescriptor(key: "count", ascending: false))
    private(set) lazy var processes = ProcessListContent(open)
    private var session: DBConnection?
    private var reading: Task<Void, Never>?
    private var askedForSizes = false
    private var found: [HostFigures.Variable] = []

    init(_ open: OpenConnection, pane: Pane = .databases) {
        self.open = open
        self.pane = pane
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = SurfaceView(.content)
        root.setAccessibilityIdentifier("host")
        heading.stringValue = open.model?.connection(open.id)?.displayName ?? "Server"
        heading.toolTip = heading.stringValue
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        properties.setAccessibilityIdentifier("host.properties")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Reading")
        tabs.segmentCount = Pane.allCases.count
        tabs.trackingMode = .selectOne
        for page in Pane.allCases {
            tabs.setLabel(page.title, forSegment: page.rawValue)
            tabs.setToolTip(page.tip, forSegment: page.rawValue)
        }
        tabs.target = self
        tabs.action = #selector(paneChosen)
        tabs.setAccessibilityIdentifier("host.panes")
        let top = NSStackView(views: [heading, spinner, NSView(), helpButton(.navigator)])
        top.spacing = Spacing.unit
        let texts = NSStackView(views: [top, properties, tabs])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = Spacing.half
        texts.setCustomSpacing(Spacing.unit, after: properties)
        texts.translatesAutoresizingMaskIntoConstraints = false
        holder.translatesAutoresizingMaskIntoConstraints = false
        [texts, holder].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            top.widthAnchor.constraint(equalTo: texts.widthAnchor),
            properties.widthAnchor.constraint(lessThanOrEqualTo: texts.widthAnchor),
            texts.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.double),
            texts.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.double),
            texts.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.double),
            holder.topAnchor.constraint(equalTo: texts.bottomAnchor, constant: Spacing.unit),
            holder.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            holder.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            holder.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        for list in [databases, variables, status, commands] {
            addChild(list)
            list.onMenu = { [weak self] in self?.contextMenu() }
        }
        databases.onOpen = { [weak self] in self?.openDatabase($0.key) }
        databases.onSelect = { [weak self] in self?.updateButtons() }
        variables.onOpen = { [weak self] _ in self?.editVariable(nil) }
        variables.onSelect = { [weak self] in self?.updateButtons() }
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: .openConnectionDidChange, object: open)
        show(pane)
        changed()
        read()
    }

    /// The pane's list in the holder, with the focus; the processes load the first time they show.
    func show(_ pane: Pane) {
        self.pane = pane
        guard isViewLoaded else { return }
        tabs.selectedSegment = pane.rawValue
        holder.subviews.forEach { $0.removeFromSuperview() }
        let content: NSViewController
        switch pane {
        case .databases: content = databases
        case .variables: content = variables
        case .status: content = status
        case .commands: content = commands
        case .processes:
            if processes.parent == nil { addChild(processes) }
            content = processes
        }
        holder.addSubview(content.view)
        content.view.pin(to: holder)
        view.window?.makeFirstResponder((content as? HostList)?.table ?? processes.table)
        updateButtons()
    }

    @objc private func paneChosen() { Pane(rawValue: tabs.selectedSegment).map(show) }

    /// The schema or the sizes changed: the databases show it, and on a server small enough the sizes are read unasked.
    @objc private func changed() {
        let snapshot = open.snapshot
        let rows = DiskUsage.databases(snapshot)
        let largest = max(1, rows.map { ($0.total ?? 0) + ($0.free ?? 0) }.max() ?? 1)
        databases.show(zip(snapshot.databases, rows).map { database, row in
            let scale = Double(largest)
            func count(_ value: Int) -> (String, Double) { (value.formatted(), Double(value)) }
            let tables = count(database.tables.filter { $0.kind != .view }.count)
            let views = count(database.tables.filter { $0.kind == .view }.count)
            let routines = count(database.routines.count), triggers = count(database.triggers.count), events = count(database.events.count)
            var numbers = ["tables": tables.1, "views": views.1, "routines": routines.1, "triggers": triggers.1, "events": events.1]
            numbers["size"] = row.total.map(Double.init)
            numbers["bar"] = numbers["size"]
            return HostList.Row(key: database.name, cells: [
                "name": database.name, "size": DiskUsage.size(row.total), "tables": tables.0, "views": views.0, "routines": routines.0,
                "triggers": triggers.0, "events": events.0, "collation": database.collation,
                "updated": database.statistics?.values.compactMap(\.updateTime).max() ?? "",
                "bar": row.total == nil ? "" : DiskUsage.size(row.total),
            ], numbers: numbers, bars: ["bar": SizeBar.Parts(data: Double(row.data ?? 0) / scale, index: Double(row.index ?? 0) / scale,
                                                             free: Double(row.free ?? 0) / scale)])
        })
        if !askedForSizes, snapshot.detailsUpfront, !open.loading.contains(.schema) {
            askedForSizes = true
            open.readSizes(unread)
        }
        updateButtons()
    }

    private var unread: [String] { open.snapshot.databases.filter { $0.statistics == nil }.map(\.name) }

    /// What the buttons and the databases' caption say for the selection and the reading.
    private func updateButtons() {
        let progress = open.sizesProgress
        readSizes.isEnabled = progress == nil
        readSizes.toolTip = progress != nil ? "It is reading already" : "Read the sizes of the selected databases, or of all of them"
        stopSizes.isEnabled = progress != nil
        stopSizes.toolTip = progress != nil ? "Stop reading sizes; what was read stays" : "Nothing is being read"
        if let progress {
            databases.note = "reading sizes: \(progress.database) (\(progress.done + 1) of \(progress.of))…"
        } else if let error = open.sizesError {
            databases.note = "couldn't read every size: " + error
        } else if !unread.isEmpty {
            databases.note = "press Read Sizes to see what they take (it opens every table, one database at a time)"
        } else {
            databases.note = "sizes are estimates for InnoDB, and only what this login can see"
        }
        let reason = reason(Commands.editVariable.action)
        edit.isEnabled = reason == nil
        edit.toolTip = reason ?? Commands.editVariable.tip
        variables.note = editRefusal ?? "double-click one to change it"
    }

    // MARK: Reading

    private func hostSession() async throws -> DBConnection {
        if let session, session.isConnected { return session }
        let opened = try await open.connection.toolsSession()
        session = opened
        return opened
    }

    /// Reads the variables and the status.
    private func read() {
        guard reading == nil else { return }
        spinner.startAnimation(nil)
        reading = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await hostSession()
                let local = try await session.rows(HostFigures.sessionVariables)
                let global = try await session.rows(HostFigures.globalVariables)
                let counters = HostFigures.counters(try await session.rows(HostFigures.status))
                show(HostFigures.variables(session: local, global: global), counters, server: session.server)
            } catch {
                properties.stringValue = "Couldn't read the server's variables and status: " + error.localizedDescription
                properties.toolTip = properties.stringValue
            }
            spinner.stopAnimation(nil)
            reading = nil
        }
    }

    /// Shows what was read. Numbers read as people write them; a rate has as many decimals as it needs to say something.
    func show(_ found: [HostFigures.Variable], _ counters: [HostFigures.Counter], server: ServerInfo?) {
        self.found = found
        func rate(_ value: Double?) -> String {
            value?.formatted(.number.precision(.fractionLength(0...(abs(value ?? 0) < 10 ? 2 : 0)))) ?? ""
        }
        variables.show(found.map { variable in
            HostList.Row(key: variable.name, cells: ["name": variable.name, "session": variable.session ?? "", "global": variable.global ?? "",
                                                     "differs": variable.differs ? "≠" : ""])
        })
        status.show(counters.map { counter in
            var numbers: [String: Double] = [:]
            numbers["value"] = counter.number
            numbers["hour"] = counter.perHour
            numbers["second"] = counter.perSecond
            return HostList.Row(key: counter.name, cells: ["name": counter.name, "value": counter.value, "hour": rate(counter.perHour),
                                                           "second": rate(counter.perSecond)], numbers: numbers)
        })
        let statements = HostFigures.commands(counters)
        let top = statements.first?.share ?? 1
        commands.show(statements.map { command in
            let percent = String(format: "%.1f%%", command.share * 100)
            var numbers = ["count": command.count, "bar": command.count, "percent": command.count]
            numbers["hour"] = command.perHour
            numbers["second"] = command.perSecond
            return HostList.Row(key: command.name, cells: ["name": command.name, "count": command.count.formatted(), "hour": rate(command.perHour),
                                                           "second": rate(command.perSecond), "percent": percent, "bar": percent],
                                numbers: numbers, bars: ["bar": SizeBar.Parts(data: command.share / top)])
        })
        var parts: [String] = []
        if let server { parts.append(server.flavor.title + " " + server.version) }
        let options = open.connection.options
        parts.append("\(options.host):\(options.port)")
        parts.append(server?.tls ?? "no TLS")
        func value(_ name: String) -> String? { found.first { $0.name == name }?.global }
        if let system = value("version_compile_os") { parts.append(system) }
        if let packet = value("max_allowed_packet").flatMap({ Int($0) }) { parts.append("packets up to " + DiskUsage.size(packet)) }
        if let uptime = counters.first(where: { $0.name == "Uptime" })?.number {
            let days = Int(uptime) / 86_400, hours = Int(uptime) % 86_400 / 3_600
            parts.append("up \(days) day\(days == 1 ? "" : "s"), \(hours) hour\(hours == 1 ? "" : "s")")
        }
        properties.stringValue = parts.joined(separator: " · ")
        properties.toolTip = properties.stringValue
    }

    // MARK: Commands

    private func openDatabase(_ name: String) {
        (view.window?.windowController as? MainWindowController)?.open(DatabaseViewController(open, name), title: name, connection: open.id)
    }

    @objc func refresh(_ sender: Any?) {
        switch pane {
        case .databases:
            let chosen = databases.selected.map(\.key)
            open.readSizes(chosen.isEmpty ? open.snapshot.databases.map(\.name) : chosen)
        case .processes: processes.refresh(sender)
        default: read()
        }
    }

    @objc private func stopReading(_ sender: Any?) { open.stopReadingSizes() }

    @objc func copyList(_ sender: Any?) { currentList?.copyList(sender) }
    @objc func exportList(_ sender: Any?) { currentList?.exportList(sender) }

    @objc func editDatabase(_ sender: Any?) {
        if let name = databases.selected.first?.key { NavigatorActions.editDatabase(name, on: open, window: view.window) }
    }

    /// Disk Usage of the selected database, else of the server.
    @objc func showDiskUsage(_ sender: Any?) {
        let database = pane == .databases && databases.selected.count == 1 ? databases.selected[0].key : nil
        (view.window?.windowController as? MainWindowController)?.showDiskUsage(open, level: database.map { .database($0) } ?? .server)
    }

    private var currentList: HostList? {
        switch pane {
        case .databases: return databases
        case .variables: return variables
        case .status: return status
        case .commands: return commands
        case .processes: return nil
        }
    }

    /// Why this connection's variables can't be changed; nil: they can. Read-only and Production say no, as a change
    /// of a server's variables reaches everyone on it.
    private var editRefusal: String? {
        guard let saved = open.model?.connection(open.id) else { return "Connect to the server again first" }
        if saved.readOnly { return "“\(saved.displayName)” is read-only: variables can't be changed" }
        if saved.isProduction { return "“\(saved.displayName)” is Production: variables can't be changed from here" }
        return nil
    }

    /// Asks for the value and the scope. Global runs after the SQL preview; session goes into a new query tab, the one
    /// place it means something, as each tab has a session of its own, to run from there.
    @objc func editVariable(_ sender: Any?) {
        if let refusal = editRefusal { return showError(refusal, title: "Couldn't edit the variable", on: view.window) }
        guard let window = view.window, let chosen = variables.selected.first,
              let variable = found.first(where: { $0.name == chosen.key }) else { return }
        let field = textField(variable.global ?? variable.session ?? "", placeholder: "Value", id: "host.variable.value",
                              tip: "Type its new value: a number, a word, or DEFAULT", width: 320)
        var scopes: [String] = []
        if variable.global != nil { scopes.append("Whole server (SET GLOBAL)") }
        if variable.session != nil { scopes.append("In a new query tab (SET SESSION)") }
        let scope = popup(scopes, selected: 0, id: "host.variable.scope", tip: "Choose whether every new session takes it, or only one query tab",
                          target: nil, action: nil)
        let fields = NSStackView(views: [field, scope])
        fields.orientation = .vertical
        fields.alignment = .leading
        NavigatorActions.ask("Edit \(variable.name)", "It lasts until the server restarts, or the session ends.", field: fields,
                             action: "Next…", on: window) { [weak self] in
            guard let self else { return }
            let global = variable.global != nil && scope.indexOfSelectedItem == 0
            self.set(variable.name, to: field.stringValue, global: global, window: window)
        }
    }

    private func set(_ name: String, to value: String, global: Bool, window: NSWindow) {
        let escapes = session?.noBackslashEscapes ?? open.snapshot.server?.noBackslashEscapes ?? false
        let sql = HostFigures.setVariable(name, to: value, global: global, noBackslashEscapes: escapes)
        guard global else {
            _ = (window.windowController as? MainWindowController)?.openConsole(text: sql + ";\n", title: nil, connection: open.id)
            return
        }
        var request = SQLPreviewRequest(change: ChangeSQL(title: "Set \(name)", statements: [sql], connection: open.id),
                                        heading: "Set \(name) for the whole server?",
                                        caption: "It reaches every new session at once, and lasts until the server restarts.")
        request.actionTitle = "Set"
        request.destructive = true
        request.noBackslashEscapes = escapes
        NavigatorActions.confirmAndRun(request, on: open, window: window, refreshing: []) { [weak self] _ in self?.read() }
    }

    private func contextMenu() -> NSMenu? {
        let menu = NSMenu(title: "Server")
        switch pane {
        case .databases: menu.add([Commands.diskUsage, Commands.editDatabase, nil])
        case .variables: menu.add([Commands.editVariable, nil])
        default: break
        }
        menu.add([Commands.copy, Commands.copyList, Commands.exportList, nil, Commands.refresh])
        return menu
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let reason = reason(item.action)
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }

    private func reason(_ action: Selector?) -> String? {
        switch action {
        case Commands.editDatabase.action?:
            if pane != .databases { return "Show the Databases first" }
            return NavigatorActions.reason(for: action, objects: [], databases: databases.selected.map(\.key), open: open, target: open,
                                           model: open.model)
        case Commands.editVariable.action?:
            if pane != .variables { return "Show the Variables first" }
            return editRefusal ?? (variables.selected.count == 1 ? nil : "Select one variable first")
        case Commands.copyList.action?, Commands.exportList.action?:
            return currentList == nil ? "The process list copies its selected rows with ⌘C" : nil
        default:
            return nil
        }
    }

    /// The tab closes or the preview shows something else: its sessions go.
    func release() {
        if let session { Task { await session.close() } }
        session = nil
        if processes.isViewLoaded { processes.shouldClose { _ in } }
    }

    func shouldClose(_ answer: @escaping (Bool) -> Void) {
        release()
        answer(true)
    }
}

extension MainWindowController {
    /// Shows `pane` on the connection's host page: in the tab that has it, else in the preview tab.
    func showHost(_ open: OpenConnection, pane: HostContent.Pane? = nil) {
        if let tab = model.allTabs.first(where: { ($0.shown as? HostContent)?.open === open }), let host = tab.shown as? HostContent {
            show(tab)
            if let pane { host.show(pane) }
        } else {
            preview(HostContent(open, pane: pane ?? .databases), title: model.connection(open.id)?.displayName ?? "Server", connection: open.id)
        }
    }
}
