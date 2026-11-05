import AppKit

// Small makers for the controls every screen uses, so each one gets its tooltip, accessibility id and Auto Layout
// behaviour (text never cut: it hugs, resists compression, or truncates with an ellipsis and a tooltip) the same way.

/// Tells VoiceOver something that happened away from the focus: a run that ended, a test's result.
@MainActor
func announce(_ text: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                         userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
}

/// `object`'s animator, or `object` itself under Reduce Motion.
@MainActor
func gently<Object: NSAnimatablePropertyContainer>(_ object: Object) -> Object {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? object : object.animator()
}

/// A text label. `wraps`: wraps within its width; else one line, truncated with an ellipsis (`truncates`) or never
/// shorter than its text.
func label(_ text: String, font: NSFont = .systemFont(ofSize: NSFont.systemFontSize), color: NSColor = .labelColor,
           wraps: Bool = false, truncates: Bool = false) -> NSTextField {
    let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
    field.font = font
    field.textColor = color
    field.translatesAutoresizingMaskIntoConstraints = false
    if wraps {
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
    } else if truncates {
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    } else {
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }
    return field
}

/// A grey caption under a field (11 pt), wrapping within `width`.
func caption(_ text: String, width: CGFloat = 380) -> NSTextField {
    let field = label(text, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, wraps: true)
    field.preferredMaxLayoutWidth = width
    return field
}

/// A push button that says what it does, with an accessibility id (`area.name`). `primary`: the screen's main button
/// (Connect, Apply, Run), in the accent.
func button(_ title: String, id: String, tip: String, target: AnyObject?, action: Selector?, primary: Bool = false) -> NSButton {
    let button = primary ? PrimaryButton(title: title, target: target, action: action) : NSButton(title: title, target: target, action: action)
    button.bezelStyle = .rounded
    button.toolTip = tip
    button.setAccessibilityIdentifier(id)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    return button
}

/// A screen's main button: filled with the accent while its window is active, and its title then in the colour for text
/// on the accent. AppKit draws that title white, 2.4:1 on Deep Water's petrol (WCAG AA asks 4.5:1).
final class PrimaryButton: NSButton {
    override class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelColor = .accent
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private final class Cell: NSButtonCell {
        override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
            // Emphasized: AppKit fills the bezel (its window is active) and would put a white title on it.
            guard interiorBackgroundStyle == .emphasized else { return super.drawTitle(title, withFrame: frame, in: controlView) }
            let text = NSMutableAttributedString(attributedString: title)
            text.addAttribute(.foregroundColor, value: NSColor.onAccent.withAlphaComponent(isEnabled ? 1 : 0.5),
                              range: NSRange(location: 0, length: text.length))
            return super.drawTitle(text, withFrame: frame, in: controlView)
        }
    }
}

/// A checkbox that says what it protects against or does.
func checkbox(_ title: String, id: String, tip: String, on: Bool, target: AnyObject?, action: Selector?) -> NSButton {
    let box = NSButton(checkboxWithTitle: title, target: target, action: action)
    box.state = on ? .on : .off
    box.toolTip = tip
    box.setAccessibilityIdentifier(id)
    box.translatesAutoresizingMaskIntoConstraints = false
    box.setContentCompressionResistancePriority(.required, for: .horizontal)
    return box
}

/// A pop-up of `titles`, with `selected` chosen.
func popup(_ titles: [String], selected: Int, id: String, tip: String, target: AnyObject?, action: Selector?) -> NSPopUpButton {
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    popup.addItems(withTitles: titles)
    popup.selectItem(at: selected)
    popup.toolTip = tip
    popup.target = target
    popup.action = action
    popup.setAccessibilityIdentifier(id)
    popup.translatesAutoresizingMaskIntoConstraints = false
    popup.setContentCompressionResistancePriority(.required, for: .horizontal)
    return popup
}

/// A text field (`width` wide) with a placeholder.
func textField(_ value: String, placeholder: String, id: String, tip: String, width: CGFloat? = nil) -> NSTextField {
    let field = NSTextField(string: value)
    field.placeholderString = placeholder
    field.toolTip = tip
    field.setAccessibilityIdentifier(id)
    field.translatesAutoresizingMaskIntoConstraints = false
    // Not scrollable: "…" at rest, where a scrollable cell cuts the text mid-letter. Its field editor still scrolls.
    field.lineBreakMode = .byTruncatingTail
    field.cell?.isScrollable = false
    field.cell?.usesSingleLineMode = true
    field.cell?.truncatesLastVisibleLine = true
    if let width { field.widthAnchor.constraint(equalToConstant: width).isActive = true }
    return field
}

/// A field over a title that renames in place (a tab, a result tab): its text chosen, Return keeps the new name and
/// Escape the old one. `done` gets the new name, or nil when the name stays as it was.
final class RenameField: NSTextField, NSTextFieldDelegate {
    private weak var title: NSTextField?
    private var done: ((String?) -> Void)?

    /// Shows the field with `text` at `frame` in `title`'s superview, over `title` (hidden meanwhile), with the focus.
    static func show(_ text: String, over title: NSTextField, frame: NSRect, id: String, tip: String,
                     done: @escaping (String?) -> Void) -> RenameField {
        let field = RenameField(string: text)
        field.font = title.font
        field.focusRingType = .none
        field.delegate = field
        field.toolTip = tip
        field.setAccessibilityIdentifier(id)
        field.frame = frame
        field.title = title
        field.done = done
        title.superview?.addSubview(field)
        title.isHidden = true
        field.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        return field
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        end(keep: false)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) { end(keep: true) }

    private func end(keep: Bool) {
        guard let done else { return }
        self.done = nil
        delegate = nil
        removeFromSuperview()
        title?.isHidden = false
        let text = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        done(keep && !text.isEmpty ? text : nil)
    }
}

/// A form: labels right-aligned in the first column, controls (with their captions under them) in the second, as
/// System Settings' older panes and AirSCP's forms lay them out.
final class Form {
    let grid = NSGridView(numberOfColumns: 2, rows: 0)
    /// The widest label, which `finish` makes the column's width: left to itself the grid's layout is ambiguous there.
    private(set) var labelWidth: CGFloat = 0

    init() {
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
    }

    /// A row: "Label:" and its controls; `caption` goes under them, in the second column.
    @discardableResult
    func row(_ title: String, _ views: [NSView], caption text: String? = nil) -> NSGridRow {
        let name = label(title.isEmpty ? "" : title + ":")
        name.alignment = .right
        labelWidth = max(labelWidth, ceil(name.intrinsicContentSize.width))
        // VoiceOver reads the label with the row's first control when that has no title of its own (a field, a pop-up).
        if !title.isEmpty, let control = views.first,
           (control as? NSTextField)?.isEditable == true || control is NSPopUpButton || control is NSSegmentedControl {
            control.setAccessibilityTitleUIElement(name)
        }
        let content: NSView
        if views.count == 1 {
            content = views[0]
        } else {
            let stack = NSStackView(views: views)
            stack.spacing = 8
            stack.alignment = .firstBaseline
            content = stack
        }
        let row = grid.addRow(with: [name, content])
        if let text {
            let note = caption(text)
            let captionRow = grid.addRow(with: [NSGridCell.emptyContentView, note])
            captionRow.topPadding = -4
        }
        return row
    }

    /// A section's heading across both columns, with space above it.
    func heading(_ title: String) {
        let text = label(title, font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold))
        let row = grid.addRow(with: [text, NSGridCell.emptyContentView])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.cell(at: 0).xPlacement = .leading
        if grid.numberOfRows > 1 { row.topPadding = 12 }
    }

    /// Finishes the layout: the first column right-aligned (as wide as its widest label).
    func finish() -> NSGridView {
        if grid.numberOfColumns > 0 {
            grid.column(at: 0).xPlacement = .trailing
            if labelWidth > 0 { grid.column(at: 0).width = labelWidth }
        }
        return grid
    }
}

extension NSView {
    /// Sends a command up this view's responder chain, then to its window's delegate, the app and its delegate: what
    /// AppKit does for the key window, whether or not this view's window is key (a double-click, a key in a list).
    @discardableResult
    func sendCommand(_ action: Selector) -> Bool {
        guard let target = commandTarget(action) else { return false }
        return NSApp.sendAction(action, to: target, from: self)
    }

    /// What `sendCommand` would send `action` to; nil: nothing here handles it.
    func commandTarget(_ action: Selector) -> AnyObject? {
        var responder: NSResponder? = self
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        let rest: [AnyObject?] = [window?.windowController, window?.delegate, NSApp, NSApp.delegate]
        return rest.compactMap { $0 }.first { $0.responds(to: action) }
    }

    /// Pins the view to `container`'s edges, inset by `insets`.
    func pin(to container: NSView, insets: NSEdgeInsets = NSEdgeInsetsZero) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom),
        ])
    }
}

extension NSTableView {
    /// For a right-click: selects the row under the pointer unless it is part of the selection (plan §2.12), and moves
    /// the focus to the list. False off the rows.
    func selectsRow(for event: NSEvent) -> Bool {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return false }
        if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        window?.makeFirstResponder(self)
        return true
    }
}

/// A filter over a list. Return and ↓ go to the list, so a sheet's default button doesn't run from it.
final class ListFilter: NSSearchField, NSSearchFieldDelegate {
    private weak var list: NSTableView?
    private let onChange: () -> Void

    init(_ placeholder: String, id: String, tip: String, list: NSTableView, onChange: @escaping () -> Void) {
        self.list = list
        self.onChange = onChange
        super.init(frame: .zero)
        placeholderString = placeholder
        toolTip = tip
        setAccessibilityIdentifier(id)
        translatesAutoresizingMaskIntoConstraints = false
        sendsSearchStringImmediately = true
        target = self
        action = #selector(changed(_:))
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func changed(_ sender: Any?) { onChange() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.moveDown(_:)),
              let list else { return false }
        window?.makeFirstResponder(list)
        if list.selectedRow < 0, list.numberOfRows > 0 { list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        return true
    }
}

/// A list on the content surface, with stripes in the theme's colours: AppKit's are neutral grey, beside Deep Water's slate.
class ContentTable: NSTableView {
    /// Instead of `usesAlternatingRowBackgroundColors`, which would give the rows AppKit's colours.
    var stripes = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        backgroundColor = .content
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func didAdd(_ rowView: NSTableRowView, forRow row: Int) {
        if stripes { rowView.backgroundColor = row.isMultiple(of: 2) ? .content : .gridZebra }
        super.didAdd(rowView, forRow: row)
    }
}

/// A table whose Return and Enter do what its double-click does.
final class ReturnTable: ContentTable {
    var onReturn: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode) { onReturn() } else { super.keyDown(with: event) }
    }
}

extension NSTableView {
    /// Rows `height` tall with their line of text in the middle: a label used as a cell draws at the top of its frame, so
    /// the height beyond a line goes to the space between rows.
    /// Column headers in the bar's colour, as the grid's, not the system's black in Deep Water.
    func themeHeader() {
        for column in tableColumns {
            let cell = BarHeaderCell(textCell: column.title)
            cell.alignment = column.headerCell.alignment
            cell.font = column.headerCell.font
            column.headerCell = cell
        }
    }

    func centreText(rowHeight height: CGFloat) {
        rowSizeStyle = .custom
        rowHeight = 16
        intercellSpacing.height = height - rowHeight
    }
}

private final class BarHeaderCell: NSTableHeaderCell {
    override func draw(withFrame frame: NSRect, in view: NSView) {
        let frame = frame.intersection(view.bounds)
        NSColor.bar.solid.setFill()
        frame.fill()
        NSColor.softSeparator.setFill()
        NSRect(x: frame.maxX - 1, y: frame.minY + 4, width: 1, height: frame.height - 8).fill()
        NSRect(x: frame.minX, y: frame.maxY - 1, width: frame.width, height: 1).fill()
        drawInterior(withFrame: frame.insetBy(dx: 0, dy: max(0, (frame.height - 18) / 2)), in: view)
    }
}

extension NSEdgeInsets {
    static func all(_ value: CGFloat) -> NSEdgeInsets { NSEdgeInsets(top: value, left: value, bottom: value, right: value) }
}
