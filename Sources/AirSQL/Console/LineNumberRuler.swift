import AppKit

/// The editor's line numbers (plan §2.6, mockup's gutter): grey, right-aligned, the caret's line darker and an error's
/// line in red. Draws only the lines on screen.
final class LineNumberRuler: NSRulerView {
    private weak var editor: SQLEditorView?
    /// The line (from 1) an error points to, marked until the text changes.
    var errorLine: Int? { didSet { needsDisplay = true } }

    init(editor: SQLEditorView) {
        self.editor = editor
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = editor
        ruleThickness = 32
        // Its edge line stays in its own frame: since macOS 14 views draw outside their bounds unless they clip, and the
        // line crossed the find bar above the editor.
        if #available(macOS 14, *) { clipsToBounds = true }
        setAccessibilityElement(false)
        toolTip = "Shows line numbers; click a triangle to fold or open what starts on that line"
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSView.boundsDidChangeNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSTextView.didChangeSelectionNotification,
                                               object: editor)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    /// As wide as the largest line number needs (after a change of the text or its size).
    func fitWidth() {
        guard let editor else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, editor.fontSize - 2), weight: .regular)
        let lines = editor.string.utf16.reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
        let width = max(32, ceil(("\(lines)" as NSString).size(withAttributes: [.font: font]).width) + 18)
        if abs(width - ruleThickness) > 0.5 { ruleThickness = width }
        needsDisplay = true
    }

    @objc private func changed(_ notification: Notification) {
        if notification.name == NSView.boundsDidChangeNotification,
           (notification.object as? NSView) !== scrollView?.contentView { return }
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        NSColor.content.setFill()
        bounds.fill()
        let text = editor.string as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, editor.fontSize - 2), weight: .regular)
        let visible = editor.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let firstChar = layout.characterIndexForGlyph(at: glyphs.location)
        var line = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: firstChar), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            line += 1
        }
        // The loop above counts the lines before the first visible one, plus one when firstChar starts a line.
        if firstChar > 0, text.character(at: firstChar - 1) != 0x0A { line -= 1 }
        let caretLine = editor.selectedRange().location
        let offset = convert(NSPoint.zero, from: editor).y + editor.textContainerInset.height
        var index = firstChar
        while index <= text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: min(index, max(0, text.length - 1)))
            var fragment = text.length == 0 ? NSRect(x: 0, y: 0, width: 0, height: layout.defaultLineHeight(for: editor.font!))
                : layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if index == text.length, text.length > 0 {
                // The empty last line after a final line break.
                guard text.character(at: text.length - 1) == 0x0A else { break }
                fragment = layout.extraLineFragmentRect
            }
            let y = fragment.minY + offset
            if y > rect.maxY { break }
            let isCaret = NSLocationInRange(caretLine, lineRange) || (caretLine == text.length && index == text.length)
            let color: NSColor = line == errorLine ? .statusBad : isCaret ? .secondaryLabelColor : .tertiaryLabelColor
            let label = "\(line)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - 10 - size.width, y: y + (fragment.height - size.height) / 2),
                       withAttributes: attributes)
            drawFoldTriangle(lineRange, y: y, height: fragment.height, font: font)
            line += 1
            if NSMaxRange(lineRange) <= index || (index == text.length) { break }
            index = NSMaxRange(lineRange)
            // The lines a fold hides have no place here, but they keep their numbers.
            if let fold = editor.folds.first(where: { $0.lowerBound < index && index <= $0.upperBound }) {
                let hidden = text.substring(with: NSRange(location: index, length: fold.upperBound - index))
                line += hidden.utf16.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } + 1
                index = NSMaxRange(text.lineRange(for: NSRange(location: fold.upperBound, length: 0)))
            }
        }
    }

    /// ▾ on a line where something can fold, ▸ on one that's folded, in the margin right of the numbers.
    private func drawFoldTriangle(_ lineRange: NSRange, y: CGFloat, height: CGFloat, font: NSFont) {
        guard let editor else { return }
        let folded = editor.folds.contains { NSLocationInRange($0.lowerBound, lineRange) }
        guard folded || editor.foldRegion(startingIn: lineRange) != nil else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.tertiaryLabelColor]
        let mark = (folded ? "▸" : "▾") as NSString
        let size = mark.size(withAttributes: attributes)
        mark.draw(at: NSPoint(x: ruleThickness - 9, y: y + (height - size.height) / 2), withAttributes: attributes)
    }

    /// A click on the triangles' margin folds or opens that line.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let editor, point.x >= ruleThickness - 10 else { return super.mouseDown(with: event) }
        let place = editor.characterIndexForInsertion(at: NSPoint(x: 0, y: editor.convert(event.locationInWindow, from: nil).y))
        editor.toggleFold(lineRange: (editor.string as NSString).lineRange(for: NSRange(location: place, length: 0)))
    }
}
