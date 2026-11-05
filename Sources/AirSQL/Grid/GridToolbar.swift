import AirSQLCore
import AppKit

/// The row of actions over a grid: the commands the menu bar has, beside the rows they act on. Each button sends its
/// command to the responder chain from the grid, whatever has the focus, and takes its state and its tooltip from the
/// same validation as the menu item, so a disabled button says why. A command nothing in the chain answers isn't shown.
/// What doesn't fit steps out from the end (every command stays in the menu bar).
@MainActor
final class GridToolbar: NSView {
    /// A button: one command, or a menu of commands that opens from it.
    struct Item {
        var command: Command
        var symbol: String
        var menu: (@MainActor () -> [NSMenuItem])?

        init(_ command: Command, _ symbol: String, menu: (@MainActor () -> [NSMenuItem])? = nil) {
            self.command = command
            self.symbol = symbol
            self.menu = menu
        }
    }

    private let grid: DataGridView
    private let row = NSStackView()
    private var buttons: [(item: Item, button: NSButton, validation: NSMenuItem)] = []
    /// Commands the host leaves out for now (a result that can't be edited has no Delete Rows).
    var left: Set<Selector> = [] { didSet { if left != oldValue { validate() } } }

    /// `label` and `trailing`: what the host keeps at the bar's right end.
    init(grid: DataGridView, groups: [[Item]], label: NSView? = nil, trailing: [Item] = []) {
        self.grid = grid
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("grid.toolbar")
        setAccessibilityRole(.toolbar)
        setAccessibilityElement(true)
        setAccessibilityLabel("Actions on the rows")
        for (rank, group) in groups.enumerated() {
            for item in group {
                let button = makeButton(item)
                row.addView(button, in: .leading)
                // The groups at the end step out first.
                row.setVisibilityPriority(.init(rawValue: NSStackView.VisibilityPriority.mustHold.rawValue - Float(rank + 1)), for: button)
                buttons.append((item, button, item.command.item()))
            }
            if let last = row.views(in: .leading).last { row.setCustomSpacing(Spacing.double, after: last) }
        }
        if let label { row.addView(label, in: .trailing) }
        for item in trailing {
            let button = makeButton(item)
            row.addView(button, in: .trailing)
            buttons.append((item, button, item.command.item()))
        }
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
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 26), button.heightAnchor.constraint(equalToConstant: 22)])
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
        for (item, button, validation) in buttons {
            let action = item.command.action, target = target(action)
            button.isHidden = target == nil || left.contains(action)
            guard let target, !button.isHidden else { continue }
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
        .init(Commands.find, "magnifyingglass"), .init(Commands.columnList, "tablecells"), .init(Commands.sortColumns, "arrow.up.arrow.down"),
    ]
    static let changeItems: [GridToolbar.Item] = [
        .init(Commands.deleteRows, "minus"), .init(Commands.revert, "arrow.uturn.backward"), .init(Commands.previewChanges, "doc.text.magnifyingglass"),
        .init(Commands.apply, "checkmark.circle"),
    ]
}
