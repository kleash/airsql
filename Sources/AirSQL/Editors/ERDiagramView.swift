import AirSQLCore
import AppKit

/// Draws an `ERDiagram`: each table a box (its name, then its first columns with their keys), in the diagram's columns,
/// and each foreign key a straight line from the child's key column to the parent (R15: no routing). A click selects a
/// table (⌘ or ⇧ adds to the selection), dragging moves the selected boxes, a double-click opens it in the table editor,
/// a right-click opens its menu; the arrow keys move between tables, ⌥ with them moves the boxes.
@MainActor
final class ERDiagramView: NSView, NSViewToolTipOwner {
    struct Box {
        let table: SchemaTable
        var frame: NSRect
        /// The column rows shown.
        let shown: [SchemaColumn]
        /// The columns left out, counted in the last line (none when only names show).
        let more: Int
    }

    private(set) var boxes: [Box] = []
    private var links: [ERDiagram.Link] = []
    /// A table's box for VoiceOver (the canvas is their group; its value is the selected table).
    private var elements: [NSAccessibilityElement] = []
    private var layout = ERLayout(name: "")
    /// Every selected table; `selected` is the one last clicked.
    private(set) var selection = Set<String>()
    var selected: String? {
        get { primary }
        set { select(newValue.map { [$0] } ?? [], primary: newValue) }
    }
    private var primary: String?
    /// Double-click or Return on a table.
    var onOpen: ((String) -> Void)?
    /// Boxes were dragged to new places.
    var onMoved: (() -> Void)?
    /// Tables' names were dropped here, from the tree.
    var onDrop: (([String]) -> Void)?
    /// The menu off the boxes.
    var blankMenu: NSMenu?
    /// Where a drag was last, while one moves boxes.
    private var dragPoint: NSPoint?
    private var dragged = false

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
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Lays out `diagram`: each box where `layout` left it, the others as it arranges them, or under the rest when some
    /// boxes have places already.
    func show(_ diagram: ERDiagram, layout: ERLayout) {
        self.layout = layout
        links = diagram.links
        boxes = arranged(diagram)
        let placed = boxes.compactMap { box in layout.positions[box.table.name].map { (box, $0) } }
        if !placed.isEmpty {
            var x = Self.margin
            let y = placed.map { CGFloat($0.1.y) + $0.0.frame.height }.max()! + Self.boxGap
            for index in boxes.indices {
                if let point = layout.positions[boxes[index].table.name] {
                    boxes[index].frame.origin = NSPoint(x: point.x, y: point.y)
                } else {
                    boxes[index].frame.origin = NSPoint(x: x, y: y)
                    x += boxes[index].frame.width + Self.boxGap
                }
            }
        }
        select(selection.intersection(boxes.map(\.table.name)), primary: primary)
        boxesMoved()
    }

    /// The boxes as `layout.arrangement` puts them: side by side in the diagram's columns, or in rows.
    private func arranged(_ diagram: ERDiagram) -> [Box] {
        var groups = diagram.columns
        if layout.arrangement == .grid {
            let tables = diagram.columns.flatMap { $0 }
            let width = max(Int(Double(tables.count).squareRoot().rounded(.up)), 1)
            groups = stride(from: 0, to: tables.count, by: width).map { Array(tables[$0..<min($0 + width, tables.count)]) }
        }
        var result: [Box] = []
        var across = Self.margin
        for group in groups {
            let row = group.map(box)
            if layout.arrangement == .leftToRight {
                let width = row.map(\.frame.width).max() ?? 0
                var y = Self.margin
                for var box in row {
                    box.frame = NSRect(x: across, y: y, width: width, height: box.frame.height)
                    y = box.frame.maxY + Self.boxGap
                    result.append(box)
                }
                across += width + Self.columnGap
            } else {
                var x = Self.margin
                for var box in row {
                    box.frame.origin = NSPoint(x: x, y: across)
                    x = box.frame.maxX + Self.boxGap
                    result.append(box)
                }
                across += (row.map(\.frame.height).max() ?? 0) + Self.columnGap
            }
        }
        return result
    }

    /// A table's box, sized to its text.
    private func box(_ table: SchemaTable) -> Box {
        let columns: [SchemaColumn]
        switch layout.detail {
        case .allColumns: columns = table.columns
        case .keysOnly: columns = table.columns.filter { !line($0, in: table).hasPrefix("   ") }
        case .namesOnly: columns = []
        }
        let shown = Array(columns.prefix(Self.shownColumns))
        let more = layout.detail == .namesOnly ? 0 : table.columns.count - shown.count
        let lines = [table.name] + shown.map { line($0, in: table) }
        let textWidth = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 80
        let rows = CGFloat(shown.count + (more > 0 ? 1 : 0))
        return Box(table: table, frame: NSRect(x: 0, y: 0, width: min(max(textWidth + 2 * Spacing.unit + 8, 140), 300),
                                               height: Self.headerHeight + rows * Self.rowHeight + Spacing.unit),
                   shown: shown, more: more)
    }

    /// The canvas's size, the tooltips and VoiceOver's boxes, for the boxes where they are now.
    private func boxesMoved() {
        content = NSSize(width: max((boxes.map(\.frame.maxX).max() ?? 0) + Self.margin, 320),
                         height: max((boxes.map(\.frame.maxY).max() ?? 0) + Self.margin, 200))
        fit(enclosingScrollView?.contentView.bounds.size ?? visibleRect.size)
        needsDisplay = true
        // A box may cut a long name or line short: its tooltip and its accessibility element have them whole.
        removeAllToolTips()
        elements = boxes.map { box in
            addToolTip(box.frame, owner: self, userData: nil)
            let element = ERBoxElement()
            element.open = { [weak self] in self?.onOpen?(box.table.name) }
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityHelp("Open the table's structure")
            element.setAccessibilityLabel("Table \(box.table.name), \(box.table.columns.count) columns: "
                                          + box.table.columns.map(\.name).joined(separator: ", "))
            element.setAccessibilityFrameInParentSpace(box.frame)
            element.setAccessibilitySelected(selection.contains(box.table.name))
            return element
        }
    }

    private func select(_ names: Set<String>, primary: String?) {
        selection = names
        self.primary = primary.flatMap { names.contains($0) ? $0 : nil } ?? names.sorted().first
        needsDisplay = true
        setAccessibilityValue(self.primary)
        for (box, element) in zip(boxes, elements) { element.setAccessibilitySelected(names.contains(box.table.name)) }
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// Where every box is now, as a layout keeps it.
    var positions: [String: ERLayout.Point] {
        Dictionary(boxes.map { ($0.table.name, ERLayout.Point(x: $0.frame.minX, y: $0.frame.minY)) }) { first, _ in first }
    }

    override func accessibilityChildren() -> [Any]? { elements }

    /// A box's tooltip: its table's name and column lines, whole.
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        guard let box = boxes.first(where: { $0.frame.contains(point) }) else { return "" }
        return ([box.table.name] + box.shown.map { line($0, in: box.table) } + (box.more > 0 ? ["+ \(box.more) more"] : []))
            .joined(separator: "\n")
    }

    /// The diagram's own size.
    private(set) var content = NSSize(width: 320, height: 200)

    /// As large as the diagram, and at least as large as what the scroll view shows (so it starts at the top left).
    func fit(_ visible: NSSize) {
        setFrameSize(NSSize(width: max(content.width, visible.width), height: max(content.height, visible.height)))
    }

    /// A column's line in its box: key marks, name, type, and its comment when those show.
    func line(_ column: SchemaColumn, in table: SchemaTable) -> String {
        let primary = table.primaryKey?.parts.contains { $0.column == column.name } ?? false
        let foreign = table.foreignKeys.contains { $0.columns.contains(column.name) }
        let comment = layout.showsComments && !column.comment.isEmpty ? "  " + column.comment : ""
        return (primary ? "PK " : foreign ? "FK " : "   ") + column.name + "  " + column.dataType + comment
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.content.setFill()
        dirtyRect.intersection(bounds).fill()
        // Lines first, under the boxes: from the child's key column to the parent's header.
        let frames = Dictionary(boxes.map { ($0.table.name, $0) }) { first, _ in first }
        NSColor.secondaryLabelColor.setStroke()
        for link in links {
            guard let child = frames[link.child], let parent = frames[link.parent] else { continue }
            let (start, end) = ends(link, from: child, to: parent)
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
            NSColor.secondaryLabelColor.setFill()
            for point in [start, end] { NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill() }
        }
        for box in boxes where box.frame.intersects(dirtyRect) { draw(box) }
    }

    /// Where a key's line starts and ends: facing sides, from its column's row; boxes one above the other, top and bottom.
    private func ends(_ link: ERDiagram.Link, from child: Box, to parent: Box) -> (NSPoint, NSPoint) {
        if link.child != link.parent, child.frame.minX < parent.frame.maxX, parent.frame.minX < child.frame.maxX {
            let down = parent.frame.midY > child.frame.midY
            return (NSPoint(x: child.frame.midX, y: down ? child.frame.maxY : child.frame.minY),
                    NSPoint(x: parent.frame.midX, y: down ? parent.frame.minY : parent.frame.maxY))
        }
        let column = child.table.foreignKeys.first { $0.name == link.name }?.columns.first
        let row = column.flatMap { name in child.shown.firstIndex { $0.name == name } }
        let right = parent.frame.midX > child.frame.midX
        return (NSPoint(x: right ? child.frame.maxX : child.frame.minX,
                        y: child.frame.minY + Self.headerHeight + (row.map { CGFloat($0) + 0.5 } ?? -0.5) * Self.rowHeight),
                NSPoint(x: link.child == link.parent ? parent.frame.minX : right ? parent.frame.minX : parent.frame.maxX,
                        y: parent.frame.minY + Self.headerHeight / 2))
    }

    private func draw(_ box: Box) {
        let shape = NSBezierPath(roundedRect: box.frame, xRadius: Radius.card, yRadius: Radius.card)
        NSColor.bar.setFill()
        shape.fill()
        let isSelected = selection.contains(box.table.name)
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
        if box.more > 0 {
            let y = box.frame.minY + Self.headerHeight + CGFloat(box.shown.count) * Self.rowHeight + 2
            text("   + \(box.more) more", at: NSPoint(x: box.frame.minX + inset, y: y),
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
        let name = table(at: point)
        if !event.modifierFlags.isDisjoint(with: [.command, .shift]) {
            guard let name else { return }
            let adding = !selection.contains(name)
            select(adding ? selection.union([name]) : selection.subtracting([name]), primary: adding ? name : primary)
            return
        }
        // A click on one of several selected boxes keeps them, to drag them together.
        if name == nil || !selection.contains(name!) { selected = name } else { select(selection, primary: name) }
        if event.clickCount == 2, let selected { return onOpen?(selected) ?? () }
        dragPoint = name == nil ? nil : point
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = dragPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        move(selection, by: NSPoint(x: point.x - last.x, y: point.y - last.y))
        dragPoint = point
        dragged = true
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        dragPoint = nil
        guard dragged else { return }
        dragged = false
        boxesMoved()
        onMoved?()
    }

    /// Moves boxes, none past the top or left of the canvas.
    private func move(_ names: Set<String>, by offset: NSPoint) {
        for index in boxes.indices where names.contains(boxes[index].table.name) {
            boxes[index].frame.origin = NSPoint(x: max(boxes[index].frame.minX + offset.x, 0), y: max(boxes[index].frame.minY + offset.y, 0))
        }
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let name = table(at: convert(event.locationInWindow, from: nil)) else { return blankMenu }
        if !selection.contains(name) { selected = name }
        return super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let key = event.specialKey else { return super.keyDown(with: event) }
        if key == .carriageReturn || key == .enter, let selected { return onOpen?(selected) ?? () }
        if event.modifierFlags.contains(.option), !selection.isEmpty {
            let step = Self.margin
            let offsets: [NSEvent.SpecialKey: NSPoint] = [.leftArrow: NSPoint(x: -step, y: 0), .rightArrow: NSPoint(x: step, y: 0),
                                                          .upArrow: NSPoint(x: 0, y: -step), .downArrow: NSPoint(x: 0, y: step)]
            guard let offset = offsets[key] else { return super.keyDown(with: event) }
            move(selection, by: offset)
            boxesMoved()
            return onMoved?() ?? ()
        }
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

    // MARK: Tables dragged from the tree

    /// The names on a drag: the tree quotes them.
    private func names(_ info: NSDraggingInfo) -> [String] {
        (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .string) }.map(ERDiagram.tableName(dragged:))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { names(sender).isEmpty ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let names = names(sender)
        guard let onDrop, !names.isEmpty else { return false }
        onDrop(names)
        return true
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

/// A box for VoiceOver: pressing it opens its table, as a double-click does.
private final class ERBoxElement: NSAccessibilityElement {
    var open: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        open?()
        return true
    }
}
