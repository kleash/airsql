import AppKit

extension MainMenu {
    /// Lane L5 (navigator and editors): the Database menu, Edit ▸ Copy Name, Copy CREATE and Copy Query, and Tools ▸
    /// Generate Liquibase Changelog… (the database's right-click menu offers it).
    static func addNavigatorItems(_ menus: Menus) {
        menus.edit.add([nil, Commands.copyName, Commands.copyCreate, Commands.copyQuery])
        menus.database.add([Commands.newDatabase, Commands.createTable, Commands.createObject, nil, Commands.openData,
                            Commands.openStructure, Commands.openObject, Commands.runRoutine, nil, Commands.generateSelect,
                            Commands.generateInsert, Commands.generateUpdate, nil, Commands.copyTable, Commands.bulkEdit])
        menus.database.addItem(NavigatorMenus.maintenance())
        menus.database.add([Commands.truncate, Commands.rename, Commands.drop, nil, Commands.expandAll, Commands.collapseAll, nil,
                            Commands.findOnServer, Commands.processList, Commands.killQuery, Commands.killConnection, nil,
                            Commands.erDiagram])
        menus.tools.add([Commands.generateLiquibase])
    }
}
