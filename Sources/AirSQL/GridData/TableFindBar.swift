import AirSQLCore
import AppKit

/// Find (⌘F) and Find and Replace (⌥⌘F) in the loaded rows (grid-spec §4): the next and previous match (⌘G, ⇧⌘G),
/// "X of Y" cells, options for case, regular expressions, whole words and Filter Rows (hide the rows without a match);
/// replacements become pending edits. Hidden until asked for; Esc or Done hides it.
@MainActor
final class TableFindBar: NSView, NSSearchFieldDelegate {
    weak var owner: TableDataController?
    let findField = NSSearchField()
    let replaceField = NSTextField()
    let options = NSPopUpButton(frame: .zero, pullsDown: true)
    let count = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor)
    lazy var previous = button("◀", id: "find.previous", tip: "Show the previous match (⇧⌘G)", target: self, action: #selector(goPrevious(_:)))
    lazy var next = button("▶", id: "find.next", tip: "Show the next match (⌘G)", target: self, action: #selector(goNext(_:)))
    lazy var replace = button("Replace", id: "find.replace", tip: "Replace the match in the focused cell (a pending edit)",
                              target: self, action: #selector(replaceOne(_:)))
    lazy var replaceAll = button("Replace All", id: "find.replaceAll", tip: "Replace every match in the loaded rows (pending edits)",
                                 target: self, action: #selector(replaceEvery(_:)))
    lazy var done = button("Done", id: "find.done", tip: "Hide the find bar", target: self, action: #selector(close(_:)))
    private static let optionTitles = ["Match Case", "Regular Expression", "Whole Words", "Filter Rows"]
    private static let optionTips = ["Tell capitals from small letters", "Read the text as a regular expression ($1 in the replacement)",
                                     "Match whole words only", "Hide the loaded rows without a match"]

    var find: GridFind {
        GridFind(findField.stringValue, matchCase: isOn(0), regex: isOn(1), wholeWords: isOn(2))
    }

    var filtersRows: Bool { isOn(3) }

    private func isOn(_ index: Int) -> Bool { options.item(at: index + 1)?.state == .on }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        findField.placeholderString = "Find in loaded rows"
        findField.toolTip = "Find this text in the loaded rows; Return shows the next match"
        findField.setAccessibilityIdentifier("find.text")
        findField.sendsWholeSearchString = true
        findField.delegate = self
        findField.target = self
        findField.action = #selector(goNext(_:))
        replaceField.placeholderString = "Replace with"
        replaceField.toolTip = "Type the text that replaces each match"
        replaceField.setAccessibilityIdentifier("find.replaceText")
        options.addItem(withTitle: "Options")
        for (title, tip) in zip(Self.optionTitles, Self.optionTips) {
            let item = NSMenuItem(title: title, action: #selector(toggle(_:)), keyEquivalent: "")
            item.target = self
            item.toolTip = tip
            options.menu?.addItem(item)
        }
        options.toolTip = "Match case, regular expressions, whole words, or show only the rows with a match"
        options.setAccessibilityIdentifier("find.options")
        count.setAccessibilityIdentifier("find.count")
        for control in [previous, next, replace, replaceAll, done] { control.controlSize = .small }
        // 200 wide when there is room, narrower rather than widening a window at its smallest (which holds its size at
        // 500); hidden, the bar still sets the tab's narrowest, so Replace is only there once asked for.
        for field in [findField, replaceField] {
            field.controlSize = .small
            field.translatesAutoresizingMaskIntoConstraints = false
            let preferred = field.widthAnchor.constraint(equalToConstant: 200)
            preferred.priority = .init(490)
            NSLayoutConstraint.activate([field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
                                         field.widthAnchor.constraint(lessThanOrEqualToConstant: 200), preferred])
        }
        for view in [replaceField, replace, replaceAll] { view.isHidden = true }
        options.controlSize = .small
        let row = NSStackView(views: [findField, replaceField, options, previous, next, count, NSView(), replace, replaceAll, done])
        row.setHuggingPriority(.defaultHigh, for: .vertical)  // a bar keeps its height; the rows get the rest
        row.spacing = Spacing.unit
        row.edgeInsets = NSEdgeInsets(top: 5, left: Spacing.unit, bottom: 5, right: Spacing.unit)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        row.pin(to: self)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.bar.cgColor }

    /// Shows the bar (with the replace field when `replacing`) and puts the keyboard in the find field.
    func show(replacing: Bool) {
        isHidden = false
        for view in [replaceField, replace, replaceAll] { view.isHidden = !replacing }
        window?.makeFirstResponder(findField)
    }

    @objc private func toggle(_ item: NSMenuItem) {
        item.state = item.state == .on ? .off : .on
        owner?.findChanged()
    }

    func controlTextDidChange(_ obj: Notification) { owner?.findChanged() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(cancelOperation(_:)) else { return false }
        close(nil)
        return true
    }

    @objc func goNext(_ sender: Any?) { owner?.findMatch(forward: true) }
    @objc func goPrevious(_ sender: Any?) { owner?.findMatch(forward: false) }
    @objc private func replaceOne(_ sender: Any?) { owner?.replaceMatch(all: false) }
    @objc private func replaceEvery(_ sender: Any?) { owner?.replaceMatch(all: true) }

    @objc func close(_ sender: Any?) {
        isHidden = true
        owner?.findClosed()
    }
}

extension TableDataController {
    /// ⌘F, ⌥⌘F, ⌘G, ⇧⌘G and ⌘E (Use Selection for Find) in the table tab: the find bar over the loaded rows.
    override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        switch NSTextFinder.Action(rawValue: tag) {
        case .showReplaceInterface: findBar.show(replacing: true)
        case .nextMatch: findMatch(forward: true)
        case .previousMatch: findMatch(forward: false)
        case .setSearchString:
            if let (_, value, _) = focusedValues(), let value { findBar.findField.stringValue = value }
            findChanged()
        default: findBar.show(replacing: false)
        }
    }

    /// The text or an option changed: the rows again when Filter Rows is on, the matches tinted, and the count.
    func findChanged() {
        updateLocalFilter()
        updateHighlight()
        updateFindCount()
    }

    func findClosed() {
        updateLocalFilter()
        updateHighlight()
        view.window?.makeFirstResponder(grid)
    }

    /// Tints the cells the find bar matches and those holding Search All Columns' text (through the viewer).
    func updateHighlight() {
        let search = bar.searchField.stringValue, find = findBar.find, expression = findBar.isHidden ? nil : find.expression
        guard let source, !search.isEmpty || expression != nil else {
            viewer.highlight = nil
            return
        }
        viewer.highlight = { row, column in
            let value = source.value(row, column)
            return expression.map { find.matches(value, $0) } == true || !search.isEmpty && GridFilter.matches(search, [value])
        }
    }

    /// The loaded rows shown: those holding the loaded-rows search (Loaded rows only) and a match of the find bar
    /// (Filter Rows).
    func updateLocalFilter() {
        guard let source else { return }
        let search = bar.loadedOnly.state == .on ? bar.searchField.stringValue : ""
        let find = findBar.find, expression = findBar.isHidden || !findBar.filtersRows ? nil : find.expression
        if search.isEmpty, expression == nil {
            source.localFilter = nil
        } else {
            source.localFilter = { values in
                (search.isEmpty || GridFilter.matches(search, values)) && (expression == nil || values.contains { find.matches($0, expression) })
            }
        }
        viewer.reloadData()
        updateBars()
    }

    /// The matching cells in grid order (rows, then display columns).
    private func matches() -> [GridPosition] {
        guard let source else { return [] }
        let find = findBar.find
        guard let expression = find.expression else { return [] }
        var found: [GridPosition] = []
        for row in 0..<source.rowCount {
            for display in 0..<grid.columnCount where find.matches(source.value(row, grid.sourceColumn(display)), expression) {
                found.append(GridPosition(row: row, column: display))
            }
        }
        return found
    }

    private func updateFindCount() {
        let found = matches(), cursor = grid.selection.cursor
        if findBar.findField.stringValue.isEmpty {
            findBar.count.stringValue = ""
        } else if findBar.find.expression == nil {
            findBar.count.stringValue = "Not a valid regular expression"
        } else if let cursor, let index = found.firstIndex(of: cursor) {
            findBar.count.stringValue = "\((index + 1).formatted()) of \(found.count.formatted())"
        } else {
            findBar.count.stringValue = found.isEmpty ? "No matches" : "\(found.count.formatted()) matching"
        }
    }

    /// Selects the next (or previous) matching cell after the focused one, wrapping around (in the grid: out of Transpose
    /// and Record View).
    func findMatch(forward: Bool) {
        if findBar.isHidden { findBar.show(replacing: false) }
        viewer.backToGrid(nil)
        let found = matches()
        guard !found.isEmpty else {
            updateFindCount()
            return NSSound.beep()
        }
        let cursor = grid.selection.cursor ?? GridPosition(row: forward ? -1 : grid.rowCount, column: 0)
        func before(_ a: GridPosition, _ b: GridPosition) -> Bool { a.row < b.row || (a.row == b.row && a.column < b.column) }
        let target = forward ? found.first { before(cursor, $0) } ?? found[0] : found.last { before($0, cursor) } ?? found[found.count - 1]
        grid.selection.select(target)
        grid.reveal(grid.cellRect(target))
        updateFindCount()
    }

    /// Replaces the match in the focused cell (then shows the next), or in every loaded cell: pending edits.
    func replaceMatch(all: Bool) {
        guard let source, editingOff == nil else { return NSSound.beep() }
        viewer.backToGrid(nil)
        let find = findBar.find, replacement = findBar.replaceField.stringValue
        guard let expression = find.expression else { return NSSound.beep() }
        let targets = all ? matches() : grid.selection.cursor.map { [$0] } ?? []
        var replaced = 0
        for position in targets {
            let column = grid.sourceColumn(position.column)
            guard source.canEdit(position.row, column), let value = source.value(position.row, column),
                  find.matches(value, expression) else { continue }
            source.set(.text(find.replacing(in: value, with: replacement, expression)), row: position.row, column: column)
            replaced += 1
        }
        guard replaced > 0 else { return all ? NSSound.beep() : findMatch(forward: true) }
        changesDidChange()
        if all {
            findBar.count.stringValue = "Replaced \(replaced.formatted()) \(replaced == 1 ? "value" : "values")"
        } else {
            findMatch(forward: true)
        }
    }
}
