import AppKit

extension MainMenu {
    /// The grid (lanes L2 and L3a): the Data menu (editing, Apply, filters with each quick filter of a cell's menu, sorting
    /// by one or several columns, going to a row, Column Summary, Display As, paging, Export Rows…), Edit ▸ Copy with
    /// Headers, Copy As, Copy Column Name, Copy Selection Summary,
    /// Extend Selection and Shrink Selection, and View ▸ Refresh Every, Value Panel, Record View, Transpose, Column List…,
    /// Heatmap, View As and Chart. Every command is in `Commands` already, with its shortcut.
    static func addGridItems(_ menus: Menus) {
        let copy = menus.edit.items.firstIndex { $0.action == Commands.copy.action } ?? menus.edit.items.count - 1
        menus.edit.insertItem(Commands.copyWithHeaders.item(), at: copy + 1)
        menus.edit.insertItem(GridCopy.copyAsItem(), at: copy + 2)
        menus.edit.insertItem(Commands.copyColumnName.item(), at: copy + 3)
        menus.edit.insertItem(Commands.copySummary.item(), at: copy + 4)
        let selectAll = menus.edit.items.firstIndex { $0.action == Commands.selectAll.action } ?? menus.edit.items.count - 1
        menus.edit.insertItem(Commands.extendSelection.item(), at: selectAll + 1)
        menus.edit.insertItem(Commands.shrinkSelection.item(), at: selectAll + 2)
        func items(_ commands: [Command]) -> [NSMenuItem] { commands.map { $0.item() } }
        menus.data.add([Commands.addRow, Commands.duplicateRow, Commands.duplicateRowWithoutKeys, Commands.pasteAsNewRows,
                        Commands.pasteWithFormat, Commands.deleteRows, Commands.moveRowsUp, Commands.moveRowsDown, nil])
        menus.data.addItem(submenu("Set Value", items([Commands.setNull, Commands.setDefault, Commands.setExpression])
                                   + [submenu("Insert Value", [], delegate: InsertValueMenu.shared)]))
        menus.data.addItem(submenu("Foreign Keys", items([Commands.chooseReferencedRow, Commands.relatedRows, Commands.useAsLabel,
                                                          Commands.addVirtualKey, Commands.removeVirtualKey])))
        menus.data.add([nil, Commands.apply, Commands.previewChanges, Commands.revert, nil, Commands.filter, Commands.searchAllColumns])
        menus.data.addItem(submenu("Quick Filter", QuickFilter.commands.map { $0.item() } + [.separator(), Commands.filterPrompt.item()]))
        menus.data.add([Commands.filterByValues, Commands.clearFilter])
        menus.data.addItem(submenu("Sort", items([Commands.sortAscending, Commands.sortDescending, Commands.addToSort, Commands.sortColumns,
                                                  Commands.orderBy, Commands.clearSort])))
        menus.data.add([nil, Commands.goToRow, Commands.columnSummary])
        menus.data.addItem(submenu("Columns", items([Commands.hideColumn, Commands.hideOtherColumns, Commands.freeze]) + [GridViewer.displayMenu()]))
        menus.data.add([Commands.openURL, Commands.compareCells, nil, Commands.loadFullCell])
        menus.data.addItem(submenu("Pages", items([Commands.loadMore, Commands.loadAll, Commands.countRows]) + [.separator()]
                                   + items([Commands.firstPage, Commands.previousPage, Commands.nextPage, Commands.lastPage])
                                   + [submenu("Rows per Page", TableDataController.pageSizeItems())]))
        menus.data.add([nil, Commands.copyTableQuery, Commands.openTableQuery, Commands.exportRows])
        let refresh = menus.view.items.firstIndex { $0.action == Commands.refresh.action } ?? menus.view.items.count - 1
        menus.view.insertItem(submenu("Refresh Every", TableDataController.autoRefreshItems()), at: refresh + 1)
        menus.view.add([nil, Commands.resetView, Commands.valuePanel])
        // A submenu of their own: at one line each, View is taller than a 13-inch screen.
        menus.view.addItem(submenu("Grid", [Commands.recordView, Commands.previousRecord, Commands.nextRecord, Commands.transpose, Commands.columnList].map { $0.item() }
                                   + [.separator(), Commands.heatmap.item(), Commands.highlightEqual.item(), submenu("View As", viewAsItems()), Commands.chart.item()]))
    }

    /// View As's choices.
    static func viewAsItems() -> [NSMenuItem] {
        ["Table", "Text", "Tree"].enumerated().map { index, title in
            let item = Commands.viewAs.item()
            item.title = title
            item.tag = index
            return item
        }
    }
}

/// Data ▸ Set Value ▸ Insert Value: the items for the focused cell's column of the table tab in front, made as the menu opens.
@MainActor
final class InsertValueMenu: NSObject, NSMenuDelegate {
    static let shared = InsertValueMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let items = (NSApp.target(forAction: Commands.insertValue.action, to: nil, from: nil) as? TableDataController)?.insertValueItems() ?? []
        items.forEach(menu.addItem)
        guard items.isEmpty else { return }
        let none = NSMenuItem(title: "Select a Cell of a Table First", action: nil, keyEquivalent: "")
        none.toolTip = "Insert Value puts a value the server works out into the selected cells of a table's rows"
        menu.addItem(none)
    }
}
