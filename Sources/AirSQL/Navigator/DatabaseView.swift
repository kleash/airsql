import AirSQLCore
import AppKit

/// The database view (scope "nav"): a database's objects, its tables with their rows, sizes, engine, collation and last update, from
/// the statistics read when it shows (and on Refresh). A click selects, a double-click opens the table's data, a
/// right-click opens the table menu; ⌘ and ⇧ select several for the bulk commands; the headers sort and their menu shows
/// or hides columns.
@MainActor
final class DatabaseViewController: NSViewController, TabContent, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuItemValidation, NSSearchFieldDelegate {
    let open: OpenConnection
    let database: String
    /// A row: a table, view or sequence, or one of the database's other objects.
    struct Listed: Hashable {
        let name: String
        let kind: DatabaseObject.Kind
        var engine: String?
        var comment = ""
    }

    let table = DatabaseTableView()
    private(set) var rows: [Listed] = []
    private let caption = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    private let spinner = NSProgressIndicator()
    let filter = NSSearchField()
    private let empty = label("", font: .systemFont(ofSize: 13), color: .secondaryLabelColor, wraps: true)
    /// The columns share the view's width down to `minimum`, then it scrolls sideways.
    private static let columns: [(id: String, title: String, width: CGFloat, minimum: CGFloat, tip: String)] = [
        ("name", "Name", 180, 120, "The object's name"), ("type", "Type", 70, 60, "What kind of object it is"), ("rows", "Rows", 80, 60, "About how many rows (InnoDB estimates it)"),
        ("bar", "Space", 110, 60, "Its data, indexes and free space, against the largest table"),
        ("size", "Size", 72, 60, "Its data plus its indexes"),
        ("data", "Data", 72, 60, "Space its rows take"), ("index", "Indexes", 72, 60, "Space its indexes take"),
        ("engine", "Engine", 70, 60, "Its storage engine"), ("collation", "Collation", 140, 130, "How its text compares and sorts"),
        ("updated", "Updated", 140, 135, "When its rows last changed, by the server's clock, where the engine keeps it"),
        ("comment", "Comment", 100, 80, "Its comment"),
        ("free", "Free", 72, 60, "Space kept but unused, which Optimize can give back"),
        ("average", "Average Row", 80, 60, "Its data divided by its rows"),
        ("autoIncrement", "Auto Increment", 90, 60, "The next value of its AUTO_INCREMENT column"),
        ("created", "Created", 140, 135, "When it was made, by the server's clock"),
        ("format", "Row Format", 90, 60, "How its engine stores a row"),
        ("options", "Options", 140, 80, "The options it was made with"),
    ]
    /// Off until the person shows them from the header's menu.
    private static let hiddenColumns: Set<String> = ["data", "index", "free", "average", "autoIncrement", "created", "format", "options"]
    private static let numericColumns: Set<String> = ["rows", "bar", "size", "data", "index", "free", "average", "autoIncrement"]
    /// Space of the largest table shown: what the bars are against.
    private var largest = 1

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
        filter.placeholderString = "Filter by name"
        filter.toolTip = "Type part of a name to show only the tables that have it"
        filter.setAccessibilityIdentifier("database.filter")
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        filter.translatesAutoresizingMaskIntoConstraints = false
        empty.alignment = .center
        empty.menu = NSMenu(title: "Tables")
        empty.menu?.add([Commands.createTable, Commands.diskUsage, Commands.refresh])
        empty.setAccessibilityIdentifier("database.empty")
        empty.translatesAutoresizingMaskIntoConstraints = false
        for column in Self.columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minimum
            tableColumn.headerToolTip = column.tip + "; click to sort by it"
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true)
            if Self.numericColumns.contains(column.id) { tableColumn.headerCell.alignment = .right }
            tableColumn.isHidden = Self.hiddenColumns.contains(column.id)
            table.addTableColumn(tableColumn)
        }
        table.autosaveName = layoutName("Database tables")  // its widths and sort, for next time
        table.autosaveTableColumns = true
        table.addColumnMenu(tip: "Show or hide this column")
        table.style = .fullWidth
        table.stripes = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.centreText(rowHeight: 22)
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
        let help = helpButton(.navigator)
        [title, spinner, caption, filter, help, scroll, empty].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.double),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.unit),  // over the list's text
            spinner.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: Spacing.unit),
            spinner.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            spinner.trailingAnchor.constraint(lessThanOrEqualTo: filter.leadingAnchor, constant: -Spacing.unit),
            filter.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            filter.trailingAnchor.constraint(equalTo: help.leadingAnchor, constant: -Spacing.unit),
            filter.widthAnchor.constraint(equalToConstant: 200),
            help.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            help.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.double),
            caption.topAnchor.constraint(equalTo: title.bottomAnchor, constant: Spacing.half),
            caption.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Spacing.double),
            scroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: Spacing.unit),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -2 * Spacing.double),
        ])
        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: .openConnectionDidChange, object: open)
        reload()
        if open.snapshot.database(database)?.statistics == nil { open.loadStatistics(database) }
    }

    @objc private func changed() { reload() }

    func controlTextDidChange(_ notification: Notification) { reload() }

    /// The columns take the width there is.
    override func viewDidLayout() {
        super.viewDidLayout()
        table.sizeToFit()
    }

    /// Shows the cache's tables again, in the chosen order, keeping the selection.
    func reload() {
        let selected = Set(table.selectedRowIndexes.compactMap { rows[safe: $0] })
        let found = open.snapshot.database(database)
        let text = filter.stringValue.trimmingCharacters(in: .whitespaces)
        let all = found.map(Self.objects) ?? []
        rows = sorted(text.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(text) }, found?.statistics ?? [:])
        largest = max(1, rows.compactMap { Self.stats($0, found?.statistics ?? [:]) }.map(Self.space).max() ?? 1)
        table.reloadData()
        table.selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0]) }), byExtendingSelection: false)
        let loading = open.loading.contains(.statistics(database))
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        var parts = [(text.isEmpty ? "" : "\(rows.count) of ") + "\(all.count) object\(all.count == 1 ? "" : "s")"]
        if let found { parts.append(found.charset + " · " + found.collation) }
        if loading { parts.append("reading sizes…") } else if found?.statistics == nil, let error = open.loadError {
            parts.append("couldn't read sizes: " + error)
        }
        caption.stringValue = found == nil ? "This database isn't on the server any more." : parts.joined(separator: " · ")
        caption.toolTip = caption.stringValue
        empty.stringValue = !rows.isEmpty || found == nil ? ""
            : all.isEmpty ? "No tables yet. Right-click here and choose Create Table…." : "Nothing has “\(text)” in its name."
        empty.isHidden = empty.stringValue.isEmpty
    }

    /// All a table takes, free space included: what its bar is long for.
    private static func space(_ stats: TableStatistics) -> Int { (stats.dataLength ?? 0) + (stats.indexLength ?? 0) + (stats.dataFree ?? 0) }

    private static func averageRow(_ stats: TableStatistics?) -> Int? {
        guard let stats, let rows = stats.rows, rows > 0, let data = stats.dataLength else { return nil }
        return data / rows
    }

    /// Everything in the database: its tables first, as the tree has them.
    private static func objects(_ database: SchemaDatabase) -> [Listed] {
        database.tables.map { table in
            Listed(name: table.name, kind: table.kind == .view ? .view : table.kind == .sequence ? .sequence : .table,
                   engine: table.engine, comment: table.comment)
        }
        + database.routines.map { Listed(name: $0.name, kind: $0.kind == .procedure ? .procedure : .function, comment: $0.comment) }
        + database.triggers.map { Listed(name: $0.name, kind: .trigger) }
        + database.events.map { Listed(name: $0.name, kind: .event, comment: $0.comment) }
    }

    /// Only tables have statistics; a routine may share a table's name.
    private static func stats(_ row: Listed, _ statistics: [String: TableStatistics]) -> TableStatistics? {
        row.kind.isTableLike ? statistics[row.name] : nil
    }

    private func sorted(_ tables: [Listed], _ statistics: [String: TableStatistics]) -> [Listed] {
        guard let sort = table.sortDescriptors.first, let key = sort.key else { return tables }
        func value(_ table: Listed) -> String { text(key, table, Self.stats(table, statistics)) }
        func number(_ table: Listed) -> Int {
            let stats = Self.stats(table, statistics)
            switch key {
            case "rows": return stats?.rows ?? -1
            case "data": return stats?.dataLength ?? -1
            case "index": return stats?.indexLength ?? -1
            case "free": return stats?.dataFree ?? -1
            case "average": return Self.averageRow(stats) ?? -1
            case "autoIncrement": return stats?.autoIncrement.map { Int(clamping: $0) } ?? -1
            default: return stats.map { ($0.dataLength ?? 0) + ($0.indexLength ?? 0) } ?? -1  // the bar and Size
            }
        }
        let numeric = Self.numericColumns.contains(key)
        return tables.sorted { first, second in
            let ordered = numeric ? number(first) < number(second)
                : value(first).localizedStandardCompare(value(second)) == .orderedAscending
            return sort.ascending ? ordered : !ordered && (numeric ? number(first) != number(second) : value(first) != value(second))
        }
    }

    private func text(_ column: String, _ table: Listed, _ stats: TableStatistics?) -> String {
        switch column {
        case "name": return table.name
        case "type": return table.kind.noun
        case "rows": return table.kind == .view ? "view" : stats?.rows.map { $0.formatted() } ?? ""
        case "data": return DiskUsage.size(stats?.dataLength)
        case "index": return DiskUsage.size(stats?.indexLength)
        case "size": return DiskUsage.size(stats.map { ($0.dataLength ?? 0) + ($0.indexLength ?? 0) })
        case "free": return DiskUsage.size(stats?.dataFree)
        case "average": return DiskUsage.size(Self.averageRow(stats))
        case "autoIncrement": return stats?.autoIncrement.map { $0.formatted() } ?? ""
        case "created": return stats?.createTime ?? ""
        case "format": return stats?.rowFormat ?? ""
        case "options": return stats?.createOptions ?? ""
        case "engine": return table.engine ?? ""
        case "collation": return stats?.collation ?? ""
        case "updated": return stats?.updateTime ?? ""
        default: return table.comment
        }
    }

    /// The selected tables, as the commands take them.
    var selectedObjects: [DatabaseObject] {
        table.selectedRowIndexes.compactMap { rows[safe: $0] }.map { DatabaseObject($0.kind, database, $0.name) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, let schemaTable = rows[safe: row] else { return nil }
        if id == "bar" {
            let stats = Self.stats(schemaTable, open.snapshot.database(database)?.statistics ?? [:])
            let bar = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell.bar"), owner: nil) as? SizeBar ?? SizeBar()
            bar.identifier = NSUserInterfaceItemIdentifier("cell.bar")
            bar.parts = SizeBar.Parts(data: Double(stats?.dataLength ?? 0) / Double(largest), index: Double(stats?.indexLength ?? 0) / Double(largest),
                                      free: Double(stats?.dataFree ?? 0) / Double(largest))
            bar.toolTip = stats.map { "\(DiskUsage.size($0.dataLength ?? 0)) data, \(DiskUsage.size($0.indexLength ?? 0)) indexes, "
                + "\(DiskUsage.size($0.dataFree ?? 0)) free" }
            return bar
        }
        let field = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell." + id), owner: nil) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        field.identifier = NSUserInterfaceItemIdentifier("cell." + id)
        field.lineBreakMode = .byTruncatingTail
        let value = text(id, schemaTable, Self.stats(schemaTable, open.snapshot.database(database)?.statistics ?? [:]))
        field.stringValue = value
        field.toolTip = value.isEmpty ? nil : value
        field.alignment = Self.numericColumns.contains(id) ? .right : .left
        field.font = Self.numericColumns.contains(id) ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
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
        guard !selectedObjects.isEmpty else { return empty.menu }
        let menu = NSMenu(title: "Table")
        guard selectedObjects.allSatisfy(\.kind.isTableLike) else {
            menu.add([Commands.openObject, Commands.copyName, Commands.copyPlainName, Commands.copyCreate, nil, Commands.drop, nil, Commands.refresh])
            return menu
        }
        menu.add([Commands.openData, Commands.openStructure, Commands.selectTop, Commands.copyName, Commands.copyPlainName, Commands.copyCreate, nil,
                  Commands.generateSelect, Commands.generateInsert, Commands.generateUpdate, nil, Commands.export, Commands.copyTable, Commands.bulkEdit])
        menu.addItem(NavigatorMenus.maintenance())
        menu.add([nil, Commands.truncate, Commands.rename, Commands.drop, nil, Commands.diskUsage, Commands.refresh])
        return menu
    }

    // MARK: Commands

    /// The selected table's indexes and partitions; with none or several selected, the database's tables.
    @objc func showDiskUsage(_ sender: Any?) {
        let one = selectedObjects.count == 1 ? selectedObjects[0] : nil
        (view.window?.windowController as? MainWindowController)?.showDiskUsage(
            open, level: one.map { .table($0.database, $0.name) } ?? .database(database))
    }

    @objc func openData(_ sender: Any?) {
        guard let main = view.window?.windowController as? MainWindowController else { return }
        for object in selectedObjects {
            if object.kind.isTableLike { main.openTableData(object, of: open) } else { main.openEditor(object, of: open) }
        }
    }

    @objc func openObject(_ sender: Any?) { openStructure(sender) }

    @objc func selectTop(_ sender: Any?) {
        NavigatorActions.selectTop(selectedObjects, on: open, main: view.window?.windowController as? MainWindowController)
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

    @objc func copyPlainName(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedObjects.map(\.name).joined(separator: ", "), forType: .string)
    }

    @objc func copyCreateStatement(_ sender: Any?) {
        if let first = selectedObjects.first { NavigatorActions.copyCreate(first, on: open, window: view.window) }
    }

    /// ⌘C: the selected tables' names.
    @objc func copy(_ sender: Any?) { copyName(sender) }

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

    /// F2: Rename… the selected table or view.
    @objc func renameSelection(_ sender: Any?) { renameObject(sender) }

    @objc func dropObject(_ sender: Any?) { NavigatorActions.drop(selectedObjects, on: open, window: view.window) }

    @objc func refresh(_ sender: Any?) {
        open.refresh([.database(database)])
        open.loadStatistics(database)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let aliases = [Commands.renameF2.action: Commands.rename.action, Commands.copy.action: Commands.copyName.action]
        let reason = [Commands.refresh.action, Commands.diskUsage.action].contains(item.action) ? nil
            : NavigatorActions.reason(for: item.action.flatMap { aliases[$0] } ?? item.action,
                                      objects: selectedObjects, databases: [], open: open, target: open, model: open.model)
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }
}

/// The database view's table: a right-click selects the row under the pointer first and opens the table menu; Return
/// opens, Delete drops.
@MainActor
final class DatabaseTableView: ContentTable {
    weak var owner: DatabaseViewController?

    override func menu(for event: NSEvent) -> NSMenu? {
        if !selectsRow(for: event) { deselectAll(nil) }
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
