import AppKit

extension MainMenu {
    /// Lane L1 (connections and routes): File ▸ Import from ~/.ssh/config…, and the sidebar's folders in the Connection
    /// menu. Connect, Disconnect, Edit…, Duplicate, Colour and Delete… are P0's already.
    static func addConnectionItems(_ menus: Menus) {
        menus.file.insertItem(Commands.importSSHConfig.item(), at: 1)
        menus.connection.add([nil, Commands.newFolder, Commands.renameFolder, Commands.deleteFolder])
    }
}
