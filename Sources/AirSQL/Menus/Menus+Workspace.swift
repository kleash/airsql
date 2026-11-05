import AppKit

extension MainMenu {
    /// The workspace's items.
    static func addWorkspaceItems(_ menus: Menus) {
        menus.file.add([nil, Commands.newScratch, Commands.attachFolder, nil, Commands.consoleList, Commands.defaultConsole])
        menus.view.add([nil, Commands.filesPanel])
    }
}
