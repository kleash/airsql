import AppKit

extension MainMenu {
    /// The SQL editor's commands: Edit ▸ Lines, Statements, and Comment Selection beside Comment Lines.
    static func addSQLEditorItems(_ menus: Menus) {
        menus.edit.addItem(submenu("Lines", [Commands.duplicateLine, Commands.deleteLine, Commands.moveLineUp, Commands.moveLineDown,
                                             Commands.joinLines, Commands.sortLines, Commands.reverseLines].map { $0.item() }))
        menus.edit.addItem(submenu("Statements", [Commands.nextStatement, Commands.previousStatement, Commands.selectStatement,
                                                  Commands.moveStatementUp, Commands.moveStatementDown].map { $0.item() }))
        menus.edit.add([Commands.blockComment, Commands.toggleCase, Commands.completeStatement])
    }
}
