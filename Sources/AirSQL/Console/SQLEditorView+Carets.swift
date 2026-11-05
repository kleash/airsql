import AirSQLCore
import AppKit

/// Several carets. The text view keeps the main one; `extraCarets` holds the others, each a place or a selection. Any
/// edit or move runs the text view's own command at each caret in turn, last in the text first, so what it does before
/// a caret doesn't shift the ones still to come. Any selection made another way (a click, Find, Undo) ends them.
extension SQLEditorView {
    /// Runs `command` at every caret; it reads and leaves the selection as the text view's commands do.
    func atEveryCaret(_ command: () -> Void) {
        let main = selectedRange()
        let all = ([main] + extraCarets).sorted { $0.location > $1.location }
        applyingCarets = true
        caretsChangedText = false
        var done: [NSRange] = []
        for caret in all {
            let before = (string as NSString).length
            setSelectedRange(caret)
            command()
            let delta = (string as NSString).length - before
            done = done.map { NSRange(location: $0.location + delta, length: $0.length) }
            done.append(selectedRange())
        }
        applyingCarets = false
        if caretsChangedText { didChangeText() }
        setCarets(done)
    }

    /// Makes `ranges` the carets: overlapping ones become one, the first in the text is the main one.
    func setCarets(_ ranges: [NSRange]) {
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location < NSMaxRange(last) || range.location == last.location {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        applyingCarets = true
        setSelectedRange(merged.first ?? NSRange(location: 0, length: 0))
        applyingCarets = false
        extraCarets = Array(merged.dropFirst())
        updateCaretMarks()
        onSelectionChange?()
    }

    /// Back to the main caret alone.
    func dropExtraCarets() { extraCarets = [] }

    /// Shows the extra selections, which `draw` doesn't: the carets are drawn there.
    func markExtraSelections(old: [NSRange]) {
        guard let layout = layoutManager else { return }
        let length = (string as NSString).length
        // By now the text may have moved under them.
        if old.contains(where: { $0.length > 0 }) {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        }
        for range in extraCarets where NSMaxRange(range) <= length && range.length > 0 {
            layout.addTemporaryAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor, forCharacterRange: range)
        }
        setNeedsDisplay(visibleRect, avoidAdditionalLayout: true)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawFoldMarks(in: dirtyRect.intersection(bounds))
        guard !extraCarets.isEmpty else { return }
        insertionPointColor.setFill()
        for caret in extraCarets where caret.length == 0 { caretRect(caret.location).intersection(dirtyRect).intersection(bounds).fill() }
    }

    /// The upright line of a caret before the character at `place`.
    private func caretRect(_ place: Int) -> NSRect {
        guard let layout = layoutManager else { return .zero }
        let text = string as NSString
        var line: NSRect, x: CGFloat
        if place >= text.length {
            line = layout.extraLineFragmentRect
            x = line.minX
            if text.length > 0, text.character(at: text.length - 1) != 0x0A {
                let glyph = layout.glyphIndexForCharacter(at: text.length - 1)
                line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                x = line.minX + layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).width
            }
        } else {
            let glyph = layout.glyphIndexForCharacter(at: place)
            line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            x = line.minX + layout.location(forGlyphAt: glyph).x
        }
        let origin = textContainerOrigin
        return NSRect(x: x + origin.x, y: line.minY + origin.y, width: 1, height: line.height)
    }

    // MARK: Commands

    /// The selected text, or the word at the cursor selected first.
    private var searchedText: String? {
        var selection = selectedRange()
        if selection.length == 0 {
            selection = selectionRange(forProposedRange: selection, granularity: .selectByWord)
            guard selection.length > 0 else { return nil }
            setSelectedRange(selection)
        }
        return (string as NSString).substring(with: selection)
    }

    /// Adds a caret at the next place the selection's text appears, going round to the top.
    @objc func selectNextOccurrence(_ sender: Any?) {
        let wasEmpty = selectedRange().length == 0
        guard let wanted = searchedText else { return NSSound.beep() }
        if wasEmpty { return }  // the first press selects the word
        let text = string as NSString
        let taken = [selectedRange()] + extraCarets
        let from = taken.map(NSMaxRange).max() ?? 0
        let after = text.range(of: wanted, options: .caseInsensitive, range: NSRange(location: from, length: text.length - from))
        var found = after
        if found.location == NSNotFound {
            found = text.range(of: wanted, options: .caseInsensitive, range: NSRange(location: 0, length: taken.map(\.location).min() ?? 0))
        }
        guard found.location != NSNotFound else { return NSSound.beep() }
        setCarets(taken + [found])
        scrollRangeToVisible(found)
    }

    /// A caret on every place the selection's text appears.
    @objc func selectAllOccurrences(_ sender: Any?) {
        guard let wanted = searchedText else { return NSSound.beep() }
        let text = string as NSString
        var found: [NSRange] = [], from = 0
        while from < text.length {
            let range = text.range(of: wanted, options: .caseInsensitive, range: NSRange(location: from, length: text.length - from))
            guard range.location != NSNotFound else { break }
            found.append(range)
            from = NSMaxRange(range)
        }
        setCarets(found)
    }

    /// A caret at the end of each selected line.
    @objc func caretPerLine(_ sender: Any?) {
        let text = string as NSString, lines = selectedLines
        var ends: [NSRange] = []
        text.enumerateSubstrings(in: lines, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            ends.append(NSRange(location: NSMaxRange(line), length: 0))
        }
        guard ends.count > 1 else { return NSSound.beep() }
        setCarets(ends)
    }

    @objc func addCaretAbove(_ sender: Any?) { addCaret(lines: -1) }
    @objc func addCaretBelow(_ sender: Any?) { addCaret(lines: 1) }

    /// A caret on the next line up or down from the carets, at the same column (or that line's end).
    private func addCaret(lines step: Int) {
        let text = string as NSString
        let all = [selectedRange()] + extraCarets
        guard let edge = step < 0 ? all.min(by: { $0.location < $1.location }) : all.max(by: { $0.location < $1.location }) else { return }
        let line = text.lineRange(for: NSRange(location: edge.location, length: 0))
        let column = edge.location - line.location
        guard step < 0 ? line.location > 0 : NSMaxRange(line) < text.length || (text.length > 0 && text.character(at: text.length - 1) == 0x0A && NSMaxRange(line) == text.length && line.length > 0)
        else { return NSSound.beep() }
        let target = text.lineRange(for: NSRange(location: step < 0 ? line.location - 1 : NSMaxRange(line), length: 0))
        let body = text.substring(with: target).trimmingCharacters(in: .newlines)
        setCarets(all + [NSRange(location: target.location + min(column, (body as NSString).length), length: 0)])
    }

    /// Column Selection Mode: a drag selects a block, and ⇧↑ and ⇧↓ add a caret at the same column.
    @objc func toggleColumnSelection(_ sender: Any?) { columnSelection.toggle() }

    /// ⌥⇧click adds a caret; in Column Selection Mode a drag is the text view's ⌥-drag, which selects a block.
    override func mouseDown(with event: NSEvent) {
        completionPopup?.close()
        let point = convert(event.locationInWindow, from: nil)
        if let fold = folds.first(where: { foldMark($0).contains(point) }) { return open(fold) }
        if event.modifierFlags.isSuperset(of: [.option, .shift]) {
            let place = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            return setCarets([selectedRange()] + extraCarets + [NSRange(location: place, length: 0)])
        }
        guard columnSelection, let block = NSEvent.mouseEvent(with: .leftMouseDown, location: event.locationInWindow,
                                                              modifierFlags: event.modifierFlags.union(.option), timestamp: event.timestamp,
                                                              windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
                                                              clickCount: event.clickCount, pressure: event.pressure)
        else { return super.mouseDown(with: event) }
        super.mouseDown(with: block)
    }
}
