import AirSQLCore
import AppKit

/// Disk Usage (scope "server"): where the space went, as sorted bars. On a server, every database; a double-click goes
/// into a database's tables, and into a table's indexes and partitions. Sizes come from the schema cache's statistics,
/// which `OpenConnection.readSizes` fills one database at a time, in the background, with Cancel.
@MainActor
final class DiskUsageContent: NSViewController, TabContent, NSMenuItemValidation {
    enum Level: Hashable {
        case server, database(String), table(String, String)
    }

    let open: OpenConnection
    private(set) var level: Level
    /// Compare Selected: only these rows, whose bars and shares are then of each other.
    private(set) var compared: Set<String>?
    private(set) var tableRows: [DiskUsageRow] = []
    private let heading = label("", font: .systemFont(ofSize: 15, weight: .semibold), truncates: true)
    private let notice = label("InnoDB's sizes and row counts are estimates. This shows only what this login can see, and the "
                               + "databases this connection lists.", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    let summary = label("", font: .systemFont(ofSize: 11.5), truncates: true)
    private let spinner = NSProgressIndicator()
    private(set) lazy var back = button("Back", id: "disk.back", tip: Commands.diskUsageUp.tip, target: self, action: #selector(goUp(_:)))
    private(set) lazy var refreshButton = button("Refresh", id: "disk.refresh", tip: Commands.refresh.tip + " (⌘R)", target: self,
                                                 action: #selector(refresh(_:)))
    private(set) lazy var stopButton = button("Stop", id: "disk.stop", tip: "Stop reading sizes; what was read stays", target: self,
                                              action: #selector(stop(_:)))
    private(set) lazy var compareButton = button("Compare Selected", id: "disk.compare", tip: Commands.diskUsageCompare.tip, target: self,
                                                 action: #selector(compareSelected(_:)))
    private(set) lazy var optimizeButton = button("Optimize…", id: "disk.optimize", tip: "", target: self, action: #selector(optimize(_:)))
    private(set) lazy var list = HostList(
        name: "Disk Usage",
        columns: [
            .init(id: "name", title: "Name", width: 220, tip: "The database, table, index or partition"),
            .init(id: "bar", title: "Space", width: 200, tip: "Data, indexes and free space, against the largest row", bar: true),
            .init(id: "total", title: "Size", width: 80, numeric: true, tip: "Data plus indexes"),
            .init(id: "share", title: "Share", width: 64, numeric: true, tip: "Its part of the size of all the rows listed"),
            .init(id: "data", title: "Data", width: 80, numeric: true, tip: "Space its rows take"),
            .init(id: "index", title: "Indexes", width: 80, numeric: true, tip: "Space its indexes take"),
            .init(id: "free", title: "Free", width: 80, numeric: true,
                  tip: "Space kept but unused; Optimize can give it back (a shared tablespace shows it on every table)"),
            .init(id: "rows", title: "Rows", width: 90, numeric: true, tip: "About how many rows (InnoDB estimates it)"),
            .init(id: "detail", title: "Kind", width: 140, tip: "How many tables, the engine, or what it is"),
        ],
        sort: NSSortDescriptor(key: "total", ascending: false),
        accessories: [back, compareButton, optimizeButton, refreshButton, stopButton])

    init(_ open: OpenConnection, level: Level = .server) {
        self.open = open
        self.level = level
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = SurfaceView(.content)
        root.setAccessibilityIdentifier("disk")
        heading.setAccessibilityIdentifier("disk.heading")
        notice.toolTip = notice.stringValue
        notice.setAccessibilityIdentifier("disk.notice")
        summary.setAccessibilityIdentifier("disk.summary")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Reading sizes")
        let help = helpButton(.navigator)
        let top = NSStackView(views: [heading, spinner, NSView(), help])
        top.spacing = Spacing.unit
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let texts = NSStackView(views: [top, notice, summary])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = Spacing.half
        texts.translatesAutoresizingMaskIntoConstraints = false
        addChild(list)
        list.view.translatesAutoresizingMaskIntoConstraints = false
        list.onOpen = { [weak self] in self?.open($0) }
        list.onMenu = { [weak self] in self?.contextMenu() }
        list.onSelect = { [weak self] in self?.updateState() }
        [texts, list.view].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            top.widthAnchor.constraint(equalTo: texts.widthAnchor),
            texts.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.double),
            texts.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.double),
            texts.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.double),
            list.view.topAnchor.constraint(equalTo: texts.bottomAnchor, constant: Spacing.unit),
            list.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: .openConnectionDidChange, object: open)
        enter()
    }

    @objc private func changed() { reload() }

    /// Shows the level, reading what it needs and hasn't got.
    private func enter() {
        compared = nil
        tableRows = []
        list.table.deselectAll(nil)
        list.filter.stringValue = ""
        reload()
        switch level {
        case .server: open.readSizes(unread)
        case .database(let name): if unread.contains(name) { open.readSizes([name]) }
        case .table(let database, let name):
            if unread.contains(database) { open.readSizes([database]) }
            readParts(of: DatabaseObject(.table, database, name))
        }
    }

    /// Databases of this level with no sizes yet.
    private var unread: [String] { open.snapshot.databases.filter { $0.statistics == nil }.map(\.name) }

    /// A table's indexes and partitions, read through the schema session: one table, so quick. Indexes keep their names
    /// when the login may not read their sizes.
    private func readParts(of table: DatabaseObject) {
        let wanted = level
        let names = open.snapshot.table(table.database, table.name)?.indexes.map(\.name) ?? []
        Task { [weak self, connection = open.connection] in
            var found: [DiskUsageRow] = []
            var note: String?
            do {
                let session = try await connection.session(.schema)
                let quoting = session.noBackslashEscapes
                let sizes = try? await session.rows(DiskUsage.indexSizesSQL(table, noBackslashEscapes: quoting))
                if sizes == nil { note = "This login can't read mysql.innodb_index_stats, so indexes show no size" }
                found = DiskUsage.indexes(names, sizes: sizes ?? [])
                found += DiskUsage.partitions(try await session.rows(DiskUsage.partitionsSQL(table, noBackslashEscapes: quoting)))
            } catch {
                note = "Couldn't read its indexes and partitions: " + error.localizedDescription
            }
            guard let self, self.level == wanted else { return }
            self.tableRows = found
            self.partsNote = note
            self.reload()
        }
    }

    private var partsNote: String?

    /// The figures of the level, as the list shows them.
    var figures: [DiskUsageRow] {
        let snapshot = open.snapshot
        let rows: [DiskUsageRow]
        switch level {
        case .server: rows = DiskUsage.databases(snapshot)
        case .database(let name): rows = snapshot.database(name).map(DiskUsage.tables) ?? []
        case .table: rows = tableRows
        }
        return compared.map { names in rows.filter { names.contains($0.name) } } ?? rows
    }

    /// Shows the cache's figures again, keeping the selection and the order.
    func reload() {
        let rows = figures
        let largest = rows.map { ($0.total ?? 0) + ($0.free ?? 0) }.max() ?? 0
        let whole = rows.reduce(0) { $0 + ($1.total ?? 0) }
        list.show(rows.map { row in
            let scale = Double(max(largest, 1))
            var numbers: [String: Double] = [:]
            for (id, value) in [("total", row.total), ("bar", row.total), ("share", row.total), ("data", row.data),
                                ("index", row.index), ("free", row.free), ("rows", row.rows)] {
                if let value { numbers[id] = Double(value) }
            }
            let size = DiskUsage.size(row.total)
            return HostList.Row(key: row.name, cells: [
                "name": row.name, "detail": row.detail, "total": size, "share": DiskUsage.share(row.total, of: whole),
                "data": DiskUsage.size(row.data), "index": DiskUsage.size(row.index), "free": DiskUsage.size(row.free),
                "rows": row.rows?.formatted() ?? "",
                "bar": row.total == nil ? "" : "\(size) (\(DiskUsage.size(row.data)) data, \(DiskUsage.size(row.index)) indexes, "
                    + "\(DiskUsage.size(row.free ?? 0)) free)",
            ], numbers: numbers, bars: ["bar": SizeBar.Parts(data: Double(row.data ?? 0) / scale, index: Double(row.index ?? 0) / scale,
                                                             free: Double(row.free ?? 0) / scale)])
        })
        updateState()
    }

    /// What depends on the level, the reading and the selection: the heading, the buttons and the summary.
    private func updateState() {
        let reading = open.sizesProgress
        if reading != nil { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        stopButton.isEnabled = reading != nil
        stopButton.toolTip = reading != nil ? "Stop reading sizes; what was read stays" : "Nothing is being read"
        back.isHidden = level == .server
        compareButton.title = compared == nil ? "Compare Selected" : "Show All"
        let compareReason = reason(Commands.diskUsageCompare.action)
        compareButton.isEnabled = compareReason == nil
        compareButton.toolTip = compareReason ?? Commands.diskUsageCompare.tip
        optimizeButton.isHidden = level == .server
        let optimizeReason = reason(Commands.maintenance.action)
        optimizeButton.isEnabled = optimizeReason == nil
        optimizeButton.toolTip = optimizeReason ?? "Rebuild the selected tables to give their free space back (shows the SQL first)"
        let name = open.model?.connection(open.id)?.displayName ?? "Server"
        switch level {
        case .server: heading.stringValue = "Disk Usage · \(name)"
        case .database(let database): heading.stringValue = "Disk Usage · \(database)"
        case .table(let database, let table): heading.stringValue = "Disk Usage · \(database).\(table)"
        }
        heading.toolTip = heading.stringValue
        list.note = note(reading)
        let chosen = Set(list.selected.map(\.key))
        summary.stringValue = chosen.count > 1 ? DiskUsage.summary(figures.filter { chosen.contains($0.name) })
            : "Total \(DiskUsage.size(figures.reduce(0) { $0 + ($1.total ?? 0) })), \(DiskUsage.size(figures.reduce(0) { $0 + ($1.free ?? 0) })) free"
        summary.toolTip = summary.stringValue
    }

    private func note(_ reading: (done: Int, of: Int, database: String)?) -> String {
        if let reading { return "reading \(reading.database) (\(reading.done + 1) of \(reading.of))…" }
        if let error = open.sizesError { return "couldn't read every size: " + error }
        if case .table = level {
            return partsNote ?? (tableRows.isEmpty ? "No indexes or partitions to show." : "indexes and partitions")
        }
        let left = unread.count
        if case .server = level, left > 0 { return "\(left) not read yet: press Refresh" }
        return ""
    }

    /// The tables selected at a database's level, or the table a table's level shows, as the commands take them.
    var selectedObjects: [DatabaseObject] {
        func object(_ database: String, _ name: String) -> DatabaseObject {
            DatabaseObject(open.snapshot.table(database, name)?.kind == .sequence ? .sequence : .table, database, name)
        }
        switch level {
        case .server: return []
        case .database(let database): return list.selected.map { object(database, $0.key) }
        case .table(let database, let name): return [object(database, name)]
        }
    }

    // MARK: Commands

    private func open(_ row: HostList.Row) {
        switch level {
        case .server: go(.database(row.key))
        case .database(let database): go(.table(database, row.key))
        case .table: openStructure(nil)
        }
    }

    /// Goes to `level`: from the row double-clicked, or from a menu in the tree.
    func go(_ level: Level) {
        self.level = level
        if isViewLoaded { enter() }
    }

    @objc func goUp(_ sender: Any?) {
        switch level {
        case .server: break
        case .database: go(.server)
        case .table(let database, _): go(.database(database))
        }
    }

    /// Disk Usage on a selected row goes into it.
    @objc func showDiskUsage(_ sender: Any?) {
        if let row = list.selected.first { open(row) }
    }

    @objc func compareSelected(_ sender: Any?) {
        compared = compared == nil ? Set(list.selected.map(\.key)) : nil
        reload()
    }

    @objc private func stop(_ sender: Any?) { open.stopReadingSizes() }

    @objc func refresh(_ sender: Any?) {
        switch level {
        case .server: open.readSizes(open.snapshot.databases.map(\.name))
        case .database(let name): open.readSizes([name])
        case .table(let database, let name):
            open.readSizes([database])
            readParts(of: DatabaseObject(.table, database, name))
        }
    }

    @objc func copyList(_ sender: Any?) { list.copyList(sender) }
    @objc func exportList(_ sender: Any?) { list.exportList(sender) }

    @objc func optimize(_ sender: Any?) {
        NavigatorActions.maintain(selectedObjects, .optimize, on: open, main: view.window?.windowController as? MainWindowController)
    }

    @objc func runMaintenance(_ sender: Any?) {
        guard let operation = NavigatorMenus.operation(sender) else { return }
        NavigatorActions.maintain(selectedObjects, operation, on: open, main: view.window?.windowController as? MainWindowController)
    }

    @objc func openData(_ sender: Any?) {
        guard let main = view.window?.windowController as? MainWindowController else { return }
        for object in selectedObjects { main.openTableData(object, of: open) }
    }

    @objc func openStructure(_ sender: Any?) {
        guard let main = view.window?.windowController as? MainWindowController else { return }
        for object in selectedObjects { main.openEditor(object, of: open) }
    }

    private func contextMenu() -> NSMenu? {
        let menu = NSMenu(title: "Disk Usage")
        if !list.selected.isEmpty, level == .server || selectedObjects.isEmpty == false {
            if case .table = level {} else { menu.add([Commands.diskUsage]) }
            if level != .server {
                menu.add([Commands.openData, Commands.openStructure])
                menu.addItem(NavigatorMenus.maintenance())
            }
            menu.add([Commands.diskUsageCompare, Commands.copy, nil])
        }
        menu.add([Commands.copyList, Commands.exportList, nil, Commands.refresh])
        return menu
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let reason = reason(item.action)
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }

    /// Why a command can't act now; nil: it can.
    private func reason(_ action: Selector?) -> String? {
        switch action {
        case Commands.diskUsageUp.action?:
            return level == .server ? "This is the top: every database of the server" : nil
        case Commands.diskUsage.action?:
            if case .table = level { return "A table's indexes and partitions have nothing under them" }
            return list.selected.isEmpty ? "Select a row first" : nil
        case Commands.diskUsageCompare.action?:
            return compared != nil || list.selected.count > 1 ? nil : "Select two or more rows first"
        case Commands.copy.action?:
            return list.selected.isEmpty ? "Select some rows first" : nil
        case Commands.maintenance.action?, Commands.openData.action?, Commands.openStructure.action?:
            return NavigatorActions.reason(for: action, objects: selectedObjects, databases: [], open: open, target: open, model: open.model)
        default:
            return nil
        }
    }
}

extension MainWindowController {
    /// Shows `level` in the connection's Disk Usage tab, made the first time.
    func showDiskUsage(_ open: OpenConnection, level: DiskUsageContent.Level) {
        if let tab = tabs.first(where: { ($0.content as? DiskUsageContent)?.open === open }), let content = tab.content as? DiskUsageContent {
            select(tab)
            content.go(level)
        } else {
            self.open(DiskUsageContent(open, level: level), title: "Disk Usage", connection: open.id)
        }
    }
}
