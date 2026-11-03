import AppKit

/// One result tab on the results bar (mockup's .rtab): its label in a capsule when shown, a pin when pinned. Clicks are
/// handled here, without AppKit's tracking loop: a click shows it, a double-click renames it, a right-click opens its
/// menu.
@MainActor
final class ResultTabButton: NSView, NSTextFieldDelegate {
    private weak var bar: ResultsView?
    private(set) weak var tab: ResultTab?
    private let title = NSTextField(labelWithString: "")
    private let pin = NSImageView()
    private var selected = false
    private var editor: NSTextField?

    init(bar: ResultsView) {
        self.bar = bar
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 11.5)
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow + 10, for: .horizontal)
        pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        pin.contentTintColor = .secondaryLabelColor
        pin.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pin)
        addSubview(title)
        let pinWidth = pin.widthAnchor.constraint(equalToConstant: 0)
        pinWidth.identifier = "pinWidth"
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            pin.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            pin.centerYAnchor.constraint(equalTo: centerYAnchor), pinWidth,
            title.leadingAnchor.constraint(equalTo: pin.trailingAnchor),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 260),
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
        constraints.first { $0.identifier == "pinWidth" }?.constant = tab.pinned ? 14 : 0
        let what = tab.content.isRenamable ? "click to show it, double-click to rename it, right-click to pin or close it"
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

    override func menu(for event: NSEvent) -> NSMenu? { bar?.menu(for: self) }

    override func accessibilityPerformPress() -> Bool {
        bar?.clicked(self, count: 1)
        return true
    }

    // MARK: Renaming in place

    func beginRename() {
        guard editor == nil, let tab else { return }
        let field = NSTextField(string: tab.title)
        field.font = title.font
        field.focusRingType = .none
        field.delegate = self
        field.toolTip = "Type the result's new name; Return keeps it, Escape leaves it as it was"
        field.setAccessibilityIdentifier("console.resultRename")
        field.frame = NSRect(x: 4, y: (bounds.height - 18) / 2, width: max(120, bounds.width - 8), height: 18)
        addSubview(field)
        title.isHidden = true
        editor = field
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endRename(keep: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) { endRename(keep: true) }

    private func endRename(keep: Bool) {
        guard let field = editor else { return }
        editor = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        field.removeFromSuperview()
        title.isHidden = false
        if keep, !text.isEmpty { bar?.renamed(self, to: text) }
    }

    /// The renaming field, while it is shown (tests).
    var renameField: NSTextField? { editor }
}
