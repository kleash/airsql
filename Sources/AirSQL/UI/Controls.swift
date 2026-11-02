import AppKit

// Small makers for the controls every screen uses, so each one gets its tooltip, accessibility id and Auto Layout
// behaviour (text never cut: it hugs, resists compression, or truncates with an ellipsis and a tooltip) the same way.

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

/// A push button that says what it does, with an accessibility id (`area.name`).
func button(_ title: String, id: String, tip: String, target: AnyObject?, action: Selector?) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    button.bezelStyle = .rounded
    button.toolTip = tip
    button.setAccessibilityIdentifier(id)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    return button
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
    field.lineBreakMode = .byTruncatingTail
    field.cell?.isScrollable = true
    if let width { field.widthAnchor.constraint(equalToConstant: width).isActive = true }
    return field
}

/// A form: labels right-aligned in the first column, controls (with their captions under them) in the second, as
/// System Settings' older panes and AirSCP's forms lay them out.
final class Form {
    let grid = NSGridView()

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
        let row = grid.addRow(with: [text])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.cell(at: 0).xPlacement = .leading
        if grid.numberOfRows > 1 { row.topPadding = 12 }
    }

    /// Finishes the layout: the first column right-aligned (as wide as its widest label).
    func finish() -> NSGridView {
        if grid.numberOfColumns > 0 { grid.column(at: 0).xPlacement = .trailing }
        return grid
    }
}

extension NSView {
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

extension NSEdgeInsets {
    static func all(_ value: CGFloat) -> NSEdgeInsets { NSEdgeInsets(top: value, left: value, bottom: value, right: value) }
}
