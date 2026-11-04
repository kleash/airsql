import AirSQLCore
import AppKit

/// Completion while typing (plan §2.6): after a letter or a dot the list opens under the cursor with what the schema
/// cache offers there (not inside strings or comments); ⌥⎋ opens it anywhere. While it is open, ↑ and ↓ choose,
/// Return or Tab inserts and Escape closes; typing on narrows it.
extension SQLEditorView {
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        if pairTyped(typed, replacementRange) { return }
        super.insertText(string, replacementRange: replacementRange)
        // One character typed: a letter, digit, _ or a dot opens or narrows the list; anything else closes it.
        if typed.count == 1, let unit = typed.utf16.first, unit == 0x2E || SQLLexer.isNameChar(unit) {
            updateCompletion(force: false)
        } else {
            completionPopup?.close()
        }
    }

    /// What a typed opener closes with.
    private static let pairs: [String: String] = ["(": ")", "[": "]", "'": "'", "\"": "\"", "`": "`"]

    /// A typed opener brings its closer, or wraps the selection; a typed closer steps over the one the opener brought.
    /// Not inside strings or comments, and not a quote against a word, where the quote is more likely the closing one.
    private func pairTyped(_ typed: String, _ range: NSRange) -> Bool {
        let selection = selectedRange(), text = self.string as NSString
        guard typed.count == 1, range == selection || range.location == NSNotFound else { return false }
        func character(_ index: Int) -> String {
            index >= 0 && index < text.length ? text.substring(with: NSRange(location: index, length: 1)) : ""
        }
        let isWord = { (text: String) in text.first?.isLetter == true || text.first?.isNumber == true }
        let next = character(selection.location), inText = inTextToken(selection.location)
        if selection.length == 0, typed == next, Self.pairs.values.contains(typed), !inText || Self.pairs[typed] == typed {
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            completionPopup?.close()
            return true
        }
        guard let close = Self.pairs[typed], !inText else { return false }
        if selection.length == 0, isWord(next) || (close == typed && isWord(character(selection.location - 1))) { return false }
        let inside = text.substring(with: selection)
        guard shouldChangeText(in: selection, replacementString: typed + inside + close) else { return false }
        textStorage?.replaceCharacters(in: selection, with: typed + inside + close)
        didChangeText()
        setSelectedRange(NSRange(location: selection.location + 1, length: (inside as NSString).length))
        completionPopup?.close()
        return true
    }

    /// The place is inside a string, name or comment, or one the text leaves open.
    private func inTextToken(_ place: Int) -> Bool {
        tokens.contains { [.string, .quotedName, .comment, .hint].contains($0.kind) && $0.range.lowerBound < place
            && (place < $0.range.upperBound || !$0.isClosed) }
    }

    override func deleteBackward(_ sender: Any?) {
        let caret = selectedRange(), text = self.string as NSString
        // Between an empty pair, Delete takes both.
        if caret.length == 0, caret.location > 0, caret.location < text.length,
           Self.pairs[text.substring(with: NSRange(location: caret.location - 1, length: 1))]
               == text.substring(with: NSRange(location: caret.location, length: 1)) {
            setSelectedRange(NSRange(location: caret.location - 1, length: 2))
        }
        super.deleteBackward(sender)
        if completionPopup?.isShown == true { updateCompletion(force: false) }
    }

    override func complete(_ sender: Any?) { updateCompletion(force: true) }

    override func doCommand(by selector: Selector) {
        guard let popup = completionPopup, popup.isShown else { return super.doCommand(by: selector) }
        switch selector {
        case #selector(moveUp(_:)): popup.move(-1)
        case #selector(moveDown(_:)): popup.move(1)
        case #selector(insertNewline(_:)), #selector(insertTab(_:)): popup.accept()
        case #selector(cancelOperation(_:)): popup.close()
        default:
            popup.close()
            super.doCommand(by: selector)
        }
    }

    override func mouseDown(with event: NSEvent) {
        completionPopup?.close()
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        completionPopup?.close()
        return super.resignFirstResponder()
    }

    /// Asks for the suggestions at the cursor and shows them (`force`: even with nothing typed yet).
    func updateCompletion(force: Bool) {
        // In a long script the list opens only when asked (⌥⎋), so typing never waits for it.
        guard let completions, selectedRange().length == 0, force || (string as NSString).length <= Self.longText else {
            completionPopup?.close()
            return
        }
        let caret = selectedRange().location
        // Not inside a string or a comment.
        if tokens.contains(where: { [.string, .comment, .hint].contains($0.kind) && $0.range.lowerBound < caret
            && (caret < $0.range.upperBound || !$0.isClosed) }) {
            completionPopup?.close()
            return
        }
        let (range, items) = completions(string, caret)
        let utf16 = Array(string.utf16)
        let afterDot = range.lowerBound > 0 && utf16[range.lowerBound - 1] == 0x2E
        let typed = String(decoding: utf16[range], as: UTF16.self)
        guard force || !range.isEmpty || afterDot, !(items.count == 1 && items[0].text == typed) else {
            completionPopup?.close()
            return
        }
        if completionPopup == nil { completionPopup = CompletionPopup(editor: self) }
        completionPopup?.show(items, replacing: range)
    }
}
