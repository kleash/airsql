import AirSQLCore
import AppKit

/// The selected object's details: its two definitions side by side with the lines that differ marked, or its rows that
/// differ in the data grid (a `DiffSource`); and its part of the sync script.
@MainActor
final class ReconDetailView: NSObject {
    weak var window: ReconWindowController?
    let view = NSView()
    let tabs = NSSegmentedControl(labels: ["Structure", "Data"], trackingMode: .selectOne, target: nil, action: nil)
    static let structureTip = "Show the two definitions side by side", dataTip = "Show the rows that differ, down to the cell"
    let ignoring = label("", font: .systemFont(ofSize: 11.5), color: .quietText, truncates: true)
    let left = ReconDetailView.textView(id: "recon.sourceDDL")
    let right = ReconDetailView.textView(id: "recon.targetDDL")
    let leftTitle = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    let rightTitle = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    /// The selected table's rows that differ, while the Data tab shows them.
    private(set) var rows: ResultGridView?
    let message = label("", color: .secondaryLabelColor, wraps: true)
    let scriptTitle = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    let destructive = checkbox("Include destructive steps", id: "recon.destructive",
                               tip: "Put DROP, DELETE and narrowing changes in the script too, each marked; off, the script only adds and changes",
                               on: false, target: nil, action: nil)
    let script = ReconDetailView.textView(id: "recon.script")
    private let structure = NSSplitView()
    private let rowsHolder = NSView()
    private var object: ReconObject?
    private var result: ReconResult?
    private var scrollingTogether = false

    override init() {
        super.init()
        tabs.target = self
        tabs.action = #selector(tabChosen(_:))
        tabs.selectedSegment = 0
        tabs.selectedSegmentBezelColor = .selectedSegment
        tabs.setToolTip(Self.structureTip, forSegment: 0)
        tabs.setToolTip(Self.dataTip, forSegment: 1)
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
        let (leftColumn, rightColumn) = (column(leftTitle, left), column(rightTitle, right))
        structure.addArrangedSubview(leftColumn)
        structure.addArrangedSubview(rightColumn)
        let halves = leftColumn.widthAnchor.constraint(equalTo: rightColumn.widthAnchor)
        halves.priority = .defaultLow  // halves to start with; dragging the divider wins
        halves.isActive = true
        for side in [left, right] {
            side.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(definitionScrolled(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: side.contentView)
        }
        message.alignment = .center
        let scriptHeader = NSStackView(views: [scriptTitle, destructive])
        scriptHeader.spacing = Spacing.double
        scriptHeader.edgeInsets = NSEdgeInsets(top: 6, left: Spacing.unit, bottom: 4, right: Spacing.double)
        script.heightAnchor.constraint(equalToConstant: 150).isActive = true
        let content = NSView()
        for view in [structure, rowsHolder] {
            content.addSubview(view)
            view.pin(to: content)
        }
        content.addSubview(message)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -48),
        ])
        let stack = NSStackView(views: [header, ReconWindowController.line(), content, ReconWindowController.line(), scriptHeader, script])
        stack.orientation = .vertical
        stack.distribution = .fill
        stack.spacing = 0
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        for view in [header, scriptHeader] { view.setHuggingPriority(.defaultHigh, for: .vertical) }
        content.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        view.addSubview(stack)
        stack.pin(to: view)
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    /// A read-only monospaced text view in a scroll view, for definitions and scripts.
    static func textView(id: String) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.backgroundColor = .content
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.setAccessibilityIdentifier(id)
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    /// The definitions' lines are aligned: one side scrolled takes the other along, as far as it goes.
    @objc private func definitionScrolled(_ notification: Notification) {
        guard !scrollingTogether, let moved = notification.object as? NSClipView else { return }
        scrollingTogether = true
        defer { scrollingTogether = false }
        let other = moved === left.contentView ? right : left
        let wanted = NSRect(origin: moved.bounds.origin, size: other.contentView.bounds.size)
        other.contentView.scroll(to: other.contentView.constrainBoundsRect(wanted).origin)
        other.reflectScrolledClipView(other.contentView)
    }

    private func text(_ scroll: NSScrollView) -> NSTextView { scroll.documentView as! NSTextView }

    var includeDestructive: Bool { destructive.state == .on }

    func show(_ object: ReconObject?, result: ReconResult, data: Bool? = nil) {
        self.object = object
        self.result = result
        rows?.removeFromSuperview()
        rows = nil
        if let data { tabs.selectedSegment = data ? 1 : 0 }
        update()
    }

    /// Before the first compare: what to do.
    func showStart() {
        for segment in 0..<2 {
            tabs.setEnabled(false, forSegment: segment)
            tabs.setToolTip("Compare first: then there is something to show", forSegment: segment)
        }
        structure.isHidden = true
        rowsHolder.isHidden = true
        message.stringValue = "Choose a database on each side, then Compare (⌘R). The script it makes changes the target only "
            + "when you run it."
        message.isHidden = false
        scriptTitle.stringValue = "Sync script · review before running"
    }

    func update() {
        guard let result else { return }
        tabs.setEnabled(true, forSegment: 0)
        tabs.setToolTip(Self.structureTip, forSegment: 0)
        let rules = result.options.ignore
        let ignored = [rules.autoIncrement ? "AUTO_INCREMENT" : nil, rules.definer ? "DEFINER" : nil,
                       rules.collation ? "collations" : nil, rules.whitespace ? "whitespace" : nil].compactMap { $0 }
        ignoring.stringValue = ignored.isEmpty ? "Nothing ignored" : "Ignoring " + ignored.joined(separator: ", ")
        tabs.setEnabled(object?.data != nil, forSegment: 1)
        tabs.setToolTip(object?.data != nil ? Self.dataTip : object == nil ? "Select a table first"
                        : "Only tables on both sides whose rows were compared show their rows", forSegment: 1)
        if object?.data == nil { tabs.selectedSegment = 0 }
        let showsData = tabs.selectedSegment == 1
        structure.isHidden = showsData || object == nil
        rowsHolder.isHidden = !showsData || object == nil
        message.isHidden = true
        scriptTitle.stringValue = "Sync script (makes \(result.target.name) match \(result.source.name)) · review before running"
        guard let object else {
            message.stringValue = "Select one object to see what differs."
            message.isHidden = false
            text(script).string = ""
            return
        }
        if showsData { showRows(object) } else { showStructure(object, result) }
        // The object's own steps: its script alone, in the same order as within the whole script.
        var alone = result
        alone.objects = [object]
        let own = alone.steps(destructive: includeDestructive)
        text(script).string = own.isEmpty ? "-- Nothing to sync for \(object.name)" + (object.differs && !includeDestructive
            ? ": what differs only goes away with destructive steps" : "")
            : own.prefix(200).map { $0.sql + ";" }.joined(separator: "\n\n")
                + (own.count > 200 ? "\n\n-- … and \(own.count - 200) more statements: Sync Script… shows them all" : "")
    }

    private func showStructure(_ object: ReconObject, _ result: ReconResult) {
        leftTitle.stringValue = "\(result.source.name) · \(result.source.database).\(object.name)"
        rightTitle.stringValue = "\(result.target.name) · \(result.target.database).\(object.targetName)"
        leftTitle.toolTip = leftTitle.stringValue
        rightTitle.toolTip = rightTitle.stringValue
        if object.sourceDDL == nil, object.targetDDL == nil {
            message.stringValue = object.status == .same ? "\(object.name) has the same structure on both sides."
                : "Compare Structure and Data to see both definitions side by side."
            message.isHidden = false
            structure.isHidden = true
            return
        }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let absent: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        guard let sourceDDL = object.sourceDDL, let targetDDL = object.targetDDL else {
            // On one side only: its definition as it is, the other side says so.
            text(left).textStorage?.setAttributedString(NSAttributedString(
                string: object.sourceDDL ?? "Not in \(result.source.name)", attributes: object.sourceDDL == nil ? absent : plain))
            text(right).textStorage?.setAttributedString(NSAttributedString(
                string: object.targetDDL ?? "Not in \(result.target.name)", attributes: object.targetDDL == nil ? absent : plain))
            return
        }
        let missing = NSAttributedString(string: "(missing)", attributes: [.foregroundColor: NSColor.quietText, .font: font])
        let (a, b) = (NSMutableAttributedString(), NSMutableAttributedString())
        let rows = ReconLines.aligned(sourceDDL, targetDDL)
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
        text(left).textStorage?.setAttributedString(a)
        text(right).textStorage?.setAttributedString(b)
    }

    // MARK: Rows

    /// The rows that differ in the grid: those only in the source, only in the target, then those changed, with the cells
    /// that differ marked. The sides go by their connections' names, or their databases' when the connection is the same.
    /// Made once per object shown, so its selection, sort and scrolling stay while the window updates.
    private func showRows(_ object: ReconObject) {
        guard let data = object.data, let result else { return }
        switch data.outcome {
        case .differentWithoutKey, .tooManyDifferences, .notCompared:
            message.stringValue = ReconReport.lines(object, result).last?.detail.capitalizedFirst ?? ""
            message.isHidden = false
            rowsHolder.isHidden = true
        case .same:
            message.stringValue = "The rows of \(object.name) are the same on both sides."
            message.isHidden = false
            rowsHolder.isHidden = true
        case .different:
            guard rows == nil else { return }
            let names = result.source.name == result.target.name ? (result.source.database, result.target.database)
                : (result.source.name, result.target.name)
            let diff = DiffSource(data, names: names)
            let settings = window?.model.data.settings ?? AppSettings()
            let grid = ResultGridView(source: diff, table: (result.source.database, object.name), legend: diff.legend,
                                      nullText: settings.nullText, fontSize: CGFloat(settings.gridFontSize))
            grid.grid.setAccessibilityIdentifier("recon.rows")
            grid.grid.setAccessibilityLabel("Rows that differ")
            rowsHolder.addSubview(grid)
            grid.pin(to: rowsHolder)
            rows = grid
        }
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
