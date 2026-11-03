import AirSQLCore
import AppKit

/// The table tab's grid bar (grid-spec §4): a chip saying where filtering runs, the WHERE condition (Return applies it,
/// ⌥↓ or the clock lists the table's recent filters), Search All Columns and its "Loaded rows only" switch.
@MainActor
final class TableDataBar: NSView, NSTextFieldDelegate {
    weak var owner: TableDataController?
    let scope = ChipView("On server · all rows", style: .accent)
    let whereField = NSTextField()
    let recentButton = NSButton()
    let clearButton = NSButton()
    let searchField = NSSearchField()
    let loadedOnly = checkbox("Loaded rows only", id: "tableData.loadedOnly",
                              tip: "Search only the rows loaded so far, without asking the server", on: false, target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    var filterText: String {
        get { whereField.stringValue }
        set {
            whereField.stringValue = newValue
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
        let whereLabel = label("WHERE", font: .systemFont(ofSize: 10.5, weight: .semibold), color: .tertiaryLabelColor)
        whereField.placeholderString = "Type a condition, for example status = 'paid'"
        whereField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        whereField.toolTip = "Type a WHERE condition and press Return to filter every row on the server"
        whereField.setAccessibilityIdentifier("tableData.where")
        whereField.setAccessibilityLabel("WHERE condition")
        whereField.delegate = self
        whereField.target = self
        whereField.action = #selector(filterEntered(_:))
        whereField.lineBreakMode = .byTruncatingTail
        whereField.cell?.isScrollable = true
        whereField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        whereField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        let row = NSStackView(views: [scope, whereLabel, whereField, clearButton, recentButton, searchField, loadedOnly, spinner])
        row.spacing = Spacing.unit
        row.setCustomSpacing(Spacing.half, after: whereLabel)
        row.setCustomSpacing(Spacing.half, after: whereField)
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
            whereField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            searchField.widthAnchor.constraint(equalToConstant: 190),
        ])
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
        owner?.applyFilter(whereField.stringValue)
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
            let item = NSMenuItem(title: filter.count > 80 ? String(filter.prefix(80)) + "…" : filter,
                                  action: #selector(recentChosen(_:)), keyEquivalent: "")
            item.representedObject = filter
            item.target = self
            item.toolTip = "Filter by \(filter)"
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: whereField.frame.minX, y: whereField.frame.minY - 4), in: whereField.superview)
    }

    @objc private func recentChosen(_ item: NSMenuItem) {
        guard let filter = item.representedObject as? String else { return }
        filterText = filter
        owner?.applyFilter(filter)
    }

    /// ⌥↓ in the condition lists the recent filters.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.moveToEndOfParagraph(_:)) else { return false }
        showRecent(nil)
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        clearButton.isHidden = whereField.stringValue.isEmpty
    }
}

/// The notice under the grid bar: pending changes with Preview SQL, Revert All and Apply; why the table is read-only;
/// or what went wrong. Hidden when there is nothing to say.
@MainActor
final class TableDataNotice: NSView {
    enum Kind { case pending, readOnly, problem }

    /// Its buttons act on the tab even while the focus is elsewhere.
    weak var owner: TableDataController? {
        didSet { for control in [preview, revert, apply] { control.target = owner } }
    }
    let text = label("", font: .systemFont(ofSize: 12), wraps: true)
    lazy var preview = button("Preview SQL…", id: "tableData.preview", tip: Commands.previewChanges.tip, target: nil,
                              action: Commands.previewChanges.action)
    lazy var revert = button("Revert All", id: "tableData.revert", tip: "Throw away every pending change of this table",
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
        text.textColor = kind == .problem ? .statusBad : kind == .readOnly ? .secondaryLabelColor : .labelColor
        for control in [preview, revert, apply] { control.isHidden = kind != .pending }
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let color: NSColor = kind == .pending ? .pendingEdit : kind == .problem ? .pendingDelete : .bar
        layer?.backgroundColor = color.cgColor
    }
}

/// The status bar's right side for a table tab: rows loaded of the total (an estimate until counted), Count Exactly,
/// Load More and Load All.
@MainActor
final class TableDataStatus: NSStackView {
    /// Its links act on the tab even while the focus is elsewhere (the status bar is outside the tab).
    weak var owner: TableDataController? {
        didSet { for link in [count, more, all] { link.target = owner } }
    }
    let rows = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor)
    let count = TableDataStatus.link("Count Exactly", Commands.countRows, id: "tableData.count")
    let more = TableDataStatus.link("Load More", Commands.loadMore, id: "tableData.loadMore")
    let all = TableDataStatus.link("Load All", Commands.loadAll, id: "tableData.loadAll")

    init() {
        super.init(frame: .zero)
        setViews([rows, count, more, all], in: .leading)
        spacing = Spacing.unit
        rows.setAccessibilityIdentifier("tableData.rows")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A small text button in the accent colour that sends `command` through the responder chain.
    static func link(_ title: String, _ command: Command, id: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: command.action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 11.5)
        button.contentTintColor = .accent
        button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.accent,
                                                                                 .font: NSFont.systemFont(ofSize: 11.5)])
        button.toolTip = command.tip + (command.shortcut.isEmpty ? "" : " (\(command.shortcut))")
        button.setAccessibilityIdentifier(id)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
}
