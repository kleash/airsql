import AirSQLCore
import AppKit

/// The query helpers beside the editor (plan §2.6, View ▸ Query Helpers): the columns of the tables the statement at
/// the cursor names (else the database's tables), the server's functions by kind, and the keywords; the filter
/// narrows them. A click selects one, a double-click puts it in the editor at the cursor, a right-click inserts or
/// copies it.
@MainActor
final class HelpersPanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private enum Row {
        case heading(String)
        case item(label: String, detail: String, insert: String)
    }

    let choice = NSSegmentedControl(labels: ["Columns", "Functions", "Keywords"], trackingMode: .selectOne, target: nil, action: nil)
    private let filter = NSSearchField()
    let table = NSTableView()
    private var rows: [Row] = []
    /// What the panel shows for the statement at the cursor: its tables' columns, and the server.
    var source: (() -> (columns: [(table: String, columns: [SchemaColumn])], server: SchemaServer?))?
    /// Puts text in the editor at the cursor.
    var insert: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        choice.selectedSegment = 0
        choice.target = self
        choice.action = #selector(reload)
        choice.toolTip = "Show the statement's columns, the server's functions or the keywords"
        choice.setAccessibilityIdentifier("helpers.choice")
        filter.placeholderString = "Filter"
        filter.toolTip = "Type part of a name to narrow the list"
        filter.delegate = self
        filter.setAccessibilityIdentifier("helpers.filter")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(insertSelected(_:))
        table.menu = NSMenu(title: "Helper")
        table.menu?.delegate = self
        table.setAccessibilityIdentifier("helpers.list")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let background = SurfaceView(.side)
        for view in [background, choice, filter, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        background.pin(to: self)
        NSLayoutConstraint.activate([
            choice.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.unit),
            choice.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.unit),
            choice.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.unit),
            filter.topAnchor.constraint(equalTo: choice.bottomAnchor, constant: Spacing.unit),
            filter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.unit),
            filter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.unit),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: Spacing.half),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        setAccessibilityIdentifier("console.helpers")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Lists again what the chosen part shows.
    @objc func reload() {
        let words = filter.stringValue.lowercased()
        func keep(_ name: String) -> Bool { words.isEmpty || name.lowercased().contains(words) }
        let given = source?() ?? (columns: [], server: nil)
        rows = []
        switch choice.selectedSegment {
        case 0:
            for (table, columns) in given.columns {
                let kept = columns.filter { keep($0.name) }
                guard !kept.isEmpty else { continue }
                rows.append(.heading(table))
                rows += kept.map { .item(label: $0.name, detail: $0.columnType, insert: SQLCompletion.quote($0.name)) }
            }
        case 1:
            let functions = SQLFunction.all.filter { $0.available(on: given.server) && keep($0.name) }
            for group in SQLFunction.Group.allCases {
                let inGroup = functions.filter { $0.group == group }
                guard !inGroup.isEmpty else { continue }
                rows.append(.heading(group.rawValue))
                rows += inGroup.map { .item(label: $0.name, detail: $0.call, insert: $0.name + "(") }
            }
        default:
            rows = SQLCompletion.keywords.filter(keep).map { .item(label: $0, detail: "", insert: $0) }
        }
        table.reloadData()
    }

    func controlTextDidChange(_ notification: Notification) { reload() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .heading = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !self.tableView(tableView, isGroupRow: row) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .heading(let title):
            let field = label(title, font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor, truncates: true)
            field.toolTip = title
            return field
        case .item(let name, let detail, _):
            let field = label(name, font: .monospacedSystemFont(ofSize: 11.5, weight: .regular), truncates: true)
            field.toolTip = detail.isEmpty ? name : name + ": " + detail + " (double-click to insert)"
            return field
        }
    }

    private var chosen: String? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(row), case .item(_, _, let text) = rows[row] else { return nil }
        return text
    }

    @objc func insertSelected(_ sender: Any?) {
        guard let text = chosen else { return }
        insert?(text)
    }

    @objc func copy(_ sender: Any?) {
        guard let text = chosen else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if table.clickedRow >= 0, self.tableView(table, shouldSelectRow: table.clickedRow) {
            table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        }
        guard chosen != nil else { return }
        let insert = NSMenuItem(title: "Insert", action: #selector(insertSelected(_:)), keyEquivalent: "")
        insert.toolTip = "Put it in the editor at the cursor"
        for item in [insert, Commands.copy.item()] {
            item.target = self
            menu.addItem(item)
        }
    }
}
