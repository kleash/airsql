import AirSQLCore
import AppKit

/// What a tab shows: a console (L4), a table's data or structure (L2, L3, L5), a recon report (L8). Its view controller
/// adopts this to tell the tab bar and the status bar about itself; each requirement has a default. After a change to
/// what it reports, it posts `.tabContentDidChange` (object: itself).
@MainActor
protocol TabContent: AnyObject {
    /// A double-click on the tab renames it (an unsaved console; a file's tab is named after its file).
    var canRename: Bool { get }
    /// The tab's unsaved dot: unsaved console text, pending grid edits.
    var isEdited: Bool { get }
    /// The status bar's transaction badge for this tab ("Transaction open · 2 changes"); nil: none.
    var transactionBadge: String? { get }
    /// What the status bar shows on its right for this tab (the grid's row counts and aggregates).
    var statusAccessory: NSView? { get }
    /// The .sql file the tab shows (Reveal in Finder), if any.
    var fileURL: URL? { get }
    /// Whether the tab may close: asks the person first when work would be lost, then answers.
    func shouldClose(_ answer: @escaping (Bool) -> Void)
    /// Duplicate Tab can copy it (`duplicate()`).
    var canDuplicate: Bool { get }
    /// A copy for Duplicate Tab.
    func duplicate() -> NSViewController?
}

extension TabContent {
    var canRename: Bool { false }
    var isEdited: Bool { false }
    var transactionBadge: String? { nil }
    var statusAccessory: NSView? { nil }
    var fileURL: URL? { nil }
    func shouldClose(_ answer: @escaping (Bool) -> Void) { answer(true) }
    var canDuplicate: Bool { false }
    func duplicate() -> NSViewController? { nil }
}

extension Notification.Name {
    /// Posted by a tab's content (object: its view controller) when what it reports to the tab bar or status bar changes.
    static let tabContentDidChange = Notification.Name("AirSQLTabContentDidChange")
}

/// A tab of the main window: its title, the connection it works on, and its content.
@MainActor
final class Tab {
    let id = UUID()
    var title: String
    var connectionID: UUID?
    let content: NSViewController

    init(title: String, connectionID: UUID?, content: NSViewController) {
        self.title = title
        self.connectionID = connectionID
        self.content = content
    }

    var tabContent: TabContent? { content as? TabContent }
}

/// The strip of tabs above the content (plan §2.4): each tab's title (cut with an ellipsis, the full title in its
/// tooltip), its unsaved dot or close button, and the connection's colour along the top of the active tab. A click
/// shows a tab, a double-click renames it, a right-click opens its menu; "+" opens a new query.
@MainActor
final class TabBarView: NSView {
    weak var controller: MainWindowController?
    private let scroll = NSScrollView()
    private let strip = FlippedView()
    private let plus = NSButton()
    private(set) var buttons: [TabButton] = []
    static let height: CGFloat = 32
    /// Wide enough for a dozen letters of a title (the tooltip has all of it); more tabs scroll sideways.
    static let minimumTabWidth: CGFloat = 140
    static let maximumTabWidth: CGFloat = 220

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let ground = SurfaceView(.ground)
        addSubview(ground)
        ground.pin(to: self)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.documentView = strip
        // The hairline under the tabs, then the tabs over it: the active tab covers it and opens into the content.
        let line = Hairline()
        addSubview(line)
        addSubview(scroll)
        scroll.pin(to: self, insets: NSEdgeInsets(top: 0, left: Spacing.unit, bottom: 0, right: Spacing.unit))
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor), line.heightAnchor.constraint(equalToConstant: 1),
        ])
        plus.bezelStyle = .texturedRounded
        plus.isBordered = false
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Query")
        plus.target = nil
        plus.action = Commands.newQuery.action
        plus.toolTip = Commands.newQuery.tip + " (⌘T)"
        plus.setAccessibilityIdentifier("tabs.new")
        strip.addSubview(plus)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
        setAccessibilityIdentifier("tabs")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `tabs`, `selected` active.
    func show(_ tabs: [Tab], selected: Tab?, colour: (Tab) -> NSColor?) {
        while buttons.count > tabs.count { buttons.removeLast().removeFromSuperview() }
        while buttons.count < tabs.count {
            let button = TabButton(bar: self)
            strip.addSubview(button)
            buttons.append(button)
        }
        for (button, tab) in zip(buttons, tabs) {
            button.update(tab, selected: tab === selected, colour: colour(tab))
        }
        needsLayout = true
        if let index = tabs.firstIndex(where: { $0 === selected }) {
            layoutSubtreeIfNeeded()
            strip.scrollToVisible(buttons[index].frame)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = Self.height
        let plusWidth: CGFloat = 28
        let available = max(0, scroll.frame.width - plusWidth - Spacing.half)
        let width = buttons.isEmpty ? 0
            : min(Self.maximumTabWidth, max(Self.minimumTabWidth, (available / CGFloat(buttons.count)).rounded(.down)))
        var x: CGFloat = 0
        for button in buttons {
            // 4 points below the bar's top, down over the hairline at its bottom.
            button.frame = NSRect(x: x, y: 4, width: width, height: height - 4)
            x += width + 1
        }
        plus.frame = NSRect(x: x + Spacing.half, y: 4 + (height - 5 - 22) / 2, width: 22, height: 22)
        strip.frame = NSRect(x: 0, y: 0, width: max(scroll.frame.width, plus.frame.maxX + Spacing.half), height: height)
    }

    func clicked(_ button: TabButton, count: Int) {
        guard let controller, let tab = button.tab else { return }
        controller.select(tab)
        if count == 2, tab.tabContent?.canRename == true { button.beginRename() }
    }

    func renamed(_ button: TabButton, to title: String) {
        guard let tab = button.tab else { return }
        controller?.rename(tab, to: title)
    }

    /// The tab's menu (plan §2.12): Close, Close Others, Duplicate, Rename, Reveal in Finder, Change Connection.
    func menu(for button: TabButton) -> NSMenu {
        if let tab = button.tab { controller?.select(tab) }
        let menu = NSMenu(title: "Tab")
        menu.add([Commands.closeTab, Commands.closeOtherTabs, Commands.duplicateTab, Commands.renameTab, nil,
                  Commands.revealInFinder, Commands.changeConnection])
        return menu
    }
}

/// A view whose origin is at the top left (the tab strip, scrolled sideways).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One tab of the strip. Clicks are handled here, without AppKit's tracking loop.
@MainActor
final class TabButton: NSView {
    private weak var bar: TabBarView?
    private(set) weak var tab: Tab?
    private let title = NSTextField(labelWithString: "")
    private let close = NSButton()
    private let dot = DotView(diameter: 6)
    private var editor: RenameField?
    private var selected = false
    private var colour: NSColor?
    private var hovering = false

    init(bar: TabBarView) {
        self.bar = bar
        super.init(frame: .zero)
        wantsLayer = true
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        close.target = self
        close.action = #selector(closeClicked)
        close.toolTip = Commands.closeTab.tip + " (⌘W)"
        close.translatesAutoresizingMaskIntoConstraints = false
        close.setAccessibilityIdentifier("tab.close")
        dot.color = .secondaryLabelColor
        addSubview(title)
        addSubview(close)
        addSubview(dot)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 4),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 16), close.heightAnchor.constraint(equalToConstant: 16),
            dot.centerXAnchor.constraint(equalTo: close.centerXAnchor), dot.centerYAnchor.constraint(equalTo: close.centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityIdentifier("tab")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ tab: Tab, selected: Bool, colour: NSColor?) {
        self.tab = tab
        self.selected = selected
        self.colour = colour
        title.stringValue = tab.title
        title.textColor = selected ? .labelColor : .secondaryLabelColor
        let edited = tab.tabContent?.isEdited ?? false
        dot.isHidden = !edited || hovering
        close.isHidden = edited && !hovering
        toolTip = tab.title + (edited ? " (unsaved)" : "") + ": click to show it, double-click to rename it, right-click for more"
        setAccessibilityLabel(tab.title)
        setAccessibilityValue(selected ? 1 : 0)
        setAccessibilityHelp(toolTip)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selected else {
            if hovering {
                NSColor.hover.setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 3), xRadius: Radius.control, yRadius: Radius.control).fill()
            }
            return
        }
        // The active tab: the content colour with a hairline edge, open at the bottom into the content; the connection's
        // colour along its top.
        let radius = Radius.card - 1
        let shape = NSBezierPath()
        shape.move(to: NSPoint(x: 0.5, y: -1))
        shape.line(to: NSPoint(x: 0.5, y: bounds.height - radius))
        shape.appendArc(withCenter: NSPoint(x: radius + 0.5, y: bounds.height - radius), radius: radius, startAngle: 180, endAngle: 90, clockwise: true)
        shape.line(to: NSPoint(x: bounds.width - radius - 0.5, y: bounds.height))
        shape.appendArc(withCenter: NSPoint(x: bounds.width - radius - 0.5, y: bounds.height - radius), radius: radius, startAngle: 90, endAngle: 0, clockwise: true)
        shape.line(to: NSPoint(x: bounds.width - 0.5, y: -1))
        NSColor.content.setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        if let colour {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            colour.setFill()
            NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ on: Bool) {
        hovering = on
        if let tab { update(tab, selected: selected, colour: colour) }
    }

    override func mouseDown(with event: NSEvent) {
        guard editor == nil else { return super.mouseDown(with: event) }
        bar?.clicked(self, count: event.clickCount)
    }

    override func menu(for event: NSEvent) -> NSMenu? { bar?.menu(for: self) }

    @objc private func closeClicked() {
        guard let tab else { return }
        bar?.controller?.close(tab)
    }

    // MARK: Renaming in place

    func beginRename() {
        guard editor == nil, let tab else { return }
        let frame = NSRect(x: 8, y: (bounds.height - 20) / 2, width: bounds.width - 16, height: 20)
        editor = RenameField.show(tab.title, over: title, frame: frame, id: "tab.rename",
                                  tip: "Type the tab's new name; Return keeps it, Escape leaves it as it was") { [weak self] name in
            guard let self else { return }
            self.editor = nil
            if let name { self.bar?.renamed(self, to: name) }
        }
    }

    /// The renaming field, while it is shown (tests).
    var renameField: NSTextField? { editor }

    override func accessibilityPerformPress() -> Bool {
        bar?.clicked(self, count: 1)
        return true
    }

    override func isAccessibilityEnabled() -> Bool { true }
}
