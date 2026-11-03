import AirSQLCore
import AppKit

/// Completion while typing (plan §2.6): after a letter or a dot the list opens under the cursor with what the schema
/// cache offers there (not inside strings or comments); ⌥⎋ opens it anywhere. While it is open, ↑ and ↓ choose,
/// Return or Tab inserts and Escape closes; typing on narrows it.
extension SQLEditorView {
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        // One character typed: a letter, digit, _ or a dot opens or narrows the list; anything else closes it.
        if typed.count == 1, let unit = typed.utf16.first, unit == 0x2E || SQLCompletion.isWordChar(unit) {
            updateCompletion(force: false)
        } else {
            completionPopup?.close()
        }
    }

    override func deleteBackward(_ sender: Any?) {
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
        guard let completions, selectedRange().length == 0 else { return }
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
