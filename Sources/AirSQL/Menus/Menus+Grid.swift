import AppKit

extension MainMenu {
    /// The grid (lanes L2 and L3a): the Data menu (editing, Apply, filters, sorting, going to a row, Column Summary,
    /// Display As, paging, Export Rows…), Edit ▸ Copy with Headers, Copy As, Copy Column Name and Copy Selection Summary,
    /// and View ▸ Refresh Every, Value Panel, Record View, Transpose, Column List…, Heatmap, View As and Chart. Every
    /// command is in `Commands` already, with its shortcut.
    static func addGridItems(_ menus: Menus) {
        let copy = menus.edit.items.firstIndex { $0.action == Commands.copy.action } ?? menus.edit.items.count - 1
        menus.edit.insertItem(Commands.copyWithHeaders.item(), at: copy + 1)
        menus.edit.insertItem(GridCopy.copyAsItem(), at: copy + 2)
        menus.edit.insertItem(Commands.copyColumnName.item(), at: copy + 3)
        menus.edit.insertItem(Commands.copySummary.item(), at: copy + 4)
        menus.data.add([Commands.addRow, Commands.duplicateRow, Commands.duplicateRowWithoutKeys, Commands.deleteRows, nil,
                        Commands.setNull, Commands.setDefault, nil, Commands.apply, Commands.previewChanges, Commands.revert, nil,
                        Commands.filter, Commands.searchAllColumns])
        menus.data.addItem(submenu("Quick Filter", [Commands.filterEquals.item(), Commands.filterNotEquals.item()]))
        menus.data.add([Commands.clearFilter, nil, Commands.sortAscending, Commands.sortDescending, Commands.clearSort, nil,
                        Commands.goToRow, Commands.columnSummary, Commands.hideColumn])
        menus.data.addItem(GridViewer.displayMenu())
        menus.data.add([nil, Commands.loadMore, Commands.loadAll, Commands.countRows, nil, Commands.exportRows])
        let refresh = menus.view.items.firstIndex { $0.action == Commands.refresh.action } ?? menus.view.items.count - 1
        menus.view.insertItem(submenu("Refresh Every", TableDataController.autoRefreshItems()), at: refresh + 1)
        menus.view.add([nil, Commands.valuePanel, Commands.recordView, Commands.previousRecord, Commands.nextRecord,
                        Commands.transpose, Commands.columnList, nil, Commands.heatmap, Commands.highlightEqual])
        menus.view.addItem(submenu("View As", ["Table", "Text", "Tree"].enumerated().map { index, title in
            let item = Commands.viewAs.item()
            item.title = title
            item.tag = index
            return item
        }))
        menus.view.add([Commands.chart])
    }
}
