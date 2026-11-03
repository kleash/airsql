import AppKit

extension MainMenu {
    /// Lanes L2 and L3 (the grid): the Data menu (Add Row, Delete Rows…, Set NULL, Apply Changes, Revert, Filter…, Go to
    /// Row…, Load More…), Edit ▸ Copy with Headers and Copy As, and View ▸ Value Panel, Record View, Transpose, View As,
    /// Chart, Column List…, Bigger, Smaller. Every command is in `Commands` already, with its shortcut.
    static func addGridItems(_ menus: Menus) {
        addGridDataItems(menus)
    }

    /// L3a: editing, Apply, filters, sorting, paging, Copy with Headers and Copy As, Refresh Every.
    private static func addGridDataItems(_ menus: Menus) {
        let copy = menus.edit.items.firstIndex { $0.action == Commands.copy.action } ?? menus.edit.items.count - 1
        menus.edit.insertItem(Commands.copyWithHeaders.item(), at: copy + 1)
        menus.edit.insertItem(GridCopy.copyAsItem(), at: copy + 2)
        menus.data.add([Commands.addRow, Commands.duplicateRow, Commands.duplicateRowWithoutKeys, Commands.deleteRows, nil,
                        Commands.setNull, Commands.setDefault, nil, Commands.apply, Commands.previewChanges, Commands.revert, nil,
                        Commands.filter, Commands.searchAllColumns])
        menus.data.addItem(submenu("Quick Filter", [Commands.filterEquals.item(), Commands.filterNotEquals.item()]))
        menus.data.add([Commands.clearFilter, nil, Commands.sortAscending, Commands.sortDescending, Commands.clearSort, nil,
                        Commands.loadMore, Commands.loadAll, Commands.countRows])
        let refresh = menus.view.items.firstIndex { $0.action == Commands.refresh.action } ?? menus.view.items.count - 1
        menus.view.insertItem(submenu("Refresh Every", TableDataController.autoRefreshItems()), at: refresh + 1)
    }
}
