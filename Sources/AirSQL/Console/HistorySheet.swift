import AirSQLCore
import AppKit

/// Query History (⌘Y, plan §2.6): the statements run on the console's connection, newest first; typing narrows them
/// down. A click selects one, a double-click or Return puts it in the editor at the cursor, a right-click copies it.
@MainActor
final class HistorySheet: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private let connection: UUID
    private let insert: (String) -> Void
    private let search = NSSearchField()
    private let table = NSTableView()
    private let status = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    private var entries: [HistoryEntry] = []
    private var loading: Task<Void, Never>?
    private lazy var insertButton = button("Insert", id: "history.insert", tip: "Put the selected statement in the editor at the cursor",
                                           target: self, action: #selector(insertSelected(_:)))
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    init(connection: UUID, insert: @escaping (String) -> Void) {
        self.connection = connection
        self.insert = insert
        super.init(nibName: nil, bundle: nil)
        title = "Query History"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        search.placeholderString = "Search the statements"
        search.toolTip = "Type words a statement contains to narrow the list"
        search.setAccessibilityIdentifier("history.search")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.translatesAutoresizingMaskIntoConstraints = false
        for (identifier, title, width) in [("time", "Run", 150.0), ("sql", "Statement", 420.0), ("result", "Result", 140.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(insertSelected(_:))
        table.menu = NSMenu(title: "History")
        table.menu?.delegate = self
        table.setAccessibilityIdentifier("history.list")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clear = button("Clear History…", id: "history.clear", tip: "Forget every statement run on this connection",
                           target: self, action: #selector(clearHistory(_:)))
        let cancel = button("Cancel", id: "history.cancel", tip: "Close the history without inserting anything",
                            target: self, action: #selector(close(_:)))
        cancel.keyEquivalent = "\u{1b}"
        insertButton.keyEquivalent = "\r"
        insertButton.bezelColor = .accent
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [clear, status, spacer, cancel, insertButton])
        buttons.spacing = Spacing.unit
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let root = SurfaceView(.ground)
        for view in [search, scroll, buttons] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 760), root.heightAnchor.constraint(equalToConstant: 440),
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        view = root
        load()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(search)
    }

    private func load() {
        loading?.cancel()
        status.stringValue = "Loading…"
        let words = search.stringValue, connection = connection
        loading = Task { [weak self] in
            let found = await QueryHistory.shared.entries(connection, matching: words)
            guard let self, !Task.isCancelled else { return }
            self.entries = found
            self.table.reloadData()
            if !found.isEmpty { self.table.selectRowIndexes([0], byExtendingSelection: false) }
            self.status.stringValue = found.isEmpty ? (words.isEmpty ? "Nothing has run on this connection yet" : "No statement has these words")
                : "\(found.count.formatted()) statement\(found.count == 1 ? "" : "s")"
            self.insertButton.isEnabled = !found.isEmpty
        }
    }

    func controlTextDidChange(_ notification: Notification) { load() }

    /// ↑ and ↓ in the search field choose in the list; Return inserts.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let row = max(0, min(entries.count - 1, table.selectedRow + (selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1)))
            if !entries.isEmpty { table.selectRowIndexes([row], byExtendingSelection: false); table.scrollRowToVisible(row) }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            insertSelected(nil)
            return true
        default:
            return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        switch tableColumn?.identifier.rawValue {
        case "time":
            field.stringValue = Self.time.string(from: entry.date)
            field.textColor = .secondaryLabelColor
        case "sql":
            field.stringValue = entry.sql.split(whereSeparator: \.isNewline).joined(separator: " ")
            field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            field.toolTip = String(entry.sql.prefix(1_000))
        default:
            field.stringValue = entry.error.map { "Failed: " + $0 } ?? entry.rows.map { "\($0.formatted()) rows" } ?? "Done"
            field.textColor = entry.error == nil ? .secondaryLabelColor : .statusBad
            field.toolTip = field.stringValue
        }
        return field
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if table.clickedRow >= 0 { table.selectRowIndexes([table.clickedRow], byExtendingSelection: false) }
        let insert = NSMenuItem(title: "Insert", action: #selector(insertSelected(_:)), keyEquivalent: "")
        insert.toolTip = "Put the statement in the editor at the cursor"
        let copy = Commands.copy.item()
        for item in [insert, copy] {
            item.target = self
            menu.addItem(item)
        }
    }

    @objc func copy(_ sender: Any?) {
        guard entries.indices.contains(table.selectedRow) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entries[table.selectedRow].sql, forType: .string)
    }

    @objc private func insertSelected(_ sender: Any?) {
        guard entries.indices.contains(table.selectedRow) else { return }
        let sql = entries[table.selectedRow].sql
        close(nil)
        insert(sql)
    }

    @objc private func clearHistory(_ sender: Any?) {
        QueryHistory.shared.clear(connection)
        entries = []
        table.reloadData()
        load()
    }

    @objc private func close(_ sender: Any?) {
        guard let sheet = view.window else { return }
        sheet.sheetParent?.endSheet(sheet)
    }
}

extension ConsoleViewController {
    @objc func showHistory(_ sender: Any?) {
        guard let id = connectionID, let window = view.window, window.attachedSheet == nil else { return }
        let sheet = HistorySheet(connection: id) { [weak self] sql in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.editor)
            self.editor.insertText(sql, replacementRange: self.editor.selectedRange())
        }
        let panel = NSPanel(contentViewController: sheet)
        panel.styleMask = [.titled]
        window.beginSheet(panel)
    }
}
