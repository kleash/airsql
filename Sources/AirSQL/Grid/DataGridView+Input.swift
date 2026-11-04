import AirSQLCore
import AppKit

// Clicks and keys on the cells (grid-spec §2, plan §2.12): a click selects the cell, ⇧ extends, ⌘ adds, a drag selects
// a block, a double click, Return, F2 or typing edits in place, a right click asks the delegate for the menu. Keys arrive
// as AppKit's standard commands (interpretKeyEvents), so people's own key bindings apply.
extension DataGridView {
    /// Takes the keyboard for a click: false while an editor keeps it, its value refused (the cell's editor or the
    /// value panel says why instead).
    func takeKeyboard() -> Bool {
        guard let window else { return editor == nil }
        return window.makeFirstResponder(self) && window.firstResponder === self
    }

    override func mouseDown(with event: NSEvent) {
        guard takeKeyboard(), let position = position(at: convert(event.locationInWindow, from: nil)) else { return }
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

    /// The cell under the pointer shows its whole value (the first 1 KB) as a tooltip when the cell cuts it, or what its
    /// source notes about it (a diff's other value).
    override func mouseMoved(with event: NSEvent) {
        let position = position(at: convert(event.locationInWindow, from: nil))
        guard position != hoveredCell else { return }
        hoveredCell = position
        guard let position, let source else { return toolTip = nil }
        let column = columnOrder[position.column], cell = source.cell(position.row, column)
        if let note = source.note(position.row, column) { return toolTip = note }
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

    /// A right click on a cell that isn't selected selects it first; the delegate's menu acts on the selection (off the
    /// cells too, for Add Row).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard takeKeyboard() else { return nil }
        if let position = position(at: convert(event.locationInWindow, from: nil)), !selection.contains(position) { selection.select(position) }
        return delegate?.dataGrid(self, menuFor: .cells)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        // ⇧↩ is Value Panel's shortcut (menus take only ⌘ and ⌃ keys).
        if [36, 76].contains(event.keyCode), flags == .shift {
            sendCommand(Commands.valuePanel.action)
        } else if event.specialKey == .f2, flags.isEmpty {
            insertNewline(nil)  // as in HeidiSQL
        } else {
            interpretKeyEvents([event])
        }
    }

    /// F2 is a hidden menu item's too, and even disabled that item takes the key before keyDown: the grid claims it first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        guard event.specialKey == .f2, flags.isEmpty, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
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

    /// Return edits the focused cell; one that can't be edited shows its value, as a double click does.
    override func insertNewline(_ sender: Any?) {
        guard let cursor = selection.cursor else { return }
        if canEdit(cursor) { beginEditing(at: cursor) } else { delegate?.dataGridOpenValue(self) }
    }

    /// ⌫ on whole rows marks them for deletion, as ⌘⌫ does; on cells it starts editing with nothing typed (nothing is
    /// lost until Return, as in a spreadsheet).
    override func deleteBackward(_ sender: Any?) {
        let wholeRows = !selection.isEmpty && selection.areas.allSatisfy { if case .rows = $0 { return true } else { return false } }
        if wholeRows {
            if !sendCommand(Commands.deleteRows.action) { NSSound.beep() }
        } else if let cursor = selection.cursor {
            beginEditing(at: cursor, text: "")
        }
    }

    override func deleteForward(_ sender: Any?) { deleteBackward(sender) }

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

    /// ⌥↑: the focused cell's column, then its row, then everything.
    @objc func extendSelection(_ sender: Any?) { selection.grow() }
    /// ⌥↓: back from everything to the row, the column and the cell.
    @objc func shrinkSelection(_ sender: Any?) { selection.shrink() }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: Self.scroll(event))
    }

    /// ⇧ scrolls a mouse wheel across; ⌥ scrolls five times as far (grid-spec §2).
    static func scroll(_ event: NSEvent) -> NSEvent {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .shift || flags == .option, let changed = event.cgEvent?.copy() else { return event }
        // Lines, then points last: setting the lines works the points out again.
        let axes: [(down: CGEventField, across: CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
            (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2),
            (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
        ]
        let deltas = axes.map { (changed.getDoubleValueField($0.down), changed.getDoubleValueField($0.across)) }
        for (axis, delta) in zip(axes, deltas) {
            var (down, across) = delta
            if flags == .shift, across == 0 { (down, across) = (0, down) }  // unless macOS turned it already
            if flags == .option { (down, across) = (down * 5, across * 5) }
            changed.setDoubleValueField(axis.down, value: down)
            changed.setDoubleValueField(axis.across, value: across)
        }
        return NSEvent(cgEvent: changed) ?? event
    }
}

extension DataGridView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(extendSelection(_:)), #selector(shrinkSelection(_:)):
            // Not while a cell is edited: there ⌥↑ and ⌥↓ move in the text.
            let enabled = window?.firstResponder === self && selection.cursor != nil
            item.explain(enabled: enabled, reason: "Select a cell in the grid first")
            return enabled
        default:
            return true
        }
    }
}
