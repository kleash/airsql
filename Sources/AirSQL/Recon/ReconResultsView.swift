import AirSQLCore
import AppKit

/// What a compare found: the summary, the objects (differences first) and the selected object's details.
@MainActor
final class ReconResultsView: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    weak var window: ReconWindowController? { didSet { detail.window = window } }
    let view = NSView()
    let summary = NSStackView()
    let list = ReturnTable()
    let detail = ReconDetailView()
    /// The result's objects the filter and Hide Matching keep.
    private(set) var objects: [ReconObject] = []
    private var ordered: [ReconObject] = []
    private let emptyNote = label("What differs lists here", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private let split = NSSplitView()
    private lazy var filter = ListFilter("Filter Objects", id: "recon.filter", tip: "Type part of a name to show only those objects",
                                         list: list) { [weak self] in self?.arrange() }
    private lazy var hideMatching = checkbox("Hide Matching", id: "recon.hideMatching", tip: "Show only the objects that differ",
                                             on: false, target: self, action: #selector(hideMatchingToggled(_:)))
    private let listBar = NSStackView()
    private lazy var back = button("All Databases", id: "recon.back", tip: Commands.backToServer.tip, target: nil,
                                   action: #selector(ReconWindowController.backToServer(_:)))

    /// The list's first width, wide enough for names, when nothing is remembered (the window calls it once laid out).
    func placeDivider() {
        guard UserDefaults.standard.object(forKey: "NSSplitView Subview Frames " + (split.autosaveName ?? "")) == nil else { return }
        split.setPosition(348, ofDividerAt: 0)
    }

    override init() {
        super.init()
        summary.spacing = Spacing.unit
        summary.distribution = .fillEqually
        summary.alignment = .height
        summary.edgeInsets = NSEdgeInsets(top: Spacing.unit + 2, left: Spacing.double - 6, bottom: Spacing.unit + 2,
                                          right: Spacing.double - 6)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("object"))
        column.resizingMask = .autoresizingMask
        list.addTableColumn(column)
        list.headerView = nil
        list.rowHeight = 26
        list.style = .plain
        list.allowsMultipleSelection = true
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(open(_:))
        list.onReturn = { [weak self] in self?.open(nil) }
        list.setAccessibilityIdentifier("recon.list")
        list.setAccessibilityLabel("Compared objects")
        list.menu = NSMenu()
        list.menu?.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = layoutName("Compare split")
        back.isHidden = true
        listBar.setViews([back, filter, hideMatching], in: .leading)
        listBar.spacing = Spacing.unit
        listBar.edgeInsets = NSEdgeInsets(top: 6, left: Spacing.unit, bottom: 6, right: Spacing.unit)
        listBar.setHuggingPriority(.defaultHigh, for: .vertical)
        hideMatching.setContentCompressionResistancePriority(.required, for: .horizontal)
        let side = NSStackView(views: [listBar, scroll])
        side.orientation = .vertical
        side.distribution = .fill
        side.spacing = 0
        for view in side.arrangedSubviews { view.widthAnchor.constraint(equalTo: side.widthAnchor).isActive = true }
        emptyNote.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(emptyNote)
        NSLayoutConstraint.activate([emptyNote.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
                                     emptyNote.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)])
        split.addArrangedSubview(side)
        split.addArrangedSubview(detail.view)
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        detail.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        let stack = NSStackView(views: [summary, ReconWindowController.line(), split])
        stack.orientation = .vertical
        stack.distribution = .fill
        stack.spacing = 0
        summary.setHuggingPriority(.defaultHigh, for: .vertical)  // the list and details take the rest
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        view.addSubview(stack)
        stack.pin(to: view)
        view.translatesAutoresizingMaskIntoConstraints = false
        show(nil)
    }

    /// Shows a result: the differences first (only on one side, structure, data), then what matches. Before the first
    /// compare the details say what to do.
    func show(_ result: ReconResult?) {
        summary.isHidden = result == nil
        listBar.isHidden = result == nil
        guard let result else {
            ordered = []
            arrange()
            detail.showStart()
            return
        }
        ordered = result.objects.sorted { Self.rank($0) < Self.rank($1) }
        // Only on the target, and views and the like that differ, when there are any (the mockup's five boxes otherwise).
        let tints = [NSColor.statusOK, .statusWarning, .statusBad, .statusBad, .statusWarning, .statusWarning]
        summary.setViews(ReconReport.summary(result).enumerated().filter { $0.offset < 3 || $0.offset == 4 || $0.element.value != "0" }
            .map { index, item in Self.box(item.value, item.label, tint: tints[index], zero: item.value == "0") } + [Self.box(ActivityPopover.elapsed(result.duration), "\(result.rowsChecked.formatted()) rows checked, "
                      + Self.share(result.rowsFetched, of: result.rowsChecked) + " fetched", tint: .labelColor, zero: false)],
                         in: .leading)
        arrange()
        if !objects.isEmpty { list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        detail.show(objects.first, result: result)
    }

    /// Lists what the filter and Hide Matching keep; what stays listed stays selected.
    private func arrange() {
        let text = filter.stringValue
        let chosen = Set(selected.map(Self.key))
        objects = ordered.filter { object in
            (hideMatching.state == .off || object.differs) && (text.isEmpty || GridFilter.matches(text, [object.name, object.targetName]))
        }
        emptyNote.isHidden = !ordered.isEmpty
        list.reloadData()
        list.selectRowIndexes(IndexSet(objects.indices.filter { chosen.contains(Self.key(objects[$0])) }), byExtendingSelection: false)
    }

    private static func key(_ object: ReconObject) -> String { "\(object.kind) \(object.name)" }

    /// The same result with other ticks: the list and the details follow, selection and scrolling kept.
    func refresh(_ result: ReconResult) {
        ordered = result.objects.sorted { Self.rank($0) < Self.rank($1) }
        arrange()
        detail.refresh(selected.count == 1 ? selected.first : nil, result: result)
    }

    @objc private func hideMatchingToggled(_ sender: Any?) { arrange() }

    func update() {
        back.isHidden = window?.serverResult == nil
        detail.update()
    }

    @objc func tickToggled(_ sender: NSButton) {
        let row = list.row(for: sender)
        guard objects.indices.contains(row) else { return }
        window?.set([objects[row]], leftOut: sender.state == .off)
    }

    var selected: [ReconObject] { list.selectedRowIndexes.compactMap { objects.indices.contains($0) ? objects[$0] : nil } }

    private static func rank(_ object: ReconObject) -> (Int, Int, String) {
        let group: Int
        switch object.status {
        case .onlyInSource: group = 0
        case .onlyInTarget: group = 1
        case .different: group = 2
        case .same: group = object.data?.differs == true ? 3 : 4
        }
        return (group, ReconObject.Kind.allCases.firstIndex(of: object.kind) ?? 0, object.name.lowercased())
    }

    private static func share(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        // Rows are fetched from both sides, so all of a table that differs is more than the rows checked.
        let share = min(Double(part) / Double(whole) * 100, 100)
        return share > 0 && share < 0.1 ? "<0.1%" : String(format: share < 10 ? "%.1f%%" : "%.0f%%", share)
    }

    /// A summary box: a big number over what it counts.
    private static func box(_ value: String, _ text: String, tint: NSColor, zero: Bool) -> NSView {
        let box = SurfaceView(.content, radius: Radius.card, border: .separatorColor)
        let number = label(value, font: .systemFont(ofSize: 19, weight: .semibold), color: zero ? .secondaryLabelColor : tint)
        let caption = label(text, font: .systemFont(ofSize: 11), color: .secondaryLabelColor, wraps: true)
        caption.maximumNumberOfLines = 2
        caption.toolTip = text
        let stack = NSStackView(views: [number, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        box.addSubview(stack)
        stack.pin(to: box, insets: NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12))
        box.heightAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        box.setAccessibilityElement(true)
        box.setAccessibilityLabel("\(value) \(text)")
        return box
    }

    // MARK: The list

    func numberOfRows(in tableView: NSTableView) -> Int { objects.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ReconObjectCell.identifier, owner: self) as? ReconObjectCell ?? ReconObjectCell()
        if let result = window?.result { cell.show(objects[row], result: result) }
        cell.tick.target = self
        cell.tick.action = #selector(tickToggled(_:))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let result = window?.result else { return }
        detail.show(selected.count == 1 ? selected.first : nil, result: result)
        window?.update()
    }

    /// Double click and Return: the object's rows when they differ, else its structure.
    @objc private func open(_ sender: Any?) {
        let row = list.clickedRow >= 0 ? list.clickedRow : list.selectedRow
        guard objects.indices.contains(row), let result = window?.result else { return }
        if result.isServer { return window?.openPair(objects[row]) ?? () }
        detail.show(objects[row], result: result, data: objects[row].data?.differs == true)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Right-clicking an object outside the selection selects it first.
        if list.clickedRow >= 0, !list.selectedRowIndexes.contains(list.clickedRow) {
            list.selectRowIndexes(IndexSet(integer: list.clickedRow), byExtendingSelection: false)
        }
        menu.removeAllItems()
        for command in [Commands.copy, Commands.copySyncScript, Commands.includeInSync, Commands.leaveOutOfCompare] {
            menu.addItem(command.item())
        }
    }
}

/// A row of the objects list: a tick for the sync script, its state as a chip, its name, and what differs.
final class ReconObjectCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("reconObject")
    let tick = checkbox("", id: "recon.tick", tip: Commands.includeInSync.tip, on: true, target: nil, action: nil)
    let chip = ChipView("", style: .neutral)
    let name = label("", truncates: true)
    let what = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    /// What differs keeps all of its text, up to 45% of the row: the name gives way first.
    private var whatMinimum: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        // Rows without a tick keep its room, so the names line up.
        let tickRoom = NSView()
        tickRoom.addSubview(tick)
        tick.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tickRoom.widthAnchor.constraint(equalToConstant: 16), tick.centerYAnchor.constraint(equalTo: tickRoom.centerYAnchor),
            tick.leadingAnchor.constraint(equalTo: tickRoom.leadingAnchor),
        ])
        let stack = NSStackView(views: [tickRoom, chip, name, what])
        stack.spacing = Spacing.unit
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        what.alignment = .right
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // What differs takes at most 40% of the row; past that it gives way (its tooltip has it).
        what.setContentCompressionResistancePriority(.defaultLow - 10, for: .horizontal)
        name.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        chip.label.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Every chip as wide as the widest, so the names line up.
        chip.label.alignment = .center
        chip.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.chipWidth).isActive = true
        addSubview(stack)
        stack.pin(to: self, insets: NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 6))
        what.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.4).isActive = true
        whatMinimum = what.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        whatMinimum.priority = .defaultLow + 5  // over the name's compression resistance, under the 40%
        whatMinimum.isActive = true
        textField = name
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ object: ReconObject, result: ReconResult) {
        let (text, style) = Self.chip(object)
        chip.text = text
        chip.style = style
        tick.isHidden = !object.differs || result.isServer
        tick.state = object.leftOut ? .off : .on
        tick.setAccessibilityLabel("Include \(object.name) in the sync script")
        name.stringValue = [.table, .database].contains(object.kind) ? object.name : "\(object.name) (\(object.kind.rawValue))"
        name.toolTip = name.stringValue + (object.targetName == object.name ? "" : " → \(object.targetName)")
        name.textColor = object.differs ? .labelColor : .secondaryLabelColor
        what.stringValue = result.databases[object.name].map(Self.what(pair:)) ?? Self.what(object)
        whatMinimum.constant = what.intrinsicContentSize.width
        what.toolTip = [what.stringValue, ReconReport.status(object, result)].filter { !$0.isEmpty }.joined(separator: ": ")
        setAccessibilityLabel("\(object.kind.rawValue) \(object.name), \(ReconReport.status(object, result))")
    }

    /// The widest chip's width: its text, its label's 2-point margins and the chip's 9-point insets.
    static let chipWidth = ["only source", "only target", "structure", "data", "match", "differs"].map {
        NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).size().width.rounded(.up) + 22
    }.max() ?? 0

    static func chip(_ object: ReconObject) -> (String, ChipView.Style) {
        switch object.status {
        case .onlyInSource: return ("only source", .tinted(.statusBad))
        case .onlyInTarget: return ("only target", .tinted(.statusBad))
        case .different where object.kind == .database: return ("differs", .tinted(.statusWarning))
        case .different: return ("structure", .tinted(.statusWarning))
        case .same: return object.data?.differs == true ? ("data", .accent) : ("match", .tinted(.statusOK))
        }
    }

    /// A pair of databases: "3 objects differ, 12 rows", or "" when it matches.
    static func what(pair: ReconResult) -> String {
        let objects = pair.objects.filter(\.differs)
        guard !objects.isEmpty else { return "" }
        let rows = objects.compactMap(\.data).reduce(0) { $0 + $1.differenceCount }
        return "\(objects.count) \(objects.count == 1 ? "object differs" : "objects differ")"
            + (rows > 0 ? ", \(rows.formatted()) \(rows == 1 ? "row" : "rows")" : "")
    }

    /// "1 column, 1 index · 12 changed, 3 missing".
    static func what(_ object: ReconObject) -> String {
        if object.kind == .database { return object.status == .different ? "couldn't be read" : "" }
        var parts: [String] = []
        let kinds: [(ReconPart.Kind, String, String)] = [(.column, "column", "columns"), (.index, "index", "indexes"),
                                                          (.foreignKey, "foreign key", "foreign keys"), (.check, "check", "checks")]
        for (kind, one, many) in kinds {
            let count = object.parts.filter { $0.kind == kind }.count
            if count > 0 { parts.append("\(count) \(count == 1 ? one : many)") }
        }
        parts += object.parts.filter { $0.kind == .options }.map { $0.name == "auto_increment" ? "AUTO_INCREMENT" : $0.name }
        if object.kind != .table, object.status == .different, object.parts.isEmpty { parts.append("definition") }
        var text = parts.joined(separator: ", ")
        if let data = object.data {
            let rows: String
            switch data.outcome {
            case .same, .notCompared: rows = ""
            case .different:
                rows = [(data.changed.count, "changed"), (data.missing.count, "missing"), (data.extra.count, "extra")]
                    .filter { $0.0 > 0 }.map { "\($0.0.formatted()) \($0.1)" }.joined(separator: ", ")
            case .differentWithoutKey: rows = "rows differ"
            case .tooManyDifferences: rows = "over \(ReconTableData.maxDifferences.formatted()) rows differ"
            }
            if !rows.isEmpty { text += (text.isEmpty ? "" : " · ") + rows }
        }
        return text
    }
}
