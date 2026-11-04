import AirSQLCore
import AppKit

/// Quick Open (⌘P): part of a name goes to a saved connection, or to a table or view of a connected server. Arrow keys
/// move, Return or a double-click opens.
@MainActor
final class QuickOpenSheet: NSWindowController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        let name: String
        /// Where it is: its database and connection, or "Connection".
        let place: String
        let open: () -> Void
    }

    /// Rows shown at most: a name typed narrows the rest.
    static let rowLimit = 200
    private let items: [Item]
    private(set) var shown: [Item] = []
    let field = NSSearchField()
    let table = ContentTable()
    private let status = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    private var retainUntilClosed: QuickOpenSheet?

    static func show(_ items: [Item], on window: NSWindow) {
        let sheet = QuickOpenSheet(items)
        sheet.retainUntilClosed = sheet
        window.beginSheet(sheet.window!)
        sheet.window?.makeFirstResponder(sheet.field)
    }

    private init(_ items: [Item]) {
        self.items = items
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.title = "Quick Open"
        window.backgroundColor = .ground
        super.init(window: window)
        window.contentView = makeContent()
        narrow()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeContent() -> NSView {
        field.placeholderString = "Table, view or connection"
        field.toolTip = "Type part of a name; ↑ and ↓ choose, Return opens"
        field.setAccessibilityIdentifier("quickOpen.field")
        field.delegate = self
        field.sendsSearchStringImmediately = true
        for (id, width) in [("name", 280.0), ("place", 240.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = width
            table.addTableColumn(column)
        }
        table.headerView = nil
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(open(_:))
        table.setAccessibilityIdentifier("quickOpen.list")
        table.setAccessibilityLabel("Matches")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let cancel = button("Cancel", id: "quickOpen.cancel", tip: "Close without opening anything", target: self,
                            action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let open = button("Open", id: "quickOpen.open", tip: "Open the row selected", target: self, action: #selector(open(_:)),
                          primary: true)
        let footer = NSStackView(views: [status, NSView(), cancel, open])
        footer.spacing = Spacing.unit
        let root = SurfaceView(.content)
        for view in [field, scroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.double),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.double),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.double),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: Spacing.unit),
            scroll.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: Spacing.unit),
            footer.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Spacing.double),
        ])
        return root
    }

    /// The items with every word typed in their name: those that start with it first, the shortest (an exact name) ahead.
    private func narrow() {
        let words = field.stringValue.lowercased().split(separator: " ")
        let matches = items.filter { item in words.allSatisfy(item.name.lowercased().contains) }
        let first = words.first.map(String.init) ?? ""
        let starting = matches.filter { $0.name.lowercased().hasPrefix(first) }.sorted { $0.name.count < $1.name.count }
        let others = matches.filter { !$0.name.lowercased().hasPrefix(first) }
        shown = Array((starting + others).prefix(Self.rowLimit))
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        table.scrollRowToVisible(0)
        status.stringValue = matches.isEmpty ? "Nothing has that name. Tables show here once their connection is open"
            : matches.count > shown.count ? "The first \(shown.count) of \(matches.count.formatted()): type more to narrow them"
            : "\(matches.count.formatted()) match\(matches.count == 1 ? "" : "es")"
        status.toolTip = status.stringValue
    }

    func controlTextDidChange(_ notification: Notification) { narrow() }

    /// The field keeps the focus: ↑ and ↓ move in the list, Return opens, Escape closes.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): open(nil)
        case #selector(NSResponder.cancelOperation(_:)): cancel(nil)
        default: return false
        }
        return true
    }

    private func move(_ offset: Int) {
        guard !shown.isEmpty else { return }
        let row = min(max(table.selectedRow + offset, 0), shown.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func open(_ sender: Any?) {
        guard let item = shown[safe: table.selectedRow] else { return NSSound.beep() }
        close()
        item.open()
    }

    @objc private func cancel(_ sender: Any?) { close() }

    override func close() {
        if let window { window.sheetParent?.endSheet(window) }
        retainUntilClosed = nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = shown[safe: row] else { return nil }
        let isName = tableColumn?.identifier.rawValue == "name"
        let value = isName ? item.name : item.place
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: 13)
        field.textColor = isName ? .labelColor : .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = value
        return field
    }
}

extension MainWindowController {
    /// Quick Open…: every saved connection, and the tables and views of those that are open.
    @objc func quickOpen(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        var items: [QuickOpenSheet.Item] = []
        for connection in model.data.connections {
            items.append(.init(name: connection.displayName, place: "Connection") { [weak self] in
                guard let self else { return }
                self.sidebar.select([connection.id])
                self.sidebarSelectionChanged()
                self.sidebar.outline.sendCommand(Commands.connect.action)
            })
            guard let open = model.openConnection(connection.id) else { continue }
            for database in open.snapshot.databases {
                for table in database.tables {
                    let kind = DatabaseObject.Kind(rawValue: table.kind.rawValue) ?? .table
                    let object = DatabaseObject(kind, database.name, table.name)
                    items.append(.init(name: table.name, place: database.name + " on " + connection.displayName) { [weak self] in
                        self?.openTableData(object, of: open)
                    })
                }
            }
        }
        QuickOpenSheet.show(items, on: window)
    }
}
