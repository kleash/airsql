import AirSQLCore
import AppKit

/// The grid's column header, above the cells and scrolled across with them: each column's name in semibold over its type, a key mark on key columns, and at the right the sort control (the column's arrow and its
/// place in the sort; on hover, both arrows), before it the filter's funnel where the host has one (on hover, and on a filtered column). Clicking selects the column; the sort control sorts; dragging the border
/// resizes and a double click on it auto-fits; dragging a header moves the column.
final class GridHeaderView: NSView {
    unowned let grid: DataGridView
    /// The display column under the pointer, for the hover sort control.
    var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    /// Where a moved column would go (the display index it would take), while one is dragged.
    var dropIndex: Int? { didSet { if dropIndex != oldValue { needsDisplay = true } } }
    static let sortWidth: CGFloat = 18
    static let funnelWidth: CGFloat = 16
    private var funnels: Bool { grid.delegate?.dataGridFiltersColumns(grid) == true }
    private var drag: Drag?
    private var symbols: [String: NSImage] = [:]

    init(grid: DataGridView) {
        self.grid = grid
        super.init(frame: .zero)
        setAccessibilityIdentifier("grid.header")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    private var nameFont: NSFont { .systemFont(ofSize: grid.fontSize, weight: .semibold) }
    private var typeFont: NSFont { .systemFont(ofSize: grid.fontSize - 1.5) }
    var thickness: CGFloat {
        // Results without types have no second line to keep room for.
        let hasTypes = grid.source?.columns.contains { !$0.typeLine.isEmpty } ?? true
        return ceil(nameFont.ascender - nameFont.descender) + (hasTypes ? ceil(typeFont.ascender - typeFont.descender) : 0) + 8
    }

    /// Follows the grid's text size.
    func updateThickness() {
        if frame.height != thickness { grid.containerView?.tile() }
    }

    /// How far the cells are scrolled across: column x in the grid minus this is x here.
    private var scrolled: CGFloat { grid.scrollView.contentView.bounds.minX }

    /// The width a column needs for its header: the key marks, the longer of name and type, the sort control.
    func width(for column: GridColumn) -> CGFloat {
        let name = (column.name as NSString).size(withAttributes: [.font: nameFont]).width + CGFloat(icons(column).count) * 13
        let type = (column.typeLine as NSString).size(withAttributes: [.font: typeFont]).width
        return ceil(max(name, type)) + 8 + 4 + Self.sortWidth + (funnels ? Self.funnelWidth : 0)
    }

    /// A display column's left and right edges here (frozen columns stay where they are).
    func edges(_ column: Int) -> (left: CGFloat, right: CGFloat) {
        let shift = column < grid.frozenColumns ? 0 : scrolled
        return (grid.offsets[column] - shift, grid.offsets[column + 1] - shift)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dirtyRect = dirtyRect.intersection(bounds)  // since macOS 14 it can reach past the view
        NSColor.bar.solid.setFill()
        dirtyRect.fill()
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        if let source = grid.source {
            let focused = grid.isFocused, frozen = min(grid.frozenColumns, grid.columnCount)
            // The frozen columns last, over the ones scrolled under them.
            for column in grid.columns(in: dirtyRect.offsetBy(dx: scrolled, dy: 0)).filter({ $0 >= frozen }) + Array(0..<frozen) {
                let (left, right) = edges(column)
                let rect = NSRect(x: left, y: 0, width: right - left, height: bounds.height)
                let sourceColumn = grid.columnOrder[column], info = source.columns[sourceColumn]
                if grid.selection.containsColumn(column) {
                    (focused ? NSColor.selectedRow : .unemphasizedSelectedContentBackgroundColor).solid.setFill()
                    rect.fill()
                } else if column < frozen {
                    NSColor.bar.solid.setFill()
                    rect.fill()
                }
                drawLabels(info, in: rect)
                drawSortControl(sourceColumn, column, in: rect)
                drawFunnel(sourceColumn, column, in: rect)
                NSColor.softSeparator.setFill()
                NSRect(x: right - pixel, y: 0, width: pixel, height: bounds.height).fill()
            }
            if let dropIndex, dropIndex <= grid.columnCount {
                NSColor.accent.setFill()
                NSRect(x: grid.offsets[dropIndex] - scrolled - 1, y: 0, width: 2, height: bounds.height).fill()
            }
        }
        NSColor.separatorColor.setFill()
        NSRect(x: dirtyRect.minX, y: bounds.height - pixel, width: dirtyRect.width, height: pixel).fill()
    }

    private func drawLabels(_ info: GridColumn, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        var x = rect.minX + 8
        let room = rect.maxX - Self.sortWidth - 4 - (funnels ? Self.funnelWidth : 0)
        let nameHeight = ceil(nameFont.ascender - nameFont.descender)
        for (name, color) in icons(info) {
            guard let image = symbol(name, size: grid.fontSize - 3, color: color) else { continue }
            let size = image.size
            image.draw(in: NSRect(x: x, y: 4 + (nameHeight - size.height) / 2, width: size.width, height: size.height))
            x += size.width + 3
        }
        func draw(_ text: String, _ font: NSFont, _ color: NSColor, x: CGFloat, baseline: CGFloat) {
            guard !text.isEmpty, room - x > 0 else { return }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor]
            var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(room - x) {
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
                line = CTLineCreateTruncatedLine(line, Double(room - x), .end, ellipsis) ?? line
            }
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
        }
        draw(info.name, nameFont, .labelColor, x: x, baseline: 4 + nameFont.ascender)
        draw(info.typeLine, typeFont, .quietText, x: rect.minX + 8, baseline: 4 + nameHeight + typeFont.ascender)
    }

    /// The symbols before a column's name: a gold key for the key that addresses rows (the primary key), a "1" (one row per value)
    /// for another unique key, an outline for an index, and an accent chain link for a foreign key.
    private func icons(_ column: GridColumn) -> [(String, NSColor)] {
        var icons: [(String, NSColor)] = []
        if column.isKey || column.marks.contains(.primary) {
            icons.append(("key.fill", .statusWarning))
        } else if column.marks.contains(.unique) {
            icons.append(("1.circle", .secondaryLabelColor))
        } else if column.marks.contains(.indexed) {
            icons.append(("key", .secondaryLabelColor))
        }
        if column.marks.contains(.foreign) { icons.append(("link", .accent)) }
        return icons
    }

    /// A symbol in a colour, made once per look and size.
    private func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let key = "\(name) \(size) \(effectiveAppearance.isDark) \(color.hash)"
        if let image = symbols[key] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold).applying(.init(paletteColors: [color])))
        symbols[key] = image
        return image
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
            color = .secondaryLabelColor
        } else {
            return
        }
        guard let image = self.symbol(symbol, size: grid.fontSize - 2, color: color) else { return }
        let size = image.size
        image.draw(in: NSRect(x: control.midX - size.width / 2 - (grid.sortOrder.count > 1 && index != nil ? 3 : 0),
                              y: control.midY - size.height / 2, width: size.width, height: size.height))
        if let index, grid.sortOrder.count > 1 {
            ("\(index + 1)" as NSString).draw(at: NSPoint(x: control.midX + size.width / 2 - 2, y: control.midY - size.height / 2 - 2),
                                              withAttributes: [.font: NSFont.systemFont(ofSize: grid.fontSize - 4, weight: .semibold),
                                                               .foregroundColor: color])
        }
    }

    /// The funnel: in the accent colour on a filtered column, quiet on hover.
    private func drawFunnel(_ sourceColumn: Int, _ column: Int, in rect: NSRect) {
        guard let funnel = funnelRect(rect) else { return }
        let filtered = grid.filteredColumns.contains(sourceColumn)
        guard filtered || hovered == column,
              let image = symbol("line.3.horizontal.decrease.circle", size: grid.fontSize - 1,
                                 color: filtered ? .accent : .secondaryLabelColor) else { return }
        let size = image.size
        image.draw(in: NSRect(x: funnel.midX - size.width / 2, y: funnel.midY - size.height / 2, width: size.width, height: size.height))
    }

    /// Where a header's funnel is; nil where the host has none, or the column is too narrow for it.
    func funnelRect(_ rect: NSRect) -> NSRect? {
        guard funnels, rect.width > Self.sortWidth + Self.funnelWidth + 8 else { return nil }
        return NSRect(x: rect.maxX - Self.sortWidth - 2 - Self.funnelWidth, y: 0, width: Self.funnelWidth, height: rect.height)
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

    /// The display column under a point.
    func column(at point: NSPoint) -> Int? {
        point.x < grid.frozenWidth ? grid.column(atX: point.x) : grid.column(atX: point.x + scrolled)
    }

    /// The display column whose right border is within 4 points of a point.
    func border(at point: NSPoint) -> Int? {
        let frozen = Array(0..<min(grid.frozenColumns, grid.columnCount))
        let near = !frozen.isEmpty && point.x < grid.frozenWidth + 4 ? frozen : Array(grid.columns(in: NSRect(x: point.x + scrolled - 4, y: 0, width: 8, height: 1)))
        return near.first { abs(edges($0).right - point.x) <= 4 }
    }

    private func isInSortControl(_ point: NSPoint, _ column: Int) -> Bool {
        let (left, right) = edges(column)
        return sortRect(NSRect(x: left, y: 0, width: right - left, height: bounds.height)).contains(point)
    }

    /// The funnel under a point, if any.
    private func funnel(at point: NSPoint, _ column: Int) -> NSRect? {
        let (left, right) = edges(column)
        return funnelRect(NSRect(x: left, y: 0, width: right - left, height: bounds.height)).flatMap { $0.contains(point) ? $0 : nil }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil), flags = event.modifierFlags
        guard grid.takeKeyboard() else { return }
        if let column = border(at: point) {
            if event.clickCount == 2 {
                grid.autoFit(column)
            } else {
                drag = .resize(column: column, startX: point.x, width: grid.columnWidths[grid.columnOrder[column]])
            }
            return
        }
        guard let column = column(at: point) else { return }
        if let funnel = funnel(at: point, column) {
            grid.delegate?.dataGrid(grid, filterValuesOf: grid.columnOrder[column], at: funnel)
            return
        }
        if isInSortControl(point, column) {
            grid.delegate?.dataGrid(grid, sortBy: grid.columnOrder[column], adding: flags.contains(.option))
            return
        }
        // Double-clicking the header acts as its sort control does (the first click has selected the column, the native rule).
        if event.clickCount == 2, flags.isDisjoint(with: [.shift, .command]) {
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
            let x = convert(event.locationInWindow, from: nil).x + scrolled
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
            toolTip = funnel(at: point, column) != nil ? "Filter by \(info.name)'s values"
                : isInSortControl(point, column) ? "Sort by \(info.name); ⌥-click to add it to the sort"
                : "Select the column; drag to move it; double-click to sort by it\n" + info.details
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
        guard let column = column(at: convert(event.locationInWindow, from: nil)), grid.takeKeyboard() else { return nil }
        if !grid.selection.containsColumn(column) { grid.selection.selectColumn(column) }
        return grid.delegate?.dataGrid(grid, menuFor: .column(grid.columnOrder[column]))
    }
}
