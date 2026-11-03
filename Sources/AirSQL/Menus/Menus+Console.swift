import AirSQLCore
import AppKit

extension MainMenu {
    /// Lane L4 (the console): File ▸ Open…, Save, Save As…; Edit ▸ Comment Lines, Shift Right, Shift Left; View ▸ Query
    /// Helpers and the text size; Query ▸ Run Selection, Isolation Level, Format SQL, Query History, Profile and the
    /// result tabs' commands. Run, Run All, Explain, Cancel, Commit, Rollback, Transaction Mode and Change Connection…
    /// are P0's already.
    static func addConsoleItems(_ menus: Menus) {
        insert(Commands.open, after: Commands.newQuery, in: menus.file)
        insert(Commands.save, after: Commands.closeWindow, in: menus.file)
        insert(Commands.saveAs, after: Commands.save, in: menus.file)

        menus.edit.add([nil, Commands.toggleComment, Commands.shiftRight, Commands.shiftLeft])

        menus.view.add([nil, Commands.helpers, Commands.bigger, Commands.smaller, Commands.actualSize])

        insert(Commands.runSelection, after: Commands.runStatement, in: menus.query)
        let mode = menus.query.items.firstIndex { $0.title == "Transaction Mode" } ?? menus.query.items.count - 1
        menus.query.insertItem(submenu("Isolation Level", isolationItems()), at: mode + 1)
        menus.query.add([nil, Commands.formatSQL, Commands.history, Commands.profile, Commands.editAsTable, nil, Commands.pinResult,
                         Commands.renameResult, Commands.closeResult, Commands.closeOtherResults, Commands.exportResult,
                         Commands.compareResult])
    }

    /// One item per isolation level (the menu bar's and the toolbar's Tx pop-up), told apart by their tags.
    static func isolationItems() -> [NSMenuItem] {
        IsolationLevel.allCases.enumerated().map { index, level in
            let item = Commands.isolation.item()
            item.title = level.title
            item.tag = index
            return item
        }
    }

    /// Puts `command`'s item right after `anchor`'s (at the end when it isn't there).
    private static func insert(_ command: Command, after anchor: Command, in menu: NSMenu) {
        let index = menu.items.firstIndex { $0.action == anchor.action && $0.tag == anchor.tag && !$0.isHidden }
        menu.insertItem(command.item(), at: index.map { $0 + 1 } ?? menu.items.count)
    }
}
