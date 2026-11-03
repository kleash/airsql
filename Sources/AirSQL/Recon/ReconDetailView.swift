import AirSQLCore
import AppKit

/// The selected object's details: its two definitions side by side with the lines that differ marked, or its rows that
/// differ; and its part of the sync script.
@MainActor
final class ReconDetailView: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var window: ReconWindowController?
    let view = NSView()
    let tabs = NSSegmentedControl(labels: ["Structure", "Data"], trackingMode: .selectOne, target: nil, action: nil)
    let ignoring = label("", font: .systemFont(ofSize: 11.5), color: .tertiaryLabelColor, truncates: true)
    let left = ReconDetailView.textView(id: "recon.sourceDDL")
    let right = ReconDetailView.textView(id: "recon.targetDDL")
    let leftTitle = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    let rightTitle = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    let rows = NSTableView()
    let message = label("", color: .secondaryLabelColor, wraps: true)
    let scriptTitle = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    let destructive = checkbox("Include destructive steps", id: "recon.destructive",
                               tip: "Put DROP, DELETE and narrowing changes in the script too, each marked; off, the script only adds and changes",
                               on: false, target: nil, action: nil)
    let script = ReconDetailView.textView(id: "recon.script")
    private let structure = NSSplitView()
    private let rowsScroll = NSScrollView()
    private var object: ReconObject?
    private var result: ReconResult?
    /// The script's steps by object ("table orders"), with destructive steps ("all") and without ("safe").
    private var steps: [String: [String: [ReconStep]]] = [:]

    override init() {
        super.init()
        tabs.target = self
        tabs.action = #selector(tabChosen(_:))
        tabs.selectedSegment = 0
        tabs.setToolTip("Show the two definitions side by side", forSegment: 0)
        tabs.setToolTip("Show the rows that differ, down to the cell", forSegment: 1)
        tabs.setAccessibilityIdentifier("recon.tabs")
        destructive.target = self
        destructive.action = #selector(destructiveToggled(_:))
        let header = NSStackView(views: [tabs, ignoring])
        header.spacing = Spacing.double
        header.edgeInsets = NSEdgeInsets(top: 6, left: Spacing.unit, bottom: 6, right: Spacing.double)
        func column(_ title: NSTextField, _ text: NSScrollView) -> NSView {
            let stack = NSStackView(views: [title, text])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            stack.edgeInsets = NSEdgeInsets(top: 6, left: Spacing.unit, bottom: 0, right: 0)
            text.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -Spacing.unit).isActive = true
            return stack
        }
        structure.isVertical = true
        structure.dividerStyle = .thin
        structure.addArrangedSubview(column(leftTitle, left))
        structure.addArrangedSubview(column(rightTitle, right))
        rows.usesAlternatingRowBackgroundColors = true
        rows.dataSource = self
        rows.delegate = self
        rows.allowsMultipleSelection = true
        rows.columnAutoresizingStyle = .noColumnAutoresizing
        rows.setAccessibilityIdentifier("recon.rows")
        rows.setAccessibilityLabel("Rows that differ")
        rowsScroll.documentView = rows
        rowsScroll.hasVerticalScroller = true
        rowsScroll.hasHorizontalScroller = true
        message.alignment = .center
        let scriptHeader = NSStackView(views: [scriptTitle, destructive])
        scriptHeader.spacing = Spacing.double
        scriptHeader.edgeInsets = NSEdgeInsets(top: 6, left: Spacing.unit, bottom: 4, right: Spacing.double)
        script.heightAnchor.constraint(equalToConstant: 150).isActive = true
        let content = NSView()
        for view in [structure, rowsScroll] as [NSView] { view.pin(to: content) }
        content.addSubview(message)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -48),
        ])
        let stack = NSStackView(views: [header, Hairline(), content, Hairline(), scriptHeader, script])
        stack.orientation = .vertical
        stack.spacing = 0
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.pin(to: view)
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    /// A read-only monospaced text view in a scroll view, for definitions and scripts.
    static func textView(id: String) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.setAccessibilityIdentifier(id)
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    private func text(_ scroll: NSScrollView) -> NSTextView { scroll.documentView as! NSTextView }

    var includeDestructive: Bool { destructive.state == .on }

    func show(_ object: ReconObject?, result: ReconResult, data: Bool? = nil) {
        if self.result.map({ $0.objects != result.objects }) ?? true { steps = [:] }
        self.object = object
        self.result = result
        if let data { tabs.selectedSegment = data ? 1 : 0 }
        update()
    }

    func update() {
        guard let result else { return }
        let rules = result.options.ignore
        let ignored = [rules.autoIncrement ? "AUTO_INCREMENT" : nil, rules.definer ? "DEFINER" : nil,
                       rules.collation ? "collations" : nil, rules.whitespace ? "whitespace" : nil].compactMap { $0 }
        ignoring.stringValue = ignored.isEmpty ? "Nothing ignored" : "Ignoring " + ignored.joined(separator: ", ")
        tabs.setEnabled(object?.data != nil, forSegment: 1)
        if object?.data == nil { tabs.selectedSegment = 0 }
        let showsData = tabs.selectedSegment == 1
        structure.isHidden = showsData || object == nil
        rowsScroll.isHidden = !showsData || object == nil
        message.isHidden = true
        scriptTitle.stringValue = "Sync script (makes \(result.target.name) match \(result.source.name)) · review before running"
        guard let object else {
            message.stringValue = "Select one object to see what differs."
            message.isHidden = false
            text(script).string = ""
            return
        }
        if showsData { showRows(object) } else { showStructure(object, result) }
        let key = includeDestructive ? "all" : "safe"
        if steps[key] == nil {
            steps[key] = Dictionary(grouping: result.steps(destructive: includeDestructive)) { "\($0.objectKind) \($0.object)" }
        }
        let own = steps[key]?["\(object.kind) \(object.name)"] ?? []
        text(script).string = own.isEmpty ? "-- Nothing to sync for \(object.name)" + (object.differs && !includeDestructive
            ? ": what differs only goes away with destructive steps" : "")
            : own.prefix(200).map { $0.sql + ";" }.joined(separator: "\n\n")
                + (own.count > 200 ? "\n\n-- … and \(own.count - 200) more statements: Sync Script… shows them all" : "")
    }

    private func showStructure(_ object: ReconObject, _ result: ReconResult) {
        leftTitle.stringValue = "\(result.source.name) · \(result.source.database).\(object.name)"
        rightTitle.stringValue = "\(result.target.name) · \(result.target.database).\(object.targetName)"
        if object.status == .same, object.sourceDDL == nil {
            message.stringValue = "\(object.name) has the same structure on both sides."
            message.isHidden = false
            structure.isHidden = true
            return
        }
        let missing = NSAttributedString(string: "(missing)", attributes: [.foregroundColor: NSColor.tertiaryLabelColor,
                                                                            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
        let (a, b) = (NSMutableAttributedString(), NSMutableAttributedString())
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let rows = ReconLines.aligned(object.sourceDDL ?? "", object.targetDDL ?? "")
        for (index, row) in rows.enumerated() {
            let end = index == rows.count - 1 ? "" : "\n"
            for (side, line, mark) in [(a, row.left, NSColor.statusOK), (b, row.right, NSColor.statusBad)] {
                if let line {
                    var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
                    if (row.left == nil) != (row.right == nil) { attributes[.backgroundColor] = mark.withAlphaComponent(0.16) }
                    side.append(NSAttributedString(string: line + end, attributes: attributes))
                } else {
                    side.append(missing)
                    side.append(NSAttributedString(string: end, attributes: [.font: font]))
                }
            }
        }
        if object.sourceDDL == nil { a.setAttributedString(NSAttributedString(string: "Not in \(result.source.name)", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])) }
        if object.targetDDL == nil { b.setAttributedString(NSAttributedString(string: "Not in \(result.target.name)", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])) }
        text(left).textStorage?.setAttributedString(a)
        text(right).textStorage?.setAttributedString(b)
    }

    // MARK: Rows

    private var shown: [(kind: String, row: ReconRow, changed: ReconRowChange?)] = []

    private func showRows(_ object: ReconObject) {
        guard let data = object.data else { return }
        shown = data.missing.map { ("Missing", $0, nil) } + data.extra.map { ("Extra", $0, nil) }
            + data.changed.map { ("Changed", $0.source, $0) }
        for column in rows.tableColumns.reversed() { rows.removeTableColumn(column) }
        for (index, title) in (["Row"] + data.columns.map(\.name)).enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
            column.title = title
            column.headerToolTip = index == 0 ? "Missing: only in the source; Extra: only in the target; Changed: in both"
                : (index - 1 < data.key.count ? "Key column \(title)" : "Column \(title)")
            column.width = index == 0 ? 80 : 140
            rows.addTableColumn(column)
        }
        rows.reloadData()
        switch data.outcome {
        case .differentWithoutKey, .tooManyDifferences, .notCompared:
            message.stringValue = ReconReport.lines(object, result!).last?.detail.capitalizedFirst ?? ""
            message.isHidden = false
            rowsScroll.isHidden = true
        case .same:
            message.stringValue = "The rows of \(object.name) are the same on both sides."
            message.isHidden = false
            rowsScroll.isHidden = true
        case .different: break
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let index = Int(tableColumn.identifier.rawValue), let data = object?.data else { return nil }
        let field = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTextField
            ?? label("", font: .monospacedSystemFont(ofSize: 11.5, weight: .regular), truncates: true)
        field.identifier = tableColumn.identifier
        let item = shown[row]
        field.drawsBackground = false
        guard index > 0 else {
            field.stringValue = item.kind
            field.textColor = item.kind == "Missing" ? .statusOK : item.kind == "Extra" ? .statusBad : .statusWarning
            field.toolTip = nil
            return field
        }
        let column = index - 1, kind = data.columns[column].kind
        let value = item.row.text(column, kind: kind)
        field.stringValue = value.map { String($0.prefix(300)) } ?? "NULL"
        field.textColor = value == nil ? .dataNull : .labelColor
        if let change = item.changed, change.columns.contains(column) {
            let old = change.target.text(column, kind: kind) ?? "NULL"
            field.drawsBackground = true
            field.backgroundColor = .pendingEdit
            field.toolTip = "\(result?.target.name ?? "Target") has \(old.prefix(300)); \(result?.source.name ?? "source") has \(value?.prefix(300) ?? "NULL")"
        } else {
            field.toolTip = value.map { String($0.prefix(300)) }
        }
        return field
    }

    @objc private func tabChosen(_ sender: Any?) { update() }

    @objc private func destructiveToggled(_ sender: Any?) {
        update()
        window?.update()
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
