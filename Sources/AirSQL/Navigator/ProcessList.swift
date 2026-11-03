import AirSQLCore
import AppKit

/// The process list (scope "server"): every connection to the server and what it runs, refreshed every few seconds,
/// read on a session of its own. Kill Query and Kill Connection ask first and then check, on the same session, that the
/// process still runs what the list showed before they stop it (plan §2.12: a click selects, a double-click shows the
/// full query, a right-click opens Kill Query…, Kill Connection…, Copy Query, Explain).
@MainActor
final class ProcessListContent: NSViewController, TabContent, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    let open: OpenConnection
    let table = ProcessTableView()
    let interval: NSPopUpButton
    private(set) var processes: [ServerProcess] = []
    private let status = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    private let spinner = NSProgressIndicator()
    private var session: DBConnection?
    private var refreshing: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    static let intervals = [0, 2, 5, 10, 30]
    private static let columns: [(String, String, CGFloat)] = [("id", "Id", 70), ("user", "User", 100), ("host", "Host", 150),
        ("db", "Database", 110), ("command", "Command", 80), ("time", "Time", 60), ("state", "State", 140), ("info", "Query", 400)]

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
        let killQuery = button("Kill Query…", id: "processes.killQuery", tip: Commands.killQuery.tip, target: nil,
                               action: Commands.killQuery.action)
        let killConnection = button("Kill Connection…", id: "processes.killConnection", tip: Commands.killConnection.tip,
                                    target: nil, action: Commands.killConnection.action)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Refreshing")
        let bar = NSStackView(views: [title, spinner, NSView(), interval, refreshButton, killQuery, killConnection])
        bar.spacing = Spacing.unit
        bar.translatesAutoresizingMaskIntoConstraints = false
        status.setAccessibilityIdentifier("processes.status")
        for (id, title, width) in Self.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 40
            table.addTableColumn(column)
        }
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
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
        [bar, status, scroll].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.double - 2),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.double),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.double),
            status.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: Spacing.half),
            status.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Spacing.double),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: Spacing.unit),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        refresh(nil)
        intervalChosen()
    }

    @objc private func intervalChosen() {
        timer?.cancel()
        let seconds = Self.intervals[safe: interval.indexOfSelectedItem] ?? 0
        guard seconds > 0 else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !Task.isCancelled, let self, self.view.window != nil else { continue }
                self.refresh(nil)
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
                status.stringValue = "Couldn't read the processes: " + ((error as? AirSQLError)?.message ?? error.localizedDescription)
                status.toolTip = status.stringValue
            }
            spinner.stopAnimation(nil)
            refreshing = nil
        }
    }

    private func show(_ list: [ServerProcess]) {
        let selected = Set(table.selectedRowIndexes.compactMap { processes[safe: $0]?.id })
        processes = list
        table.reloadData()
        table.selectRowIndexes(IndexSet(processes.indices.filter { selected.contains(processes[$0].id) }), byExtendingSelection: false)
        let busy = list.filter { $0.info != nil }.count
        status.stringValue = "\(list.count) connections, \(busy) running a statement · read at "
            + Date().formatted(date: .omitted, time: .standard)
        status.toolTip = status.stringValue
    }

    var selected: [ServerProcess] { table.selectedRowIndexes.compactMap { processes[safe: $0] } }

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
            notes.append((error as? AirSQLError)?.message ?? error.localizedDescription)
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
        var reason: String?
        switch item.action {
        case Commands.killQuery.action?, Commands.copyQuery.action?:
            reason = selected.contains { $0.info != nil } ? nil : "Select a process that is running a statement first"
        case Commands.killConnection.action?:
            reason = selected.isEmpty ? "Select a process first" : nil
        case Commands.explain.action?:
            reason = selected.count == 1 && selected[0].info != nil ? nil : "Select one process that is running a statement first"
        default:
            break
        }
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }

    func contextMenu() -> NSMenu? {
        guard !selected.isEmpty else { return nil }
        let menu = NSMenu(title: "Process")
        menu.add([Commands.killQuery, Commands.killConnection, nil, Commands.copyQuery, Commands.explain])
        return menu
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { processes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let process = processes[safe: row], let id = tableColumn?.identifier.rawValue else { return nil }
        let value: String
        switch id {
        case "id": value = String(process.id)
        case "user": value = process.user
        case "host": value = process.host
        case "db": value = process.database ?? ""
        case "command": value = process.command
        case "time": value = String(process.time)
        case "state": value = process.state ?? ""
        default: value = (process.info ?? "").replacingOccurrences(of: "\n", with: " ")
        }
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

/// The process list: a right-click selects the row under the pointer first and opens the process menu.
@MainActor
final class ProcessTableView: NSTableView {
    weak var owner: ProcessListContent?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        window?.makeFirstResponder(self)
        return owner?.contextMenu()
    }
}
