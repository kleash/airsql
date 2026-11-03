import AirSQLCore
import AppKit

/// The database view (scope "nav"): a database's tables with their rows, sizes, engine, collation and last update, from
/// the statistics read when it shows (and on Refresh). A click selects, a double-click opens the table's data, a
/// right-click opens the table menu; ⌘ and ⇧ select several for the bulk commands; the headers sort.
@MainActor
final class DatabaseViewController: NSViewController, TabContent, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuItemValidation {
    let open: OpenConnection
    let database: String
    let table = DatabaseTableView()
    private(set) var rows: [SchemaTable] = []
    private let caption = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    private let spinner = NSProgressIndicator()
    /// The columns share the view's width down to `minimum`, then it scrolls sideways.
    private static let columns: [(id: String, title: String, width: CGFloat, minimum: CGFloat, tip: String)] = [
        ("name", "Name", 180, 120, "The table's name"), ("rows", "Rows", 80, 60, "About how many rows (InnoDB estimates it)"),
        ("data", "Data", 72, 60, "Space its rows take"), ("index", "Indexes", 72, 60, "Space its indexes take"),
        ("engine", "Engine", 70, 60, "Its storage engine"), ("collation", "Collation", 130, 110, "How its text compares and sorts"),
        ("updated", "Updated", 130, 120, "When its rows last changed, where the engine keeps it"),
        ("comment", "Comment", 200, 80, "Its comment"),
    ]

    init(_ open: OpenConnection, _ database: String) {
        self.open = open
        self.database = database
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = SurfaceView(.content)
        root.setAccessibilityIdentifier("database")
        let title = label(database, font: .systemFont(ofSize: 15, weight: .semibold), truncates: true)
        title.toolTip = database
        caption.setAccessibilityIdentifier("database.caption")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.setAccessibilityLabel("Loading")
        for column in Self.columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minimum
            tableColumn.headerToolTip = column.tip + "; click to sort by it"
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true)
            if ["rows", "data", "index"].contains(column.id) { tableColumn.headerCell.alignment = .right }
            table.addTableColumn(tableColumn)
        }
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openData(_:))
        table.owner = self
        table.setAccessibilityIdentifier("database.tables")
        table.setAccessibilityLabel("Tables of \(database)")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        [title, spinner, caption, scroll].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.double),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.double),
            spinner.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: Spacing.unit),
            spinner.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            spinner.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Spacing.double),
            caption.topAnchor.constraint(equalTo: title.bottomAnchor, constant: Spacing.half),
            caption.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Spacing.double),
            scroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: Spacing.unit),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: .openConnectionDidChange, object: open)
        reload()
        if open.snapshot.database(database)?.statistics == nil { open.loadStatistics(database) }
    }

    @objc private func changed() { reload() }

    /// The columns take the width there is.
    override func viewDidLayout() {
        super.viewDidLayout()
        table.sizeToFit()
    }

    /// Shows the cache's tables again, in the chosen order, keeping the selection.
    func reload() {
        let selected = Set(table.selectedRowIndexes.compactMap { rows[safe: $0]?.name })
        let found = open.snapshot.database(database)
        rows = sorted(found?.tables ?? [], found?.statistics ?? [:])
        table.reloadData()
        table.selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0].name) }), byExtendingSelection: false)
        let loading = open.loading.contains(.statistics(database))
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        var parts = ["\(rows.count) table\(rows.count == 1 ? "" : "s") and views"]
        if let found { parts.append(found.charset + " · " + found.collation) }
        if loading { parts.append("reading sizes…") } else if found?.statistics == nil, let error = open.loadError {
            parts.append("couldn't read sizes: " + error)
        }
        caption.stringValue = found == nil ? "This database isn't on the server any more." : parts.joined(separator: " · ")
        caption.toolTip = caption.stringValue
    }

    private func sorted(_ tables: [SchemaTable], _ statistics: [String: TableStatistics]) -> [SchemaTable] {
        guard let sort = table.sortDescriptors.first, let key = sort.key else { return tables }
        func value(_ table: SchemaTable) -> String { text(key, table, statistics[table.name]) }
        func number(_ table: SchemaTable) -> Int {
            let stats = statistics[table.name]
            switch key {
            case "rows": return stats?.rows ?? -1
            case "data": return stats?.dataLength ?? -1
            default: return stats?.indexLength ?? -1
            }
        }
        let numeric = ["rows", "data", "index"].contains(key)
        return tables.sorted { first, second in
            let ordered = numeric ? number(first) < number(second)
                : value(first).localizedStandardCompare(value(second)) == .orderedAscending
            return sort.ascending ? ordered : !ordered && (numeric ? number(first) != number(second) : value(first) != value(second))
        }
    }

    private func text(_ column: String, _ table: SchemaTable, _ stats: TableStatistics?) -> String {
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        bytes.allowsNonnumericFormatting = false  // 0 KB, not Zero KB
        bytes.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        switch column {
        case "name": return table.name
        case "rows": return table.kind == .view ? "view" : stats?.rows.map { $0.formatted() } ?? ""
        case "data": return stats?.dataLength.map { bytes.string(fromByteCount: Int64($0)) } ?? ""
        case "index": return stats?.indexLength.map { bytes.string(fromByteCount: Int64($0)) } ?? ""
        case "engine": return table.engine ?? ""
        case "collation": return stats?.collation ?? ""
        case "updated": return stats?.updateTime ?? ""
        default: return table.comment
        }
    }

    /// The selected tables, as the commands take them.
    var selectedObjects: [DatabaseObject] {
        table.selectedRowIndexes.compactMap { rows[safe: $0] }.map { table in
            DatabaseObject(table.kind == .view ? .view : table.kind == .sequence ? .sequence : .table, database, table.name)
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, let schemaTable = rows[safe: row] else { return nil }
        let field = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell." + id), owner: nil) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        field.identifier = NSUserInterfaceItemIdentifier("cell." + id)
        field.lineBreakMode = .byTruncatingTail
        let value = text(id, schemaTable, open.snapshot.database(database)?.statistics?[schemaTable.name])
        field.stringValue = value
        field.toolTip = value.isEmpty ? nil : value
        field.alignment = ["rows", "data", "index"].contains(id) ? .right : .left
        field.font = ["rows", "data", "index"].contains(id) ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12, weight: id == "name" ? .medium : .regular)
        field.textColor = id == "name" ? .labelColor : .secondaryLabelColor
        return field
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { reload() }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        rows[safe: row]?.name
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let name = rows[safe: row]?.name else { return nil }
        let item = NSPasteboardItem()
        item.setString(SQLQuote.identifier(name), forType: .string)
        return item
    }

    func contextMenu() -> NSMenu? {
        guard !selectedObjects.isEmpty else { return nil }
        let menu = NSMenu(title: "Table")
        menu.add([Commands.openData, Commands.openStructure, Commands.copyName, nil, Commands.generateSelect,
                  Commands.generateInsert, Commands.generateUpdate, nil, Commands.export, Commands.copyTable, Commands.bulkEdit])
        menu.addItem(NavigatorMenus.maintenance())
        menu.add([nil, Commands.truncate, Commands.rename, Commands.drop, nil, Commands.refresh])
        return menu
    }

    // MARK: Commands

    @objc func openData(_ sender: Any?) {
        guard let main = view.window?.windowController as? MainWindowController else { return }
        for object in selectedObjects { main.openTableData(object, of: open) }
    }

    @objc func openStructure(_ sender: Any?) {
        guard let main = view.window?.windowController as? MainWindowController else { return }
        for object in selectedObjects { main.openEditor(object, of: open) }
    }

    @objc func generateSelect(_ sender: Any?) { generate(.select) }
    @objc func generateInsert(_ sender: Any?) { generate(.insert) }
    @objc func generateUpdate(_ sender: Any?) { generate(.update) }

    private func generate(_ kind: NavigatorActions.Generated) {
        NavigatorActions.generate(kind, selectedObjects, on: open, main: view.window?.windowController as? MainWindowController)
    }

    @objc func copyName(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedObjects.map { SQLQuote.identifier($0.name) }.joined(separator: ", "), forType: .string)
    }

    @objc func copyTable(_ sender: Any?) {
        if let first = selectedObjects.first { NavigatorActions.copyTable(first, on: open, window: view.window) }
    }

    @objc func bulkEditTables(_ sender: Any?) { NavigatorActions.bulkEdit(selectedObjects, on: open, window: view.window) }

    @objc func runMaintenance(_ sender: Any?) {
        guard let operation = NavigatorMenus.operation(sender) else { return }
        NavigatorActions.maintain(selectedObjects, operation, on: open, main: view.window?.windowController as? MainWindowController)
    }

    @objc func truncateTable(_ sender: Any?) { NavigatorActions.truncate(selectedObjects, on: open, window: view.window) }

    @objc func renameObject(_ sender: Any?) {
        if let first = selectedObjects.first { NavigatorActions.rename(first, on: open, window: view.window) }
    }

    @objc func dropObject(_ sender: Any?) { NavigatorActions.drop(selectedObjects, on: open, window: view.window) }

    @objc func refresh(_ sender: Any?) {
        open.refresh([.database(database)])
        open.loadStatistics(database)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let reason = item.action == Commands.refresh.action ? nil
            : NavigatorActions.reason(for: item.action, objects: selectedObjects, databases: [], open: open, target: open,
                                      model: open.model)
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }
}

/// The database view's table: a right-click selects the row under the pointer first and opens the table menu; Return
/// opens, Delete drops.
@MainActor
final class DatabaseTableView: NSTableView {
    weak var owner: DatabaseViewController?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        window?.makeFirstResponder(self)
        return owner?.contextMenu()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: owner?.openData(self)
        case 51, 117: if !selectedRowIndexes.isEmpty { sendCommand(Commands.drop.action) }
        default: super.keyDown(with: event)
        }
    }
}
