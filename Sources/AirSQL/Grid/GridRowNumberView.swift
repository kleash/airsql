import AirSQLCore
import AppKit

/// The grid's row numbers (the scroll view's vertical ruler, so they scroll with the cells): 1-based, right-aligned in
/// tabular digits. Clicking selects the row, a double click opens it in Record View.
final class GridRowNumberView: NSRulerView {
    unowned let grid: DataGridView
    private var dragging = false

    init(grid: DataGridView) {
        self.grid = grid
        super.init(scrollView: grid.scrollView, orientation: .verticalRuler)
        clientView = grid
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        setAccessibilityIdentifier("grid.rowNumbers")
        toolTip = "Select the row; double-click to open it in Record View"
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var requiredThickness: CGFloat { ruleThickness }
    private var font: NSFont { .monospacedDigitSystemFont(ofSize: grid.fontSize, weight: .regular) }

    /// As wide as the largest row number needs (at least 40 points).
    func updateThickness() {
        let digits = String(repeating: "8", count: String(max(1, grid.rowCount)).count) as NSString
        let width = max(40, ceil(digits.size(withAttributes: [.font: font]).width) + 2 * GridStyles.padding)
        if ruleThickness != width { ruleThickness = width }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Clipped by hand: AppKit doesn't clip a ruler when an ancestor caches its display (a screenshot), and the fill
        // covered the cells.
        bounds.clip()
        NSColor.bar.setFill()
        dirtyRect.intersection(bounds).fill()
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        let focused = grid.isFocused
        let rows = grid.rows(in: grid.shownRect)
        for row in rows {
            let top = convert(NSPoint(x: 0, y: CGFloat(row) * grid.rowHeight), from: grid).y
            let rect = NSRect(x: 0, y: top, width: bounds.width, height: grid.rowHeight)
            guard rect.intersects(dirtyRect) else { continue }
            let selected = grid.selection.containsRow(row)
            if selected {
                (focused ? NSColor.selectedRow : .unemphasizedSelectedContentBackgroundColor).setFill()
                rect.fill()
            }
            var color = selected ? NSColor.labelColor : .tertiaryLabelColor
            if let source = grid.source, let first = grid.columnOrder.first {
                let mark = source.mark(row, first)
                let line: NSColor? = mark == .inserted ? .pendingInsertLine : mark == .deleted ? .pendingDeleteLine : nil
                if let line {
                    line.setFill()
                    NSRect(x: 0, y: top, width: 3, height: grid.rowHeight).fill()
                    color = line
                }
            }
            let text = String(row + 1) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let width = text.size(withAttributes: attributes).width
            text.draw(at: NSPoint(x: bounds.width - GridStyles.padding - width, y: top + grid.styles.baseline - font.ascender),
                      withAttributes: attributes)
            NSColor.softSeparator.setFill()
            NSRect(x: 0, y: top + grid.rowHeight - pixel, width: bounds.width, height: pixel).fill()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - pixel, y: dirtyRect.minY, width: pixel, height: dirtyRect.height).fill()
    }

    // MARK: Mouse

    private func row(at event: NSEvent) -> Int? {
        let y = grid.convert(event.locationInWindow, from: nil).y
        return y >= 0 && Int(y / grid.rowHeight) < grid.rowCount ? Int(y / grid.rowHeight) : nil
    }

    override func mouseDown(with event: NSEvent) {
        grid.window?.makeFirstResponder(grid)
        guard let row = row(at: event) else { return }
        if event.clickCount == 2 {
            dragging = false
            grid.delegate?.dataGrid(grid, openRecord: row)
            return
        }
        grid.selection.selectRow(row, extend: event.modifierFlags.contains(.shift), add: event.modifierFlags.contains(.command))
        dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, grid.rowCount > 0 else { return }
        grid.autoscroll(with: event)
        let y = grid.convert(event.locationInWindow, from: nil).y
        grid.selection.selectRow(min(max(0, Int(y / grid.rowHeight)), grid.rowCount - 1), extend: true)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
    }

    /// A right click on a row that isn't selected selects it first.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let row = row(at: event) else { return nil }
        grid.window?.makeFirstResponder(grid)
        if !grid.selection.containsRow(row) { grid.selection.selectRow(row) }
        return grid.delegate?.dataGrid(grid, menuFor: .row(row))
    }
}
