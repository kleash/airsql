import AppKit

extension MainMenu {
    /// Lane L5 (navigator and editors): the Database menu, Edit ▸ Copy Name, Copy CREATE and Copy Query, and Tools ▸
    /// Generate Liquibase Changelog… (the database's right-click menu offers it).
    static func addNavigatorItems(_ menus: Menus) {
        menus.edit.add([nil, Commands.copyName, Commands.copyPlainName, Commands.copyCreate, Commands.createToConsole, Commands.copyQuery])
        menus.database.add([Commands.newDatabase, Commands.createTable, Commands.createObject, nil, Commands.openData,
                            Commands.openStructure, Commands.openObject, Commands.runRoutine, nil, Commands.selectTop, Commands.generateSelect,
                            Commands.generateInsert, Commands.generateUpdate, nil, Commands.copyTable, Commands.bulkEdit])
        menus.database.addItem(NavigatorMenus.maintenance())
        menus.database.add([Commands.truncate, Commands.rename, Commands.drop, nil, Commands.expandAll, Commands.collapseAll, nil,
                            Commands.findOnServer, Commands.processList, Commands.killQuery, Commands.killConnection, nil,
                            Commands.erDiagram, Commands.sqlGenerator])
        menus.database.add([nil])
        menus.database.addItem(MainMenu.submenu("Server Home", [Commands.hostDatabases, Commands.hostVariables, Commands.hostStatus,
                                                                Commands.hostProcesses, Commands.hostCommands].map { $0.item() }))
        menus.database.add([Commands.editVariable, Commands.editDatabase])
        menus.tools.add([Commands.generateLiquibase, nil, Commands.diskUsage, Commands.diskUsageUp, Commands.diskUsageCompare,
                         Commands.copyList, Commands.exportList])
    }
}
