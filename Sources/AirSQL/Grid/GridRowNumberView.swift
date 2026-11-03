import AirSQLCore
import AppKit

/// The grid's row numbers, beside the cells and scrolled down with them: 1-based, right-aligned in tabular digits. Clicking selects the row, a double click opens it in Record View.
final class GridRowNumberView: NSView {
    unowned let grid: DataGridView
    private var dragging = false

    init(grid: DataGridView) {
        self.grid = grid
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: 0))
        setAccessibilityIdentifier("grid.rowNumbers")
        toolTip = "Select the row; double-click to open it in Record View"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    private var font: NSFont { .monospacedDigitSystemFont(ofSize: grid.fontSize, weight: .regular) }

    /// As wide as the largest row number needs (at least 40 points).
    var thickness: CGFloat {
        let digits = String(repeating: "8", count: String(max(1, grid.rowCount)).count) as NSString
        return max(40, ceil(digits.size(withAttributes: [.font: font]).width) + 2 * GridStyles.padding)
    }

    func updateThickness() {
        if frame.width != thickness { grid.containerView?.tile() }
    }

    /// How far the cells are scrolled down: row y in the grid minus this is y here.
    private var scrolled: CGFloat { grid.scrollView.contentView.bounds.minY }

    /// The numbers of the rows shown.
    override func draw(_ dirtyRect: NSRect) {
        let dirtyRect = dirtyRect.intersection(bounds)  // since macOS 14 it can reach past the view
        NSColor.bar.solid.setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        let selectedFill = (grid.isFocused ? NSColor.selectedRow : .unemphasizedSelectedContentBackgroundColor).solid
        for row in grid.rows(in: dirtyRect.offsetBy(dx: 0, dy: scrolled)) {
            let top = CGFloat(row) * grid.rowHeight - scrolled
            let selected = grid.selection.containsRow(row)
            if selected {
                selectedFill.setFill()
                NSRect(x: 0, y: top, width: bounds.width, height: grid.rowHeight).fill()
            }
            var color = selected ? NSColor.labelColor : .tertiaryLabelColor
            if let source = grid.source, let first = grid.columnOrder.first {
                let mark = source.mark(row, first)
                if let line = mark == .inserted ? NSColor.pendingInsertLine : mark == .deleted ? NSColor.pendingDeleteLine : nil {
                    line.setFill()
                    NSRect(x: 0, y: top, width: 3, height: grid.rowHeight).fill()
                    color = line
                }
            }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(row + 1), attributes: [
                .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
            ]))
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            context.textPosition = CGPoint(x: bounds.width - GridStyles.padding - width, y: top + grid.styles.baseline)
            CTLineDraw(line, context)
            NSColor.softSeparator.setFill()
            NSRect(x: 0, y: top + grid.rowHeight - pixel, width: bounds.width, height: pixel).fill()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - pixel, y: dirtyRect.minY, width: pixel, height: dirtyRect.height).fill()
    }

    // MARK: Mouse

    private func row(at event: NSEvent) -> Int? {
        let y = convert(event.locationInWindow, from: nil).y + scrolled
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
