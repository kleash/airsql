import AirSQLCore
import AppKit
import Combine

/// The status bar under the content (plan §2.4): the route, the server's version, the tab's transaction badge, the
/// work running now (with Cancel), what the tab adds on the right (the grid's counts), the agents' chip and the SQL
/// log. A click on an item shows its popover; a right-click its menu (Copy, and its actions).
@MainActor
final class StatusBarView: NSView {
    let route = StatusItemView(id: "status.route", symbol: "point.3.connected.trianglepath.dotted")
    let server = StatusItemView(id: "status.server", symbol: "server.rack")
    let transaction = StatusItemView(id: "status.transaction", chip: .tinted(.statusWarning))
    let activity = StatusItemView(id: "status.activity", spinner: true)
    let agent = StatusItemView(id: "status.agent", chip: .accent)
    let sqlLog = NSButton(title: "SQL log", target: nil, action: Commands.sqlLog.action)
    /// The tab's own items (`TabContent.statusAccessory`).
    let accessory = NSStackView()
    static let height: CGFloat = 26

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let background = SurfaceView(.bar)
        addSubview(background)
        background.pin(to: self)
        let line = Hairline()
        addSubview(line)
        sqlLog.isBordered = false
        sqlLog.font = .systemFont(ofSize: 11.5)
        sqlLog.contentTintColor = .accent
        sqlLog.attributedTitle = NSAttributedString(string: "SQL log", attributes: [.foregroundColor: NSColor.accent,
                                                                                    .font: NSFont.systemFont(ofSize: 11.5)])
        sqlLog.setAccessibilityIdentifier("status.sqlLog")
        sqlLog.translatesAutoresizingMaskIntoConstraints = false
        sqlLog.setContentCompressionResistancePriority(.required, for: .horizontal)
        accessory.spacing = 10
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let left = NSStackView(views: [route, server, transaction, activity])
        left.spacing = 12
        left.translatesAutoresizingMaskIntoConstraints = false
        left.setHuggingPriority(.defaultLow, for: .horizontal)
        // Narrow windows drop the less important items first (they stay in the popovers and the snapshot).
        left.setVisibilityPriority(.detachOnlyIfNecessary, for: server)
        let right = NSStackView(views: [accessory, agent, sqlLog])
        right.spacing = 12
        right.translatesAutoresizingMaskIntoConstraints = false
        addSubview(left)
        addSubview(right)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            line.topAnchor.constraint(equalTo: topAnchor), line.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            left.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 12),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Status bar")
        setAccessibilityIdentifier("status")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the tab's own status items in place of the last tab's.
    func setAccessory(_ view: NSView?) {
        accessory.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let view { accessory.addArrangedSubview(view) }
    }
}

/// One item of the status bar: a label (with a symbol, a spinner, or as a chip). Its owner gives it a popover and a
/// menu; it handles clicks itself, without AppKit's tracking loop.
@MainActor
final class StatusItemView: NSView {
    private let text = NSTextField(labelWithString: "")
    private var chip: ChipView?
    private let image = NSImageView()
    private let spinner = NSProgressIndicator()
    /// What a click shows, under the item.
    var popover: (() -> NSViewController?)?
    /// What a right-click opens (Copy is added first).
    var menuItems: (() -> [NSMenuItem])?

    init(id: String, symbol: String? = nil, chip style: ChipView.Style? = nil, spinner showsSpinner: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier(id)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        var views: [NSView] = []
        if let symbol {
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
            image.contentTintColor = .secondaryLabelColor
            image.setContentHuggingPriority(.required, for: .horizontal)
            views.append(image)
        }
        if showsSpinner {
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.widthAnchor.constraint(equalToConstant: 12).isActive = true
            spinner.heightAnchor.constraint(equalToConstant: 12).isActive = true
            views.append(spinner)
        }
        if let style {
            let chip = ChipView("", style: style)
            self.chip = chip
            views.append(chip)
        } else {
            text.font = .systemFont(ofSize: 11.5)
            text.textColor = .secondaryLabelColor
            text.lineBreakMode = .byTruncatingTail
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(text)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 4
        addSubview(stack)
        stack.pin(to: self)
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The item's text ("" hides it) and tooltip.
    func show(_ value: String, tip: String) {
        if let chip { chip.text = value } else { text.stringValue = value }
        isHidden = value.isEmpty
        toolTip = tip
        setAccessibilityLabel(value)
        setAccessibilityHelp(tip)
    }

    var value: String { chip?.text ?? text.stringValue }

    func setSpinning(_ on: Bool) {
        if on { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func setChipStyle(_ style: ChipView.Style) { chip?.style = style }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1 else { return }
        showPopover()
    }

    /// Shows the item's popover (a click, Activity in the View menu, VoiceOver's press).
    @discardableResult
    func showPopover() -> Bool {
        guard let controller = popover?() else { return false }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        shown = popover
        return true
    }

    /// The popover shown last (tests and the agent snapshot read it).
    private(set) weak var shown: NSPopover?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Status")
        let copy = Commands.copy.item()
        copy.target = self
        copy.action = #selector(copyValue(_:))
        copy.toolTip = "Copy what this item says"
        menu.addItem(copy)
        let items = menuItems?() ?? []
        if !items.isEmpty { menu.addItem(.separator()) }
        items.forEach(menu.addItem)
        return menu
    }

    @objc func copyValue(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    override func accessibilityPerformPress() -> Bool { showPopover() }
}

/// A popover's content: a heading, lines of text, and buttons, inset by the popover's radius.
@MainActor
final class InfoPopover: NSViewController {
    private let heading: String
    private let lines: [String]
    private let buttons: [NSButton]
    private let extra: NSView?
    let id: String

    init(id: String, heading: String, lines: [String], buttons: [NSButton] = [], extra: NSView? = nil) {
        self.id = id
        self.heading = heading
        self.lines = lines
        self.buttons = buttons
        self.extra = extra
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let title = label(heading, font: .systemFont(ofSize: 12, weight: .semibold))
        var views: [NSView] = [title]
        for line in lines {
            let text = label(line, font: .systemFont(ofSize: 12), color: .secondaryLabelColor, wraps: true)
            text.preferredMaxLayoutWidth = 300
            text.isSelectable = true
            views.append(text)
        }
        if let extra { views.append(extra) }
        if !buttons.isEmpty {
            let row = NSStackView(views: buttons)
            row.spacing = Spacing.unit
            views.append(row)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.unit
        let root = NSView()
        root.setAccessibilityIdentifier(id)
        root.addSubview(stack)
        stack.pin(to: root, insets: .all(Spacing.double))
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        root.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        view = root
    }
}

/// The Activity popover: each piece of work running, its connection, elapsed time or progress, and Cancel.
@MainActor
final class ActivityPopover: NSViewController {
    private let center: ActivityCenter
    private let names: (UUID?) -> String?
    private let list = NSStackView()
    private var observer: AnyCancellable?
    private var timer: Timer?
    /// Each Cancel button's work.
    private var cancels: [ObjectIdentifier: Activity] = [:]

    init(center: ActivityCenter, names: @escaping (UUID?) -> String?) {
        self.center = center
        self.names = names
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let title = label("Running now", font: .systemFont(ofSize: 12, weight: .semibold))
        let cancelAll = button("Cancel All", id: "activity.cancelAll", tip: Commands.cancelAll.tip, target: self,
                               action: #selector(cancelAllClicked(_:)))
        cancelAll.controlSize = .small
        let header = NSStackView(views: [title, NSView(), cancelAll])
        header.distribution = .fill
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = Spacing.unit
        let stack = NSStackView(views: [header, list])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.unit
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        list.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let root = NSView()
        root.setAccessibilityIdentifier("activity.popover")
        root.addSubview(stack)
        stack.pin(to: root, insets: .all(Spacing.double))
        root.widthAnchor.constraint(equalToConstant: 360).isActive = true
        view = root
        observer = center.$running.sink { [weak self] _ in DispatchQueue.main.async { self?.rebuild() } }
        rebuild()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick() { rebuild() }

    @objc private func cancelClicked(_ sender: NSButton) {
        cancels[ObjectIdentifier(sender)]?.cancel()
        rebuild()
    }

    @objc private func cancelAllClicked(_ sender: Any?) {
        center.cancelAll()
        rebuild()
    }

    private func rebuild() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cancels = [:]
        if center.running.isEmpty {
            list.addArrangedSubview(label("Nothing is running.", font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
            return
        }
        for activity in center.running {
            let title = label(activity.title, font: .systemFont(ofSize: 12), truncates: true)
            title.toolTip = activity.title
            var detail = ActivityPopover.elapsed(activity.elapsed(at: center.now()))
            if let name = names(activity.connection) { detail = name + " · " + detail }
            if let more = activity.detail { detail += " · " + more }
            let info = label(detail, font: .systemFont(ofSize: 11), color: .secondaryLabelColor, truncates: true)
            info.toolTip = detail
            let texts = NSStackView(views: [title, info])
            texts.orientation = .vertical
            texts.alignment = .leading
            texts.spacing = 2
            if let progress = activity.progress {
                let bar = NSProgressIndicator()
                bar.isIndeterminate = false
                bar.doubleValue = progress * 100
                bar.controlSize = .small
                bar.widthAnchor.constraint(equalToConstant: 200).isActive = true
                texts.addArrangedSubview(bar)
            }
            let cancel = button(activity.cancelling ? "Cancelling…" : "Cancel", id: "activity.cancel",
                                tip: activity.canCancel ? "Stop “\(activity.title)”" : "This work can't be stopped part-way",
                                target: self, action: #selector(cancelClicked(_:)))
            cancels[ObjectIdentifier(cancel)] = activity
            cancel.controlSize = .small
            cancel.isEnabled = activity.canCancel
            let row = NSStackView(views: [texts, cancel])
            row.distribution = .fill
            row.alignment = .centerY
            texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    /// "4 s", "2 min 5 s", "1 h 3 min".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min \(total % 60) s" }
        return "\(total / 3600) h \(total % 3600 / 60) min"
    }
}
