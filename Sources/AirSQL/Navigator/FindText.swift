import AirSQLCore
import AppKit

/// Find Text on Server (scope "nav"): counts, table by table, the rows whose text columns hold a text, on a session of
/// its own, with progress and Cancel in the status bar. A double-click on a result opens the table's matching rows.
@MainActor
final class FindTextContent: NSViewController, TabContent, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate,
    NSMenuItemValidation {
    struct Match {
        var table: DatabaseObject
        var columns: [String]
        var rows: Int
    }

    let open: OpenConnection
    let field = NSSearchField()
    let scope: NSPopUpButton
    let table = ReturnTable()
    var matches: [Match] = []
    private(set) var searched = ""
    private let status = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    private let spinner = NSProgressIndicator()
    private var search: Task<Void, Never>? {
        didSet { updateButtons() }
    }
    private var go: NSButton?
    private var stopButton: NSButton?
    private var noBackslashEscapes = false

    init(_ open: OpenConnection, database: String?) {
        self.open = open
        let databases = open.snapshot.databases.map(\.name)
        scope = popup(["All databases"] + databases, selected: database.flatMap { databases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0,
                      id: "find.scope", tip: "Search every database, or only this one", target: nil, action: nil)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = SurfaceView(.content)
        root.setAccessibilityIdentifier("find")
        field.placeholderString = "Text to find"
        field.toolTip = "Type the text to look for in every text column; press Return to search"
        field.setAccessibilityIdentifier("find.text")
        field.sendsWholeSearchString = true
        field.target = self
        field.action = #selector(find(_:))
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        let go = button("Find", id: "find.go", tip: "Search the tables for the text (Return)", target: self, action: #selector(find(_:)))
        let stop = button("Stop", id: "find.stop", tip: "Stop searching; the matches found so far stay", target: self,
                          action: #selector(stop(_:)))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Searching")
        status.stringValue = "Type the text, then press Return: AirSQL counts the rows of each table whose text columns hold it. "
            + "Every table is read in full."
        status.toolTip = status.stringValue
        status.setAccessibilityIdentifier("find.status")
        self.go = go
        stopButton = stop
        updateButtons()
        let bar = NSStackView(views: [field, scope, go, stop, spinner])
        bar.spacing = Spacing.unit
        bar.translatesAutoresizingMaskIntoConstraints = false
        for (id, title, width) in [("table", "Table", 260.0), ("columns", "Columns", 260.0), ("rows", "Matching rows", 110.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id != "rows")
            table.addTableColumn(column)
        }
        table.style = .fullWidth
        table.stripes = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openMatch(_:))
        table.onReturn = { [weak self] in self?.openMatch(nil) }
        table.menu = resultMenu()
        table.setAccessibilityIdentifier("find.results")
        table.setAccessibilityLabel("Tables with matches")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        [bar, status, scroll].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.double),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.double),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Spacing.double),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            status.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: Spacing.unit),
            status.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Spacing.double),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: Spacing.unit),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    private func updateButtons() {
        go?.isEnabled = search == nil && !field.stringValue.isEmpty
        go?.toolTip = search != nil ? "It is searching: Stop first to search again"
            : field.stringValue.isEmpty ? "Type the text to find first" : "Search the tables for the text (Return)"
        stopButton?.isEnabled = search != nil
        stopButton?.toolTip = search != nil ? "Stop searching; the matches found so far stay" : "Nothing is being searched"
    }

    @objc func find(_ sender: Any?) {
        let text = field.stringValue
        guard !text.isEmpty, search == nil else { return }
        let databases = scope.indexOfSelectedItem == 0 ? open.snapshot.databases.map(\.name) : [scope.titleOfSelectedItem ?? ""]
        matches = []
        searched = text
        table.reloadData()
        spinner.startAnimation(nil)
        search = Task { [weak self] in
            await self?.run(text, in: databases)
            self?.search = nil
            self?.spinner.stopAnimation(nil)
        }
    }

    @objc func stop(_ sender: Any?) { search?.cancel() }

    func controlTextDidChange(_ notification: Notification) { updateButtons() }

    private func run(_ text: String, in databases: [String]) async {
        guard let model = open.model else { return }
        var session: DBConnection?
        let activity = model.activity.start("Finding “\(text)” on \(model.connection(open.id)?.displayName ?? "the server")",
                                            connection: open.id) { [weak self] in self?.search?.cancel() }
        defer {
            activity.end()
            if let session { Task { await session.close() } }
        }
        do {
            // Text columns come with the details: load them for databases that don't have them yet.
            activity.detail = "Reading the tables' columns"
            try await open.schema.loadDetails(databases)
            let snapshot = open.schema.snapshot
            let tables: [(DatabaseObject, [String])] = databases.compactMap(snapshot.database).flatMap { database in
                database.tables.filter { $0.kind == .table }.compactMap { table in
                    let columns = table.columns.filter { NavigatorSQL.textTypes.contains($0.dataType.lowercased()) }.map(\.name)
                    return columns.isEmpty ? nil : (DatabaseObject(.table, database.name, table.name), columns)
                }
            }
            let opened = try await open.connection.toolsSession()
            session = opened
            noBackslashEscapes = opened.noBackslashEscapes
            for (index, (object, columns)) in tables.enumerated() {
                try Task.checkCancellation()
                activity.progress = Double(index) / Double(max(tables.count, 1))
                activity.detail = "\(index + 1) of \(tables.count): \(object.database).\(object.name)"
                status.stringValue = "Searching \(object.database).\(object.name) (\(index + 1) of \(tables.count))…"
                let sql = NavigatorSQL.countContaining(text, in: object, columns: columns, noBackslashEscapes: noBackslashEscapes)
                let running = Task { try await opened.query(sql) }
                let results = try await withTaskCancellationHandler { try await running.value } onCancel: {
                    Task { _ = try? await opened.cancel() }
                }
                let count = results.first?.rows.flatMap { $0.string(0, 0) }.flatMap { Int($0) } ?? 0
                if count > 0 {
                    matches.append(Match(table: object, columns: columns, rows: count))
                    arrange()
                }
            }
            status.stringValue = "\(matches.count) of \(tables.count) tables hold “\(text)”. Double-click one to see its rows."
        } catch {
            let stopped = error is CancellationError || (error as? AirSQLError)?.kind == .cancelled
            status.stringValue = stopped ? "Stopped: \(matches.count) tables with matches so far."
                : "Couldn't search: " + ((error as? AirSQLError)?.message ?? error.localizedDescription)
        }
        status.toolTip = status.stringValue
    }

    /// The result clicked (a double- or right-click), else the selected one.
    private var chosen: Match? { matches[safe: table.clickedRow >= 0 ? table.clickedRow : table.selectedRow] }

    @objc func openMatch(_ sender: Any?) {
        guard let match = chosen, let main = view.window?.windowController as? MainWindowController else { return }
        let condition = NavigatorSQL.contains(searched, columns: match.columns, noBackslashEscapes: noBackslashEscapes)
        main.openTableData(match.table, of: open, condition: condition)
    }

    @objc func openData(_ sender: Any?) {
        guard let match = chosen, let main = view.window?.windowController as? MainWindowController else { return }
        main.openTableData(match.table, of: open)
    }

    @objc func copyName(_ sender: Any?) {
        guard let match = chosen else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SQLQuote.identifier(match.table.database) + "." + SQLQuote.identifier(match.table.name),
                                       forType: .string)
    }

    /// ⌘C: the chosen table's name.
    @objc func copy(_ sender: Any?) { copyName(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == Commands.copy.action else { return true }
        let reason = chosen == nil ? "Select a table in the results first" : nil
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }

    /// A result's menu: its matching rows (what a double-click opens), all its rows, its name.
    private func resultMenu() -> NSMenu {
        let menu = NSMenu(title: "Match")
        let matching = NSMenuItem(title: "Open Matching Rows", action: #selector(openMatch(_:)), keyEquivalent: "")
        matching.toolTip = "Open the table's rows that hold the text"
        menu.addItem(matching)
        menu.add([Commands.openData, Commands.copyName])
        for item in menu.items { item.target = self }
        return menu
    }

    /// The matches in the header's order; what is selected stays selected.
    private func arrange() {
        if let sort = table.sortDescriptors.first, let key = sort.key {
            let chosen = Set(table.selectedRowIndexes.compactMap { matches[safe: $0]?.table })
            matches.sort { a, b in
                let order = key == "rows" ? (a.rows == b.rows ? .orderedSame : a.rows < b.rows ? .orderedAscending : .orderedDescending)
                    : Self.text(a, key).localizedStandardCompare(Self.text(b, key))
                return sort.ascending ? order == .orderedAscending : order == .orderedDescending
            }
            table.reloadData()
            table.selectRowIndexes(IndexSet(matches.indices.filter { chosen.contains(matches[$0].table) }), byExtendingSelection: false)
        } else {
            table.reloadData()
        }
    }

    /// What a column shows for a match.
    private static func text(_ match: Match, _ id: String) -> String {
        switch id {
        case "table": return match.table.database + "." + match.table.name
        case "columns": return match.columns.joined(separator: ", ")
        default: return match.rows.formatted()
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { arrange() }

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let match = matches[safe: row], let id = tableColumn?.identifier.rawValue else { return nil }
        let value = Self.text(match, id)
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = value
        field.alignment = id == "rows" ? .right : .left
        field.font = id == "rows" ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        return field
    }

    func shouldClose(_ answer: @escaping (Bool) -> Void) {
        search?.cancel()
        answer(true)
    }
}
