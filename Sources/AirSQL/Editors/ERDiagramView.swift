import AirSQLCore
import AppKit

/// Draws an `ERDiagram`: each table a box (its name, then its first columns with their keys), in the diagram's columns,
/// and each foreign key a straight line from the child's key column to the parent (R15: no routing). A click selects a
/// table, a double-click opens it in the table editor, a right-click opens its menu; the arrow keys move between tables.
@MainActor
final class ERDiagramView: NSView, NSViewToolTipOwner {
    struct Box {
        let table: SchemaTable
        let frame: NSRect
        /// The column rows shown (the rest are counted in the last line).
        let shown: [SchemaColumn]
    }

    private(set) var boxes: [Box] = []
    private var links: [ERDiagram.Link] = []
    /// A table's box for VoiceOver (the canvas is their group; its value is the selected table).
    private var elements: [NSAccessibilityElement] = []
    var selected: String? {
        didSet {
            needsDisplay = true
            setAccessibilityValue(selected)
            for (box, element) in zip(boxes, elements) { element.setAccessibilitySelected(box.table.name == selected) }
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }
    /// Double-click or Return on a table.
    var onOpen: ((String) -> Void)?

    static let rowHeight: CGFloat = 17, headerHeight: CGFloat = 24, columnGap: CGFloat = 72, boxGap: CGFloat = 24, margin: CGFloat = 24
    static let shownColumns = 12
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("ER diagram")
        setAccessibilityIdentifier("erDiagram.canvas")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Lays out `diagram`: every box sized to its text, the columns side by side.
    func show(_ diagram: ERDiagram) {
        links = diagram.links
        boxes = []
        var x = Self.margin, height: CGFloat = 0
        for column in diagram.columns {
            var y = Self.margin, width: CGFloat = 0
            var laid: [(SchemaTable, CGFloat, [SchemaColumn])] = []
            for table in column {
                let shown = Array(table.columns.prefix(Self.shownColumns))
                let rows = CGFloat(shown.count + (table.columns.count > shown.count ? 1 : 0))
                let lines = [table.name] + shown.map { line($0, in: table) }
                let textWidth = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 80
                width = max(width, min(max(textWidth + 2 * Spacing.unit + 8, 140), 300))
                laid.append((table, y, shown))
                y += Self.headerHeight + rows * Self.rowHeight + Spacing.unit + Self.boxGap
            }
            for (table, top, shown) in laid {
                let rows = CGFloat(shown.count + (table.columns.count > shown.count ? 1 : 0))
                boxes.append(Box(table: table, frame: NSRect(x: x, y: top, width: width,
                                                             height: Self.headerHeight + rows * Self.rowHeight + Spacing.unit), shown: shown))
            }
            height = max(height, y)
            x += width + Self.columnGap
        }
        content = NSSize(width: max(x - Self.columnGap + Self.margin, 320), height: max(height, 200))
        fit(visibleRect.size)
        needsDisplay = true
        // A box may cut a long name or line short: its tooltip and its accessibility element have them whole.
        removeAllToolTips()
        elements = boxes.map { box in
            addToolTip(box.frame, owner: self, userData: nil)
            let element = NSAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.group)
            element.setAccessibilityLabel("Table \(box.table.name), \(box.table.columns.count) columns")
            element.setAccessibilityFrameInParentSpace(box.frame)
            element.setAccessibilitySelected(box.table.name == selected)
            return element
        }
    }

    override func accessibilityChildren() -> [Any]? { elements }

    /// A box's tooltip: its table's name and column lines, whole.
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let box = boxes.first(where: { $0.frame.contains(point) }) else { return "" }
        let more = box.table.columns.count - box.shown.count
        return ([box.table.name] + box.shown.map { line($0, in: box.table) } + (more > 0 ? ["+ \(more) more"] : []))
            .joined(separator: "\n")
    }

    /// The diagram's own size.
    private(set) var content = NSSize(width: 320, height: 200)

    /// As large as the diagram, and at least as large as what the scroll view shows (so it starts at the top left).
    func fit(_ visible: NSSize) {
        setFrameSize(NSSize(width: max(content.width, visible.width), height: max(content.height, visible.height)))
    }

    /// A column's line in its box: key marks, name, type.
    func line(_ column: SchemaColumn, in table: SchemaTable) -> String {
        let primary = table.primaryKey?.parts.contains { $0.column == column.name } ?? false
        let foreign = table.foreignKeys.contains { $0.columns.contains(column.name) }
        return (primary ? "PK " : foreign ? "FK " : "   ") + column.name + "  " + column.dataType
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        // Lines first, under the boxes: from the child's key column to the parent's header.
        let frames = Dictionary(boxes.map { ($0.table.name, $0) }) { first, _ in first }
        NSColor.tertiaryLabelColor.setStroke()
        for link in links {
            guard let child = frames[link.child], let parent = frames[link.parent] else { continue }
            let column = child.table.foreignKeys.first { $0.name == link.name }?.columns.first
            let row = column.flatMap { name in child.shown.firstIndex { $0.name == name } }
            let start = NSPoint(x: child.frame.minX, y: child.frame.minY + Self.headerHeight
                                    + (row.map { CGFloat($0) + 0.5 } ?? -0.5) * Self.rowHeight)
            let end = NSPoint(x: link.child == link.parent ? parent.frame.minX : parent.frame.maxX,
                              y: parent.frame.minY + Self.headerHeight / 2)
            let path = NSBezierPath()
            path.lineWidth = 1
            if link.child == link.parent {
                path.move(to: start)
                path.curve(to: end, controlPoint1: NSPoint(x: start.x - 28, y: start.y), controlPoint2: NSPoint(x: end.x - 28, y: end.y))
            } else {
                path.move(to: start)
                path.line(to: end)
            }
            path.stroke()
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6)).fill()
        }
        for box in boxes where box.frame.intersects(dirtyRect) { draw(box) }
    }

    private func draw(_ box: Box) {
        let shape = NSBezierPath(roundedRect: box.frame, xRadius: Radius.card, yRadius: Radius.card)
        NSColor.windowBackgroundColor.setFill()
        shape.fill()
        let isSelected = box.table.name == selected
        (isSelected ? NSColor.accent : NSColor.separatorColor).setStroke()
        shape.lineWidth = isSelected ? 2 : 1
        shape.stroke()
        let header = NSRect(x: box.frame.minX, y: box.frame.minY, width: box.frame.width, height: Self.headerHeight)
        NSColor.accentFill.setFill()
        NSBezierPath(roundedRect: header.insetBy(dx: 1, dy: 1), xRadius: Radius.card - 1, yRadius: Radius.card - 1).fill()
        let inset = Spacing.unit + 2
        text(box.table.name, at: NSPoint(x: box.frame.minX + inset, y: box.frame.minY + 5), width: box.frame.width - 2 * inset,
             font: titleFont, color: .labelColor)
        for (index, column) in box.shown.enumerated() {
            let y = box.frame.minY + Self.headerHeight + CGFloat(index) * Self.rowHeight + 2
            text(line(column, in: box.table), at: NSPoint(x: box.frame.minX + inset, y: y), width: box.frame.width - 2 * inset,
                 font: font, color: .labelColor)
        }
        if box.table.columns.count > box.shown.count {
            let y = box.frame.minY + Self.headerHeight + CGFloat(box.shown.count) * Self.rowHeight + 2
            text("   + \(box.table.columns.count - box.shown.count) more", at: NSPoint(x: box.frame.minX + inset, y: y),
                 width: box.frame.width - 2 * inset, font: font, color: .secondaryLabelColor)
        }
    }

    private func text(_ string: String, at point: NSPoint, width: CGFloat, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (string as NSString).draw(in: NSRect(x: point.x, y: point.y, width: width, height: font.boundingRectForFont.height + 2),
                                  withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    // MARK: Clicks and keys

    func table(at point: NSPoint) -> String? { boxes.first { $0.frame.contains(point) }?.table.name }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        selected = table(at: point)
        if event.clickCount == 2, let selected { onOpen?(selected) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let name = table(at: convert(event.locationInWindow, from: nil)) else { return nil }
        selected = name
        return super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let key = event.specialKey else { return super.keyDown(with: event) }
        if key == .carriageReturn || key == .enter, let selected { return onOpen?(selected) ?? () }
        let current = boxes.first { $0.table.name == selected }?.frame ?? .zero
        let candidates: [Box]
        switch key {
        case .rightArrow: candidates = boxes.filter { $0.frame.minX > current.maxX }
        case .leftArrow: candidates = boxes.filter { $0.frame.maxX < current.minX }
        case .downArrow: candidates = boxes.filter { $0.frame.minX == current.minX && $0.frame.minY > current.maxY }
        case .upArrow: candidates = boxes.filter { $0.frame.minX == current.minX && $0.frame.maxY < current.minY }
        default: return super.keyDown(with: event)
        }
        let center = NSPoint(x: current.midX, y: current.midY)
        guard let next = (selected == nil ? boxes : candidates).min(by: {
            hypot($0.frame.midX - center.x, $0.frame.midY - center.y) < hypot($1.frame.midX - center.x, $1.frame.midY - center.y)
        }) else { return }
        selected = next.table.name
        scrollToVisible(next.frame.insetBy(dx: -Self.margin, dy: -Self.margin))
    }

    /// The diagram as a PNG at twice its size, as it looks now (light or dark).
    func png() -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
