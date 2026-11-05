import AppKit

/// Lines marked to come back to, by where they start; a line's mark goes with it through edits.
extension SQLEditorView {
    @objc func toggleBookmark(_ sender: Any?) {
        let line = (string as NSString).lineRange(for: NSRange(location: selectedRange().location, length: 0)).location
        if let index = bookmarks.firstIndex(of: line) { bookmarks.remove(at: index) } else { bookmarks.append(line) }
        bookmarks.sort()
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    @objc func nextBookmark(_ sender: Any?) {
        let caret = selectedRange().location
        go(toBookmark: bookmarks.first { $0 > caret } ?? bookmarks.first)
    }

    @objc func previousBookmark(_ sender: Any?) {
        let line = (string as NSString).lineRange(for: NSRange(location: selectedRange().location, length: 0)).location
        go(toBookmark: bookmarks.last { $0 < line } ?? bookmarks.last)
    }

    private func go(toBookmark place: Int?) {
        guard let place else { return NSSound.beep() }
        setSelectedRange(NSRange(location: place, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// Text in `before` became text `delta` longer: marks after it move, marks of lines it took away go.
    func moveBookmarks(replacing before: Range<Int>, by delta: Int) {
        bookmarks = bookmarks.compactMap { place in
            if place <= before.lowerBound { return place }
            return place >= before.upperBound ? place + delta : nil
        }
    }
}
