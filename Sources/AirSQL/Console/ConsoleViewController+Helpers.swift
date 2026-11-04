import AirSQLCore
import AppKit

/// The helpers panel beside the editor and results (View ▸ Query Helpers): it follows the statement at the cursor.
extension ConsoleViewController {
    func makeHelpers() -> HelpersPanel {
        let panel = HelpersPanel()
        panel.source = { [weak self] in
            guard let self else { return ([], nil) }
            let snapshot = self.connectionID.flatMap { Self.schemaCache($0)?.snapshot }
            let columns = SQLCompletion.columns(text: self.text, caret: self.editor.selectedRange().location, snapshot: snapshot,
                                                database: self.database, noBackslashEscapes: self.editor.noBackslashEscapes)
            return (columns, snapshot?.server)
        }
        panel.insert = { [weak self] text in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.editor)
            self.editor.insertText(text, replacementRange: self.editor.selectedRange())
        }
        return panel
    }

    var helpersShown: Bool { outer.arrangedSubviews.contains(helpers) }

    @objc func toggleHelpers(_ sender: Any?) {
        if helpersShown {
            Self.helpersWidth = helpers.frame.width
            outer.removeArrangedSubview(helpers)
            helpers.removeFromSuperview()
            editor.onSelectionChange = nil
        } else {
            outer.addArrangedSubview(helpers)
            outer.setHoldingPriority(.defaultLow + 10, forSubviewAt: 1)
            outer.layoutSubtreeIfNeeded()
            outer.setPosition(max(320, outer.bounds.width - Self.helpersWidth), ofDividerAt: 0)
            helpers.reload()
            // Follows the statement at the cursor, a moment after it moves.
            editor.onSelectionChange = { [weak self] in
                guard let self else { return }
                NSObject.cancelPreviousPerformRequests(withTarget: self.helpers, selector: #selector(HelpersPanel.reload), object: nil)
                self.helpers.perform(#selector(HelpersPanel.reload), with: nil, afterDelay: 0.3)
            }
        }
    }
}
