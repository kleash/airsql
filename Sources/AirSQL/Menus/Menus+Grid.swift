import AppKit

extension MainMenu {
    /// Lanes L2 and L3 (the grid): the Data menu (Add Row, Delete Rows…, Set NULL, Apply Changes, Revert, Filter…, Go to
    /// Row…, Load More…), Edit ▸ Copy with Headers and Copy As, and View ▸ Value Panel, Record View, Transpose, View As,
    /// Chart, Column List…, Bigger, Smaller. Every command is in `Commands` already, with its shortcut.
    static func addGridItems(_ menus: Menus) {
        // L2: reading the data.
        menus.edit.add([nil, Commands.copySummary])
        menus.data.add([Commands.openTable, nil, Commands.goToRow, Commands.hideColumn, nil, Commands.loadMore, Commands.countRows])
        menus.view.add([nil, Commands.columnList])
    }
}
