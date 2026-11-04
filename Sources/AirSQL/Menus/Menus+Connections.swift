import AppKit

extension MainMenu {
    /// Lane L1 (connections and routes): File's imports and exports of connections, and the sidebar's folders in the Connection
    /// menu. Connect, Disconnect, Edit…, Duplicate, Colour and Delete… are P0's already.
    static func addConnectionItems(_ menus: Menus) {
        menus.file.insertItem(Commands.newConnectionFromURL.item(), at: 1)
        menus.file.insertItem(Commands.importSSHConfig.item(), at: 2)
        menus.file.insertItem(Commands.importConnections.item(), at: 3)
        menus.file.insertItem(Commands.exportConnections.item(), at: 4)
        menus.connection.add([nil, Commands.newFolder, Commands.renameFolder, Commands.deleteFolder])
    }
}
