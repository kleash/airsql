import AirSQLCore
import AppKit

/// Completion while typing (plan §2.6): after a letter or a dot the list opens under the cursor with what the schema
/// cache offers there (not inside strings or comments); ⌥⎋ opens it anywhere. While it is open, ↑ and ↓ choose,
/// Return inserts, Tab replaces the rest of the word too and Escape closes; typing on narrows it.
extension SQLEditorView {
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        if !extraCarets.isEmpty, !applyingCarets {
            return atEveryCaret { self.insertText(typed, replacementRange: self.selectedRange()) }
        }
        if pairTyped(typed, replacementRange) {
            if typed == "'" { updateCompletion(force: false) }  // an ENUM's values
            if typed == "\"", otherLanguage != nil { updateCompletion(force: true) }  // a pipeline's paths and values
            if typed == "(" { applyKeywordCase(before: selectedRange().location - 1) }
            return
        }
        super.insertText(string, replacementRange: replacementRange)
        if typed.count == 1, let unit = typed.utf16.first, !SQLLexer.isNameChar(unit), unit != 0x2E { applyKeywordCase(before: selectedRange().location - 1) }
        // One character typed: a letter, digit, _, a dot, @ or * opens or narrows the list; anything else closes it.
        if typed.count == 1, let unit = typed.utf16.first, [0x2E, 0x40, 0x2A].contains(unit) || SQLLexer.isNameChar(unit) || popupOpenInString {
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

    /// Settings ▸ Editor: the reserved word that ends at `end` takes the keyword case, with nothing else touched: not a
    /// name after a dot, a variable or anything in a string or a comment.
    // shortcut: not with several carets, whose text isn't coloured (so not lexed) until all have typed; do it if asked.
    private func applyKeywordCase(before end: Int) {
        let settings = Self.settings()
        guard otherLanguage == nil, settings.autoKeywordCase, settings.formatStyle.keywords != .keep, !applyingCarets, extraCarets.isEmpty, end > 0 else { return }
        let text = self.string as NSString
        var start = end
        while start > 0, SQLLexer.isNameChar(text.character(at: start - 1)) { start -= 1 }
        guard start < end, start == 0 || ![0x2E, 0x40, 0x60].contains(text.character(at: start - 1)), !inTextToken(end) else { return }
        let range = NSRange(location: start, length: end - start), word = text.substring(with: range)
        let cased = settings.formatStyle.keywords.apply(word)
        guard cased != word, SQLWords.reserved.contains(word.uppercased()) else { return }
        replace(range, with: cased)
    }

    /// Typing inside a string keeps an ENUM's list up to date, whatever is typed.
    private var popupOpenInString: Bool { completionPopup?.isShown == true && completionPopup?.items.first?.kind == .value }

    override func doCommand(by selector: Selector) {
        // Menus see only ⌘ and ⌃ keys and function keys: ⌥↩ arrives here, as a line break.
        if selector == #selector(insertNewlineIgnoringFieldEditor(_:)), Commands.showContextActions.shortcut == "⌥↩" {
            completionPopup?.close()
            return showContextActions(nil)
        }
        if completionPopup?.isShown != true, !applyingCarets, templateCommand(selector) { return }
        if selector == #selector(insertNewline(_:)) || selector == #selector(insertTab(_:)), completionPopup?.isShown != true {
            applyKeywordCase(before: selectedRange().location)
        }
        if !extraCarets.isEmpty, !applyingCarets {
            if selector == #selector(cancelOperation(_:)) { return dropExtraCarets() }
            return atEveryCaret { super.doCommand(by: selector) }
        }
        if columnSelection, selector == #selector(moveUpAndModifySelection(_:)) { return addCaretAbove(nil) }
        if columnSelection, selector == #selector(moveDownAndModifySelection(_:)) { return addCaretBelow(nil) }
        guard let popup = completionPopup, popup.isShown else { return super.doCommand(by: selector) }
        switch selector {
        case #selector(moveUp(_:)): popup.move(-1)
        case #selector(moveDown(_:)): popup.move(1)
        case #selector(insertNewline(_:)): popup.accept()
        case #selector(insertTab(_:)): popup.accept(replacingWord: true)
        case #selector(cancelOperation(_:)): popup.close()
        default:
            popup.close()
            super.doCommand(by: selector)
        }
    }

    override func resignFirstResponder() -> Bool {
        completionPopup?.close()
        return super.resignFirstResponder()
    }

    /// Reading the statement at the cursor takes too long for a key in a long script or a long statement (a dump's INSERT).
    var completesWhileTyping: Bool {
        guard (string as NSString).length <= Self.longText else { return false }
        let caret = selectedRange().location
        return statements.first { $0.range.lowerBound <= caret && caret <= $0.end }.map { $0.range.count <= Self.longStatement } ?? true
    }

    static let longStatement = 50_000

    /// Asks for the suggestions at the cursor and shows them (`force`: even with nothing typed yet).
    func updateCompletion(force: Bool) {
        // In a long script the list opens only when asked (⌥⎋), so typing never waits for it.
        guard let completions, extraCarets.isEmpty, !applyingCarets, selectedRange().length == 0, force || completesWhileTyping else {
            completionPopup?.close()
            return
        }
        let caret = selectedRange().location
        let (range, items) = completions(string, caret)
        // Inside a string only an ENUM's values, and nothing inside a comment; another language's completion knows its own.
        let inText = otherLanguage == nil && tokens.contains { [.string, .comment, .hint].contains($0.kind) && $0.range.lowerBound < caret
            && (caret < $0.range.upperBound || !$0.isClosed) }
        let utf16 = Array(string.utf16)
        let afterDot = range.lowerBound > 0 && utf16[range.lowerBound - 1] == 0x2E
        let typed = String(decoding: utf16[range], as: UTF16.self)
        let asked = force || !range.isEmpty || afterDot || items.first?.replacing != nil
        guard asked, !inText || items.first?.kind == .value, !(items.count == 1 && items[0].text == typed) else {
            completionPopup?.close()
            return
        }
        if completionPopup == nil { completionPopup = CompletionPopup(editor: self) }
        completionPopup?.documentation = completionDocs
        completionPopup?.show(items, replacing: range)
    }
}
