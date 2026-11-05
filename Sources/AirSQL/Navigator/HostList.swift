import AirSQLCore
import AppKit

/// A row's value as a bar: its parts, each a fraction of the cell's width, one after the other. Drawn plainly: a list
/// has few of these on screen.
@MainActor
final class SizeBar: NSView {
    struct Parts: Hashable {
        var data = 0.0, index = 0.0, free = 0.0
    }

    var parts = Parts() {
        didSet { needsDisplay = true }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { toolTip }

    override func draw(_ dirtyRect: NSRect) {
        let height = min(8, bounds.height)
        var x = bounds.minX
        for (value, colour) in [(parts.data, NSColor.controlAccentColor), (parts.index, .systemTeal), (parts.free, .tertiaryLabelColor)]
        where value > 0 {
            let width = max(1, bounds.width * value)
            colour.setFill()
            NSRect(x: x, y: bounds.midY - height / 2, width: width, height: height).intersection(bounds).intersection(dirtyRect).fill()
            x += width
        }
    }
}

/// A list of the host page and Disk Usage: a caption with the count, a filter (a word or a regular expression), columns
/// that sort and that the header's menu shows or hides, and Copy, Copy List and Export List. A click selects, a
/// double-click or Return does `onOpen`, a right-click opens `onMenu`'s menu on the row under the pointer.
@MainActor
final class HostList: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    struct Column {
        let id: String
        let title: String
        var width: CGFloat = 100
        /// Right-aligned, and sorted by the row's `numbers`, largest first.
        var numeric = false
        var tip: String
        /// Off until the person shows it, from the header's menu.
        var hidden = false
        /// Draws the row's `bars` instead of text.
        var bar = false
    }

    struct Row {
        /// What the selection follows when the list is read again.
        let key: String
        var cells: [String: String]
        var numbers: [String: Double] = [:]
        var bars: [String: SizeBar.Parts] = [:]
    }

    /// Names the list, for its tooltip, its saved layout and the file Export List offers.
    let name: String
    let columns: [Column]
    let table = HostTable()
    let filter = NSSearchField()
    let caption = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    /// After the count: what the rows are, or why there are none.
    var note = "" {
        didSet { updateCaption() }
    }
    var onOpen: ((Row) -> Void)?
    var onMenu: (() -> NSMenu?)?
    var onSelect: (() -> Void)?
    /// The rows shown: of what was set, those the filter keeps, in the header's order.
    private(set) var rows: [Row] = []
    private var all: [Row] = []
    private let defaultSort: NSSortDescriptor?
    private let accessories: [NSView]

    /// `accessories` go in the bar over the list, before the filter.
    init(name: String, columns: [Column], sort: NSSortDescriptor? = nil, accessories: [NSView] = []) {
        self.name = name
        self.columns = columns
        defaultSort = sort
        self.accessories = accessories
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var id: String { "list." + name.lowercased().replacingOccurrences(of: " ", with: "") }

    override func loadView() {
        let root = SurfaceView(.content)
        root.setAccessibilityIdentifier(id)
        caption.setAccessibilityIdentifier(id + ".caption")
        filter.placeholderString = "Filter"
        filter.toolTip = "Type a word or a regular expression to show only the rows that have it"
        filter.setAccessibilityIdentifier(id + ".filter")
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        filter.widthAnchor.constraint(equalToConstant: 200).isActive = true
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [caption, NSView()] + accessories + [filter])
        bar.spacing = Spacing.unit
        bar.translatesAutoresizingMaskIntoConstraints = false
        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 40
            tableColumn.isHidden = column.hidden
            tableColumn.headerToolTip = column.tip + "; click to sort by it, again to reverse"
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: !column.numeric && !column.bar)
            if column.numeric { tableColumn.headerCell.alignment = .right }
            table.addTableColumn(tableColumn)
        }
        table.autosaveName = layoutName("List " + name)  // its widths, columns shown and sort, for next time
        table.autosaveTableColumns = true
        if table.sortDescriptors.isEmpty, let defaultSort { table.sortDescriptors = [defaultSort] }
        table.addColumnMenu(tip: "Show or hide this column")
        table.style = .fullWidth
        table.stripes = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.centreText(rowHeight: 22)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openRow(_:))
        table.owner = self
        table.setAccessibilityIdentifier(id + ".table")
        table.setAccessibilityLabel(name)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        [bar, scroll].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.double),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.double),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: Spacing.unit),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        arrange()
    }

    /// The list's rows, kept filtered and sorted as they are.
    func show(_ rows: [Row]) {
        all = rows
        if isViewLoaded { arrange() }
    }

    private func arrange() {
        let selected = Set(self.selected.map(\.key))
        let text = filter.stringValue.trimmingCharacters(in: .whitespaces)
        rows = text.isEmpty ? all : all.filter { row in row.cells.values.contains { Self.matches($0, text) } }
        if let sort = table.sortDescriptors.first, let key = sort.key {
            let numeric = columns.contains { $0.id == key && ($0.numeric || $0.bar) }
            rows.sort { first, second in
                if numeric {
                    // An unknown figure goes last either way.
                    guard let a = first.numbers[key] else { return false }
                    guard let b = second.numbers[key] else { return true }
                    return a == b ? first.key < second.key : (a < b) == sort.ascending
                }
                let order = (first.cells[key] ?? "").localizedStandardCompare(second.cells[key] ?? "")
                return order == .orderedSame ? first.key < second.key : (order == .orderedAscending) == sort.ascending
            }
        }
        table.reloadData()
        table.selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0].key) }), byExtendingSelection: false)
        updateCaption()
    }

    /// `text` as a regular expression, or as plain text where it isn't a valid one.
    private static func matches(_ value: String, _ text: String) -> Bool {
        guard (try? NSRegularExpression(pattern: text)) != nil else { return value.localizedCaseInsensitiveContains(text) }
        return value.range(of: text, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func updateCaption() {
        let count = rows.count == all.count ? "\(all.count)" : "\(rows.count) of \(all.count)"
        caption.stringValue = note.isEmpty ? count : count + " · " + note
        caption.toolTip = caption.stringValue
    }

    var selected: [Row] { table.selectedRowIndexes.compactMap { rows[safe: $0] } }

    func controlTextDidChange(_ notification: Notification) { arrange() }

    @objc private func openRow(_ sender: Any?) {
        if let row = rows[safe: table.clickedRow >= 0 ? table.clickedRow : table.selectedRow] { onOpen?(row) }
    }

    fileprivate func returnPressed() { openRow(nil) }

    fileprivate func contextMenu() -> NSMenu? { onMenu?() }

    // MARK: Copying

    private var shownColumns: [Column] { columns.filter { !$0.bar && table.tableColumn(withIdentifier: .init($0.id))?.isHidden == false } }

    private func lines(_ rows: [Row]) -> [[String]] { rows.map { row in shownColumns.map { row.cells[$0.id] ?? "" } } }

    /// ⌘C: the selected rows, tab-separated.
    @objc func copy(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines(selected).map { $0.joined(separator: "\t") }.joined(separator: "\n"), forType: .string)
    }

    /// The whole list as it shows, as CSV with its headers.
    var csv: String { HostFigures.csv([shownColumns.map(\.title)] + lines(rows)) }

    @objc func copyList(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(csv, forType: .string)
    }

    @objc func exportList(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + ".csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        let text = csv
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task.detached {
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    await showError(error.localizedDescription, title: "Couldn't save the list", on: window)
                }
            }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let reason = item.action == Commands.copy.action && selected.isEmpty ? "Select some rows first" : nil
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, let item = rows[safe: row], let column = columns.first(where: { $0.id == id })
        else { return nil }
        if column.bar {
            let bar = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell.bar"), owner: nil) as? SizeBar ?? SizeBar()
            bar.identifier = NSUserInterfaceItemIdentifier("cell.bar")
            bar.parts = item.bars[id] ?? SizeBar.Parts()
            bar.toolTip = item.cells[id]
            return bar
        }
        let field = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell." + id), owner: nil) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        field.identifier = NSUserInterfaceItemIdentifier("cell." + id)
        field.lineBreakMode = .byTruncatingTail
        let value = item.cells[id] ?? ""
        field.stringValue = value
        field.toolTip = value.isEmpty ? nil : value
        field.alignment = column.numeric ? .right : .left
        field.font = column.numeric ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12, weight: id == columns.first?.id ? .medium : .regular)
        field.textColor = id == columns.first?.id ? .labelColor : .secondaryLabelColor
        return field
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { arrange() }

    func tableViewSelectionDidChange(_ notification: Notification) { onSelect?() }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        rows[safe: row]?.cells[columns.first?.id ?? ""]
    }
}

/// A host list's table: a right-click selects the row under the pointer first and opens the list's menu; Return opens.
@MainActor
final class HostTable: ContentTable {
    weak var owner: HostList?

    override func menu(for event: NSEvent) -> NSMenu? {
        if !selectsRow(for: event) { deselectAll(nil) }
        return owner?.contextMenu()
    }

    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode) { owner?.returnPressed() } else { super.keyDown(with: event) }
    }
}

extension NSTableView {
    /// A menu on the header with every column but the first, ticked while it shows. Call it once the saved layout is in.
    func addColumnMenu(tip: String) {
        let menu = NSMenu(title: "Columns")
        for column in tableColumns.dropFirst() where !column.title.isEmpty {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column
            item.state = column.isHidden ? .off : .on
            item.toolTip = tip
            menu.addItem(item)
        }
        headerView?.menu = menu
    }

    @objc fileprivate func toggleColumn(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn else { return }
        column.isHidden.toggle()
        sender.state = column.isHidden ? .off : .on
    }
}
