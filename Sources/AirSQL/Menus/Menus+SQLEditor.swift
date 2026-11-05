import AppKit

extension MainMenu {
    /// The SQL editor's commands: Edit ▸ Lines, Statements, Carets, Folding, and Comment Selection beside Comment Lines.
    static func addSQLEditorItems(_ menus: Menus) {
        menus.edit.addItem(submenu("Lines", [Commands.duplicateLine, Commands.deleteLine, Commands.moveLineUp, Commands.moveLineDown,
                                             Commands.joinLines, Commands.sortLines, Commands.reverseLines].map { $0.item() }))
        menus.edit.addItem(submenu("Statements", [Commands.nextStatement, Commands.previousStatement, Commands.selectStatement,
                                                  Commands.moveStatementUp, Commands.moveStatementDown].map { $0.item() }))
        menus.edit.addItem(submenu("Carets", [Commands.selectNextOccurrence, Commands.selectAllOccurrences, Commands.caretPerLine,
                                              Commands.addCaretAbove, Commands.addCaretBelow, Commands.columnSelection].map { $0.item() }))
        menus.edit.addItem(submenu("Folding", [Commands.foldHere, Commands.unfoldHere, Commands.foldAll, Commands.unfoldAll].map { $0.item() }))
        menus.edit.addItem(submenu("Surround With", [], delegate: SurroundMenu.shared))
        menus.edit.addItem(submenu("Paste from History", [], delegate: PasteHistoryMenu.shared))
        menus.edit.add([Commands.blockComment, Commands.toggleCase, Commands.completeStatement])
    }
}

/// Edit ▸ Surround With: the templates, and the person's snippets that hold `$SELECTION$`, made as the menu opens.
@MainActor
final class SurroundMenu: NSObject, NSMenuDelegate {
    static let shared = SurroundMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let own = SQLEditorView.settings().snippets.filter { $0.body.contains("$SELECTION$") }.map { (title: $0.name, body: $0.body) }
        for surround in SQLEditorView.surrounds + own {
            let item = Commands.surroundWith.item()
            item.title = surround.title
            item.representedObject = surround.body
            menu.addItem(item)
        }
    }
}

/// Edit ▸ Paste from History: the editor's last copies, a line of each, made as the menu opens.
@MainActor
final class PasteHistoryMenu: NSObject, NSMenuDelegate {
    static let shared = PasteHistoryMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for text in SQLEditorView.copied {
            let item = Commands.pasteFromHistory.item()
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? ""
            item.title = line.count > 60 ? line.prefix(60) + "…" : line
            item.representedObject = text
            menu.addItem(item)
        }
        guard menu.items.isEmpty else { return }
        let none = NSMenuItem(title: "Copy Something in the Editor First", action: nil, keyEquivalent: "")
        none.toolTip = "Paste from History lists what you copied or cut in an editor since AirSQL opened"
        menu.addItem(none)
    }
}
