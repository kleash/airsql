import AirSQLCore
import AppKit

extension MainMenu {
    /// Lane L1 (connections and routes): File's imports and exports of connections, and the sidebar's folders in the Connection
    /// menu. Connect, Disconnect, Edit…, Duplicate, Colour and Delete… are P0's already.
    static func addConnectionItems(_ menus: Menus) {
        menus.file.insertItem(Commands.newConnectionFromURL.item(), at: 1)
        menus.file.insertItem(Commands.importSSHConfig.item(), at: 2)
        menus.file.insertItem(Commands.importConnections.item(), at: 3)
        menus.file.insertItem(Commands.exportConnections.item(), at: 4)
        menus.file.insertItem(submenu("Connect To", [], delegate: ConnectToMenu.connect), at: 1)
        menus.file.insertItem(.separator(), at: 6)
        menus.connection.addItem(submenu("Deleted Connections", [], delegate: ConnectToMenu.bringBack))
        menus.connection.add([nil, Commands.newFolder, Commands.renameFolder, Commands.deleteFolder])
        menus.connection.addItem(ConnectionMenus.moveMenu())
    }
}

/// File ▸ Connect To and Connection ▸ Deleted Connections: a connection per item, made as the menu opens.
@MainActor
final class ConnectToMenu: NSObject, NSMenuDelegate {
    static let connect = ConnectToMenu(Commands.connectTo, empty: "No Connections Yet", tip: "Add a connection first") { $0.connections }
    static let bringBack = ConnectToMenu(Commands.bringBack, empty: "None Deleted", tip: "Connections you delete show here") { $0.deletedConnections }

    private let command: Command, empty: String, tip: String, list: (AirSQLData) -> [SavedConnection]

    private init(_ command: Command, empty: String, tip: String, list: @escaping (AirSQLData) -> [SavedConnection]) {
        (self.command, self.empty, self.tip, self.list) = (command, empty, tip, list)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu, from: NSApp.target(forAction: command.action, to: nil, from: nil) as? MainWindowController)
    }

    func fill(_ menu: NSMenu, from main: MainWindowController?) {
        menu.removeAllItems()
        let saved = main.map { list($0.model.data) } ?? []
        for connection in saved {
            let item = command.item()
            item.title = connection.displayName
            item.representedObject = connection.id
            menu.addItem(item)
        }
        guard saved.isEmpty else { return }
        let none = NSMenuItem(title: empty, action: nil, keyEquivalent: "")
        none.isEnabled = false
        none.toolTip = tip
        menu.addItem(none)
    }
}
