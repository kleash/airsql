import AirSQLCore
import AppKit

/// The grid's one editor overlay: a text field over the cell being edited. Return commits, Tab and ⇧Tab commit and
/// move, Esc cancels, a click elsewhere commits. A commit goes to the grid's delegate as a pending change; nothing is
/// written to the database here.
final class GridEditor: NSTextField, NSTextFieldDelegate {
    let position: GridPosition
    private unowned let grid: DataGridView
    /// Whether the text was changed: an editor closed without a change commits nothing.
    private(set) var changed = false

    init(grid: DataGridView, position: GridPosition, text: String, font: NSFont) {
        self.grid = grid
        self.position = position
        super.init(frame: .zero)
        stringValue = text
        self.font = font
        isBordered = false
        drawsBackground = true
        backgroundColor = .content
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

    func controlTextDidChange(_ obj: Notification) { changed = true }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)): grid.endEditing(commit: true)
        case #selector(insertTab(_:)): grid.endEditing(commit: true, move: .next)
        case #selector(insertBacktab(_:)): grid.endEditing(commit: true, move: .previous)
        case #selector(cancelOperation(_:)): grid.endEditing(commit: false)
        default: return false
        }
        return true
    }

    /// The field lost the keyboard some other way (a click elsewhere): keeps the edit.
    func controlTextDidEndEditing(_ obj: Notification) {
        if grid.editor === self { grid.endEditing(commit: true, refocus: false) }
    }
}

extension DataGridView {
    /// Edits a cell in place when the delegate allows it; `text` replaces the value (typing), else the value is
    /// selected for editing. Beeps on a read-only cell.
    func beginEditing(at position: GridPosition, text: String? = nil) {
        guard editor == nil, let source, position.row < rowCount, position.column < columnCount else { return }
        let column = columnOrder[position.column]
        guard delegate?.dataGrid(self, canEditRow: position.row, column: column) == true else { return NSSound.beep() }
        selection.select(position)
        reveal(cellRect(position))
        let editor = GridEditor(grid: self, position: position, text: text ?? source.cell(position.row, column).text,
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

    /// Closes the editor: with `commit`, a changed value goes to the delegate; then the cursor moves (Tab).
    func endEditing(commit: Bool, move: GridSelection.Move? = nil, refocus: Bool = true) {
        guard let editor else { return }
        self.editor = nil
        let text = editor.stringValue, position = editor.position
        editor.delegate = nil
        if refocus { window?.makeFirstResponder(self) }
        editor.removeFromSuperview()
        if commit, editor.changed, position.row < rowCount, position.column < columnCount {
            delegate?.dataGrid(self, didEditRow: position.row, column: columnOrder[position.column], text: text)
        }
        setNeedsDisplay(cellRect(position))
        if let move { self.move(move) }
    }
}
