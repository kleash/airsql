import AppKit

/// One result tab on the results bar (mockup's .rtab): its label in a capsule when shown, a pin when pinned, a ✕ unless
/// it is Messages. Clicks are handled here, without AppKit's tracking loop: a click shows it, a double-click renames it,
/// a middle-click closes it, a right-click opens its menu.
@MainActor
final class ResultTabButton: NSView {
    private weak var bar: ResultsView?
    private(set) weak var tab: ResultTab?
    private let title = NSTextField(labelWithString: "")
    private let pin = NSImageView()
    let closeButton = NSButton()
    private var selected = false
    private var editor: RenameField?
    private var pinWidth: NSLayoutConstraint!
    private var closeWidth: NSLayoutConstraint!

    init(bar: ResultsView) {
        self.bar = bar
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 11.5)
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow + 2, for: .horizontal)
        let shortest = title.widthAnchor.constraint(greaterThanOrEqualToConstant: 60)
        shortest.priority = .defaultLow + 6  // over the bar's wish to show every tab
        shortest.isActive = true
        pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        pin.contentTintColor = .secondaryLabelColor
        pin.translatesAutoresizingMaskIntoConstraints = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Result")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = Commands.closeResult.tip
        closeButton.setAccessibilityIdentifier("console.resultClose")
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pin)
        addSubview(title)
        addSubview(closeButton)
        pinWidth = pin.widthAnchor.constraint(equalToConstant: 0)
        closeWidth = closeButton.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            pin.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            pin.centerYAnchor.constraint(equalTo: centerYAnchor), pinWidth,
            title.leadingAnchor.constraint(equalTo: pin.trailingAnchor),
            title.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor), closeWidth,
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityIdentifier("console.resultTab")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ tab: ResultTab, selected: Bool) {
        self.tab = tab
        self.selected = selected
        title.stringValue = tab.label
        title.textColor = selected ? .labelColor : .secondaryLabelColor
        pin.isHidden = !tab.pinned
        pinWidth.constant = tab.pinned ? 14 : 0
        closeButton.isHidden = !tab.content.isRenamable
        closeWidth.constant = tab.content.isRenamable ? 14 : 0
        let what = tab.content.isRenamable ? "click to show it, double-click to rename it, middle-click to close it, right-click for more"
            : "click to show what each statement did"
        toolTip = tab.label + (tab.pinned ? " (pinned)" : "") + ": " + what
        setAccessibilityLabel(tab.label)
        setAccessibilityValue(selected ? 1 : 0)
        setAccessibilityHelp(toolTip)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.control, yRadius: Radius.control)
        NSColor.content.setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard editor == nil else { return super.mouseDown(with: event) }
        bar?.clicked(self, count: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        guard editor == nil else { return super.mouseDragged(with: event) }
        bar?.dragged(self, to: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        guard editor == nil else { return super.mouseUp(with: event) }
        bar?.dragEnded()
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        bar?.close(self)
    }

    override func menu(for event: NSEvent) -> NSMenu? { bar?.menu(for: self) }

    @objc private func closeClicked(_ sender: Any?) { bar?.close(self) }

    override func accessibilityPerformPress() -> Bool {
        bar?.clicked(self, count: 1)
        return true
    }

    override func isAccessibilityEnabled() -> Bool { true }

    // MARK: Renaming in place

    func beginRename() {
        guard editor == nil, let tab else { return }
        let frame = NSRect(x: 4, y: (bounds.height - 18) / 2, width: max(120, bounds.width - 8), height: 18)
        editor = RenameField.show(tab.title, over: title, frame: frame, id: "console.resultRename",
                                  tip: "Type the result's new name; Return keeps it, Escape leaves it as it was") { [weak self] name in
            guard let self else { return }
            self.editor = nil
            if let name { self.bar?.renamed(self, to: name) }
        }
    }

    /// The renaming field, while it is shown (tests).
    var renameField: NSTextField? { editor }
}
