import AirSQLCore
import AppKit

/// The steps' boxes or bars, laid out once; a box's tooltip holds what it can't show.
@MainActor
class PlanDrawing: NSView {
    struct Box {
        var frame: NSRect
        var node: PlanNode
        /// The box above it (the diagram's lines).
        var parent: NSRect?
    }

    fileprivate(set) var boxes: [Box] = []
    override var isFlipped: Bool { true }

    fileprivate func finish(size: NSSize) {
        setFrameSize(size)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("console.planDiagram")
        setAccessibilityLabel("The plan's steps")
        for box in boxes { addToolTip(box.frame, owner: Self.tip(box.node) as NSString, userData: nil) }
    }

    fileprivate static func figures(_ node: PlanNode) -> String {
        var parts: [String] = []
        if let time = node.time { parts.append(String(format: "%.2f ms", time)) }
        if let rows = node.actualRows ?? node.rows { parts.append("\(rows.formatted(.number.precision(.fractionLength(0...1)))) rows") }
        if node.time == nil, let cost = node.cost { parts.append("cost \(cost.formatted(.number.precision(.fractionLength(0...2))))") }
        return parts.joined(separator: " · ")
    }

    private static func tip(_ node: PlanNode) -> String { node.operation + (figures(node).isEmpty ? "" : "\n" + figures(node)) }

    fileprivate func draw(_ text: String, in rect: NSRect, size: CGFloat = 11, color: NSColor = .labelColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: style])
            .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// The plan as a tree of boxes, the root at the top.
final class PlanDiagramView: PlanDrawing {
    private static let box = NSSize(width: 220, height: 54), gap = NSSize(width: 20, height: 34), margin: CGFloat = 16

    init(nodes: [PlanNode]) {
        super.init(frame: .zero)
        var next = Self.margin, deepest: CGFloat = 0
        /// Places `node` over its children, and returns where.
        func place(_ node: PlanNode, depth: Int) -> Int {
            let y = Self.margin + CGFloat(depth) * (Self.box.height + Self.gap.height)
            deepest = max(deepest, y + Self.box.height)
            let children = node.children.map { place($0, depth: depth + 1) }
            let x: CGFloat
            if let first = children.first, let last = children.last {
                x = (boxes[first].frame.minX + boxes[last].frame.minX) / 2
            } else {
                x = next
                next += Self.box.width + Self.gap.width
            }
            let frame = NSRect(origin: NSPoint(x: x, y: y), size: Self.box)
            boxes.append(Box(frame: frame, node: node))
            for child in children { boxes[child].parent = frame }
            return boxes.count - 1
        }
        for node in nodes { _ = place(node, depth: 0) }
        finish(size: NSSize(width: next + Self.margin, height: deepest + Self.margin))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.saveGraphicsState()
        dirtyRect.intersection(bounds).clip()
        for box in boxes {
            guard let parent = box.parent else { continue }
            let line = NSBezierPath()
            line.move(to: NSPoint(x: parent.midX, y: parent.maxY))
            line.line(to: NSPoint(x: box.frame.midX, y: box.frame.minY))
            NSColor.separatorColor.setStroke()
            line.stroke()
        }
        for box in boxes where box.frame.intersects(dirtyRect) {
            let path = NSBezierPath(roundedRect: box.frame, xRadius: 6, yRadius: 6)
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            (box.node.hot ? NSColor.statusWarning : .separatorColor).setStroke()
            path.lineWidth = box.node.hot ? 2 : 1
            path.stroke()
            let inner = box.frame.insetBy(dx: 8, dy: 6)
            draw(box.node.operation, in: NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: 28))
            draw(Self.figures(box.node), in: NSRect(x: inner.minX, y: inner.maxY - 13, width: inner.width, height: 14), size: 10, color: .secondaryLabelColor)
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

/// The plan as bars, each as wide as its share of its parent: its time, or its cost before it has been analyzed.
final class PlanFlameView: PlanDrawing {
    private static let row: CGFloat = 22, width: CGFloat = 900

    init(nodes: [PlanNode]) {
        super.init(frame: .zero)
        func figure(_ node: PlanNode) -> Double { max(node.time ?? node.cost ?? 0, 0) }
        var deepest: CGFloat = 0
        func place(_ nodes: [PlanNode], x: CGFloat, width: CGFloat, depth: Int) {
            let total = nodes.map(figure).reduce(0, +)
            var left = x
            for node in nodes {
                let share = total > 0 ? figure(node) / total : 1 / Double(nodes.count)
                let part = width * CGFloat(share)
                let frame = NSRect(x: left, y: CGFloat(depth) * Self.row, width: part, height: Self.row - 1)
                deepest = max(deepest, frame.maxY)
                if part >= 1 { boxes.append(Box(frame: frame, node: node)) }
                place(node.children, x: left, width: part, depth: depth + 1)
                left += part
            }
        }
        place(nodes, x: 0, width: Self.width, depth: 0)
        finish(size: NSSize(width: Self.width, height: deepest + 1))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.saveGraphicsState()
        dirtyRect.intersection(bounds).clip()
        for box in boxes where box.frame.intersects(dirtyRect) {
            (box.node.hot ? NSColor.statusWarning.withAlphaComponent(0.55) : NSColor.accent.withAlphaComponent(0.22)).setFill()
            box.frame.insetBy(dx: 0.5, dy: 0).fill()
            if box.frame.width > 40 { draw(box.node.operation, in: box.frame.insetBy(dx: 4, dy: 3)) }
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
