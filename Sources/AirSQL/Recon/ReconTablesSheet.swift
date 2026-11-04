import AirSQLCore
import AppKit

/// Tables…: which source tables the next compare looks at, the target table each is compared with (a renamed one), the
/// columns whose values it leaves out, and a WHERE for its rows.
@MainActor
final class ReconTablesSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private struct Row {
        var name: String
        var choice: ReconTableChoice
    }

    private weak var compare: ReconWindowController?
    private var rows: [Row]
    /// The indexes in `rows` the filter keeps, in order.
    private var shown: [Int]
    private let table = ContentTable()
    private lazy var filter = ListFilter("Filter Tables", id: "reconTables.filter", tip: "Type part of a name to show only those tables",
                                         list: table) { [weak self] in self?.applyFilter() }
    private var retainUntilClosed: ReconTablesSheet?
    private static let columns: [(id: String, title: String, width: CGFloat, tip: String)] = [
        ("include", "Compare", 64, "Compare this table; untick to leave it out"),
        ("name", "Source Table", 180, "The table in the source"),
        ("target", "Compare With", 180, "The target table to compare it with, when it has another name there; empty for the same name"),
        ("excluded", "Leave Out Columns", 200, "Columns whose values aren't compared, separated by commas, such as updated_at"),
        ("filter", "WHERE", 240, "A condition both sides' rows must meet, such as created_at >= '2026-01-01'; empty for every row"),
    ]

    static func show(for owner: ReconWindowController, tables: [String], on window: NSWindow) {
        let sheet = ReconTablesSheet(owner: owner, tables: tables)
        sheet.retainUntilClosed = sheet
        window.beginSheet(sheet.window!)
    }

    private init(owner: ReconWindowController, tables: [String]) {
        self.compare = owner
        let known = Set(tables)
        rows = (tables + owner.options.tables.keys.filter { !known.contains($0) }).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.map { Row(name: $0, choice: owner.options.choice($0)) }
        shown = Array(rows.indices)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 520), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 760, height: 360)
        super.init(window: window)
        window.contentView = makeContent()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeContent() -> NSView {
        let root = SurfaceView(.ground)
        let heading = label("Choose the tables to compare", font: .boldSystemFont(ofSize: 13))
        let note = caption("Rows are matched on the primary key, or a unique key of NOT NULL columns. The WHERE applies to "
                           + "both sides, so rows outside it are neither compared nor synced.", width: 700)
        for spec in Self.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.id == "include" ? spec.width : 100
            column.headerToolTip = spec.tip
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.centreText(rowHeight: 24)
        table.allowsMultipleSelection = true
        table.stripes = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityIdentifier("reconTables.list")
        // A double-click ticks or unticks the row's Compare; a right-click offers both.
        table.target = self
        table.doubleAction = #selector(toggleClicked(_:))
        let menu = NSMenu(title: "Table")
        for (title, tip, action) in [("Compare", "Compare the selected tables in the next compare", #selector(includeChosen(_:))),
                                     ("Leave Out", "Leave the selected tables out of the next compare", #selector(leaveOutChosen(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.toolTip = tip
            menu.addItem(item)
        }
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        filter.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let all = button("Compare All", id: "reconTables.all", tip: "Tick every table shown", target: self, action: #selector(tickAll(_:)))
        let none = button("Compare None", id: "reconTables.none", tip: "Untick every table shown", target: self, action: #selector(tickNone(_:)))
        let cancel = button("Cancel", id: "reconTables.cancel", tip: "Close without changing what the next compare looks at",
                            target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let done = button("Done", id: "reconTables.done", tip: "Use these choices for the next compare", target: self,
                          action: #selector(done(_:)), primary: true)
        done.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [helpButton(.compare), all, none, spacer, cancel, done])
        let stack = NSStackView(views: [heading, note, filter, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.unit + 4
        for view in [scroll, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.addSubview(stack)
        stack.pin(to: root)
        return root
    }

    private func applyFilter() {
        let text = filter.stringValue
        shown = rows.indices.filter { text.isEmpty || GridFilter.matches(text, [rows[$0].name]) }
        table.deselectAll(nil)
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let index = shown[row], item = rows[index]
        if id == "include" {
            let box = checkbox("", id: "reconTables.include", tip: "Compare \(item.name)", on: item.choice.included,
                               target: self, action: #selector(toggled(_:)))
            box.tag = index
            return box
        }
        if id == "name" {
            let name = label(item.name, truncates: true)
            name.toolTip = item.name
            return name
        }
        let value: String, placeholder: String
        switch id {
        case "target": (value, placeholder) = (item.choice.target ?? "", item.name)
        case "excluded": (value, placeholder) = (item.choice.excludedColumns.joined(separator: ", "), "none")
        default: (value, placeholder) = (item.choice.filter, "every row")
        }
        let tip = Self.columns.first(where: { $0.id == id })?.tip ?? ""
        let field: NSTextField = AirSQL.textField(value, placeholder: placeholder, id: "reconTables." + id, tip: tip)
        field.isBordered = false
        field.drawsBackground = false
        field.font = id == "filter" ? NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular) : NSFont.systemFont(ofSize: 12)
        field.tag = index
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.delegate = self
        return field
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, rows.indices.contains(field.tag) else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        switch field.identifier?.rawValue {
        case "target": rows[field.tag].choice.target = text.isEmpty ? nil : text
        case "excluded":
            rows[field.tag].choice.excludedColumns = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        case "filter": rows[field.tag].choice.filter = field.stringValue
        default: break
        }
    }

    @objc private func toggled(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        rows[sender.tag].choice.included = sender.state == .on
    }

    /// The table's rows a menu command acts on: the clicked one, with the rest of the selection when it is part of it.
    private var chosenRows: IndexSet {
        let clicked = table.clickedRow
        guard clicked >= 0 else { return table.selectedRowIndexes }
        return table.selectedRowIndexes.contains(clicked) ? table.selectedRowIndexes : IndexSet(integer: clicked)
    }

    private func include(_ tableRows: IndexSet, _ included: Bool) {
        for row in tableRows where shown.indices.contains(row) { rows[shown[row]].choice.included = included }
        table.reloadData(forRowIndexes: tableRows, columnIndexes: IndexSet(integer: 0))
    }

    @objc func toggleClicked(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard shown.indices.contains(row) else { return }
        include(IndexSet(integer: row), !rows[shown[row]].choice.included)
    }

    @objc func includeChosen(_ sender: Any?) { include(chosenRows, true) }

    @objc func leaveOutChosen(_ sender: Any?) { include(chosenRows, false) }

    @objc private func tickAll(_ sender: Any?) { include(IndexSet(shown.indices), true) }

    @objc private func tickNone(_ sender: Any?) { include(IndexSet(shown.indices), false) }

    @objc private func cancel(_ sender: Any?) { close(saving: false) }

    @objc private func done(_ sender: Any?) {
        window?.makeFirstResponder(nil)  // ends the edit under way, so its text counts
        close(saving: true)
    }

    private func close(saving: Bool) {
        if saving, let owner = compare {
            for row in rows { owner.options.tables[row.name] = row.choice == ReconTableChoice() ? nil : row.choice }
            owner.update()
        }
        if let window { window.sheetParent?.endSheet(window) }
        retainUntilClosed = nil
    }
}
