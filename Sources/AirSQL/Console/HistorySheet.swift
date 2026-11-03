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
    private let empty = label("", font: .systemFont(ofSize: 12.5), color: .secondaryLabelColor, wraps: true)
    private var loading: Task<Void, Never>?
    private lazy var insertButton = button("Insert", id: "history.insert", tip: "Put the selected statement in the editor at the cursor",
                                           target: self, action: #selector(insertSelected(_:)), primary: true)
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
        // The statement and the result share what the time leaves; a long error is shortened, whole in its tooltip.
        for (identifier, title, width, minimum) in [("time", "When", 150.0, 150.0), ("sql", "Statement", 360.0, 160.0),
                                                    ("result", "Result", 200.0, 100.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = minimum
            if identifier == "time" { column.resizingMask = .userResizingMask }
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
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
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [clear, status, spacer, cancel, insertButton])
        buttons.spacing = Spacing.unit
        buttons.translatesAutoresizingMaskIntoConstraints = false
        empty.alignment = .center
        empty.setAccessibilityIdentifier("history.empty")
        insertButton.isEnabled = false
        let root = SurfaceView(.ground)
        for view in [search, scroll, buttons, empty] { root.addSubview(view) }
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
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
        ])
        view = root
        load()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(search)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        table.sizeToFit()
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
            self.status.stringValue = found.isEmpty ? "" : "\(found.count.formatted()) statement\(found.count == 1 ? "" : "s")"
            self.empty.stringValue = words.isEmpty ? "Nothing has run on this connection yet: statements you run in a console show here."
                : "No statement has these words."
            self.empty.isHidden = !found.isEmpty
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
            field.toolTip = field.stringValue.count > 2_000 ? String(field.stringValue.prefix(2_000)) + "…" : field.stringValue
        default:
            field.stringValue = entry.error.map { "Failed: " + $0 } ?? entry.rows.map { "\($0.formatted()) row\($0 == 1 ? "" : "s")" } ?? "Done"
            field.textColor = entry.error == nil ? .secondaryLabelColor : .statusBad
            field.toolTip = field.stringValue
        }
        // On one baseline across the columns (their fonts differ), with the capitals centred in the row.
        let cell = NSTableCellView()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.firstBaselineAnchor.constraint(equalTo: cell.topAnchor,
                                                 constant: ((tableView.rowHeight + NSFont.systemFont(ofSize: NSFont.systemFontSize).capHeight) / 2).rounded()),
        ])
        return cell
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
        guard let window = view.window else { return }
        ConsoleClosing.alert(window, "Forget the statements run on this connection?",
                             "The history of this connection is removed from this Mac. The statements' results on the server stay.",
                             buttons: [("Clear", "Forget every statement in this history"), ("Cancel", "Keep the history")],
                             destructive: 0) { [weak self] choice in
            // The gate (plan §2.8): the history is the person's record.
            guard choice == 0, let self, !AgentGuard.refuses("The history is the person's: only they can clear it.") else { return }
            QueryHistory.shared.clear(self.connection)
            self.load()
        }
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
