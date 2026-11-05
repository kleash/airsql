import AirSQLCore
import AppKit

/// Quick Open (⌘P): letters of a name, in order (`fica` finds `film_category`), go to a tab, a saved connection, anything
/// in a connected server's tree, a recent file or a command. Arrow keys move, Return or a double-click opens.
@MainActor
final class QuickOpenSheet: NSWindowController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        let name: String
        /// Where it is: its database and connection, "Connection", a command's menu.
        let place: String
        let open: () -> Void
        let fuzzy: FuzzyName

        init(name: String, place: String, open: @escaping () -> Void) {
            self.name = name
            self.place = place
            self.open = open
            fuzzy = FuzzyName(name)
        }
    }

    /// Rows shown at most: a name typed narrows the rest.
    static let rowLimit = 200
    private let items: [Item]
    private(set) var shown: [Item] = []
    let field = NSSearchField()
    let table = ContentTable()
    private let status = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    private var retainUntilClosed: QuickOpenSheet?

    static func show(_ items: [Item], title: String = "Quick Open", prompt: String = "Table, routine, tab, file or command",
                     on window: NSWindow) {
        let sheet = QuickOpenSheet(items, title: title, prompt: prompt)
        sheet.retainUntilClosed = sheet
        window.beginSheet(sheet.window!)
        sheet.window?.makeFirstResponder(sheet.field)
    }

    private init(_ items: [Item], title: String, prompt: String) {
        self.items = items
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.title = title
        window.backgroundColor = .ground
        super.init(window: window)
        window.contentView = makeContent()
        field.placeholderString = prompt
        narrow()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeContent() -> NSView {
        field.toolTip = "Type letters of a name, in order; ↑ and ↓ choose, Return opens"
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

    /// The items that hold every word's letters, the best first and the shortest (an exact name) ahead; with nothing
    /// typed, all of them as they came.
    private func narrow() {
        let words = FuzzyName.words(field.stringValue)
        var matches = items
        if !words.isEmpty {
            let scored = items.compactMap { item in item.fuzzy.score(words).map { (item, $0) } }
            matches = scored.sorted { ($0.1, $1.0.name.count) > ($1.1, $0.0.name.count) }.map(\.0)
        }
        shown = Array(matches.prefix(Self.rowLimit))
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
    /// Quick Open…: everything there is to go to, tabs first.
    @objc func quickOpen(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        // The commands first: their menu items check themselves against the focus, which the sheet is about to take.
        let commands = commandItems()
        QuickOpenSheet.show(tabItems() + objectItems() + fileItems() + commands, on: window)
    }

    private func tabItems() -> [QuickOpenSheet.Item] {
        model.allTabs.map { tab in
            .init(name: tab.title, place: "Tab" + (model.connection(tab.connectionID).map { " on " + $0.displayName } ?? "")) { [weak self] in
                self?.show(tab)
            }
        }
    }

    /// Every saved connection, and what the tree of those that are open holds.
    private func objectItems() -> [QuickOpenSheet.Item] {
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
                let place = database.name + " on " + connection.displayName
                items.append(.init(name: database.name, place: "Database on " + connection.displayName) { [weak self] in
                    self?.sidebar.reveal(.database(open.id, database.name), showing: true)
                })
                for table in database.tables {
                    let object = DatabaseObject(DatabaseObject.Kind(rawValue: table.kind.rawValue) ?? .table, database.name, table.name)
                    items.append(.init(name: table.name, place: place) { [weak self] in self?.openTableData(object, of: open) })
                }
                let others = database.routines.map { DatabaseObject($0.kind == .function ? .function : .procedure, database.name, $0.name) }
                    + database.triggers.map { DatabaseObject(.trigger, database.name, $0.name) }
                    + database.events.map { DatabaseObject(.event, database.name, $0.name) }
                for object in others {
                    items.append(.init(name: object.name, place: object.kind.noun + " in " + place) { [weak self] in
                        self?.openEditor(object, of: open)
                    })
                }
            }
        }
        return items
    }

    /// Recent files, then those the Files panel has listed.
    func fileItems() -> [QuickOpenSheet.Item] {
        let recent = NSDocumentController.shared.recentDocumentURLs
        return (recent + sidebar.files.listedFiles.filter { !recent.contains($0) }).map { url in
            .init(name: url.lastPathComponent, place: "File in " + url.deletingLastPathComponent().path) { [weak self] in
                self?.openFiles([url])
            }
        }
    }

    /// The menu bar's commands; one that's off says why and stays shut.
    private func commandItems() -> [QuickOpenSheet.Item] {
        var items: [QuickOpenSheet.Item] = []
        func walk(_ menu: NSMenu, _ path: String) {
            menu.update()
            for item in menu.items where !item.isSeparatorItem && !item.isHidden && !item.title.isEmpty {
                if let submenu = item.submenu {
                    if submenu !== NSApp.servicesMenu { walk(submenu, path.isEmpty ? item.title : path + " ▸ " + item.title) }
                    continue
                }
                guard let action = item.action, action != Commands.quickOpen.action else { continue }
                let shortcut = Command.shortcut(item.keyEquivalent, item.keyEquivalentModifierMask)
                let place = item.isEnabled ? path + (shortcut.isEmpty ? "" : " · " + shortcut) : "Off: " + (item.toolTip ?? path)
                items.append(.init(name: item.title, place: place) {
                    // The harness checks an agent's menu commands, and this would go round it.
                    guard !AgentGuard.refuses("Commands in Quick Open are the person's: use the menu tool.") else { return }
                    guard item.isEnabled else { return NSSound.beep() }
                    // A moment later: the window has its focus back from the sheet.
                    DispatchQueue.main.async { NSApp.sendAction(action, to: item.target, from: item) }
                })
            }
        }
        if let bar = NSApp.mainMenu { walk(bar, "") }
        return items
    }
}
