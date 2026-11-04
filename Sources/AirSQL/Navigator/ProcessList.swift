import AirSQLCore
import AppKit

/// The process list (scope "server"): every connection to the server and what it runs, refreshed every few seconds,
/// read on a session of its own. Kill Query and Kill Connection ask first and then check, on the same session, that the
/// process still runs what the list showed before they stop it (plan §2.12: a click selects, a double-click shows the
/// full query, a right-click opens Kill Query…, Kill Connection…, Copy Query, Explain). A header sorts, the filter and
/// Hide Sleeping narrow what the last read found.
@MainActor
final class ProcessListContent: NSViewController, TabContent, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation,
    NSSearchFieldDelegate {
    let open: OpenConnection
    let table = ProcessTableView()
    let interval: NSPopUpButton
    /// The rows shown: of what the last read found, those the filter keeps, in the header's order.
    private(set) var processes: [ServerProcess] = []
    private var found: [ServerProcess] = []
    private var readAt = Date()
    let filter = NSSearchField()
    lazy var hideSleeping = checkbox("Hide Sleeping", id: "processes.hideSleeping",
                                     tip: "Leave out connections that are waiting for their next statement", on: false,
                                     target: self, action: #selector(arrange))
    private let status = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    private let spinner = NSProgressIndicator()
    private var session: DBConnection?
    private var refreshing: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private let killQuery = button("Kill Query…", id: "processes.killQuery", tip: Commands.killQuery.tip, target: nil,
                                   action: Commands.killQuery.action)
    private let killConnection = button("Kill Connection…", id: "processes.killConnection", tip: Commands.killConnection.tip,
                                        target: nil, action: Commands.killConnection.action)
    static let intervals = [0, 2, 5, 10, 30]
    private static let columns: [(String, String, CGFloat)] = [("id", "Id", 60), ("user", "User", 96), ("host", "Host", 150),
        ("db", "Database", 100), ("command", "Command", 84), ("time", "Time", 64), ("state", "State", 150), ("info", "Query", 300)]

    private static let columnTips = [
        "id": "The server's number for this connection, used to kill it",
        "command": "What the connection is doing: Query runs a statement, Sleep waits for the next one",
        "time": "How many seconds it has been in this state",
        "state": "What the statement is busy with now, in the server's words",
    ]

    init(_ open: OpenConnection) {
        self.open = open
        interval = popup(Self.intervals.map { $0 == 0 ? "Off" : "Every \($0) s" }, selected: 2, id: "processes.interval",
                         tip: "Refresh the list by itself every few seconds, or not", target: nil, action: nil)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = SurfaceView(.content)
        root.setAccessibilityIdentifier("processes")
        let title = label("Processes", font: .systemFont(ofSize: 15, weight: .semibold))
        interval.target = self
        interval.action = #selector(intervalChosen)
        let refreshButton = button("Refresh", id: "processes.refresh", tip: Commands.refresh.tip + " (⌘R)", target: self,
                             action: #selector(refresh(_:)))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Refreshing")
        let bar = NSStackView(views: [title, spinner, NSView(), interval, refreshButton, killQuery, killConnection])
        bar.spacing = Spacing.unit
        bar.translatesAutoresizingMaskIntoConstraints = false
        status.setAccessibilityIdentifier("processes.status")
        filter.placeholderString = "Filter"
        filter.toolTip = "Type words to show only the processes that contain them"
        filter.setAccessibilityIdentifier("processes.filter")
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        filter.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let narrow = NSStackView(views: [status, NSView(), hideSleeping, filter, helpButton(.navigator)])
        narrow.spacing = Spacing.unit
        narrow.translatesAutoresizingMaskIntoConstraints = false
        for (id, title, width) in Self.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "info" ? 200 : 40
            if id == "id" || id == "time" { column.headerCell.alignment = .right }
            // Time starts with the longest running, the main reason to sort.
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id != "time")
            column.headerToolTip = (Self.columnTips[id].map { $0 + ". " } ?? "") + "Click to sort by it, again to reverse"
            table.addTableColumn(column)
        }
        table.autosaveName = layoutName("Processes")  // its widths and sort, for next time
        table.autosaveTableColumns = true
        table.style = .fullWidth
        table.stripes = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.centreText(rowHeight: 24)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(showQuery(_:))
        table.owner = self
        table.setAccessibilityIdentifier("processes.list")
        table.setAccessibilityLabel("Processes")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        [bar, narrow, scroll].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.double - 2),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.double),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.double),
            narrow.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: Spacing.half),
            narrow.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            narrow.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: narrow.bottomAnchor, constant: Spacing.unit),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        updateButtons()
        refresh(nil)
        intervalChosen()
    }

    /// The bar's Kill buttons, as their menu items: enabled for the selection they act on, else saying why not.
    private func updateButtons() {
        for (button, command) in [(killQuery, Commands.killQuery), (killConnection, Commands.killConnection)] {
            let reason = reason(command.action)
            button.isEnabled = reason == nil
            button.toolTip = reason ?? command.tip
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    /// The query takes the width that is left.
    override func viewDidLayout() {
        super.viewDidLayout()
        table.sizeLastColumnToFit()
    }

    @objc private func intervalChosen() {
        timer?.cancel()
        let seconds = Self.intervals[safe: interval.indexOfSelectedItem] ?? 0
        guard seconds > 0 else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard let self else { return }
                // Only while it shows: a tab behind another isn't refreshed.
                if !Task.isCancelled, self.view.window != nil { self.refresh(nil) }
            }
        }
    }

    /// The list's session, opened on first use.
    private func listSession() async throws -> DBConnection {
        if let session, session.isConnected { return session }
        let opened = try await open.connection.toolsSession()
        session = opened
        return opened
    }

    @objc func refresh(_ sender: Any?) {
        guard refreshing == nil else { return }
        spinner.startAnimation(nil)
        refreshing = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await listSession()
                let mariaDB = session.server?.flavor == .mariadb
                let rows = try await session.rows(NavigatorSQL.processList(mariaDB: mariaDB))
                show(NavigatorSQL.processes(rows))
            } catch {
                status.stringValue = "Couldn't read the processes: " + error.localizedDescription
                status.toolTip = status.stringValue
            }
            spinner.stopAnimation(nil)
            refreshing = nil
        }
    }

    func show(_ list: [ServerProcess]) {
        found = list
        readAt = Date()
        arrange()
    }

    /// Shows what was found, filtered and in the header's order, keeping the selection.
    @objc private func arrange() {
        let selected = Set(table.selectedRowIndexes.compactMap { processes[safe: $0]?.id })
        let words = filter.stringValue.lowercased().split(separator: " ")
        processes = found.filter { process in
            guard hideSleeping.state == .off || process.command != "Sleep" else { return false }
            let row = Self.columns.map { Self.text(process, $0.0) }.joined(separator: " ").lowercased()
            return words.allSatisfy(row.contains)
        }
        if let sort = table.sortDescriptors.first, let key = sort.key {
            processes.sort { a, b in
                let order = Self.compare(a, b, key)
                return order == .orderedSame ? a.id < b.id : (order == .orderedAscending) == sort.ascending
            }
        }
        table.reloadData()
        table.selectRowIndexes(IndexSet(processes.indices.filter { selected.contains(processes[$0].id) }), byExtendingSelection: false)
        updateButtons()
        let busy = processes.filter { $0.info != nil }.count
        status.stringValue = (processes.count == found.count ? "\(found.count)" : "\(processes.count) of \(found.count)")
            + " processes, \(busy) running a statement · read at " + readAt.formatted(date: .omitted, time: .standard)
        status.toolTip = status.stringValue
    }

    /// Id and Time as numbers, the rest as a person sorts text.
    private static func compare(_ a: ServerProcess, _ b: ServerProcess, _ key: String) -> ComparisonResult {
        switch key {
        case "id": return a.id == b.id ? .orderedSame : a.id < b.id ? .orderedAscending : .orderedDescending
        case "time": return a.time == b.time ? .orderedSame : a.time < b.time ? .orderedAscending : .orderedDescending
        default: return text(a, key).localizedStandardCompare(text(b, key))
        }
    }

    /// What a column shows for a process.
    private static func text(_ process: ServerProcess, _ id: String) -> String {
        switch id {
        case "id": return String(process.id)
        case "user": return process.user
        case "host": return process.host
        case "db": return process.database ?? ""
        case "command": return process.command
        case "time": return String(process.time)
        case "state": return process.state ?? ""
        default: return (process.info ?? "").replacingOccurrences(of: "\n", with: " ")
        }
    }

    func controlTextDidChange(_ notification: Notification) { arrange() }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { arrange() }

    var selected: [ServerProcess] { table.selectedRowIndexes.compactMap { processes[safe: $0] } }

    var isRefreshing: Bool { refreshing != nil }

    // MARK: Commands

    @objc func showQuery(_ sender: Any?) {
        guard let process = processes[safe: table.clickedRow >= 0 ? table.clickedRow : table.selectedRow], let window = view.window
        else { return }
        let alert = NSAlert()
        alert.messageText = "Process \(process.id): \(process.user)@\(process.host)"
        alert.informativeText = process.info ?? "It isn't running a statement now (\(process.command.lowercased()))."
        alert.addOK()
        alert.beginSheetModal(for: window)
    }

    @objc func copyQuery(_ sender: Any?) {
        let text = selected.compactMap(\.info).joined(separator: ";\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// ⌘C: the selected rows, tab-separated.
    @objc func copy(_ sender: Any?) {
        let rows = selected.map { process in Self.columns.map { Self.text(process, $0.0) }.joined(separator: "\t") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rows.joined(separator: "\n"), forType: .string)
    }

    @objc func killQuery(_ sender: Any?) { kill(connection: false) }
    @objc func killConnection(_ sender: Any?) { kill(connection: true) }

    private func kill(connection: Bool) {
        guard let window = view.window, !selected.isEmpty else { return }
        let targets = selected
        let alert = NSAlert()
        alert.messageText = connection ? "End \(targets.count == 1 ? "process \(targets[0].id)’s connection" : "\(targets.count) connections")?"
            : "Stop \(targets.count == 1 ? "process \(targets[0].id)’s statement" : "\(targets.count) statements")?"
        alert.informativeText = connection ? "Its open transaction is rolled back and its client is disconnected."
            : "The statement stops and its changes are rolled back; the connection stays."
        let kill = alert.addButton(withTitle: connection ? "Kill Connection" : "Kill Query")
        kill.hasDestructiveAction = true
        kill.toolTip = connection ? Commands.killConnection.tip : Commands.killQuery.tip
        alert.addButton(withTitle: "Cancel").toolTip = "Leave it running"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { await self?.kill(targets, connection: connection) }
        }
    }

    private func kill(_ targets: [ServerProcess], connection: Bool) async {
        var notes: [String] = []
        do {
            let session = try await listSession()
            for process in targets {
                let check = connection ? NavigatorSQL.stillConnected(process, noBackslashEscapes: session.noBackslashEscapes)
                    : NavigatorSQL.stillRunning(process, noBackslashEscapes: session.noBackslashEscapes)
                let found = try await session.rows(check).first?.first ?? nil
                guard found.flatMap({ Int($0) }) == 1 else {
                    notes.append("Process \(process.id) had moved on, so nothing was stopped.")
                    continue
                }
                _ = try await session.query(connection ? NavigatorSQL.killConnection(process) : NavigatorSQL.killQuery(process))
            }
        } catch {
            notes.append(error.localizedDescription)
        }
        if !notes.isEmpty { showError(notes.joined(separator: "\n"), title: "Not everything was stopped", on: view.window) }
        refresh(nil)
    }

    @objc func explain(_ sender: Any?) {
        guard let process = selected.first, process.info != nil, let main = view.window?.windowController as? MainWindowController,
              let session else { return }
        let sql = session.server?.flavor == .mariadb ? "SHOW EXPLAIN FOR \(process.id)" : "EXPLAIN FOR CONNECTION \(process.id)"
        let content = TextContent(title: "Explain · process \(process.id)", caption: process.info ?? "") {
            guard let rows = try await session.query(sql).first?.rows else { return "" }
            let header = rows.columns.map(\.name).joined(separator: "   ")
            return ([header] + (0..<rows.rowCount).map { row in
                (0..<rows.columns.count).map { rows.display(row, $0) ?? "NULL" }.joined(separator: "   ")
            }).joined(separator: "\n")
        }
        main.open(content, title: "Explain · \(process.id)", connection: open.id)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let reason = reason(item.action)
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }

    /// Why a command can't act on the selection now (nil: it can).
    private func reason(_ action: Selector?) -> String? {
        switch action {
        case Commands.killQuery.action?, Commands.copyQuery.action?:
            return selected.contains { $0.info != nil } ? nil : "Select a process that is running a statement first"
        case Commands.killConnection.action?, Commands.copy.action?:
            return selected.isEmpty ? "Select a process first" : nil
        case Commands.explain.action?:
            return selected.count == 1 && selected[0].info != nil ? nil : "Select one process that is running a statement first"
        default:
            return nil
        }
    }

    func contextMenu() -> NSMenu? {
        let menu = NSMenu(title: "Process")
        guard !selected.isEmpty else {
            menu.add([Commands.refresh])
            return menu
        }
        menu.add([Commands.killQuery, Commands.killConnection, nil, Commands.copyQuery, Commands.explain])
        return menu
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { processes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let process = processes[safe: row], let id = tableColumn?.identifier.rawValue else { return nil }
        let value = Self.text(process, id)
        let field = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell." + id), owner: nil) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        field.identifier = NSUserInterfaceItemIdentifier("cell." + id)
        field.stringValue = value
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = value.isEmpty ? nil : value
        field.alignment = id == "id" || id == "time" ? .right : .left
        field.font = id == "info" ? .monospacedSystemFont(ofSize: 11.5, weight: .regular) : .systemFont(ofSize: 12)
        return field
    }

    func shouldClose(_ answer: @escaping (Bool) -> Void) {
        timer?.cancel()
        if let session { Task { await session.close() } }
        session = nil
        answer(true)
    }
}

/// The process list: a right-click selects the row under the pointer first and opens the process menu; Return shows the
/// query, Delete offers to stop it (the connection, when it isn't running one).
@MainActor
final class ProcessTableView: ContentTable {
    weak var owner: ProcessListContent?

    override func menu(for event: NSEvent) -> NSMenu? {
        if !selectsRow(for: event) { deselectAll(nil) }
        return owner?.contextMenu()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: owner?.showQuery(self)
        case 51, 117:
            if owner?.selected.contains(where: { $0.info != nil }) == true { owner?.killQuery(self) } else { owner?.killConnection(self) }
        default: super.keyDown(with: event)
        }
    }
}
