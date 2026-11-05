import AirSQLCore
import AppKit

/// Moving by statement, and selecting by syntax.
extension SQLEditorView {
    @objc func nextStatement(_ sender: Any?) {
        let caret = selectedRange().location
        guard let next = statements.first(where: { $0.range.lowerBound > caret }) else { return NSSound.beep() }
        go(to: next.range.lowerBound)
    }

    @objc func previousStatement(_ sender: Any?) {
        let caret = selectedRange().location
        guard let previous = statements.last(where: { $0.range.lowerBound < caret }) else { return NSSound.beep() }
        go(to: previous.range.lowerBound)
    }

    private func go(to place: Int) {
        setSelectedRange(NSRange(location: place, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    @objc func selectStatement(_ sender: Any?) {
        guard let statement = SQLSplitter.statement(at: selectedRange().location, in: string, noBackslashEscapes: noBackslashEscapes)
        else { return NSSound.beep() }
        setSelectedRange(NSRange(statement.range))
        scrollRangeToVisible(selectedRange())
    }

    @objc func moveStatementUp(_ sender: Any?) { moveStatement(by: -1) }
    @objc func moveStatementDown(_ sender: Any?) { moveStatement(by: 1) }

    /// Swaps the statement at the cursor with its neighbour. Their delimiters stay where they are, so the last statement
    /// may go without one.
    private func moveStatement(by step: Int) {
        let all = statements, caret = selectedRange().location
        guard let statement = SQLSplitter.statement(at: caret, in: string, noBackslashEscapes: noBackslashEscapes),
              let index = all.firstIndex(of: statement), all.indices.contains(index + step) else { return NSSound.beep() }
        let (first, second) = step < 0 ? (all[index + step], statement) : (statement, all[index + step])
        let text = string as NSString
        let between = text.substring(with: NSRange(first.range.upperBound..<second.range.lowerBound))
        let swapped = second.sql + between + first.sql
        let start = step < 0 ? first.range.lowerBound
            : first.range.lowerBound + (second.sql as NSString).length + (between as NSString).length
        replace(NSRange(first.range.lowerBound..<second.range.upperBound), with: swapped,
                select: NSRange(location: start + max(0, min(caret - statement.range.lowerBound, statement.range.count)), length: 0))
    }

    /// ⌥↑: the next larger piece of syntax; ⌥↓ takes the steps back.
    @objc func extendSelection(_ sender: Any?) {
        let selection = selectedRange()
        guard let range = Range(selection), let next = SQLEditing.grown(range, in: string, noBackslashEscapes: noBackslashEscapes) else {
            return NSSound.beep()
        }
        if grownSelections.last?.to != selection { grownSelections = [] }
        grownSelections.append((selection, NSRange(next)))
        setSelectedRange(NSRange(next))
    }

    @objc func shrinkSelection(_ sender: Any?) {
        guard let step = grownSelections.popLast(), step.to == selectedRange() else {
            grownSelections = []
            return NSSound.beep()
        }
        setSelectedRange(step.from)
    }
}
