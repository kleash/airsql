import AppKit

extension MainMenu {
    /// The workspace's items.
    static func addWorkspaceItems(_ menus: Menus) {
        menus.window.add([nil, Commands.pinTab, Commands.moveTabToNewWindow, Commands.moveTabToNextWindow])
        menus.file.add([nil, Commands.newWindow, Commands.newScratch, Commands.attachFolder, nil, Commands.consoleList, Commands.defaultConsole])
        menus.edit.addItem(submenu("Bookmarks", [Commands.toggleBookmark, Commands.nextBookmark, Commands.previousBookmark].map { $0.item() }))
        menus.query.addItem(submenu("Ask an Agent", [Commands.askAgent, Commands.askAgentFix, Commands.askAgentOptimise, Commands.askAgentWrite].map { $0.item() }))
        menus.view.add([nil, Commands.filesPanel, Commands.splitRight, Commands.otherPane])
    }
}
