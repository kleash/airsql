import AirSQLCore
import AppKit

/// What a compare found: the summary, the objects (differences first) and the selected object's details.
@MainActor
final class ReconResultsView: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    weak var window: ReconWindowController? { didSet { detail.window = window } }
    let view = NSView()
    let summary = NSStackView()
    let list = NSTableView()
    let detail = ReconDetailView()
    let empty = label("Choose a database on each side, then Compare (⌘R). The script it makes changes the target only when you run it.",
                      color: .secondaryLabelColor, wraps: true)
    private(set) var objects: [ReconObject] = []
    private let split = NSSplitView()

    override init() {
        super.init()
        summary.spacing = Spacing.unit
        summary.distribution = .fillEqually
        summary.edgeInsets = NSEdgeInsets(top: Spacing.unit + 2, left: Spacing.double - 6, bottom: Spacing.unit + 2,
                                          right: Spacing.double - 6)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("object"))
        column.resizingMask = .autoresizingMask
        list.addTableColumn(column)
        list.headerView = nil
        list.rowHeight = 26
        list.style = .sourceList
        list.allowsMultipleSelection = true
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(open(_:))
        list.setAccessibilityIdentifier("recon.list")
        list.setAccessibilityLabel("Compared objects")
        list.menu = NSMenu()
        list.menu?.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "Compare split"
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(detail.view)
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        detail.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        let stack = NSStackView(views: [summary, Hairline(), split])
        stack.orientation = .vertical
        stack.spacing = 0
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        stack.pin(to: view)
        view.addSubview(empty)
        empty.preferredMaxLayoutWidth = 520
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        view.translatesAutoresizingMaskIntoConstraints = false
        show(nil)
    }

    /// Shows a result: the differences first (only on one side, structure, data), then what matches.
    func show(_ result: ReconResult?) {
        summary.isHidden = result == nil
        split.isHidden = result == nil
        empty.isHidden = result != nil
        guard let result else { return }
        objects = result.objects.sorted { Self.rank($0) < Self.rank($1) }
        summary.setViews(ReconReport.summary(result).enumerated().map { index, item in
            Self.box(item.value, item.label, tint: [NSColor.statusOK, .statusWarning, .statusBad, .statusBad, .statusWarning,
                                                    .statusWarning][index], zero: item.value == "0")
        } + [Self.box(Self.duration(result.duration), "\(result.rowsChecked.formatted()) rows checked, "
                      + Self.share(result.rowsFetched, of: result.rowsChecked) + " fetched", tint: .labelColor, zero: false)],
                         in: .leading)
        list.reloadData()
        list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        detail.show(objects.first, result: result)
    }

    func update() { detail.update() }

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

    private static func duration(_ seconds: TimeInterval) -> String {
        seconds < 60 ? String(format: seconds < 10 ? "%.1f s" : "%.0f s", seconds) : "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
    }

    private static func share(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        let share = Double(part) / Double(whole) * 100
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
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let result = window?.result else { return }
        detail.show(selected.count == 1 ? selected.first : nil, result: result)
        window?.update()
    }

    /// Double click: the object's rows when they differ, else its structure.
    @objc private func open(_ sender: Any?) {
        guard list.clickedRow >= 0, let result = window?.result else { return }
        detail.show(objects[list.clickedRow], result: result, data: objects[list.clickedRow].data?.differs == true)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Right-clicking an object outside the selection selects it first.
        if list.clickedRow >= 0, !list.selectedRowIndexes.contains(list.clickedRow) {
            list.selectRowIndexes(IndexSet(integer: list.clickedRow), byExtendingSelection: false)
        }
        menu.removeAllItems()
        for command in [Commands.copy, Commands.copySyncScript, Commands.leaveOutOfCompare] { menu.addItem(command.item()) }
    }
}

/// A row of the objects list: its state as a chip, its name, and what differs.
final class ReconObjectCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("reconObject")
    let chip = ChipView("", style: .neutral)
    let name = label("", truncates: true)
    let what = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let stack = NSStackView(views: [chip, name, what])
        stack.spacing = Spacing.unit
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        what.alignment = .right
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.pin(to: self, insets: NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 6))
        textField = name
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ object: ReconObject, result: ReconResult) {
        let (text, style) = Self.chip(object)
        chip.text = text
        chip.style = style
        name.stringValue = object.kind == .table ? object.name : "\(object.name) (\(object.kind.rawValue))"
        name.toolTip = object.targetName == object.name ? object.name : "\(object.name) → \(object.targetName)"
        name.textColor = object.differs ? .labelColor : .secondaryLabelColor
        what.stringValue = Self.what(object)
        what.toolTip = ReconReport.status(object, result)
        setAccessibilityLabel("\(object.kind.rawValue) \(object.name), \(ReconReport.status(object, result))")
    }

    static func chip(_ object: ReconObject) -> (String, ChipView.Style) {
        switch object.status {
        case .onlyInSource: return ("only left", .tinted(.statusBad))
        case .onlyInTarget: return ("only right", .tinted(.statusBad))
        case .different: return ("structure", .tinted(.statusWarning))
        case .same: return object.data?.differs == true ? ("data", .accent) : ("match", .tinted(.statusOK))
        }
    }

    /// "1 column, 1 index · 12 changed, 3 missing".
    static func what(_ object: ReconObject) -> String {
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
