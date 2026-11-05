import AppKit

extension MainMenu {
    /// Lane L6 (client tools and transfer): File ▸ Run SQL File…, Import CSV…; Tools ▸ Copy to Another Server…. Open in
    /// Terminal, Export… and Restore… are P0's already (the sidebar's menu has them). `ToolsResponder` handles them all.
    static func addToolItems(_ menus: Menus) {
        menus.file.add([nil, Commands.runSQLFile, Commands.importCSV, Commands.importClipboard])
        let restore = menus.tools.indexOfItem(withTitle: Commands.restore.title)
        menus.tools.insertItem(Commands.copyToServer.item(), at: restore + 1)
        menus.tools.insertItem(submenu("Flush", [Commands.flushHosts, Commands.flushLogs, Commands.flushPrivileges, Commands.flushTables,
                                                 Commands.flushStatus, Commands.flushReadLock].map { $0.item() }), at: restore + 2)
    }
}
