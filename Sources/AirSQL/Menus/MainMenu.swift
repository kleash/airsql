import AirSQLCore
import AppKit

/// The menu bar (plan §2.4): the menus in their fixed order, P0's own items, then each lane's items from its
/// `Menus+<Lane>.swift`. Items come from `Commands`, so the shortcut, tooltip and action are the same wherever a command
/// appears. A menu that no lane has filled yet is hidden.
@MainActor
enum MainMenu {
    /// The menus, for the lanes' slot functions to add their items to.
    struct Menus {
        let app = NSMenu(title: "AirSQL")
        let file = NSMenu(title: "File")
        let edit = NSMenu(title: "Edit")
        let view = NSMenu(title: "View")
        let query = NSMenu(title: "Query")
        let data = NSMenu(title: "Data")
        let database = NSMenu(title: "Database")
        let connection = NSMenu(title: "Connection")
        let tools = NSMenu(title: "Tools")
        let window = NSMenu(title: "Window")
        let help = NSMenu(title: "Help")

        var inOrder: [NSMenu] { [app, file, edit, view, query, data, database, connection, tools, window, help] }
    }

    /// A submenu item: `title`'s tip from `Commands.submenus`, the items given.
    static func submenu(_ title: String, _ items: [NSMenuItem], delegate: NSMenuDelegate? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        menu.delegate = delegate
        item.submenu = menu
        item.toolTip = Commands.submenus[title]
        return item
    }

    /// The menu bar.
    static func build() -> NSMenu {
        let menus = Menus()
        let services = submenu("Services", [])
        NSApp.servicesMenu = services.submenu
        menus.app.add([Commands.about, nil, Commands.settings, nil])
        menus.app.addItem(services)
        menus.app.add([nil, Commands.hide, Commands.hideOthers, Commands.showAll, nil, Commands.quit])

        menus.file.add([Commands.newConnection, Commands.newQuery, Commands.quickOpen, nil, Commands.closeTab, Commands.closeOtherTabs,
                        Commands.closeAllTabs, Commands.reopenClosedTab, Commands.closeWindow, nil, Commands.duplicateTab, Commands.renameTab, Commands.renameF2,
                        Commands.revealInFinder])

        menus.edit.add([Commands.undo, Commands.redo, nil, Commands.cut, Commands.copy, Commands.paste, Commands.pastePlain, Commands.delete,
                        Commands.selectAll, nil])
        menus.edit.addItem(submenu("Find", [Commands.find, Commands.findAndReplace, Commands.findNext, Commands.findPrevious,
                                            Commands.useSelectionForFind].map { $0.item() }))

        menus.view.add([Commands.toggleSidebar, Commands.filterSidebar, Commands.selectInTree])
        menus.view.addItem(submenu("Focus", [Commands.focusSidebar, Commands.focusEditor, Commands.focusResults].map { $0.item() }))
        menus.view.add([nil, Commands.sqlLog, Commands.clearSQLLog, Commands.activity, Commands.cancelAll, nil, Commands.refresh])

        menus.query.add([Commands.runStatement, Commands.runAll, Commands.runAllF9, Commands.runStatementF9, Commands.explain,
                         Commands.cancelQuery, nil, Commands.commit, Commands.rollback])
        menus.query.addItem(submenu("Transaction Mode", [Commands.autoCommit.item(), Commands.manualCommit.item()]))
        menus.query.add([nil, Commands.changeConnection])

        let colours = ConnectionMenus.colourMenu()
        menus.connection.add([Commands.connect, Commands.disconnect, nil, Commands.editConnection, Commands.duplicateConnection])
        menus.connection.addItem(colours)
        menus.connection.add([Commands.deleteConnection])

        menus.tools.add([Commands.openInTerminal, Commands.export, Commands.restore, nil, Commands.compare, nil])
        menus.tools.addItem(submenu("Agents", [Commands.setUpAgents.item(), Commands.agentActivity.item(),
                                               Commands.turnAgentsOff.item()]))

        menus.window.add([Commands.minimize, Commands.zoom, nil, Commands.previousTab, Commands.nextTab, Commands.previousTabControl,
                          Commands.nextTabControl, nil])
        for number in 1...9 {
            let item = Commands.tab(number).item()
            item.isHidden = true  // shown with the tab's title while there is such a tab (`menuNeedsUpdate`)
            item.allowsKeyEquivalentWhenHidden = true
            menus.window.addItem(item)
        }
        menus.window.add([nil, Commands.mainWindow, Commands.bringAllToFront])
        menus.window.delegate = WindowMenu.shared
        NSApp.windowsMenu = menus.window

        // No ⌘?: macOS keeps it for the Help menu's search field.
        menus.help.add([Commands.help, Commands.offlineHelp, Commands.gettingStarted, Commands.shortcuts, Commands.releaseNotes, nil,
                        Commands.reportProblem, Commands.copyDiagnostics])
        NSApp.helpMenu = menus.help

        // The lanes' items (plan §2.4: each lane adds its own in its Menus+<Lane>.swift).
        addConnectionItems(menus)
        addGridItems(menus)
        addConsoleItems(menus)
        addSQLEditorItems(menus)
        addNavigatorItems(menus)
        addEditorItems(menus)
        addToolItems(menus)
        addAgentItems(menus)
        addReconItems(menus)
        addWorkspaceItems(menus)
        addMongoItems(menus)
        addMongoEditItems(menus)

        // Last in View, as on every Mac.
        menus.view.add([nil, Commands.customizeToolbar, Commands.fullScreen])

        let bar = NSMenu()
        for menu in menus.inOrder {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            item.isHidden = menu.items.isEmpty
            bar.addItem(item)
            OffReasons.watch(menu)
        }
        return bar
    }
}

/// Says why a menu item is off when nothing where the focus is answers it. AppKit then greys the item without asking
/// any validator, so its tooltip would stay "what it does" (or a closed tab's reason).
@MainActor
final class OffReasons: NSObject, NSMenuDelegate {
    static let shared = OffReasons()

    /// By the menu bar's menu the item is in.
    private static let reasons = [
        "File": "Open a tab first: double-click a connection, or press ⌘T in one",
        "Edit": "Click in a grid, an editor or a list first",
        "View": "Open a tab with a grid or a query first",
        "Query": "Open a query tab first: File ▸ New Query (⌘T)",
        "Data": "Open a table or a query's result first",
        "Database": "Connect, then select a database or table in the sidebar",
        "Connection": "Select a connection in the sidebar first",
        "Tools": "Select a connection in the sidebar first",
    ]
    private static let inCompare: Set<Selector> = [Commands.syncScript.action, Commands.exportReport.action,
                                                   Commands.copySyncScript.action, Commands.leaveOutOfCompare.action,
                                                   Commands.includeInSync.action, Commands.backToServer.action,
                                                   Commands.nextDifference.action, Commands.previousDifference.action]
    private static let inLists: [Selector: String] = [
        Commands.diskUsageUp.action: "Open Tools ▸ Disk Usage first", Commands.diskUsageCompare.action: "Open Tools ▸ Disk Usage first",
        Commands.copyList.action: "Open Disk Usage or Server Home first", Commands.exportList.action: "Open Disk Usage or Server Home first",
        Commands.editVariable.action: "Open Database ▸ Server ▸ Server Home ▸ Variables first",
        Commands.newUser.action: "Open Database ▸ Users ▸ Users and Roles first", Commands.newRole.action: "Open Database ▸ Users ▸ Users and Roles first",
        Commands.editUser.action: "Open Database ▸ Users ▸ Users and Roles first", Commands.cloneUser.action: "Open Database ▸ Users ▸ Users and Roles first",
        Commands.dropUser.action: "Open Database ▸ Users ▸ Users and Roles first",
    ]

    /// Tells `menu` and its submenus, but not those that make their own items, or the system's.
    static func watch(_ menu: NSMenu) {
        menu.delegate = menu.delegate ?? shared
        for submenu in menu.items.compactMap(\.submenu) where submenu.delegate == nil && submenu !== NSApp.servicesMenu {
            watch(submenu)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.update()
        var top = menu
        while let parent = top.supermenu, parent.supermenu != nil { top = parent }
        for item in menu.items where !item.isEnabled {
            guard let action = item.action, NSApp.target(forAction: action, to: item.target, from: item) == nil else { continue }
            if NotForMongo.applies(item, (NSApp.mainWindow?.windowController as? MainWindowController)?.activeConnection) { continue }
            let reason = Self.inCompare.contains(action) ? "Open Tools ▸ Compare… first" : Self.inLists[action] ?? Self.reasons[top.title]
            item.toolTip = reason ?? Commands.tip(for: item)
        }
    }
}

/// SQL's commands, off for a MongoDB tab or connection (mongo-plan.md, decision 4). The validators that answer for a
/// connection ask it first: the main window, the sidebar and the tools; `OffReasons` when nothing answers.
@MainActor
enum NotForMongo {
    static let reason = "Not for MongoDB"
    /// The menu bar's menus that are all SQL or MySQL's tools, but for Tools ▸ Agents.
    private static let menus: Set<String> = ["Query", "Database", "Tools"]
    /// SQL's commands elsewhere: in the File menu and the sidebar's menu.
    private static let actions = Set([Commands.newQuery, Commands.sessions, Commands.openInTerminal, Commands.export, Commands.restore,
                                      Commands.compare, Commands.compareWith, Commands.compareRows, Commands.diskUsage, Commands.users,
                                      Commands.databasesShown].map(\.action))

    /// Whether `item` is SQL's and `connection` (the tab's, else the one selected) is MongoDB's; it then says so.
    static func applies(_ item: NSMenuItem, _ connection: SavedConnection?) -> Bool {
        guard connection?.engine == .mongodb, let action = item.action, item.menu?.title != "Agents" else { return false }
        var top = item.menu
        while let parent = top?.supermenu, parent.supermenu != nil { top = parent }
        guard actions.contains(action) || menus.contains(top?.title ?? "") else { return false }
        item.explain(enabled: false, reason: reason)
        return true
    }
}

extension NSMenu {
    /// Adds the commands' items in order; nil is a separator.
    func add(_ commands: [Command?]) {
        for command in commands { addItem(command?.item() ?? .separator()) }
    }
}

/// The Window menu's tabs (⌘1…⌘9), named after the tabs of the frontmost main window as the menu opens.
@MainActor
final class WindowMenu: NSObject, NSMenuDelegate {
    static let shared = WindowMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        let windows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
        let main = windows.lazy.compactMap { $0.windowController as? MainWindowController }.first
        main?.updateWindowMenu(menu)
    }

    func menuWillOpen(_ menu: NSMenu) { OffReasons.shared.menuWillOpen(menu) }
}

/// The Colour menu of a connection (the menu bar's and the sidebar's): None, then each colour with its dot.
@MainActor
enum ConnectionMenus {
    static func colourMenu() -> NSMenuItem {
        let items = ConnectionColour.allCases.map { colour -> NSMenuItem in
            let item = Commands.colour.item()
            item.title = colour.title
            item.representedObject = colour.rawValue
            item.image = colour.color.map { dotImage($0) }
            return item
        }
        return MainMenu.submenu("Colour", items)
    }

    static func moveMenu() -> NSMenuItem {
        MainMenu.submenu("Move to Folder", [], delegate: MoveToFolderMenu.shared)
    }

    /// An 8 pt dot of `color` for a menu item.
    static func dotImage(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

/// Connection ▸ Move to Folder: the folders, made as the menu opens.
@MainActor
final class MoveToFolderMenu: NSObject, NSMenuDelegate {
    static let shared = MoveToFolderMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(Commands.moveToFolder.item())
        let main = NSApp.target(forAction: Commands.moveToFolder.action, to: nil, from: nil) as? MainWindowController
        for folder in main?.model.data.folders.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) ?? [] {
            let item = Commands.moveToFolder.item()
            item.title = folder.name
            item.representedObject = folder.id
            menu.addItem(item)
        }
        menu.add([nil, Commands.newFolder])
    }
}
