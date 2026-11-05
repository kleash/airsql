import AirSQLCore
import AppKit

/// The query helpers beside the editor (plan §2.6, View ▸ Query Helpers): the columns of the tables the statement at
/// the cursor names (else of the table selected in the tree), the server's functions by kind, the keywords, the saved
/// snippets and the connection's history by day; the filter narrows them. A click selects one, a double-click puts it
/// in the editor at the cursor (as dragging it there does), a right-click offers the rest.
@MainActor
final class HelpersPanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private enum Row {
        case heading(String)
        case item(label: String, detail: String, insert: String)
        /// `builtIn`: it comes with AirSQL, so it can be copied but not changed.
        case snippet(SQLSnippet, builtIn: Bool)
        /// `share`: how long it took, from 0 to 1 of the longest listed.
        case history(HistoryEntry, share: Double)
    }

    let choice = NSSegmentedControl(labels: ["Columns", "Functions", "Keywords", "Snippets", "History"], trackingMode: .selectOne, target: nil, action: nil)
    private let filter = NSSearchField()
    let table = NSTableView()
    private var rows: [Row] = []
    private let empty = label("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor, wraps: true)
    /// What the panel shows for the statement at the cursor: its tables' columns, and the server.
    var source: (() -> (columns: [(table: String, columns: [SQLColumnInfo])], server: SchemaServer?))?
    /// Puts text in the editor at the cursor.
    var insert: ((String) -> Void)?
    /// The person's snippets; puts one in the editor, with its fields; opens the sheet that edits one (nil: a new one).
    var snippets: (() -> [SQLSnippet])?
    var insertSnippet: ((SQLSnippet) -> Void)?
    var editSnippet: ((SQLSnippet?) -> Void)?
    var removeSnippet: ((SQLSnippet) -> Void)?
    /// The connection's statements, newest first.
    var history: (() async -> [HistoryEntry])?
    private var loading: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Five words would be wider than the panel, and widen the window.
        for (index, (symbol, title)) in [("tablecells", "Columns"), ("function", "Functions"), ("textformat", "Keywords"),
                                         ("text.quote", "Snippets"), ("clock", "History")].enumerated() {
            choice.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: title), forSegment: index)
            choice.setLabel("", forSegment: index)
            choice.setToolTip("Show the \(title.lowercased())", forSegment: index)
        }
        choice.selectedSegment = 0
        choice.selectedSegmentBezelColor = .selectedSegment
        choice.target = self
        choice.action = #selector(reload)
        choice.toolTip = "Show the statement's columns, the server's functions, the keywords, your snippets or the history"
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
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
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
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.setAccessibilityIdentifier("helpers.empty")
        addSubview(empty)
        NSLayoutConstraint.activate([
            empty.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: Spacing.double),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.double),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.double),
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
        loading?.cancel()
        switch choice.selectedSegment {
        case 0:
            for (table, columns) in given.columns {
                let kept = columns.filter { keep($0.name) }
                guard !kept.isEmpty else { continue }
                rows.append(.heading(table))
                rows += kept.map { .item(label: $0.name, detail: $0.type ?? "", insert: SQLCompletion.quote($0.name)) }
            }
        case 1:
            let functions = SQLFunction.all.filter { $0.available(on: given.server) && keep($0.name) }
            for group in SQLFunction.Group.allCases {
                let inGroup = functions.filter { $0.group == group }
                guard !inGroup.isEmpty else { continue }
                rows.append(.heading(group.rawValue))
                rows += inGroup.map { .item(label: $0.name, detail: $0.call, insert: $0.name + "(") }
            }
        case 2:
            rows = SQLCompletion.keywords.filter(keep).map { .item(label: $0, detail: "", insert: $0) }
        case 3:
            let own = (snippets?() ?? []).filter { keep($0.name) || keep($0.abbreviation) || keep($0.body) }
            for folder in Set(own.map(\.folder)).sorted() {
                rows.append(.heading(folder.isEmpty ? "My Snippets" : folder))
                rows += own.filter { $0.folder == folder }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    .map { .snippet($0, builtIn: false) }
            }
            let builtIn = SQLSnippet.builtIn.filter { keep($0.name) || keep($0.abbreviation) }
            if !builtIn.isEmpty { rows.append(.heading("Built In")) }
            rows += builtIn.map { .snippet($0, builtIn: true) }
        default:
            loadHistory(keep)
            return
        }
        show(words)
    }

    /// The history comes from its file, off the main thread, then a day at a time.
    private func loadHistory(_ keep: @escaping (String) -> Bool) {
        let words = filter.stringValue.lowercased()
        loading = Task { [weak self] in
            let entries = await self?.history?() ?? []
            guard let self, !Task.isCancelled else { return }
            let shown = entries.filter { keep($0.sql) }.prefix(300)
            let longest = shown.compactMap(\.duration).max() ?? 0
            var day = ""
            for entry in shown {
                let title = entry.date.formatted(date: .complete, time: .omitted)
                if title != day {
                    day = title
                    self.rows.append(.heading(title))
                }
                self.rows.append(.history(entry, share: longest > 0 ? (entry.duration ?? 0) / longest : 0))
            }
            self.show(words)
        }
    }

    private func show(_ words: String) {
        table.reloadData()
        empty.isHidden = !rows.isEmpty
        empty.stringValue = !words.isEmpty ? "Nothing has this name."
            : choice.selectedSegment == 0 ? "Put the cursor in a statement that names tables, or select a table in the tree: its columns show here."
            : choice.selectedSegment == 4 ? "Nothing has run on this connection yet: run a statement and it shows here." : ""
    }

    func controlTextDidChange(_ notification: Notification) { reload() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .heading = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !self.tableView(tableView, isGroupRow: row) }

    /// Dragging an item into the editor drops what a double-click inserts: a column's name quoted as completion quotes it.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let text = text(of: rows[row]) else { return nil }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        return item
    }

    /// What dragging or copying a row gives.
    private func text(of row: Row) -> String? {
        switch row {
        case .heading: return nil
        case .item(_, _, let text): return text
        case .snippet(let snippet, _): return SQLTemplate.expand(snippet.body).text
        case .history(let entry, _): return entry.sql
        }
    }

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
        case .snippet(let snippet, _):
            let title = snippet.abbreviation.isEmpty ? snippet.name : "\(snippet.name) (\(snippet.abbreviation))"
            let field = label(title, font: .systemFont(ofSize: 11.5), truncates: true)
            field.toolTip = snippet.body + "\n(double-click to insert)"
            return field
        case .history(let entry, let share):
            return historyRow(entry, share)
        }
    }

    /// A statement's first line, with a bar as long as it took next to the longest listed.
    private func historyRow(_ entry: HistoryEntry, _ share: Double) -> NSView {
        let line = entry.sql.split(whereSeparator: \.isNewline).first.map(String.init) ?? entry.sql
        let field = label(line, font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: entry.error == nil ? .labelColor : .systemRed, truncates: true)
        let time = entry.date.formatted(date: .omitted, time: .shortened)
        let took = entry.duration.map { $0 < 1 ? "\(Int($0 * 1000)) ms" : String(format: "%.1f s", $0) } ?? "time not known"
        field.toolTip = "\(time), \(took): \(entry.sql)"
        let bar = SurfaceView(.accent, radius: 1)
        let row = NSView()
        for view in [field, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: row.leadingAnchor), field.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            field.topAnchor.constraint(equalTo: row.topAnchor, constant: 1),
            bar.leadingAnchor.constraint(equalTo: row.leadingAnchor), bar.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -1),
            bar.heightAnchor.constraint(equalToConstant: 2),
            bar.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: max(0.01, min(1, share))),
        ])
        return row
    }

    private var chosenRow: Row? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return rows.indices.contains(row) ? rows[row] : nil
    }

    private var chosen: String? { chosenRow.flatMap(text(of:)) }

    @objc func insertSelected(_ sender: Any?) {
        if case .snippet(let snippet, _)? = chosenRow { return insertSnippet?(snippet) ?? () }
        guard let text = chosen else { return }
        insert?(text)
    }

    @objc private func newSnippet(_ sender: Any?) { editSnippet?(nil) }

    @objc private func editChosen(_ sender: Any?) {
        guard case .snippet(let snippet, let builtIn)? = chosenRow else { return }
        // A built-in stays as it is: this makes one's own of it.
        var copy = snippet
        if builtIn { copy.id = UUID() }
        editSnippet?(copy)
    }

    @objc private func deleteChosen(_ sender: Any?) {
        guard case .snippet(let snippet, false)? = chosenRow else { return }
        removeSnippet?(snippet)
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
        var items: [NSMenuItem] = []
        func add(_ title: String, _ action: Selector, _ tip: String) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.toolTip = tip
            items.append(item)
        }
        if chosen != nil {
            add("Insert", #selector(insertSelected(_:)), "Put it in the editor at the cursor")
            items.append(Commands.copy.item())
        }
        if choice.selectedSegment == 3 {
            add("New Snippet…", #selector(newSnippet(_:)), "Save a piece of SQL to use again")
            if case .snippet(_, let builtIn)? = chosenRow {
                add(builtIn ? "Edit a Copy…" : "Edit…", #selector(editChosen(_:)), "Change this snippet's name, abbreviation, folder or SQL")
                if !builtIn { add("Delete", #selector(deleteChosen(_:)), "Delete this snippet") }
            }
        }
        for item in items {
            item.target = self
            menu.addItem(item)
        }
    }
}
