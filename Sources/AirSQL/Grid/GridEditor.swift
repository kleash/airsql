import AirSQLCore
import AppKit

/// The grid's one editor overlay: a text field over the cell being edited. Return commits, Tab and ⇧Tab commit and
/// move, Esc cancels, a click elsewhere commits. A commit goes to the grid's delegate as a pending change; nothing is
/// written to the database here. A value the delegate's check refuses keeps the editor open, saying why under it;
/// typing is never blocked. ↑ and ↓ step the part of a date or time under the cursor (the delegate's step).
final class GridEditor: NSTextField, NSTextFieldDelegate {
    let position: GridPosition
    private unowned let grid: DataGridView
    /// Whether the text was changed: an editor closed without a change commits nothing.
    private(set) var changed = false
    /// Esc: the editor closes whatever its text.
    var cancelling = false
    /// Why the text can't be kept, under the editor.
    private var problem: NSPopover?

    init(grid: DataGridView, position: GridPosition, text: String, font: NSFont) {
        self.grid = grid
        self.position = position
        super.init(frame: .zero)
        stringValue = text
        self.font = font
        // Clear, so the cell's focus colour and ring show around the text, where the cell's own text was.
        isBordered = false
        drawsBackground = false
        textColor = .labelColor
        focusRingType = .exterior
        usesSingleLineMode = false
        lineBreakMode = .byClipping
        cell?.isScrollable = true
        delegate = self
        setAccessibilityIdentifier("grid.editor")
        toolTip = "Edit the value: Return keeps it as a pending change, Esc cancels, Tab moves to the next cell"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Over `cell`: the text where the cell's own text was, the field centred in the row.
    func place(over cell: NSRect) {
        let height = min(cell.height, ceil(fittingSize.height))
        frame = NSRect(x: cell.minX + GridStyles.padding - 2, y: cell.minY + ((cell.height - height) / 2).rounded(),
                       width: max(20, cell.width - 2 * GridStyles.padding + 4), height: height)
    }

    func controlTextDidChange(_ obj: Notification) {
        changed = true
        problem?.close()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)): grid.endEditing(commit: true)
        case #selector(insertTab(_:)): grid.endEditing(commit: true, move: .next)
        case #selector(insertBacktab(_:)): grid.endEditing(commit: true, move: .previous)
        case #selector(cancelOperation(_:)): grid.endEditing(commit: false)
        case #selector(moveUp(_:)), #selector(moveDown(_:)):
            let column = grid.columnOrder[position.column]
            guard let (text, part) = grid.delegate?.dataGrid(grid, step: textView.string, at: textView.selectedRange().location,
                                                              by: selector == #selector(moveUp(_:)) ? 1 : -1,
                                                              row: position.row, column: column) else { return false }
            textView.string = text
            textView.setSelectedRange(part)
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        default: return false
        }
        return true
    }

    /// Why the text can't be kept, nil when it can (or wasn't changed).
    var refusal: String? {
        guard changed, !cancelling, position.row < grid.rowCount, position.column < grid.columnCount else { return nil }
        return grid.delegate?.dataGrid(grid, check: stringValue, row: position.row, column: grid.columnOrder[position.column])
    }

    /// A click elsewhere can't take the keyboard while the text is refused: it says why instead.
    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        guard let refusal else { return true }
        show(problem: refusal)
        return false
    }

    /// Says under the editor why its text can't be kept, until the text changes.
    func show(problem message: String) {
        NSSound.beep()
        problem?.close()
        let text = label(message + ".\nFix the value, or press Esc to leave the cell as it was.", font: .systemFont(ofSize: 12), wraps: true)
        text.preferredMaxLayoutWidth = 320
        let stack = NSStackView(views: [text])
        stack.setAccessibilityIdentifier("grid.editor.problem")
        let popover = popover(around: stack, behavior: .applicationDefined)
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        problem = popover
    }

    override func removeFromSuperview() {
        problem?.close()
        super.removeFromSuperview()
    }

    /// The field lost the keyboard some other way (a click elsewhere): keeps the edit.
    func controlTextDidEndEditing(_ obj: Notification) {
        if grid.editor === self { grid.endEditing(commit: true, refocus: false) }
    }
}

/// A popover around `content` with margins, as large as they and the content need.
@MainActor
func popover(around content: NSView, behavior: NSPopover.Behavior) -> NSPopover {
    let controller = NSViewController()
    controller.view = NSView()
    // The popover's id is its content's (what the harness's wait reports).
    controller.view.setAccessibilityIdentifier(content.accessibilityIdentifier())
    content.setAccessibilityIdentifier(nil)
    content.translatesAutoresizingMaskIntoConstraints = false
    controller.view.addSubview(content)
    NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 10),
        content.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -10),
        content.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 12),
        content.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -12),
    ])
    controller.view.layoutSubtreeIfNeeded()
    controller.preferredContentSize = controller.view.fittingSize
    let popover = NSPopover()
    popover.contentViewController = controller
    popover.behavior = behavior
    return popover
}

extension DataGridView {
    /// Edits a cell in place when the delegate allows it; `text` replaces the value (typing), else the value is
    /// selected for editing. Beeps on a read-only cell.
    func beginEditing(at position: GridPosition, text: String? = nil) {
        guard editor == nil, let source, position.row < rowCount, position.column < columnCount else { return }
        let column = columnOrder[position.column]
        guard canEdit(position) else { return NSSound.beep() }
        // Typing over several selected cells keeps them selected: the host gives them all the value (multi-cell edit).
        if text == nil || !selection.contains(position) { selection.select(position) }
        reveal(cellRect(position))
        if delegate?.dataGrid(self, edit: position.row, column: column, typed: text) == true { return }
        // The stored value, not what Display As shows (a date for a Unix time) or a new row's (auto) mark.
        let editor = GridEditor(grid: self, position: position, text: text ?? source.value(position.row, column) ?? "",
                                font: styles.font(source.columns[column], isNull: false))
        self.editor = editor
        editor.place(over: cellRect(position))
        addSubview(editor)
        window?.makeFirstResponder(editor)
        if text != nil, let field = editor.currentEditor() {
            // Typed: carries on after what was typed, which counts as a change.
            field.selectedRange = NSRange(location: (field.string as NSString).length, length: 0)
            editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        }
        setNeedsDisplay(cellRect(position))
    }

    /// Closes the editor: with `commit`, a changed value goes to the delegate; then the cursor moves (Tab). False when
    /// the delegate refuses the value: the editor stays open and says why.
    @discardableResult
    func endEditing(commit: Bool, move: GridSelection.Move? = nil, refocus: Bool = true) -> Bool {
        guard let editor else { return true }
        if commit, let refusal = editor.refusal {
            editor.show(problem: refusal)
            return false
        }
        editor.cancelling = !commit
        self.editor = nil
        let text = editor.stringValue, position = editor.position
        editor.delegate = nil
        if refocus { window?.makeFirstResponder(self) }
        editor.removeFromSuperview()
        if commit, editor.changed { self.commit(text, at: position) }
        if position.row < rowCount, position.column < columnCount { setNeedsDisplay(cellRect(position)) }
        if let move { self.move(move) }
        return true
    }
}
