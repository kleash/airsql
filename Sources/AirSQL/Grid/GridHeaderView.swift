import AirSQLCore
import AppKit

/// The grid's column header (the scroll view's horizontal ruler, so it scrolls with the cells): each column's name in
/// semibold over its type, a key mark on key columns, and at the right the sort control (the column's arrow and its
/// place in the sort; on hover, both arrows). Clicking selects the column; the sort control sorts; dragging the border
/// resizes and a double click on it auto-fits; dragging a header moves the column.
final class GridHeaderView: NSRulerView {
    unowned let grid: DataGridView
    /// The display column under the pointer, for the hover sort control.
    var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    /// Where a moved column would go (the display index it would take), while one is dragged.
    var dropIndex: Int? { didSet { if dropIndex != oldValue { needsDisplay = true } } }
    static let sortWidth: CGFloat = 18
    private var drag: Drag?

    init(grid: DataGridView) {
        self.grid = grid
        super.init(scrollView: grid.scrollView, orientation: .horizontalRuler)
        clientView = grid
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        ruleThickness = thickness
        setAccessibilityIdentifier("grid.header")
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var requiredThickness: CGFloat { thickness }

    private var nameFont: NSFont { .systemFont(ofSize: grid.fontSize, weight: .semibold) }
    private var typeFont: NSFont { .systemFont(ofSize: grid.fontSize - 1.5) }
    private var thickness: CGFloat {
        ceil(nameFont.ascender - nameFont.descender) + ceil(typeFont.ascender - typeFont.descender) + 8
    }

    /// The width a column needs for its header: the key mark, the longer of name and type, the sort control.
    func width(for column: GridColumn) -> CGFloat {
        let name = (column.name as NSString).size(withAttributes: [.font: nameFont]).width + (column.isKey ? 13 : 0)
        let type = (column.type as NSString).size(withAttributes: [.font: typeFont]).width
        return ceil(max(name, type)) + 8 + 4 + Self.sortWidth
    }

    /// A display column's left and right edges in this view.
    func edges(_ column: Int) -> (left: CGFloat, right: CGFloat) {
        (convert(NSPoint(x: grid.offsets[column], y: 0), from: grid).x, convert(NSPoint(x: grid.offsets[column + 1], y: 0), from: grid).x)
    }

    /// Where the cells start in this view: left of it is the corner above the row numbers.
    var contentLeft: CGFloat { convert(NSPoint(x: grid.shownRect.minX, y: 0), from: grid).x }

    override func draw(_ dirtyRect: NSRect) {
        // Clipped by hand: AppKit doesn't clip a ruler when an ancestor caches its display (a screenshot), and the fill
        // covered the cells.
        bounds.clip()
        NSColor.bar.setFill()
        dirtyRect.intersection(bounds).fill()
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        let clipLeft = contentLeft
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: clipLeft, y: 0, width: max(0, bounds.maxX - clipLeft), height: bounds.height).clip()
        if let source = grid.source {
            let visible = grid.columns(in: grid.shownRect)
            let focused = grid.isFocused
            for column in visible {
                let (left, right) = edges(column)
                let rect = NSRect(x: left, y: 0, width: right - left, height: bounds.height)
                guard rect.intersects(dirtyRect) else { continue }
                let sourceColumn = grid.columnOrder[column], info = source.columns[sourceColumn]
                if grid.selection.containsColumn(column) {
                    (focused ? NSColor.selectedRow : .unemphasizedSelectedContentBackgroundColor).setFill()
                    rect.fill()
                }
                drawLabels(info, in: rect)
                drawSortControl(sourceColumn, column, in: rect)
                NSColor.softSeparator.setFill()
                NSRect(x: right - pixel, y: 0, width: pixel, height: bounds.height).fill()
            }
            if let dropIndex, dropIndex <= grid.columnCount {
                NSColor.accent.setFill()
                let x = convert(NSPoint(x: grid.offsets[dropIndex], y: 0), from: grid).x
                NSRect(x: x - 1, y: 0, width: 2, height: bounds.height).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - pixel, width: bounds.width, height: pixel).fill()
        // The corner's own edge, in line with the row numbers' border.
        NSRect(x: clipLeft - pixel, y: 0, width: pixel, height: bounds.height).fill()
    }

    private func drawLabels(_ info: GridColumn, in rect: NSRect) {
        var x = rect.minX + 8
        let room = rect.maxX - Self.sortWidth - 4
        let nameHeight = ceil(nameFont.ascender - nameFont.descender)
        if info.isKey, let key = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Key")?
            .withSymbolConfiguration(.init(pointSize: grid.fontSize - 3, weight: .semibold).applying(.init(paletteColors: [.statusWarning]))) {
            let size = key.size
            key.draw(in: NSRect(x: x, y: 4 + (nameHeight - size.height) / 2, width: size.width, height: size.height))
            x += size.width + 3
        }
        let cut = NSMutableParagraphStyle()
        cut.lineBreakMode = .byTruncatingTail
        (info.name as NSString).draw(with: NSRect(x: x, y: 4, width: max(0, room - x), height: nameHeight),
                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                     attributes: [.font: nameFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: cut])
        (info.type as NSString).draw(with: NSRect(x: rect.minX + 8, y: 4 + nameHeight, width: max(0, room - rect.minX - 8),
                                                  height: ceil(typeFont.ascender - typeFont.descender)),
                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                     attributes: [.font: typeFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: cut])
    }

    /// The column's arrow (accent) and its place when the sort has several columns; both arrows on hover.
    private func drawSortControl(_ sourceColumn: Int, _ column: Int, in rect: NSRect) {
        let control = sortRect(rect)
        let index = grid.sortOrder.firstIndex { $0.column == sourceColumn }
        let symbol: String, color: NSColor
        if let index {
            symbol = grid.sortOrder[index].ascending ? "arrow.up" : "arrow.down"
            color = .accent
        } else if hovered == column {
            symbol = "chevron.up.chevron.down"
            color = .tertiaryLabelColor
        } else {
            return
        }
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: grid.fontSize - 2, weight: .semibold).applying(.init(paletteColors: [color])))
        else { return }
        let size = image.size
        image.draw(in: NSRect(x: control.midX - size.width / 2 - (grid.sortOrder.count > 1 && index != nil ? 3 : 0),
                              y: control.midY - size.height / 2, width: size.width, height: size.height))
        if let index, grid.sortOrder.count > 1 {
            ("\(index + 1)" as NSString).draw(at: NSPoint(x: control.midX + size.width / 2 - 2, y: control.midY - size.height / 2 - 2),
                                              withAttributes: [.font: NSFont.systemFont(ofSize: grid.fontSize - 4, weight: .semibold),
                                                               .foregroundColor: color])
        }
    }

    /// Where a header's sort control is.
    func sortRect(_ rect: NSRect) -> NSRect {
        NSRect(x: rect.maxX - Self.sortWidth - 2, y: 0, width: Self.sortWidth, height: rect.height)
    }

    // MARK: Mouse

    private enum Drag {
        case resize(column: Int, startX: CGFloat, width: CGFloat)
        case move(column: Int, startX: CGFloat)
    }

    /// The display column under a point (not the corner above the row numbers).
    func column(at point: NSPoint) -> Int? {
        guard point.x >= contentLeft else { return nil }
        return grid.column(atX: grid.convert(point, from: self).x)
    }

    /// The display column whose right border is within 4 points of a point.
    func border(at point: NSPoint) -> Int? {
        guard point.x >= contentLeft else { return nil }
        return grid.columns(in: grid.shownRect).first { abs(edges($0).right - point.x) <= 4 }
    }

    private func isInSortControl(_ point: NSPoint, _ column: Int) -> Bool {
        let (left, right) = edges(column)
        return sortRect(NSRect(x: left, y: 0, width: right - left, height: bounds.height)).contains(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil), flags = event.modifierFlags
        grid.window?.makeFirstResponder(grid)
        if let column = border(at: point) {
            if event.clickCount == 2 {
                grid.autoFit(column)
            } else {
                drag = .resize(column: column, startX: point.x, width: grid.columnWidths[grid.columnOrder[column]])
            }
            return
        }
        guard let column = column(at: point) else { return }
        if isInSortControl(point, column) {
            grid.delegate?.dataGrid(grid, sortBy: grid.columnOrder[column], adding: flags.contains(.option))
            return
        }
        grid.selection.selectColumn(column, extend: flags.contains(.shift), add: flags.contains(.command))
        drag = .move(column: column, startX: point.x)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .resize(let column, let startX, let width):
            grid.columnWidths[grid.columnOrder[column]] = max(40, (width + point.x - startX).rounded())
        case .move(_, let startX):
            guard abs(point.x - startX) > 4 else { return }
            grid.autoscroll(with: event)
            // The border nearest the pointer is where the column would go.
            let x = grid.convert(event.locationInWindow, from: nil).x
            dropIndex = grid.column(atX: x).map { x - grid.offsets[$0] < (grid.offsets[$0 + 1] - grid.offsets[$0]) / 2 ? $0 : $0 + 1 }
                ?? (x < 0 ? 0 : grid.columnCount)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            dropIndex = nil
        }
        switch drag {
        case .resize:
            grid.delegate?.dataGridColumnsDidChange(grid)
        case .move(let column, _):
            guard let dropIndex, dropIndex != column, dropIndex != column + 1 else { return }
            var order = grid.columnOrder
            let moved = order.remove(at: column), index = dropIndex > column ? dropIndex - 1 : dropIndex
            order.insert(moved, at: index)
            grid.columnOrder = order
            grid.selection.selectColumn(index)
            grid.delegate?.dataGridColumnsDidChange(grid)
        case nil:
            break
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow,
                                                               .inVisibleRect], owner: self))
    }

    /// The resize cursor on a border, the sort control on hover, and a tooltip for what is under the pointer.
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let border = border(at: point), column = border == nil ? column(at: point) : nil
        (border != nil ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
        hovered = column
        if border != nil {
            toolTip = "Drag to resize the column; double-click to fit its values"
        } else if let column, let info = grid.source?.columns[grid.columnOrder[column]] {
            let type = info.type.isEmpty ? "" : " (\(info.type))"
            toolTip = isInSortControl(point, column) ? "Sort by \(info.name); ⌥-click to add it to the sort"
                : "Select the column \(info.name)\(type); drag to move it"
        } else {
            toolTip = nil
        }
    }

    override func cursorUpdate(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        NSCursor.arrow.set()
    }

    /// A right click on a column that isn't selected selects it first.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let column = column(at: convert(event.locationInWindow, from: nil)) else { return nil }
        grid.window?.makeFirstResponder(grid)
        if !grid.selection.containsColumn(column) { grid.selection.selectColumn(column) }
        return grid.delegate?.dataGrid(grid, menuFor: .column(grid.columnOrder[column]))
    }
}
