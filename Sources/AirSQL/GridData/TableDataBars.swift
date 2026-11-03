import AirSQLCore
import AppKit

/// The table tab's grid bar (grid-spec §4): a chip saying where filtering runs, the WHERE condition (coloured, growing to
/// eight lines; Return applies it, ⌥↓ or the clock lists the table's recent filters), Search All Columns and its "Loaded
/// rows only" switch, and the Data Grid page of the help.
@MainActor
final class TableDataBar: NSView, NSTextViewDelegate {
    weak var owner: TableDataController?
    let scope = ChipView("On server · all rows", style: .accent)
    let whereField = ConditionView.make()
    let recentButton = NSButton()
    let clearButton = NSButton()
    let searchField = NSSearchField()
    let loadedOnly = checkbox("Loaded rows only", id: "tableData.loadedOnly",
                              tip: "Search only the rows loaded so far, without asking the server", on: false, target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    var filterText: String {
        get { whereField.text }
        set {
            whereField.text = newValue
            clearButton.isHidden = GridFilter.condition(newValue).isEmpty
        }
    }

    var busy = false {
        didSet { busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil) }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        scope.setAccessibilityIdentifier("tableData.scope")
        scope.toolTip = "Where the filter and the sort run: on the server for every row, or here on the loaded rows"
        scope.label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)  // the search and WHERE narrow first
        let whereLabel = label("WHERE", font: .systemFont(ofSize: 10.5, weight: .semibold), color: .quietText)
        whereField.placeholder = "for example status = 'paid'"
        whereField.toolTip = "Type a WHERE condition and press Return to filter every row on the server (⌥↩ starts a new line, "
            + "⌥⎋ completes column names)"
        whereField.setAccessibilityIdentifier("tableData.where")
        whereField.setAccessibilityLabel("WHERE condition")
        whereField.delegate = self
        whereField.onReturn = { [weak self] in self?.filterEntered(nil) }
        whereField.onRecent = { [weak self] in self?.showRecent(nil) }
        whereField.box.setContentHuggingPriority(.defaultLow, for: .horizontal)
        whereField.box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(recentButton, symbol: "clock.arrow.circlepath", id: "tableData.recentFilters",
                  tip: "Use one of this table's recent filters (⌥↓ in the condition)", action: #selector(showRecent(_:)))
        configure(clearButton, symbol: "xmark.circle.fill", id: "tableData.clearFilter", tip: "Show every row again",
                  action: #selector(clearFilter(_:)))
        clearButton.isHidden = true
        searchField.placeholderString = "Search all columns"
        searchField.toolTip = "Find rows with this text in any column; press Return to search"
        searchField.setAccessibilityIdentifier("tableData.search")
        searchField.sendsWholeSearchString = true
        searchField.target = self
        searchField.action = #selector(searchEntered(_:))
        loadedOnly.target = self
        loadedOnly.action = #selector(searchEntered(_:))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityIdentifier("tableData.busy")
        spinner.toolTip = "Rows are loading from the server"
        let row = NSStackView(views: [scope, whereLabel, whereField.box, clearButton, recentButton, searchField, loadedOnly, spinner,
                                      helpButton(.dataGrid)])
        row.setHuggingPriority(.defaultHigh, for: .vertical)  // a bar keeps its height; the rows get the rest
        row.spacing = Spacing.unit
        row.setCustomSpacing(Spacing.half, after: whereLabel)
        row.setCustomSpacing(Spacing.half, after: whereField.box)
        row.setCustomSpacing(Spacing.half, after: clearButton)
        row.edgeInsets = NSEdgeInsets(top: 6, left: Spacing.unit, bottom: 6, right: Spacing.unit)
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
            whereField.box.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            // The bar grows with the condition's lines, keeping a margin round it.
            whereField.box.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 4),
            row.bottomAnchor.constraint(greaterThanOrEqualTo: whereField.box.bottomAnchor, constant: 4),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),  // its placeholder whole
            searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 190),
        ])
        // In a window at its smallest the search narrows first, then the condition, rather than the bar widening the
        // window (which holds its size at 500).
        let searchWidth = searchField.widthAnchor.constraint(equalToConstant: 190)
        searchWidth.priority = .init(480)
        let whereWidth = whereField.box.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        whereWidth.priority = .init(490)
        NSLayoutConstraint.activate([searchWidth, whereWidth])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.bar.cgColor }

    private func configure(_ button: NSButton, symbol: String, id: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.setAccessibilityIdentifier(id)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @objc private func filterEntered(_ sender: Any?) {
        owner?.applyFilter(whereField.text)
    }

    @objc func clearFilter(_ sender: Any?) {
        owner?.applyFilter("")
    }

    @objc private func searchEntered(_ sender: Any?) {
        owner?.search(searchField.stringValue, loadedOnly: loadedOnly.state == .on)
    }

    /// The table's recent filters, newest first; choosing one applies it.
    @objc func showRecent(_ sender: Any?) {
        let menu = NSMenu(title: "Recent Filters")
        let recent = owner?.settings.recentFilters ?? []
        if recent.isEmpty {
            let item = NSMenuItem(title: "No recent filters", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for filter in recent {
            let line = filter.split(whereSeparator: \.isNewline).joined(separator: " ")
            let item = NSMenuItem(title: line.count > 80 ? String(line.prefix(80)) + "…" : line,
                                  action: #selector(recentChosen(_:)), keyEquivalent: "")
            item.representedObject = filter
            item.target = self
            item.toolTip = "Filter by \(filter)"
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: whereField.box.frame.minX, y: whereField.box.frame.minY - 4), in: whereField.box.superview)
    }

    @objc private func recentChosen(_ item: NSMenuItem) {
        guard let filter = item.representedObject as? String else { return }
        filterText = filter
        owner?.applyFilter(filter)
    }

    func textDidChange(_ notification: Notification) {
        clearButton.isHidden = whereField.text.isEmpty
    }

    /// Completion in the condition (⌥⎋ or F5): the table's columns (quoted when they need it) and the words conditions use.
    func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                  indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
        let partial = (textView.string as NSString).substring(with: charRange).lowercased()
        let names = (owner?.source?.columns ?? []).map { column -> String in
            let plain = column.name.first.map { $0.isLetter || $0 == "_" } == true
                && column.name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            return plain ? column.name : SQLQuote.identifier(column.name)
        }
        let keywords = ["AND", "OR", "NOT", "IS NULL", "IS NOT NULL", "LIKE", "IN", "BETWEEN", "NOW()", "CURDATE()"]
        index?.pointee = -1
        return (names + keywords).filter { $0.lowercased().hasPrefix(partial) || $0.lowercased().hasPrefix("`" + partial) }
    }
}

/// The notice under the grid bar: pending changes with Preview SQL, Revert All and Apply; why the table is read-only;
/// or what went wrong. Hidden when there is nothing to say.
@MainActor
final class TableDataNotice: NSView {
    enum Kind { case pending, readOnly, problem }

    /// Its buttons act on the tab (or the console result) even while the focus is elsewhere.
    weak var owner: AnyObject? {
        didSet { for control in [preview, revert, apply] { control.target = owner } }
    }
    let text = label("", font: .systemFont(ofSize: 12), wraps: true)
    lazy var preview = button("Preview SQL…", id: "tableData.preview", tip: Commands.previewChanges.tip, target: nil,
                              action: Commands.previewChanges.action)
    lazy var revert = button("Revert All", id: "tableData.revert", tip: "Throw away every pending change",
                             target: nil, action: #selector(TableDataController.revertAllChanges(_:)))
    lazy var apply = button("Apply", id: "tableData.apply", tip: Commands.apply.tip, target: nil, action: Commands.apply.action)
    private var kind = Kind.readOnly

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("tableData.notice")
        text.setAccessibilityIdentifier("tableData.noticeText")
        apply.keyEquivalent = ""
        for control in [preview, revert, apply] { control.controlSize = .small }
        let row = NSStackView(views: [text, preview, revert, apply])
        row.setHuggingPriority(.defaultHigh, for: .vertical)  // a bar keeps its height; the rows get the rest
        row.spacing = Spacing.unit
        row.edgeInsets = NSEdgeInsets(top: 5, left: Spacing.double, bottom: 5, right: Spacing.unit)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        row.pin(to: self)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ kind: Kind, _ message: String?) {
        self.kind = kind
        isHidden = message == nil
        text.stringValue = message ?? ""
        text.textColor = kind == .problem ? NSColor.statusBad.asTextOnItsTint : kind == .readOnly ? .secondaryLabelColor : .labelColor
        for control in [preview, revert, apply] { control.isHidden = kind != .pending }
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let color: NSColor = kind == .pending ? .pendingEdit : kind == .problem ? .pendingDelete : .bar
        layer?.backgroundColor = color.cgColor
    }
}
