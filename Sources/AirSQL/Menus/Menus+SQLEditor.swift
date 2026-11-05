import AppKit

extension MainMenu {
    /// The SQL editor's commands: Edit ▸ SQL ▸ Lines, Statements, Carets, Folding, and Comment Selection beside Comment Lines.
    static func addSQLEditorItems(_ menus: Menus) {
        func items(_ commands: [Command]) -> [NSMenuItem] { commands.map { $0.item() } }
        menus.edit.add([nil])
        menus.edit.addItem(submenu("SQL", items([Commands.toggleComment, Commands.blockComment, Commands.shiftRight, Commands.shiftLeft,
                                                 Commands.toggleCase, Commands.completeStatement, Commands.goToLine]) + [.separator(),
            submenu("Lines", items([Commands.duplicateLine, Commands.deleteLine, Commands.moveLineUp, Commands.moveLineDown,
                                    Commands.joinLines, Commands.sortLines, Commands.reverseLines])),
            submenu("Statements", items([Commands.nextStatement, Commands.previousStatement, Commands.selectStatement,
                                         Commands.moveStatementUp, Commands.moveStatementDown])),
            submenu("Carets", items([Commands.selectNextOccurrence, Commands.selectAllOccurrences, Commands.caretPerLine,
                                     Commands.addCaretAbove, Commands.addCaretBelow, Commands.columnSelection])),
            submenu("Folding", items([Commands.foldHere, Commands.unfoldHere, Commands.foldAll, Commands.unfoldAll])),
            submenu("Surround With", [], delegate: SurroundMenu.shared),
            submenu("Paste from History", [], delegate: PasteHistoryMenu.shared)]))
    }
}

/// Edit ▸ SQL ▸ Surround With: the templates, and the person's snippets that hold `$SELECTION$`, made as the menu opens.
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

/// Edit ▸ SQL ▸ Paste from History: the editor's last copies, a line of each, made as the menu opens.
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
