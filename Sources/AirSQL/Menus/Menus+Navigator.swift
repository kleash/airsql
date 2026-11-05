import AppKit

extension MainMenu {
    /// Lane L5 (navigator and editors): the Database menu, Edit ▸ Copy Name, Copy CREATE and Copy Query, and Tools ▸
    /// Generate Liquibase Changelog… (the database's right-click menu offers it).
    static func addNavigatorItems(_ menus: Menus) {
        func items(_ commands: [Command]) -> [NSMenuItem] { commands.map { $0.item() } }
        menus.edit.add([nil, Commands.copyName, Commands.copyPlainName, Commands.copyCreate, Commands.createToConsole, Commands.copyQuery,
                        Commands.statementList, Commands.findInFiles])
        menus.database.add([Commands.newDatabase, Commands.editDatabase, Commands.createTable, nil, Commands.openData,
                            Commands.openStructure, Commands.openObject, Commands.runRoutine, nil])
        menus.database.addItem(submenu("Generate", items([Commands.selectTop, Commands.generateSelect, Commands.generateInsert,
                                                          Commands.generateUpdate, Commands.sqlGenerator])))
        menus.database.addItem(submenu("Go To", items([Commands.openNameData, Commands.goToDDL, Commands.quickDefinition, Commands.findUsedBy,
                                                       Commands.findOnServer])))
        menus.database.add([nil, Commands.favourite, Commands.copyTable, Commands.bulkEdit])
        menus.database.addItem(NavigatorMenus.maintenance())
        menus.database.add([Commands.truncate, Commands.rename, Commands.drop, nil])
        menus.database.addItem(submenu("Table Parts", items([Commands.editComment, Commands.newColumn, Commands.newIndex, Commands.newForeignKey,
                                                             Commands.indexFromColumns, Commands.uniqueFromColumns])))
        menus.database.add([nil])
        let home = submenu("Server Home", items([Commands.hostDatabases, Commands.hostVariables, Commands.hostStatus, Commands.hostProcesses,
                                                 Commands.hostCommands]))
        menus.database.addItem(submenu("Server", [home] + items([Commands.editVariable, Commands.processList, Commands.killQuery, Commands.killConnection])))
        menus.database.addItem(submenu("Users", items([Commands.users, Commands.newUser, Commands.newRole, Commands.editUser, Commands.cloneUser,
                                                       Commands.dropUser, Commands.modifyGrants])))
        // Before Bring All to Front, which stays last.
        let main = menus.window.items.firstIndex { $0.action == Commands.mainWindow.action } ?? menus.window.items.count
        for (offset, item) in (items([Commands.goBack, Commands.goForward, Commands.recentTabs]) + [.separator()]).enumerated() {
            menus.window.insertItem(item, at: main + offset)
        }
        menus.connection.add([nil, Commands.moveConnectionUp, Commands.moveConnectionDown])
        menus.tools.add([nil, Commands.generateLiquibase, nil, Commands.diskUsage])
        menus.tools.addItem(submenu("In the List", items([Commands.diskUsageUp, Commands.diskUsageCompare, Commands.copyList, Commands.exportList])))
        menus.view.addItem(submenu("Tree", Commands.treeMenuItems() + [.separator()] + items([Commands.expandAll, Commands.collapseAll])))
        menus.view.addItem(submenu("Table Page", [Commands.pageData, Commands.pageStructure, Commands.pageDDL].map { $0.item() }))
    }
}
