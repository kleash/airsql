import AirSQLCore
import AppKit

/// Code folding. The text stays whole, so Run, Copy, Find and Save see all of it: the layout manager is only told to
/// draw nothing for a fold's characters. A cursor that lands in a fold, or an edit touching it, opens it.
extension SQLEditorView: NSLayoutManagerDelegate, NSTextStorageDelegate {
    private func isFolded(_ place: Int) -> Bool { folds.contains { $0.contains(place) } }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>, font: NSFont,
                       forGlyphRange range: NSRange) -> Int {
        guard !folds.isEmpty else { return 0 }
        var hidden = Array(UnsafeBufferPointer(start: properties, count: range.length))
        for index in hidden.indices where isFolded(characterIndexes[index]) { hidden[index] = .null }
        layoutManager.setGlyphs(glyphs, properties: hidden, characterIndexes: characterIndexes, font: font, forGlyphRange: range)
        return range.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt place: Int) -> NSLayoutManager.ControlCharacterAction {
        isFolded(place) ? .zeroAdvancement : action
    }

    /// Keeps the folds on their text through every edit, however it's made; those it touches open.
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !folds.isEmpty else { return }
        let before = range.location..<(NSMaxRange(range) - delta)
        let count = folds.count
        folds = folds.compactMap { fold in
            if fold.upperBound <= before.lowerBound { return fold }
            if fold.lowerBound >= before.upperBound { return (fold.lowerBound + delta)..<(fold.upperBound + delta) }
            return nil
        }
        if folds.count != count { DispatchQueue.main.async { [weak self] in self?.refreshFolds() } }
    }

    /// Lays the text out again after folds changed.
    private func refreshFolds() {
        guard let layout = layoutManager else { return }
        let all = NSRange(location: 0, length: (string as NSString).length)
        layout.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
        layout.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    private func setFolds(_ new: [Range<Int>]) {
        folds = new
        refreshFolds()
    }

    func open(_ fold: Range<Int>) { setFolds(folds.filter { $0 != fold }) }

    /// Opens any fold an end of the selection landed inside.
    func openFoldsAtSelection() {
        let selection = selectedRange()
        let inside = { (fold: Range<Int>) in
            (fold.lowerBound < selection.location && selection.location < fold.upperBound)
                || (fold.lowerBound < NSMaxRange(selection) && NSMaxRange(selection) < fold.upperBound)
        }
        if folds.contains(where: inside) { setFolds(folds.filter { !inside($0) }) }
    }

    /// The regions of the text, as of its last change. Past `longText`, none: folding stays out of its way.
    var foldRegions: [Range<Int>] {
        guard (string as NSString).length <= Self.longText else { return [] }
        if let cachedFoldRegions { return cachedFoldRegions }
        let found = SQLFolding.regions(in: string, noBackslashEscapes: noBackslashEscapes)
        cachedFoldRegions = found
        return found
    }

    /// The region whose first line is the one `lineRange` covers, the longest there.
    func foldRegion(startingIn lineRange: NSRange) -> Range<Int>? {
        foldRegions.first { lineRange.location <= $0.lowerBound && $0.lowerBound < max(NSMaxRange(lineRange), lineRange.location + 1) }
    }

    /// The gutter's triangle: folds or opens the region of that line.
    func toggleFold(lineRange: NSRange) {
        if let open = folds.first(where: { NSLocationInRange($0.lowerBound, lineRange) }) { return self.open(open) }
        if let region = foldRegion(startingIn: lineRange) { fold(region) }
    }

    /// Folds `region`, moving a cursor inside it out to the line it stays on.
    private func fold(_ region: Range<Int>) {
        setFolds(folds.filter { !region.overlaps($0) } + [region])
        if region.contains(selectedRange().location) { setSelectedRange(NSRange(location: region.lowerBound, length: 0)) }
    }

    /// Fold: the selection, or the innermost region at the cursor that isn't folded yet.
    @objc func foldHere(_ sender: Any?) {
        if selectedRange().length > 0, let selection = Range(selectedRange()) { return fold(selection) }
        let caret = selectedRange().location, text = string as NSString
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        let candidates = foldRegions.filter { !folds.contains($0) && (NSLocationInRange($0.lowerBound, line) || $0.contains(caret)) }
        guard let region = candidates.min(by: { $0.count < $1.count }) else { return NSSound.beep() }
        fold(region)
    }

    @objc func unfoldHere(_ sender: Any?) {
        let text = string as NSString
        let line = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let here = folds.filter { NSLocationInRange($0.lowerBound, line) || NSLocationInRange($0.upperBound, line) }
        guard !here.isEmpty else { return NSSound.beep() }
        setFolds(folds.filter { !here.contains($0) })
    }

    /// Fold All: the outermost regions.
    @objc func foldAll(_ sender: Any?) {
        var outer: [Range<Int>] = []
        for region in foldRegions where !(outer.last?.overlaps(region) ?? false) { outer.append(region) }
        guard !outer.isEmpty else { return NSSound.beep() }
        setFolds(outer)
        if isFolded(selectedRange().location) { setSelectedRange(NSRange(location: outer.first { $0.contains(selectedRange().location) }?.lowerBound ?? 0, length: 0)) }
    }

    @objc func unfoldAll(_ sender: Any?) { setFolds([]) }

    /// Where a fold's "…" is drawn, at the end of its first line.
    func foldMark(_ fold: Range<Int>) -> NSRect {
        guard let layout = layoutManager, fold.lowerBound > 0, fold.lowerBound <= (string as NSString).length else { return .zero }
        let glyph = layout.glyphIndexForCharacter(at: fold.lowerBound - 1)
        let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let origin = textContainerOrigin
        return NSRect(x: used.maxX + origin.x + 4, y: used.minY + origin.y, width: 22, height: used.height)
    }

    func drawFoldMarks(in dirty: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        for fold in folds {
            let mark = foldMark(fold)
            guard mark.intersects(dirty) else { continue }
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: mark.insetBy(dx: 0, dy: 1), xRadius: 3, yRadius: 3).fill()
            let size = ("…" as NSString).size(withAttributes: attributes)
            ("…" as NSString).draw(at: NSPoint(x: mark.midX - size.width / 2, y: mark.midY - size.height / 2), withAttributes: attributes)
        }
    }
}
