import AirSQLCore
import AppKit

/// A database or table in the picker, with what the server says about its size.
final class PickerNode {
    let name: String
    let database: String
    /// Rows (a table; approximate for InnoDB) and bytes of data.
    let rows: Int64
    let bytes: Int64
    let isView: Bool
    var tables: [PickerNode] = []
    var included = false
    weak var parent: PickerNode?

    init(name: String, database: String, rows: Int64 = 0, bytes: Int64 = 0, isView: Bool = false) {
        self.name = name
        self.database = database
        self.rows = rows
        self.bytes = bytes
        self.isView = isView
    }

    var isDatabase: Bool { parent == nil }

    /// A database: on when every table is included, mixed when some are.
    var state: NSControl.StateValue {
        guard isDatabase, !tables.isEmpty else { return included ? .on : .off }
        let count = tables.filter(\.included).count
        return count == 0 ? .off : count == tables.count ? .on : .mixed
    }

    /// The databases and tables of a list of information_schema.TABLES rows (schema, name, type, rows, bytes) and the
    /// databases without tables, in order.
    static func databases(_ databases: [String], tables rows: [[String?]]) -> [PickerNode] {
        var byName: [String: PickerNode] = [:]
        let nodes = databases.map { name -> PickerNode in
            let node = PickerNode(name: name, database: name)
            byName[name] = node
            return node
        }
        for row in rows {
            guard row.count >= 5, let schema = row[0], let name = row[1], let database = byName[schema] else { continue }
            let table = PickerNode(name: name, database: schema, rows: Int64(row[3] ?? "") ?? 0, bytes: Int64(row[4] ?? "") ?? 0,
                                   isView: row[2] == "VIEW")
            table.parent = database
            database.tables.append(table)
        }
        return nodes
    }

    /// The SQL that lists them (system databases left out).
    static let listSQL = """
        SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE, TABLE_ROWS, DATA_LENGTH FROM information_schema.TABLES \
        WHERE TABLE_SCHEMA NOT IN ('information_schema', 'performance_schema', 'sys') ORDER BY TABLE_SCHEMA, TABLE_NAME
        """
    static let databasesSQL = """
        SELECT SCHEMA_NAME FROM information_schema.SCHEMATA \
        WHERE SCHEMA_NAME NOT IN ('information_schema', 'performance_schema', 'sys') ORDER BY SCHEMA_NAME
        """
}

/// The databases and tables to include (Export, Copy to Another Server): a checkbox each, a database's ticking all its
/// tables; space ticks the selected rows, a double-click ticks or unticks one, and the right-click menu includes all,
/// none or only the selected rows (plan §2.12, lists in sheets).
@MainActor
final class ObjectPicker: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let outline = PickerOutline()
    let scroll = NSScrollView()
    private(set) var databases: [PickerNode] = []
    /// After each change of what is included.
    var onChange: () -> Void = {}

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.rowHeight = 22
        outline.style = .inset
        outline.allowsMultipleSelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.picker = self
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.setAccessibilityIdentifier("tools.objects")
        outline.toolTip = "Tick what to include; space ticks the selected rows"
        // The rounded box draws the background: no second one inside it.
        outline.backgroundColor = .clear
        scroll.drawsBackground = false
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
    }

    /// The list in a rounded box.
    func view(height: CGFloat) -> NSView {
        let box = SurfaceView(.content, radius: Radius.card, border: .separatorColor)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        scroll.pin(to: box, insets: .all(Radius.card))
        box.heightAnchor.constraint(equalToConstant: height).isActive = true
        return box
    }

    func show(_ databases: [PickerNode], expanding: String?) {
        self.databases = databases
        outline.reloadData()
        if let node = databases.first(where: { $0.name == expanding }) { outline.expandItem(node) }
    }

    var isEnabled: Bool {
        get { outline.isEnabled }
        set {
            outline.isEnabled = newValue
            outline.toolTip = newValue ? "Tick what to include; space ticks the selected rows" : "It is running: wait for it, or Stop it"
            outline.reloadData()
        }
    }

    /// The included tables, by database, in order (a database with all its tables included has them all).
    var included: [(database: String, tables: [String], all: Bool)] {
        databases.compactMap { database in
            let tables = database.tables.filter(\.included).map(\.name)
            let all = database.tables.isEmpty ? database.included : tables.count == database.tables.count
            return tables.isEmpty && !all ? nil : (database.name, tables, all)
        }
    }

    func include(_ node: PickerNode, _ on: Bool) {
        if node.isDatabase {
            node.included = on
            node.tables.forEach { $0.included = on }
        } else {
            node.included = on
            node.parent?.included = node.parent?.state == .on
        }
    }

    private func changed() {
        outline.reloadData()
        onChange()
    }

    /// The rows a command acts on: the clicked row and, when it is selected, the whole selection.
    private var targetNodes: [PickerNode] {
        let clicked = outline.clickedRow
        let rows = clicked >= 0 && !outline.selectedRowIndexes.contains(clicked) ? IndexSet(integer: clicked) : outline.selectedRowIndexes
        return rows.compactMap { outline.item(atRow: $0) as? PickerNode }
    }

    func toggleSelected() {
        let nodes = targetNodes
        guard isEnabled, !nodes.isEmpty else { return }
        let on = !nodes.allSatisfy { $0.state == .on }
        nodes.forEach { include($0, on) }
        changed()
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard outline.clickedRow >= 0 else { return }
        toggleSelected()
    }

    @objc private func boxClicked(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard let node = outline.item(atRow: row) as? PickerNode else { return }
        include(node, node.state != .on)
        changed()
    }

    @objc private func includeAll(_ sender: Any?) {
        databases.forEach { include($0, true) }
        changed()
    }

    @objc private func includeNone(_ sender: Any?) {
        databases.forEach { include($0, false) }
        changed()
    }

    @objc private func includeOnly(_ sender: Any?) {
        let nodes = targetNodes
        databases.forEach { include($0, false) }
        nodes.forEach { include($0, true) }
        changed()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ action: Selector, _ tip: String) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.toolTip = tip
            item.isEnabled = isEnabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        item("Include", #selector(includeSelected(_:)), "Tick the selected rows")
        item("Leave Out", #selector(leaveOutSelected(_:)), "Untick the selected rows")
        item("Include Only These", #selector(includeOnly(_:)), "Tick the selected rows and untick every other")
        menu.addItem(.separator())
        item("Include All", #selector(includeAll(_:)), "Tick every database and table")
        item("Include None", #selector(includeNone(_:)), "Untick everything")
    }

    @objc private func includeSelected(_ sender: Any?) {
        targetNodes.forEach { include($0, true) }
        changed()
    }

    @objc private func leaveOutSelected(_ sender: Any?) {
        targetNodes.forEach { include($0, false) }
        changed()
    }

    // MARK: Data source and rows

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? PickerNode)?.tables.count ?? databases.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? PickerNode)?.tables[index] ?? databases[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? PickerNode)?.tables.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? PickerNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: PickerCell.id, owner: nil) as? PickerCell ?? PickerCell()
        cell.name.stringValue = node.name
        cell.name.toolTip = node.name
        cell.name.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        cell.box.setAccessibilityLabel(node.name)
        cell.box.allowsMixedState = node.isDatabase
        cell.box.state = node.state
        cell.box.isEnabled = isEnabled
        cell.box.target = self
        cell.box.action = #selector(boxClicked(_:))
        cell.box.setAccessibilityIdentifier("tools.include." + node.name)
        cell.box.toolTip = node.isDatabase ? "Include every table of \(node.name)" : "Include \(node.name)"
        cell.detail.stringValue = node.isDatabase ? Self.count(node.tables.count, "table")
            : node.isView ? "view" : Self.compact(node.rows) + " rows"
        cell.detail.toolTip = node.isDatabase ? nil : node.isView ? "A view: its definition is exported, not rows"
            : "About \(node.rows) rows, \(ToolSheet.bytes(node.bytes)) of data"
        return cell
    }

    static func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number == 1 ? "" : "s")" }

    /// 412 K, 2.4 M.
    static func compact(_ number: Int64) -> String {
        switch number {
        case ..<1_000: return "\(number)"
        case ..<1_000_000: return String(format: number < 10_000 ? "%.1f K" : "%.0f K", Double(number) / 1_000)
        default: return String(format: number < 10_000_000 ? "%.1f M" : "%.0f M", Double(number) / 1_000_000)
        }
    }
}

/// The picker's outline: space ticks the selected rows.
final class PickerOutline: NSOutlineView {
    weak var picker: ObjectPicker?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            MainActor.assumeIsolated { picker?.toggleSelected() }
        } else {
            super.keyDown(with: event)
        }
    }
}

/// A row: the checkbox, the name (shortened with an ellipsis when long, whole in its tooltip) and the size at the end.
final class PickerCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("pickerCell")
    let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let name = label("", truncates: true)
    let detail = label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        box.translatesAutoresizingMaskIntoConstraints = false
        [box, name, detail].forEach(addSubview)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: Spacing.half),
            name.firstBaselineAnchor.constraint(equalTo: detail.firstBaselineAnchor),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: Spacing.unit),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.half),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
