import AirSQLCore
import AppKit

/// The row of actions over a grid: the commands the menu bar has, beside the rows they act on. Each button sends its
/// command to the responder chain from the grid, whatever has the focus, and takes its state and its tooltip from the
/// same validation as the menu item, so a disabled button says why. A command nothing in the chain answers isn't shown.
/// What doesn't fit goes behind the » button, in a set order that depends only on the width (`fit`).
@MainActor
final class GridToolbar: NSView {
    /// A button: one command, or a menu of commands that opens from it.
    struct Item {
        var command: Command
        var symbol: String
        var menu: (@MainActor () -> [NSMenuItem])?
        /// Among the last to go behind the » button.
        var stays: Bool

        init(_ command: Command, _ symbol: String, stays: Bool = false, menu: (@MainActor () -> [NSMenuItem])? = nil) {
            self.command = command
            self.symbol = symbol
            self.stays = stays
            self.menu = menu
        }
    }

    private let grid: DataGridView
    private let row = NSStackView()
    private var buttons: [(item: Item, button: NSButton, validation: NSMenuItem)] = []
    /// Commands the host leaves out for now (a result that can't be edited has no Delete Rows).
    var left: Set<Selector> = [] { didSet { if left != oldValue { validate() } } }
    /// The space each button takes, with the gap after its group, and the order they go behind `more`.
    private var room: [CGFloat] = []
    private var stepOut: [Int] = []
    private let label: NSView?
    private let more = NSButton()
    /// Those that don't fit now.
    private(set) var overflow: [Int] = []

    /// `label` and `trailing`: what the host keeps at the bar's right end.
    init(grid: DataGridView, groups: [[Item]], label: NSView? = nil, trailing: [Item] = []) {
        self.grid = grid
        self.label = label
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("grid.toolbar")
        setAccessibilityRole(.toolbar)
        setAccessibilityElement(true)
        setAccessibilityLabel("Actions on the rows")
        for group in groups {
            for item in group {
                let button = makeButton(item)
                row.addView(button, in: .leading)
                buttons.append((item, button, item.command.item()))
                room.append(Self.buttonWidth + 2)
            }
            if let last = row.views(in: .leading).last {
                row.setCustomSpacing(Spacing.double, after: last)
                room[room.count - 1] += Spacing.double
            }
        }
        more.image = NSImage(systemSymbolName: "chevron.right.2", accessibilityDescription: "More")
        more.imageScaling = .scaleProportionallyDown
        more.isBordered = false
        more.bezelStyle = .regularSquare
        more.contentTintColor = .secondaryLabelColor
        more.toolTip = "Show the actions that don't fit here"
        more.setAccessibilityLabel("More actions")
        more.setAccessibilityIdentifier("grid.toolbar.more")
        more.target = self
        more.action = #selector(showOverflow(_:))
        more.isHidden = true
        more.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([more.widthAnchor.constraint(equalToConstant: Self.buttonWidth), more.heightAnchor.constraint(equalToConstant: 22)])
        row.addView(more, in: .leading)
        let leading = buttons.indices
        if let label { row.addView(label, in: .trailing) }
        for item in trailing {
            let button = makeButton(item)
            row.addView(button, in: .trailing)
            buttons.append((item, button, item.command.item()))
            room.append(Self.buttonWidth + 2)
        }
        // The pager's ends first, then from the end of the row, then what stays.
        stepOut = buttons.indices.filter { !leading.contains($0) && !buttons[$0].item.stays } + leading.reversed().filter { !buttons[$0].item.stays }
            + buttons.indices.reversed().filter { buttons[$0].item.stays }
        row.spacing = 2
        row.edgeInsets = NSEdgeInsets(top: 2, left: Spacing.unit, bottom: 2, right: Spacing.unit)
        row.setHuggingPriority(.defaultHigh, for: .vertical)  // a bar keeps its height; the rows get the rest
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
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
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.bar.cgColor }

    static let buttonWidth: CGFloat = 26

    override func layout() {
        super.layout()
        fit()
    }

    /// Shows what fits and leaves the rest to `more`. Only this and `validate` set the buttons' `isHidden`, from the width
    /// alone: the stack's own visibility priorities were undone by each validation, and depended on how the width came.
    private func fit() {
        func wanted(_ index: Int) -> Bool {
            let action = buttons[index].item.command.action
            return target(action) != nil && !left.contains(action)
        }
        let insets = 2 * Spacing.unit + (label?.fittingSize.width ?? 0) + Spacing.double
        var out: [Int] = [], width = insets + buttons.indices.filter(wanted).reduce(0) { $0 + room[$1] }
        for index in stepOut where width > bounds.width && wanted(index) {
            if out.isEmpty { width += Self.buttonWidth + 2 }
            out.append(index)
            width -= room[index]
        }
        overflow = buttons.indices.filter(out.contains)
        for index in buttons.indices {
            let hidden = !wanted(index) || out.contains(index)
            if buttons[index].button.isHidden != hidden { buttons[index].button.isHidden = hidden }
        }
        if more.isHidden != out.isEmpty { more.isHidden = out.isEmpty }
    }

    /// The items of the » menu, each aimed at this grid.
    func overflowItems() -> [NSMenuItem] {
        overflow.map { index in
            let item = buttons[index].item
            let entry = item.command.item()
            entry.title = buttons[index].validation.title
            if let items = item.menu?() {
                entry.action = nil
                entry.submenu = NSMenu(title: item.command.title)
                items.forEach { entry.submenu?.addItem($0) }
            }
            if let fallback = target(item.command.action) { aim(entry, at: fallback) }
            return entry
        }
    }

    @objc private func showOverflow(_ sender: NSButton) {
        let menu = NSMenu(title: "More Actions")
        overflowItems().forEach(menu.addItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    private func makeButton(_ item: Item) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.command.title)
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.toolTip = item.command.tip
        button.setAccessibilityLabel(item.command.title)
        button.setAccessibilityIdentifier("grid.toolbar." + NSStringFromSelector(item.command.action).dropLast())
        button.target = self
        button.action = #selector(pressed(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: Self.buttonWidth), button.heightAnchor.constraint(equalToConstant: 22)])
        return button
    }

    /// What answers `action` for this grid: AppKit's walk for a menu item, from the grid rather than the focus. By class:
    /// a table tab steps aside for some actions while text has the focus, which says nothing about a button.
    private func target(_ action: Selector) -> NSResponder? {
        var responder: NSResponder? = grid
        while let next = responder {
            if type(of: next).instancesRespond(to: action) { return next }
            responder = next.nextResponder
        }
        return nil
    }

    func button(_ command: Command) -> NSButton? { buttons.first { $0.item.command.action == command.action }?.button }

    /// Validates once things settle: a drag across a big selection asks many times.
    func setNeedsValidation() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(validate), object: nil)
        perform(#selector(validate), with: nil, afterDelay: 0.05)
    }

    @objc func validate() {
        guard window != nil else { return }
        fit()
        for (item, button, validation) in buttons {
            let action = item.command.action
            guard let target = target(action), !left.contains(action) else { continue }
            let enabled = (target as? NSMenuItemValidation)?.validateMenuItem(validation) ?? true
            button.isEnabled = enabled
            button.contentTintColor = !enabled ? .tertiaryLabelColor : validation.state == .on && item.menu == nil ? .accent : .secondaryLabelColor
            let shortcut = item.command.shortcut
            button.toolTip = (validation.toolTip ?? item.command.tip) + (enabled && !shortcut.isEmpty ? " (\(shortcut))" : "")
            button.setAccessibilityLabel(validation.title)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        validate()
        setNeedsValidation()  // a tab's view can reach the window before its controller joins the chain
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let (item, _, validation) = buttons.first(where: { $0.button === sender }), let target = target(item.command.action) else { return }
        if let items = item.menu?() {
            let menu = NSMenu(title: item.command.title)
            for entry in items {
                aim(entry, at: target)
                menu.addItem(entry)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        } else {
            target.perform(item.command.action, with: validation)
        }
        setNeedsValidation()
    }

    /// Items of a menu opened here act on this grid, wherever the focus is.
    private func aim(_ item: NSMenuItem, at fallback: NSResponder) {
        if let action = item.action { item.target = target(action) ?? fallback }
        item.submenu?.items.forEach { aim($0, at: fallback) }
    }
}

@MainActor
extension GridToolbar.Item {
    static let viewItems: [GridToolbar.Item] = [
        .init(Commands.valuePanel, "sidebar.right"), .init(Commands.recordView, "list.bullet.rectangle"),
        .init(Commands.transpose, "rectangle.landscape.rotate"), .init(Commands.viewAs, "text.justify.left", menu: { MainMenu.viewAsItems() }),
        .init(Commands.chart, "chart.bar"),
    ]
    static let findItems: [GridToolbar.Item] = [
        .init(Commands.find, "magnifyingglass", stays: true), .init(Commands.columnList, "tablecells"),
        .init(Commands.sortColumns, "arrow.up.arrow.down", stays: true),
    ]
    /// Revert and Preview SQL… are the pending changes' bar's, which shows with them.
    static let changeItems: [GridToolbar.Item] = [
        .init(Commands.deleteRows, "minus", stays: true), .init(Commands.apply, "checkmark.circle", stays: true),
    ]
}

extension NSButton {
    /// This button in the look of a toolbar's: its symbol alone, no border; its title stays, for the tooltip's sake and for
    /// who reads it out.
    func onBar(_ symbol: String) -> Self {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        bezelStyle = .regularSquare
        contentTintColor = .secondaryLabelColor
        setAccessibilityLabel(title)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: GridToolbar.buttonWidth), heightAnchor.constraint(equalToConstant: 22)])
        return self
    }
}
