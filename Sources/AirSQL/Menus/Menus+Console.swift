import AirSQLCore
import AppKit

extension MainMenu {
    /// Lane L4 (the console): File ▸ Open…, Save, Save As…; Edit ▸ SQL ▸ Comment Lines, Shift Right, Shift Left; View ▸ Query
    /// Helpers and the text size; Query ▸ Run Selection, Isolation Level, Format SQL, Query History, Profile and the
    /// result tabs' commands. Run, Run All, Explain, Cancel, Commit, Rollback, Transaction Mode and Change Connection…
    /// are P0's already.
    static func addConsoleItems(_ menus: Menus) {
        insert(Commands.open, after: Commands.newQuery, in: menus.file)
        let recent = submenu("Open Recent", [])
        recent.toolTip = "Open a .sql file you had open lately"
        recent.submenu?.delegate = RecentFiles.shared
        let open = menus.file.items.firstIndex { $0.action == Commands.open.action } ?? 0
        menus.file.insertItem(recent, at: open + 1)
        insert(Commands.save, after: Commands.closeWindow, in: menus.file)
        insert(Commands.saveAs, after: Commands.save, in: menus.file)
        insert(Commands.localHistory, after: Commands.saveAs, in: menus.file)

        menus.view.add([nil, Commands.helpers, Commands.wordWrap])
        menus.view.addItem(MainMenu.submenu("Text Size", [Commands.bigger, Commands.smaller, Commands.actualSize].map { $0.item() }))

        insert(Commands.runSelection, after: Commands.runStatement, in: menus.query)
        let explain = menus.query.items.firstIndex { $0.action == Commands.explain.action } ?? menus.query.items.count - 1
        menus.query.insertItem(submenu("Run Special", [Commands.runSelectionWhole, Commands.runSubquery, Commands.runFromCaret,
                                                       Commands.runToFile].map { $0.item() }), at: explain)
        insert(Commands.explainAnalyze, after: Commands.explain, in: menus.query)
        let mode = menus.query.items.firstIndex { $0.title == "Transaction Mode" } ?? menus.query.items.count - 1
        menus.query.insertItem(submenu("Isolation Level", isolationItems()), at: mode + 1)
        menus.query.add([nil, Commands.formatSQL, Commands.saveAsSnippet, Commands.history, Commands.sessions, Commands.profile, Commands.editAsTable, nil])
        menus.query.addItem(submenu("Result", [Commands.keepResults, Commands.resultWindow, Commands.rerunResult, Commands.copyResultQuery,
                                               Commands.pinResult, Commands.renameResult, Commands.closeResult, Commands.closeOtherResults,
                                               Commands.nextResult, Commands.previousResult, Commands.exportResult, Commands.copyResultToTable,
                                               Commands.compareResult].map { $0.item() }))
        let code = submenu("Code", [Commands.showContextActions, Commands.goToDeclaration, Commands.findUsages, Commands.renameSymbol,
                                    Commands.quickDocumentation, Commands.parameterInfo, nil, Commands.nextProblem, Commands.previousProblem,
                                    Commands.showProblem, nil, Commands.previewAffectedRows].map { $0?.item() ?? .separator() })
        code.toolTip = "Find your way around the SQL at the cursor, and fix what's underlined"
        menus.query.addItem(code)
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
