import AirSQLCore
import AppKit

/// Templates: a snippet or a suggestion goes in with its fields, the first selected. Tab or Return goes to the next
/// field and on to where the cursor ends, ⇧Tab goes back, Escape stops; a field used twice takes carets, so both follow.
extension SQLEditorView {
    /// Puts `body` (`SQLTemplate`) in place of `range` as one undoable step. Its lines start as the line it goes in does.
    func insertTemplate(_ body: String, replacing range: NSRange, selection: String = "") {
        let text = string as NSString, line = text.lineRange(for: NSRange(location: range.location, length: 0))
        let indent = text.substring(with: line).prefix { $0 == " " || $0 == "\t" }
        let expansion = SQLTemplate.expand(body.replacingOccurrences(of: "\n", with: "\n" + indent), selection: selection)
        endTemplate()
        replace(range, with: expansion.text)
        let base = range.location, end = expansion.end ?? (expansion.text as NSString).length
        templateFields = expansion.fields.map { $0.map { NSRange(location: base + $0.lowerBound, length: $0.count) } }
            + [[NSRange(location: base + end, length: 0)]]
        templateField = -1
        nextTemplateField(1)
    }

    func endTemplate() {
        templateFields = []
        templateField = 0
    }

    private func nextTemplateField(_ step: Int) {
        templateField = max(0, templateField + step)
        // An Undo can have taken the text away from under the fields.
        guard templateField < templateFields.count, templateFields[templateField].allSatisfy({ NSMaxRange($0) <= (string as NSString).length }) else {
            return endTemplate()
        }
        setCarets(templateFields[templateField])
        if let first = templateFields[templateField].first { scrollRangeToVisible(first) }
        if templateField == templateFields.count - 1 { endTemplate() }
    }

    /// Handles Tab, ⇧Tab, Return and Escape while a template is being filled in, and Tab after an abbreviation.
    func templateCommand(_ selector: Selector) -> Bool {
        let next = selector == #selector(insertTab(_:)) || selector == #selector(insertNewline(_:))
        let back = selector == #selector(insertBacktab(_:))
        if !templateFields.isEmpty {
            guard next || back || selector == #selector(cancelOperation(_:)), templateFields.indices.contains(templateField) else { return false }
            let caret = selectedRange()
            guard templateFields[templateField].contains(where: { caret.location >= $0.location && NSMaxRange(caret) <= NSMaxRange($0) }) else {
                endTemplate()
                return false
            }
            if next || back {
                nextTemplateField(next ? 1 : -1)
            } else {
                endTemplate()
                dropExtraCarets()
            }
            return true
        }
        return selector == #selector(insertTab(_:)) && expandAbbreviation()
    }

    /// The word before the cursor is a template's whole abbreviation, or a postfix like `orders.from`.
    private func expandAbbreviation() -> Bool {
        guard extraCarets.isEmpty, selectedRange().length == 0, let completions else { return false }
        let (range, items) = completions(string, selectedRange().location)
        let typed = (string as NSString).substring(with: NSRange(range))
        guard !typed.isEmpty, let item = items.first(where: { $0.kind == .template && $0.label.caseInsensitiveCompare(typed) == .orderedSame }) else { return false }
        insertTemplate(item.text, replacing: NSRange(item.replacing ?? range))
        return true
    }

    /// Keeps the fields on their text, edit by edit: the text storage reports a batch of them as one. An edit at the edge
    /// of the current field is in it: that's the typing.
    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: range, replacementString: replacementString) else { return false }
        if let replacementString, !templateFields.isEmpty { moveTemplateFields(range, replacementString.utf16.count - range.length) }
        return true
    }

    private func moveTemplateFields(_ edited: NSRange, _ delta: Int) {
        let start = edited.location, end = NSMaxRange(edited)
        for (index, field) in templateFields.enumerated() {
            let current = index == templateField
            templateFields[index] = field.map { place in
                let placeEnd = NSMaxRange(place)
                if start > placeEnd || (start == placeEnd && !current) { return place }
                if end < place.location || (end == place.location && !current) {
                    return NSRange(location: place.location + delta, length: place.length)
                }
                let location = min(place.location, start)
                return NSRange(location: location, length: max(placeEnd, end) + delta - location)
            }
        }
    }
}
