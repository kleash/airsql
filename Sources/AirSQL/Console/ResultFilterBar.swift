import AirSQLCore
import AppKit

/// A console result's filter bar (grid-spec §4: results filter and sort here, on their rows in memory): as the table
/// tab's grid bar, a chip saying how many rows show, the conditions the quick filters and Filter by Values add (ANDed,
/// shown as SQL) and Search All Columns. It shows while a filter or a search is on (the results bar has the help's ?).
@MainActor
final class ResultFilterBar: NSView, NSSearchFieldDelegate {
    weak var owner: ResultGridView?
    let scope = ChipView("Local · every row", style: .neutral)
    let conditionsText = label("", font: .monospacedSystemFont(ofSize: 12, weight: .regular), truncates: true)
    let clearButton = NSButton()
    let searchField = NSSearchField()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("result.filterBar")
        scope.setAccessibilityIdentifier("result.scope")
        scope.toolTip = "Filters and the sort run here, on the rows the query returned; the query isn't run again"
        let whereLabel = label("Filter", font: .systemFont(ofSize: 10.5, weight: .semibold), color: .quietText)
        conditionsText.setAccessibilityIdentifier("result.filter")
        // The conditions give way first (the chip's text resists at .defaultLow), down to a readable part; the tooltip has
        // all of them.
        conditionsText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        conditionsText.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        conditionsText.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        whereLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Show every row again")
        clearButton.isBordered = false
        clearButton.bezelStyle = .regularSquare
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.toolTip = "Show every row again"
        clearButton.setAccessibilityIdentifier("result.clearFilter")
        clearButton.target = self
        clearButton.action = #selector(clear(_:))
        clearButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        searchField.placeholderString = "Search all columns"
        searchField.toolTip = "Show only the rows with this text in any column; press Return to search"
        searchField.setAccessibilityIdentifier("result.search")
        searchField.sendsWholeSearchString = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searched(_:))
        let row = NSStackView(views: [scope, whereLabel, conditionsText, clearButton, searchField])
        row.setHuggingPriority(.defaultHigh, for: .vertical)  // a bar keeps its height; the rows get the rest
        row.spacing = Spacing.unit
        row.setCustomSpacing(Spacing.half, after: whereLabel)
        row.edgeInsets = NSEdgeInsets(top: 4, left: Spacing.unit, bottom: 4, right: Spacing.unit)
        let hairline = Hairline(.softSeparator)
        for view in [row, hairline] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: hairline.topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor), hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor), hairline.heightAnchor.constraint(equalToConstant: 1),
            searchField.widthAnchor.constraint(equalToConstant: 190),
        ])
        show([], shown: 0, of: 0)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.bar.cgColor }

    /// The conditions as SQL (an empty bar says how to add one) and how many of the rows meet them.
    func show(_ conditions: [GridCondition], shown: Int, of total: Int) {
        let sql = conditions.map { $0.sql() }.joined(separator: " AND ")
        if sql.isEmpty {
            conditionsText.attributedStringValue = NSAttributedString(string: "Right-click a cell for a quick filter", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor])
            conditionsText.toolTip = "Right-click a cell for a quick filter, or a header for Filter by Values…"
        } else {
            conditionsText.attributedStringValue = SQLPreviewSheet.coloured(sql, font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                                                            noBackslashEscapes: false)
            conditionsText.toolTip = "Showing the rows where " + sql + ". This runs here, not on the server: = is exact whatever "
                + "the column's collation, and LIKE ignores case and accents"
        }
        clearButton.isHidden = conditions.isEmpty && searchField.stringValue.isEmpty
        scope.text = shown == total ? "Local · every row" : "Local · \(shown.formatted()) of \(total.formatted()) rows"
    }

    @objc private func clear(_ sender: Any?) { owner?.clearFilter(sender) }
    @objc private func searched(_ sender: Any?) { owner?.reorder() }

    /// Leaving an empty search with no filter on puts the bar away.
    func controlTextDidEndEditing(_ obj: Notification) { owner?.reorder() }
}

// Filtering, searching and sorting a console result (grid-spec §4): quick filters, Type a Value…, Filter by Values and
// Column Summary's values add conditions (⌥ or Add keeps those there are), Search All Columns keeps the rows with its
// text, and the sort orders what is left; all of it on the rows in memory, with no query.
extension ResultGridView {
    func focusedValues() -> QuickFilter.Focus? { QuickFilter.focus(viewer, columns: source.columns, value: rows.value) }

    func quickFilterItem() -> NSMenuItem {
        QuickFilter.menuItem(focusedValues(), noBackslashEscapes: false, target: self, action: #selector(applyQuickFilter(_:)))
    }

    @objc func applyQuickFilter(_ sender: NSMenuItem) {
        guard let condition = sender.representedObject as? GridCondition, let column = viewer.focusedCell?.column else { return }
        filter(column, by: condition, adding: sender.tag == 1)
    }

    /// The rows meeting `condition` on the source's `column`, alone or with the conditions there are.
    func filter(_ column: Int, by condition: GridCondition, adding: Bool) {
        conditions = (adding ? conditions : []) + [(column, condition)]
        reorder()
    }

    @objc func quickFilterEquals(_ sender: Any?) { quickFilter(.equals) }
    @objc func quickFilterNotEquals(_ sender: Any?) { quickFilter(.notEquals) }

    /// Data ▸ Quick Filter ▸'s other operators (the item's tag is the operator's index).
    @objc func quickFilter(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, GridCondition.Operator.allCases.indices.contains(tag) else { return }
        quickFilter(GridCondition.Operator.allCases[tag])
    }

    private func quickFilter(_ op: GridCondition.Operator) {
        guard let focus = focusedValues(), let column = viewer.focusedCell?.column, QuickFilter.reason(op, focus) == nil else {
            return NSSound.beep()
        }
        filter(column, by: QuickFilter.condition(op, focus), adding: false)
    }

    @objc func quickFilterPrompt(_ sender: Any?) {
        guard let focus = focusedValues(), let column = viewer.focusedCell?.column, let window else { return NSSound.beep() }
        QuickFilter.ask(focus, canAdd: !conditions.isEmpty, on: window) { [weak self] condition, adding in
            self?.filter(column, by: condition, adding: adding)
        }
    }

    /// Filter by Values…: the focused column's values in the rows shown, with their counts.
    @objc func filterByValues(_ sender: Any?) {
        guard let column = viewer.focusedColumn, let window else { return NSSound.beep() }
        let rows = rows
        FilterByValuesSheet.show(column: source.columns[column], table: "the result", onServer: false, on: window, read: {
            var counts: [String?: Int] = [:], order: [String?] = []
            for row in 0..<rows.rowCount {
                let value = rows.value(row, column)
                if counts[value] == nil { order.append(value) }
                counts[value, default: 0] += 1
            }
            let sorted = order.sorted { counts[$0]! > counts[$1]! }.prefix(FilterByValuesSheet.limit)
            return sorted.map { [$0, String(counts[$0]!)] }
        }, completion: { [weak self] condition in
            guard let condition else { return }
            self?.filter(column, by: condition, adding: true)
        })
    }

    @objc func clearFilter(_ sender: Any?) {
        conditions = []
        filterBar.searchField.stringValue = ""
        reorder()
    }

    @objc func searchAllColumns(_ sender: Any?) {
        filterBar.isHidden = false
        window?.makeFirstResponder(filterBar.searchField)
    }

    @objc func sortAscending(_ sender: Any?) { sortFocused(ascending: true) }
    @objc func sortDescending(_ sender: Any?) { sortFocused(ascending: false) }
    @objc func clearSort(_ sender: Any?) { sortRows([]) }

    private func sortFocused(ascending: Bool) {
        guard let column = viewer.focusedColumn else { return NSSound.beep() }
        sortRows([DataGridView.Sort(column: column, ascending: ascending)])
    }

    /// Sort by Columns…: the sort's columns, directions and order in a sheet.
    @objc func sortColumns(_ sender: Any?) {
        guard let window else { return NSSound.beep() }
        SortSheet.show(columns: source.columns, keys: grid.sortOrder.map { ($0.column, $0.ascending) }, title: "the result",
                       on: window) { [weak self] keys in
            self?.sortRows(keys.map { DataGridView.Sort(column: $0.column, ascending: $0.ascending) })
        }
    }

    /// The rows shown: those meeting every condition and holding the search's text, in the sort's order; matches tinted.
    func reorder() {
        let search = filterBar.searchField.stringValue, conditions = conditions, source = source, columns = source.columns.indices
        let find = findBar.find, expression = findBar.isHidden || !findBar.filtersRows ? nil : find.expression
        var shown: [Int]?
        if !conditions.isEmpty || !search.isEmpty || expression != nil {
            shown = (0..<source.rowCount).filter { row in
                conditions.allSatisfy { $0.condition.matches(source.value(row, $0.column)) }
                    && (search.isEmpty || GridFilter.matches(search, columns.map { source.value(row, $0) }))
                    && (expression == nil || columns.contains { find.matches(source.value(row, $0), expression) })
            }
        }
        let keys = viewer.sortOrder
        if !keys.isEmpty {
            shown = GridSorting.sorted(shown ?? Array(0..<source.rowCount), by: keys.map { ($0.column, $0.ascending) },
                                       columns: source.columns) { source.value($0, $1) }
        }
        let reordered = rows
        reordered.order = shown
        // In the grid: Record View's row and Transpose's columns would be other rows now.
        viewer.backToGrid(nil)
        updateHighlight()
        viewer.reloadData()
        filterBar.show(conditions.map(\.condition), shown: reordered.rowCount, of: source.rowCount)
        updateEmptyNote()
        let idle = conditions.isEmpty && search.isEmpty && filterBar.searchField.currentEditor() == nil
        guard idle else { return filterBar.isHidden = false }
        guard !filterBar.isHidden else { return }
        filterBar.isHidden = true
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: filterBar) { window?.makeFirstResponder(grid) }
    }

    func updateEmptyNote() {
        let filtered = source.rowCount > 0
        emptyNote.isHidden = rows.rowCount > 0 || viewer.presentation != .table
        emptyNote.text.stringValue = filtered ? "No rows match the filter or search." : "This result has no rows."
        emptyNote.clear.isHidden = conditions.isEmpty && filterBar.searchField.stringValue.isEmpty  // the find bar's filter is its own
    }

    /// Tints the cells holding Search All Columns' text and the find bar's matches.
    private func updateHighlight() {
        let search = filterBar.searchField.stringValue, find = findBar.find, rows = rows
        let expression = findBar.isHidden ? nil : find.expression
        guard !search.isEmpty || expression != nil else {
            viewer.highlight = nil
            return
        }
        viewer.highlight = { row, column in
            let value = rows.value(row, column)
            return expression.map { find.matches(value, $0) } == true || !search.isEmpty && GridFilter.matches(search, [value])
        }
    }

    /// Whether a filter or sort command can run now, and why not; nil for the others.
    func filterState(_ item: NSMenuItem) -> (Bool, String?)? {
        let focus = viewer.focusedCell != nil
        switch item.action {
        case Commands.find.action where item.tag == Commands.findAndReplace.tag:
            return (false, "Replace works in a table tab: a result's rows can only be found here")
        case Commands.filterEquals.action, Commands.filterNotEquals.action, Commands.filterPrompt.action:
            return (focus, "Select a cell first")
        case Commands.quickFilter.action:
            let reason = GridCondition.Operator.allCases.indices.contains(item.tag)
                ? QuickFilter.reason(GridCondition.Operator.allCases[item.tag], focusedValues()) : "Select a cell first"
            return (reason == nil, reason)
        case Commands.filterByValues.action, Commands.sortAscending.action, Commands.sortDescending.action:
            return (viewer.focusedColumn != nil, "Select a cell or a column first")
        case Commands.clearFilter.action:
            return (!conditions.isEmpty || !filterBar.searchField.stringValue.isEmpty, "The rows aren't filtered")
        case Commands.clearSort.action: return (!grid.sortOrder.isEmpty, "The rows aren't sorted")
        case Commands.sortColumns.action, Commands.searchAllColumns.action:
            return (!(grid.source is TransposedSource), "Leave Transpose or Record View first")
        default: return nil
        }
    }
}

extension ResultGridView: FindBarOwner {
    var findRows: GridSource? { rows }

    override func performTextFinderAction(_ sender: Any?) { findAction(sender) }

    /// The text or an option changed: the tint and the count, and the rows when Filter Rows is or was on.
    func findChanged() {
        let filtered = !findBar.isHidden && findBar.filtersRows
        if filtered || findFiltered { reorder() } else { updateHighlight() }
        findFiltered = filtered
        updateFindCount()
    }

    func findClosed() {
        findChanged()
        window?.makeFirstResponder(grid)
    }

    /// Never asked for: Find and Replace is off here (`filterState`).
    func replaceMatch(all: Bool) { NSSound.beep() }
}

extension ResultGridView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let (enabled, reason) = filterState(item) ?? editingState(item) else { return true }
        item.explain(enabled: enabled, reason: reason)
        return enabled
    }
}
