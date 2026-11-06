import AirSQLCore
import AppKit

/// What the editor marks around the cursor: a band on its line, a shade on its statement when the text has several,
/// the name it's on wherever else it appears, and the line and column in the corner.
extension SQLEditorView {
    /// Past `longText`, the shade and the marks stay off, so moving the cursor never waits for them.
    var marksTheText: Bool { (string as NSString).length <= Self.longText }

    /// The band of the lines `range` lies on, across the whole editor.
    private func band(_ range: NSRange) -> NSRect {
        guard let layout = layoutManager, let container = textContainer else { return .zero }
        let text = string as NSString
        var rect: NSRect
        if range.location >= text.length, text.length == 0 || text.character(at: text.length - 1) == 0x0A {
            layout.ensureLayout(for: container)  // the empty last line has no glyphs of its own
            rect = layout.extraLineFragmentRect
        } else {
            rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: text.lineRange(for: range), actualCharacterRange: nil),
                                       in: container)
        }
        rect.origin.y += textContainerOrigin.y
        rect.origin.x = 0
        rect.size.width = bounds.width
        return rect
    }

    var caretBand: NSRect { selectedRange().length == 0 ? band(NSRange(location: selectedRange().location, length: 0)) : .zero }

    /// The statement at the cursor, when there's another to tell it from.
    var markedStatement: SQLStatement? {
        guard marksTheText, statements.count > 1 else { return nil }
        return SQLSplitter.statement(at: selectedRange().location, in: string, noBackslashEscapes: noBackslashEscapes, of: statements)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let dirty = rect.intersection(bounds)
        if let statement = shadedStatement, let layout = layoutManager, let container = textContainer {
            // Only the part on screen: a long statement shouldn't be laid out to shade it.
            let glyphs = layout.glyphRange(forBoundingRect: visibleRect, in: container)
            let visible = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let shown = NSIntersectionRange(visible, NSRange(statement))
            if shown.length > 0 {
                NSColor.accent.withAlphaComponent(0.05).setFill()
                band(shown).intersection(dirty).fill()
            }
        }
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        caretBand.intersection(dirty).fill(using: .sourceOver)
    }

    /// Redraws what the moved cursor changes.
    func updateCaretMarks() {
        let statement = markedStatement?.range
        if statement != shadedStatement {
            shadedStatement = statement
            setNeedsDisplay(visibleRect, avoidAdditionalLayout: true)
        } else {
            setNeedsDisplay(shownCaretBand, avoidAdditionalLayout: true)
            setNeedsDisplay(caretBand, avoidAdditionalLayout: true)
        }
        shownCaretBand = caretBand
        updatePosition()
    }

    /// Writes "Ln 3, Col 14" and what's selected in the corner.
    @objc func updatePosition() {
        let text = string as NSString, selection = selectedRange()
        guard selection.location <= text.length else { return }
        let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let line = text.substring(to: lineStart).utf16.reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
        let column = text.substring(with: NSRange(location: lineStart, length: selection.location - lineStart)).count + 1
        var shown = "Ln \(line.formatted()), Col \(column.formatted())"
        if selection.length > 0 { shown += " · \(text.substring(with: selection).count.formatted()) selected" }
        positionLabel.stringValue = shown
        guard let scroll = enclosingScrollView else { return }
        positionLabel.sizeToFit()
        let size = positionLabel.frame.size
        // Clear of both scrollers wherever there can be one: they come and go after this runs.
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: scroll.scrollerStyle)
        let gap = 2 + (scroll.hasHorizontalScroller ? scroller : 0), side = 4 + (scroll.hasVerticalScroller ? scroller : 0)
        positionLabel.setFrameOrigin(NSPoint(x: scroll.bounds.maxX - size.width - side, y: scroll.isFlipped ? scroll.bounds.maxY - size.height - gap : gap))
    }

    // MARK: The name at the cursor

    /// Every other use of the name at the cursor or selected, in the text. Keywords and short-lived text don't count.
    func markSameNames(_ add: (NSRange) -> Void) {
        guard marksTheText, tokens.last.map({ $0.range.upperBound <= (string as NSString).length }) ?? false else { return }
        let text = string as NSString, selection = selectedRange()
        guard let token = tokens.first(where: { ($0.kind == .word || $0.kind == .quotedName || $0.kind == .variable)
            && $0.range.lowerBound <= selection.location && NSMaxRange(selection) <= $0.range.upperBound }) else { return }
        // A selection marks only when it is the whole name.
        if selection.length > 0, NSRange(token.range) != selection { return }
        func name(_ token: SQLToken) -> String { SQLQuote.unquoted(text.substring(with: NSRange(token.range))).lowercased() }
        let wanted = name(token)
        guard token.kind != .word || !SQLWords.reserved.contains(wanted.uppercased()) else { return }
        let length = wanted.utf16.count  // with its backticks a name is two longer: most tokens go without reading their text
        let same = tokens.filter { [.word, .quotedName, .variable].contains($0.kind) && abs($0.range.count - length) <= 2 && name($0) == wanted }
        guard same.count > 1 else { return }
        same.prefix(Self.usageLimit).forEach { add(NSRange($0.range)) }
    }

    static let usageLimit = 1_000
}
