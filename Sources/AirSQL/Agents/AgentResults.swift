import AirSQLCore
import AppKit

/// One statement an agent ran with run_queries, as its connection's Agent tab shows it.
struct AgentRun {
    let id = UUID()
    /// The Agent Activity entry of the call it was in.
    let call: UUID
    let time = Date()
    let client: String
    let connection: UUID
    let sql: String
    /// The rows the agent got, and no more (its max_rows and row cap); nil when it got none.
    let rows: ResultStore?
    /// What it got, in a few words, or why it failed.
    let outcome: String
    /// What the tab shows in place of rows: the error, or where the rows went.
    let detail: String
    let failed: Bool

    /// One entry of a run_queries reply, with its rows.
    init(call: UUID, client: String, connection: UUID, result: [String: Any], rows: ResultStore?) {
        self.call = call
        self.client = client
        self.connection = connection
        sql = result["sql"] as? String ?? ""
        self.rows = rows
        failed = result["ok"] as? Bool == false
        let count = result["rowCount"] as? Int ?? 0
        let counted = "\(count.formatted()) row\(count == 1 ? "" : "s")"
        if failed {
            outcome = result["error"] as? String ?? "Failed"
            detail = outcome
        } else if let file = result["file"] as? String {
            outcome = counted + " saved to a file"
            detail = "The agent had its rows saved to a file in AirSQL's agent export folder: " + file
        } else if result["columns"] == nil {
            outcome = "No rows"
            detail = "The statement returned no rows."
        } else {
            outcome = counted + (result["capped"] as? Bool == true ? ", more weren't sent" : "")
            detail = outcome
        }
    }
}

/// A connection's Agent tab (scope ai-3): the statements agents ran on it with run_queries, newest last, and under them
/// the rows the selected one got, read-only in the result grid. One tab per connection, reused (View ▸ Agent Results,
/// or a double-click in Agent Activity). A click shows a statement's rows, a double-click opens it in a new console tab,
/// a right-click offers that and Copy.
@MainActor
final class AgentResultsContent: NSViewController, TabContent, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuItemValidation {
    let connection: UUID
    private let service: AgentService
    let table = AgentRunTable()
    private let split = NSSplitView()
    private let detail = NSView()
    private let empty = label("", font: .systemFont(ofSize: 13), color: .secondaryLabelColor, wraps: true)
    private(set) var runs: [AgentRun] = []
    /// The statement whose rows show under the list.
    private(set) var shown: UUID?
    private var placed = false
    private var observer: NSObjectProtocol?
    private static let columns: [(String, String, CGFloat)] = [("time", "Time", 72), ("client", "Agent", 120),
                                                               ("sql", "Statement", 380), ("outcome", "Result", 200)]
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()
    /// The time column's width: a late time in the person's format ("10:58:58 PM") and the cell's margins.
    private static var timeWidth: CGFloat {
        let late = Calendar.current.date(bySettingHour: 22, minute: 58, second: 58, of: Date()) ?? Date()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        return ceil((time.string(from: late) as NSString).size(withAttributes: [.font: font]).width) + 16
    }

    init(service: AgentService, connection: UUID) {
        self.service = service
        self.connection = connection
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func loadView() {
        let root = SurfaceView(.content)
        root.setAccessibilityIdentifier("agentResults")
        for (id, title, width) in Self.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.headerToolTip = ["time": "When the agent ran it", "client": "Which agent ran it",
                                    "sql": "The statement; double-click to open it in a new query tab",
                                    "outcome": "What came of it: rows, or an error"][id]
            column.width = id == "time" ? max(width, Self.timeWidth) : width
            column.minWidth = id == "sql" ? 160 : 50
            table.addTableColumn(column)
        }
        table.style = .fullWidth
        table.stripes = true
        table.centreText(rowHeight: 24)
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openInNewConsole(_:))
        table.owner = self
        table.setAccessibilityIdentifier("agentResults.list")
        table.setAccessibilityLabel("Statements agents ran")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let list = NSView()
        list.addSubview(scroll)
        scroll.pin(to: list)
        list.addSubview(empty)
        empty.alignment = .center
        empty.setAccessibilityIdentifier("agentResults.empty")
        let name = service.model.connection(connection)?.displayName ?? "this connection"
        empty.stringValue = "No agent has run a query on \(name) yet. When one does, what it ran and the rows it got show "
            + "here, read-only."
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            empty.widthAnchor.constraint(lessThanOrEqualTo: list.widthAnchor, constant: -2 * Spacing.triple),
            list.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
            detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(list)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        root.addSubview(split)
        split.pin(to: root)
        view = root
        reload()
        observer = NotificationCenter.default.addObserver(forName: AgentService.didChange, object: service, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// The list a third of the height at first, the statement's rows the rest, then the shown statement scrolled into
    /// view: just after the first layout, as the split view places its divider itself during one.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard !placed, split.bounds.height > 0 else { return }
        placed = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.split.setPosition(max(120, (self.split.bounds.height / 3).rounded()), ofDividerAt: 0)
            self.split.layoutSubtreeIfNeeded()
            self.reveal()
        }
    }

    /// Scrolls the statement whose rows are shown into view, once the list has its size (before, it would scroll the
    /// first rows under the header).
    private func reveal() {
        guard placed, let row = runs.firstIndex(where: { $0.id == shown }) else { return }
        table.scrollRowToVisible(row)
    }

    /// The connection's statements again when agents ran more: the selection kept, or moved on to the newest statement
    /// when it was on the newest (so the tab follows what agents do).
    func reload() {
        let latest = service.runs.filter { $0.connection == connection }
        guard latest.map(\.id) != runs.map(\.id) else { return }  // another call, or another connection's
        let before = Set(table.selectedRowIndexes.compactMap { runs[safe: $0]?.id })
        let followed = before.isEmpty || runs.last.map { before == [$0.id] } == true
        runs = latest
        table.reloadData()
        let keep = followed ? IndexSet(runs.indices.suffix(1)) : IndexSet(runs.indices.filter { before.contains(runs[$0].id) })
        table.selectRowIndexes(keep, byExtendingSelection: false)
        empty.isHidden = !runs.isEmpty
        let still = selected.first { $0.id == shown }
        showRows(of: still ?? runs[safe: table.selectedRow])
        reveal()
    }

    /// Selects the statements of one call and shows the first one's rows (a double-click in Agent Activity).
    func select(call: UUID) {
        let rows = IndexSet(runs.indices.filter { runs[$0].call == call })
        guard let first = rows.first else { return }
        table.selectRowIndexes(rows, byExtendingSelection: false)
        showRows(of: runs[first])
        reveal()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showRows(of: runs[safe: table.clickedRow >= 0 && table.isRowSelected(table.clickedRow) ? table.clickedRow : table.selectedRow])
    }

    /// Under the list: the statement's rows in the result grid, else what it got instead.
    private func showRows(of run: AgentRun?) {
        guard run?.id != shown else { return }
        shown = run?.id
        detail.subviews.forEach { $0.removeFromSuperview() }
        guard let run else { return }
        let view: NSView
        if let rows = run.rows {
            let settings = service.model.data.settings
            view = ResultGridView(store: rows, nullText: settings.nullText, fontSize: CGFloat(settings.gridFontSize))
        } else {
            let text = label(run.detail, font: .systemFont(ofSize: 13), color: run.failed ? .statusBad : .secondaryLabelColor,
                             wraps: true)
            text.isSelectable = true
            text.setAccessibilityIdentifier("agentResults.detail")
            let holder = NSView()
            holder.addSubview(text)
            NSLayoutConstraint.activate([
                text.topAnchor.constraint(equalTo: holder.topAnchor, constant: Spacing.double),
                text.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: Spacing.double),
                text.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -Spacing.double),
            ])
            view = holder
        }
        detail.addSubview(view)
        view.pin(to: detail)
    }

    var selected: [AgentRun] { table.selectedRowIndexes.compactMap { runs[safe: $0] } }

    // MARK: Commands

    /// A double-click, or Query ▸ Open in New Query: the statements in a new console tab, to edit and run yourself.
    @objc func openInNewConsole(_ sender: Any?) {
        let picked = sender is NSTableView ? runs[safe: table.clickedRow].map { [$0] } ?? selected : selected
        guard !picked.isEmpty, let main = view.window?.windowController as? MainWindowController else { return }
        main.openConsole(text: Self.script(picked), title: nil, connection: connection)
    }

    /// Copies the selected statements' SQL.
    @objc func copy(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.script(selected), forType: .string)
    }

    /// Statements as a script: one a line, each ended by a semicolon.
    static func script(_ runs: [AgentRun]) -> String {
        runs.map { run in
            let sql = run.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            return sql.hasSuffix(";") ? sql : sql + ";"
        }.joined(separator: "\n")
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(openInNewConsole(_:)) || item.action == #selector(copy(_:)) else { return true }
        let enabled = !selected.isEmpty
        item.explain(enabled: enabled, reason: "Select a statement in the list first")
        return enabled
    }

    func contextMenu() -> NSMenu? {
        guard !selected.isEmpty else { return nil }
        let menu = NSMenu(title: "Statement")
        menu.add([Commands.openInNewConsole, nil, Commands.copy])
        return menu
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { runs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let run = runs[safe: row], let id = tableColumn?.identifier.rawValue else { return nil }
        let value: String
        switch id {
        case "time": value = Self.time.string(from: run.time)
        case "client": value = run.client
        case "sql": value = run.sql.split(whereSeparator: \.isNewline).joined(separator: " ")
        default: value = run.outcome
        }
        let field = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell." + id), owner: nil) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        field.identifier = NSUserInterfaceItemIdentifier("cell." + id)
        field.stringValue = value
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = id == "sql" ? String(run.sql.prefix(2_000)) : value
        field.font = id == "sql" ? .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            : id == "time" ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        field.textColor = id == "outcome" && run.failed ? .statusBad : .labelColor
        return field
    }
}

/// The Agent tab's list: a right-click selects the row under the pointer first and opens the statement's menu.
@MainActor
final class AgentRunTable: ContentTable {
    weak var owner: AgentResultsContent?

    override func menu(for event: NSEvent) -> NSMenu? { selectsRow(for: event) ? owner?.contextMenu() : nil }
}

extension AgentService {
    /// The Agent tab of `connection`, made the first time and then reused, showing `call`'s statements when given.
    func showResults(_ connection: UUID, call: UUID? = nil) {
        guard let main else { return }
        let existing = main.tabs.first { ($0.content as? AgentResultsContent)?.connection == connection }
        let content = existing?.content as? AgentResultsContent ?? AgentResultsContent(service: self, connection: connection)
        if let existing { main.select(existing) } else { main.open(content, title: "Agent Results", connection: connection) }
        main.showWindow(nil)
        if let call { content.select(call: call) }
    }
}

extension MainWindowController {
    /// View ▸ Agent Results: the active connection's Agent tab.
    @objc func showAgentResults(_ sender: Any?) {
        guard let connection = activeConnection else { return }
        agents?.showResults(connection.id)
    }
}
