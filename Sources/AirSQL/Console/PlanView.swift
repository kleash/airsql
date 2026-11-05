import AirSQLCore
import AppKit

/// An EXPLAIN's tab (plan §2.6): the plan's steps with their figures, the server's table, the steps as text and the
/// server's own answer, one at a time by the switch at its top.
@MainActor
final class PlanView: NSView {
    let choice = NSSegmentedControl(labels: ["Operations", "Table", "Tree", "Raw"], trackingMode: .selectOne, target: nil, action: nil)
    private let holder = NSView()
    private let pages: [NSView]
    var operations: PlanOperationsView? { pages[0] as? PlanOperationsView }

    init(table: ResultStore?, tree: String, nodes: [PlanNode], raw: String, nullText: String, fontSize: CGFloat) {
        let none = label("The server gave no steps for this statement.", color: .secondaryLabelColor)
        pages = [nodes.isEmpty ? none : PlanOperationsView(nodes: nodes, fontSize: fontSize),
                 table.map { ResultGridView(store: $0, nullText: nullText, fontSize: fontSize) }
                    ?? label("Explain Analyze has no plan table: see Operations or Tree.", color: .secondaryLabelColor),
                 Self.text(tree.isEmpty ? "The server gave no plan tree for this statement." : tree, id: "console.planTree", fontSize: fontSize),
                 Self.text(raw, id: "console.planRaw", fontSize: fontSize)]
        super.init(frame: .zero)
        choice.selectedSegment = nodes.isEmpty ? (table == nil ? 2 : 1) : 0
        choice.selectedSegmentBezelColor = .selectedSegment
        choice.target = self
        choice.action = #selector(switched(_:))
        choice.toolTip = "Show the plan as steps with figures, the server's table, a tree of text, or the server's own answer"
        choice.setAccessibilityIdentifier("console.planChoice")
        choice.translatesAutoresizingMaskIntoConstraints = false
        holder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(choice)
        addSubview(holder)
        NSLayoutConstraint.activate([
            choice.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.unit),
            choice.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.unit),
            holder.topAnchor.constraint(equalTo: choice.bottomAnchor, constant: Spacing.unit),
            holder.leadingAnchor.constraint(equalTo: leadingAnchor), holder.trailingAnchor.constraint(equalTo: trailingAnchor),
            holder.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        switched(choice)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func text(_ string: String, id: String, fontSize: CGFloat) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        text.backgroundColor = .content
        text.string = string
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.setAccessibilityIdentifier(id)
        return scroll
    }

    @objc private func switched(_ sender: NSSegmentedControl) { show(page: sender.selectedSegment) }

    func show(page: Int) {
        holder.subviews.forEach { $0.removeFromSuperview() }
        let view = pages[page]
        holder.addSubview(view)
        if view is NSTextField {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.topAnchor.constraint(equalTo: holder.topAnchor, constant: Spacing.unit),
                                         view.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: Spacing.double)])
        } else {
            view.pin(to: holder)
        }
    }
}

/// A plan's steps as a tree with columns. A click on a figure's header sorts the steps of each level by it.
@MainActor
final class PlanOperationsView: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// An outline's items must be objects.
    final class Item {
        let node: PlanNode
        var children: [Item]

        init(_ node: PlanNode) {
            self.node = node
            children = node.children.map(Item.init)
        }
    }

    private static let columns: [(id: String, title: String, tip: String, value: (PlanNode) -> Double?)] = [
        ("rows", "Rows", "The rows the server expected", \.rows),
        ("cost", "Cost", "The server's cost figure", \.cost),
        ("actualRows", "Actual Rows", "The rows really read, per loop", \.actualRows),
        ("time", "Time (ms)", "The time really taken, over all loops", \.time),
        ("loops", "Loops", "How many times the step ran", \.loops),
    ]

    let outline = NSOutlineView()
    private var items: [Item]
    private let font: NSFont

    init(nodes: [PlanNode], fontSize: CGFloat) {
        items = nodes.map(Item.init)
        font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        outline.style = .plain
        outline.usesAlternatingRowBackgroundColors = true
        outline.setAccessibilityIdentifier("console.planOperations")
        outline.setAccessibilityLabel("Plan steps")
        let operation = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("operation"))
        operation.title = "Operation"
        operation.width = 420
        operation.headerToolTip = "What the server does in this step"
        outline.addTableColumn(operation)
        outline.outlineTableColumn = operation
        for column in Self.columns where Self.any(nodes, column.value) {
            let added = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            added.title = column.title
            added.width = 90
            added.headerToolTip = column.tip
            added.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: false)
            outline.addTableColumn(added)
        }
        outline.dataSource = self
        outline.delegate = self
        documentView = outline
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func any(_ nodes: [PlanNode], _ value: (PlanNode) -> Double?) -> Bool {
        nodes.contains { value($0) != nil || any($0.children, value) }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { ((item as? Item)?.children ?? items).count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? Item)?.children ?? items)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Item)?.children.isEmpty == false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = (item as? Item)?.node, let id = tableColumn?.identifier.rawValue else { return nil }
        let text: String
        if let column = Self.columns.first(where: { $0.id == id }) {
            text = column.value(node).map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? ""
        } else {
            text = node.operation
        }
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.lineBreakMode = .byTruncatingTail
        field.alignment = id == "operation" ? .left : .right
        field.toolTip = id == "operation" ? node.operation + (node.hot ? " (a large share of the plan)" : "") : nil
        if node.hot { field.textColor = .statusWarning }
        return field
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sort = outlineView.sortDescriptors.first, let column = Self.columns.first(where: { $0.id == sort.key }) else { return }
        func sorted(_ list: [Item]) -> [Item] {
            for item in list { item.children = sorted(item.children) }
            return list.sorted { a, b in
                let (x, y) = (column.value(a.node) ?? -1, column.value(b.node) ?? -1)
                return sort.ascending ? x < y : x > y
            }
        }
        items = sorted(items)
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
    }
}
