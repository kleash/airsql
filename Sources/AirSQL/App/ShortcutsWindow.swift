import AppKit

/// Help ▸ Keyboard Shortcuts: every shortcut of `Commands.all`, in menu order, narrowed as you type.
@MainActor
final class ShortcutsWindowController: NSWindowController, NSSearchFieldDelegate {
    private static var shown: ShortcutsWindowController?
    private let filter = NSSearchField()
    let text = NSTextView()

    @discardableResult
    static func show() -> ShortcutsWindowController {
        let controller = shown ?? ShortcutsWindowController()
        shown = controller
        controller.showWindow(nil)
        return controller
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Keyboard Shortcuts"
        window.minSize = NSSize(width: 360, height: 280)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        filter.placeholderString = "Filter: a command or a key"
        filter.toolTip = "Type part of a command's name, or a key such as ⌘T, to show only those"
        filter.setAccessibilityIdentifier("shortcuts.filter")
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        filter.translatesAutoresizingMaskIntoConstraints = false
        text.isEditable = false
        text.textContainerInset = NSSize(width: Spacing.unit, height: Spacing.unit)
        text.autoresizingMask = .width
        text.setAccessibilityIdentifier("shortcuts.list")
        text.setAccessibilityLabel("Keyboard shortcuts")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(filter)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            filter.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.unit),
            filter.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.unit),
            filter.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.unit),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: Spacing.unit),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root
        window.initialFirstResponder = filter
        fill()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func controlTextDidChange(_ notification: Notification) { fill() }

    private func fill() {
        let words = filter.stringValue.trimmingCharacters(in: .whitespaces)
        let lines = Commands.all.filter { !$0.shortcut.isEmpty }
            .filter { words.isEmpty || $0.title.localizedCaseInsensitiveContains(words) || $0.shortcut.contains(words) }
            .map { "\($0.shortcut)\t\($0.title)" }
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 80)]
        style.lineSpacing = 3
        text.textStorage?.setAttributedString(NSAttributedString(
            string: lines.isEmpty ? "No shortcut matches: every command is in the menu bar." : lines.joined(separator: "\n"),
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: style]))
    }
}
