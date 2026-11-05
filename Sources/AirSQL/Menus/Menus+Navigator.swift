import AppKit

extension MainMenu {
    /// Lane L5 (navigator and editors): the Database menu, Edit ▸ Copy Name, Copy CREATE and Copy Query, and Tools ▸
    /// Generate Liquibase Changelog… (the database's right-click menu offers it).
    static func addNavigatorItems(_ menus: Menus) {
        menus.edit.add([nil, Commands.copyName, Commands.copyPlainName, Commands.copyCreate, Commands.copyQuery])
        menus.database.add([Commands.newDatabase, Commands.createTable, Commands.createObject, nil, Commands.openData,
                            Commands.openStructure, Commands.openObject, Commands.runRoutine, nil, Commands.generateSelect,
                            Commands.generateInsert, Commands.generateUpdate, nil, Commands.favourite, Commands.copyTable, Commands.bulkEdit])
        menus.database.addItem(NavigatorMenus.maintenance())
        menus.database.add([Commands.truncate, Commands.rename, Commands.drop, nil, Commands.expandAll, Commands.collapseAll, nil,
                            Commands.findOnServer, Commands.processList, Commands.killQuery, Commands.killConnection, nil,
                            Commands.erDiagram])
        menus.database.add([nil, Commands.openNameData, Commands.goToDDL, Commands.quickDefinition, Commands.findUsedBy, nil, Commands.editComment,
                            Commands.newColumn, Commands.newIndex, Commands.newForeignKey])
        menus.window.add([nil, Commands.goBack, Commands.goForward, Commands.recentTabs])
        menus.edit.add([Commands.statementList, Commands.findInFiles])
        menus.connection.add([nil, Commands.moveConnectionUp, Commands.moveConnectionDown])
        menus.tools.add([Commands.generateLiquibase])
        menus.view.addItem(submenu("Tree", Commands.treeMenuItems()))
        menus.view.addItem(submenu("Table Page", [Commands.pageData, Commands.pageStructure, Commands.pageDDL].map { $0.item() }))
    }
}
