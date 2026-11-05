import AirSQLCore
import AppKit

/// Edit ▸ Lines and the commands on the selection or the word at the cursor. Each is one change that Undo takes back.
extension SQLEditorView {
    @objc func duplicateLine(_ sender: Any?) {
        let lines = selectedLines, selection = selectedRange()
        let block = (string as NSString).substring(with: lines)
        let copy = block.hasSuffix("\n") ? block : "\n" + block
        let shift = (copy as NSString).length
        replace(NSRange(location: NSMaxRange(lines), length: 0), with: copy,
                select: NSRange(location: selection.location + shift, length: selection.length))
    }

    @objc func deleteLine(_ sender: Any?) {
        var lines = selectedLines
        let text = string as NSString
        // The last line has no line break of its own: the one before it goes.
        if NSMaxRange(lines) == text.length, lines.location > 0, text.character(at: text.length - 1) != 0x0A {
            lines = NSRange(location: lines.location - 1, length: lines.length + 1)
        }
        let start = min(lines.location, text.length - lines.length)
        replace(lines, with: "", select: NSRange(location: start, length: 0))
    }

    @objc func moveLineUp(_ sender: Any?) {
        let lines = selectedLines
        guard lines.location > 0 else { return }
        let before = (string as NSString).lineRange(for: NSRange(location: lines.location - 1, length: 0))
        swapLines(before, lines, moved: lines)
    }

    @objc func moveLineDown(_ sender: Any?) {
        let lines = selectedLines
        guard NSMaxRange(lines) < (string as NSString).length else { return }
        let after = (string as NSString).lineRange(for: NSRange(location: NSMaxRange(lines), length: 0))
        swapLines(lines, after, moved: lines)
    }

    /// Swaps two neighbouring runs of lines, the selection going with `moved`. The text's last line has no break, so the
    /// break moves to the line that stops being last.
    private func swapLines(_ first: NSRange, _ second: NSRange, moved: NSRange) {
        let text = string as NSString, selection = selectedRange()
        var top = text.substring(with: second), bottom = text.substring(with: first)
        if !top.hasSuffix("\n") {
            top += "\n"
            bottom.removeLast()
        }
        let start = moved == first ? first.location + (top as NSString).length : first.location
        replace(NSUnionRange(first, second), with: top + bottom,
                select: NSRange(location: start + selection.location - moved.location, length: selection.length))
    }

    @objc func joinLines(_ sender: Any?) {
        let text = string as NSString
        var lines = selectedLines
        if !text.substring(with: lines).dropLast().contains("\n"), NSMaxRange(lines) < text.length {
            lines = NSUnionRange(lines, text.lineRange(for: NSRange(location: NSMaxRange(lines), length: 0)))
        }
        // The last line's own break stays, with whatever comes after the lines.
        if text.substring(with: lines).hasSuffix("\n") { lines.length -= 1 }
        let joined = SQLEditing.joined(string, lines.location..<NSMaxRange(lines), noBackslashEscapes: noBackslashEscapes)
        guard joined != text.substring(with: lines) else { return }
        replace(lines, with: joined, select: NSRange(location: lines.location + (joined as NSString).length, length: 0))
    }

    @objc func sortLines(_ sender: Any?) {
        changeLines { $0.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    }

    @objc func reverseLines(_ sender: Any?) { changeLines { $0.reversed() } }

    /// The selection, or the word at the cursor.
    private var selectionOrWord: NSRange {
        selectedRange().length > 0 ? selectedRange() : selectionRange(forProposedRange: selectedRange(), granularity: .selectByWord)
    }

    @objc func toggleCase(_ sender: Any?) {
        let range = selectionOrWord, text = (string as NSString).substring(with: range)
        let changed = text == text.uppercased() ? text.lowercased() : text.uppercased()
        guard changed != text else { return }
        replace(range, with: changed, select: NSRange(location: range.location, length: (changed as NSString).length))
    }

    /// Wraps the selection (or the line's text) in /* */, or unwraps the selection or the comment at the cursor.
    @objc func toggleBlockComment(_ sender: Any?) {
        let selection = selectedRange(), text = string as NSString
        let caret = selection.location
        let comment = tokens.first { $0.kind == .comment && text.substring(with: NSRange($0.range)).hasPrefix("/*") && $0.isClosed
            && $0.range.lowerBound <= caret && NSMaxRange(selection) <= $0.range.upperBound }
        if let comment {
            var inner = text.substring(with: NSRange(comment.range)).dropFirst(2).dropLast(2)
            if inner.hasPrefix(" ") { inner = inner.dropFirst() }
            if inner.hasSuffix(" ") { inner = inner.dropLast() }
            let plain = String(inner)
            return replace(NSRange(comment.range), with: plain,
                           select: NSRange(location: comment.range.lowerBound, length: (plain as NSString).length))
        }
        var range = selection
        if range.length == 0 {
            let line = text.lineRange(for: selection), body = text.substring(with: line)
            let lead = body.prefix { $0 == " " || $0 == "\t" }.utf16.count
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            range = NSRange(location: line.location + lead, length: (trimmed as NSString).length)
        }
        let wrapped = "/* " + text.substring(with: range) + " */"
        replace(range, with: wrapped, select: NSRange(location: range.location, length: (wrapped as NSString).length))
    }

    /// Closes the statement at the cursor and starts a line after it.
    @objc func completeStatement(_ sender: Any?) {
        guard let done = SQLEditing.completed(string, caret: selectedRange().location, noBackslashEscapes: noBackslashEscapes) else { return }
        replace(NSRange(done.range), with: done.text)
        replace(NSRange(location: done.caret, length: 0), with: "\n", select: NSRange(location: done.caret + 1, length: 0))
    }

    /// ⌘C with nothing selected copies the line.
    override func copy(_ sender: Any?) {
        guard selectedRange().length == 0 else { return super.copy(sender) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((string as NSString).substring(with: selectedLines), forType: .string)
    }
}
