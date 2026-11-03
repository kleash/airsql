import AirSQLCore
import AppKit

/// Filter by Values… (grid-spec §4): a column's values within the current filter, each with its count, worked out on
/// the server (the 1,000 most frequent); tick the ones to show, as in a spreadsheet. OK adds `column IN (…)` to the
/// filter.
@MainActor
final class FilterByValuesSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let limit = 1_000

    private let column: GridColumn
    private let completion: (GridCondition?) -> Void
    private var values: [(value: String?, count: Int)] = []
    private var ticked: Set<Int> = []
    private var shown: [Int] = []
    private let table = NSTableView()
    private let search = NSSearchField()
    private let note = label("Counting the values on the server…", font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                             color: .secondaryLabelColor, truncates: true)
    private let spinner = NSProgressIndicator()
    private var okButton: NSButton!
    private var retainUntilClosed: FilterByValuesSheet?

    /// Shows the sheet for `column` and reads its values with `read` (rows of value and count).
    static func show(column: GridColumn, table: String, on window: NSWindow, read: @escaping () async throws -> [[String?]],
                     completion: @escaping (GridCondition?) -> Void) {
        let sheet = FilterByValuesSheet(column: column, table: table, completion: completion)
        sheet.retainUntilClosed = sheet
        window.beginSheet(sheet.window!)
        Task {
            do {
                let rows = try await read()
                sheet.show(rows.map { ($0.first ?? nil, Int(($0.count > 1 ? $0[1] : nil) ?? "") ?? 0) })
            } catch {
                sheet.spinner.stopAnimation(nil)
                sheet.note.stringValue = "The values weren't counted: " + ((error as? AirSQLError)?.message ?? error.localizedDescription)
                sheet.note.textColor = .statusBad
            }
        }
    }

    private init(column: GridColumn, table: String, completion: @escaping (GridCondition?) -> Void) {
        self.column = column
        self.completion = completion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.title = "Filter \(table) by \(column.name)"
        super.init(window: window)
        window.contentView = makeContent(table)
        window.setContentSize(NSSize(width: 380, height: 420))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeContent(_ tableName: String) -> NSView {
        let heading = label("Show the rows of \(tableName) whose \(column.name) is:", font: .systemFont(ofSize: 13, weight: .semibold),
                            truncates: true)
        search.placeholderString = "Find a value"
        search.toolTip = "Show only the values with this text"
        search.setAccessibilityIdentifier("values.search")
        search.delegate = self
        let check = NSTableColumn(identifier: .init("value"))
        check.title = column.name
        table.addTableColumn(check)
        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("values.list")
        table.setAccessibilityLabel("Values of \(column.name)")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)
        let all = button("Select All", id: "values.all", tip: "Tick every value shown", target: self, action: #selector(tickAll(_:)))
        let none = button("Select None", id: "values.none", tip: "Untick every value shown", target: self, action: #selector(tickNone(_:)))
        let cancel = button("Cancel", id: "values.cancel", tip: "Close without filtering", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        okButton = button("Filter", id: "values.ok", tip: "Show only the rows with the ticked values", target: self, action: #selector(ok(_:)))
        okButton.keyEquivalent = "\r"
        okButton.isEnabled = false
        let status = NSStackView(views: [spinner, note])
        let buttons = NSStackView(views: [helpButton(.tableData), all, none, NSView(), cancel, okButton])
        let stack = NSStackView(views: [heading, search, scroll, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.unit
        stack.edgeInsets = NSEdgeInsets(top: Spacing.double, left: Spacing.double, bottom: Spacing.double, right: Spacing.double)
        for view in [heading, search, scroll, status, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Spacing.double).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return stack
    }

    private func show(_ rows: [(value: String?, count: Int)]) {
        values = rows
        ticked = Set(rows.indices)
        filter()
        spinner.stopAnimation(nil)
        let more = rows.count >= Self.limit ? " (the \(Self.limit.formatted()) most frequent)" : ""
        note.stringValue = "\(rows.count.formatted()) values\(more), counted on the server within the current filter"
        okButton.isEnabled = true
    }

    private func filter() {
        let text = search.stringValue
        shown = values.indices.filter { text.isEmpty || GridFilter.matches(text, [values[$0].value]) }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let index = shown[row], entry = values[index]
        let title = (entry.value ?? "NULL") + "  (\(entry.count.formatted()))"
        let box = NSButton(checkboxWithTitle: title.count > 120 ? String(title.prefix(120)) + "…" : title, target: self,
                           action: #selector(toggled(_:)))
        box.tag = index
        box.state = ticked.contains(index) ? .on : .off
        box.lineBreakMode = .byTruncatingTail
        box.toolTip = entry.value.map { "Show rows whose \(column.name) is \($0)" } ?? "Show rows whose \(column.name) is NULL"
        return box
    }

    @objc private func toggled(_ sender: NSButton) {
        if sender.state == .on { ticked.insert(sender.tag) } else { ticked.remove(sender.tag) }
    }

    @objc private func tickAll(_ sender: Any?) {
        ticked.formUnion(shown)
        table.reloadData()
    }

    @objc private func tickNone(_ sender: Any?) {
        ticked.subtract(shown)
        table.reloadData()
    }

    @objc private func cancel(_ sender: Any?) { finish(nil, filtering: false) }

    @objc private func ok(_ sender: Any?) {
        guard !ticked.isEmpty else { return NSSound.beep() }
        // Every value ticked (and none beyond the first thousand): no condition.
        let everything = ticked.count == values.count && values.count < Self.limit
        finish(everything ? nil : GridCondition(column, .isIn, ticked.sorted().map { values[$0].value }), filtering: true)
    }

    private func finish(_ condition: GridCondition?, filtering: Bool) {
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        if filtering { completion(condition) }
        retainUntilClosed = nil
    }
}
