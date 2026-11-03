import AirSQLCore
import AppKit

// Clicks and keys on the cells (grid-spec §2, plan §2.12): a click selects the cell, ⇧ extends, ⌘ adds, a drag selects
// a block, a double click or Return or typing edits in place, a right click asks the delegate for the menu. Keys arrive
// as AppKit's standard commands (interpretKeyEvents), so people's own key bindings apply.
extension DataGridView {
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let position = position(at: convert(event.locationInWindow, from: nil)) else { return }
        let flags = event.modifierFlags
        if event.clickCount == 2, flags.isDisjoint(with: [.shift, .command]) {
            isDragging = false
            if canEdit(position) {
                beginEditing(at: position)
            } else {
                selection.select(position)
                delegate?.dataGridOpenValue(self)
            }
            return
        }
        selection.select(position, extend: flags.contains(.shift), add: flags.contains(.command))
        isDragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, rowCount > 0, columnCount > 0 else { return }
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let row = min(max(0, Int(point.y / rowHeight)), rowCount - 1)
        let column = column(atX: min(max(0, point.x), offsets[columnCount] - 1)) ?? 0
        selection.select(GridPosition(row: row, column: column), extend: true)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    /// The cell under the pointer shows its whole value (the first 1 KB) as a tooltip when the cell cuts it.
    override func mouseMoved(with event: NSEvent) {
        let position = position(at: convert(event.locationInWindow, from: nil))
        guard position != hoveredCell else { return }
        hoveredCell = position
        guard let position, let source else { return toolTip = nil }
        let column = columnOrder[position.column], cell = source.cell(position.row, column)
        let width = styles.width(of: cell, in: source.columns[column], nullText: nullText)
        let text = cell.text
        let cut = width > cellRect(position).width - 2 * GridStyles.padding || text.contains(where: \.isNewline)
        toolTip = cut ? String(text.prefix(1024)) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
    }

    /// A right click on a cell that isn't selected selects it first; the delegate's menu acts on the selection.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let position = position(at: convert(event.locationInWindow, from: nil)) else { return nil }
        window?.makeFirstResponder(self)
        if !selection.contains(position) { selection.select(position) }
        return delegate?.dataGrid(self, menuFor: .cells)
    }

    override func keyDown(with event: NSEvent) {
        // ⇧↩ is Value Panel's shortcut (menus take only ⌘ and ⌃ keys).
        if [36, 76].contains(event.keyCode), event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift {
            sendCommand(Commands.valuePanel.action)
        } else {
            interpretKeyEvents([event])
        }
    }

    override func becomeFirstResponder() -> Bool {
        focusDidChange()
        return true
    }

    override func resignFirstResponder() -> Bool {
        focusDidChange()
        return true
    }

    /// Redraws what looks different with or without the keyboard: the selection's colour and the focus ring.
    func focusDidChange() {
        needsDisplay = true
        header.needsDisplay = true
        rowNumbers.needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: name, object: window)
        }
    }

    @objc private func windowKeyChanged(_ note: Notification) { focusDidChange() }

    // MARK: Keys

    /// Moves the cursor (and with ⇧ the selection) and scrolls to it.
    func move(_ move: GridSelection.Move, extend: Bool = false) {
        selection.move(move, extend: extend, rows: rowCount, columns: columnCount, page: rowsPerPage)
        if let cursor = selection.cursor { reveal(cellRect(cursor)) }
    }

    override func moveUp(_ sender: Any?) { move(.up) }
    override func moveDown(_ sender: Any?) { move(.down) }
    override func moveLeft(_ sender: Any?) { move(.left) }
    override func moveRight(_ sender: Any?) { move(.right) }
    override func moveUpAndModifySelection(_ sender: Any?) { move(.up, extend: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { move(.down, extend: true) }
    override func moveLeftAndModifySelection(_ sender: Any?) { move(.left, extend: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { move(.right, extend: true) }
    // ⌘↑ ⌘↓: the first and last row; ⌘← ⌘→: the first and last column.
    override func moveToBeginningOfDocument(_ sender: Any?) { move(.firstRow) }
    override func moveToEndOfDocument(_ sender: Any?) { move(.lastRow) }
    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { move(.firstRow, extend: true) }
    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { move(.lastRow, extend: true) }
    override func moveToLeftEndOfLine(_ sender: Any?) { move(.firstColumn) }
    override func moveToRightEndOfLine(_ sender: Any?) { move(.lastColumn) }
    override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { move(.firstColumn, extend: true) }
    override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { move(.lastColumn, extend: true) }
    override func moveToBeginningOfLine(_ sender: Any?) { move(.firstColumn) }
    override func moveToEndOfLine(_ sender: Any?) { move(.lastColumn) }
    // Page Up and Page Down move the cursor a screen; Home and End go to the first and last row.
    override func scrollPageUp(_ sender: Any?) { move(.pageUp) }
    override func scrollPageDown(_ sender: Any?) { move(.pageDown) }
    override func pageUp(_ sender: Any?) { move(.pageUp) }
    override func pageDown(_ sender: Any?) { move(.pageDown) }
    override func pageUpAndModifySelection(_ sender: Any?) { move(.pageUp, extend: true) }
    override func pageDownAndModifySelection(_ sender: Any?) { move(.pageDown, extend: true) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { move(.firstRow) }
    override func scrollToEndOfDocument(_ sender: Any?) { move(.lastRow) }
    override func insertTab(_ sender: Any?) { move(.next) }
    override func insertBacktab(_ sender: Any?) { move(.previous) }

    /// Return edits the focused cell.
    override func insertNewline(_ sender: Any?) {
        if let cursor = selection.cursor { beginEditing(at: cursor) }
    }

    /// Typing edits the focused cell, starting from what was typed (spreadsheet behaviour).
    override func insertText(_ insertString: Any) {
        let text = (insertString as? NSAttributedString)?.string ?? insertString as? String ?? ""
        guard let cursor = selection.cursor, !text.isEmpty else { return }
        beginEditing(at: cursor, text: text)
    }

    override func selectAll(_ sender: Any?) {
        guard rowCount > 0, columnCount > 0 else { return }
        selection.selectAll()
    }
}
