import AirSQLCore
import AppKit

extension NSToolbarItem.Identifier {
    static let connection = Self("connection")
    static let database = Self("database")
    static let run = Self("run")
    static let runAll = Self("runAll")
    static let explain = Self("explain")
    static let transactionMode = Self("transactionMode")
    static let commit = Self("commit")
    static let rollback = Self("rollback")
    static let cancel = Self("cancel")
}

/// The main window's toolbar (plan §2.4): connection ▾ · database ▾ · Run · Run All · Explain · Tx ▾ · Commit · Rollback ·
/// Cancel. Its buttons send their commands through the responder chain and are enabled only where something can
/// handle them, saying why not when they can't.
@MainActor
final class MainToolbar: NSObject, NSToolbarDelegate {
    let model: AppModel
    weak var main: MainWindowController?
    let connectionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let databasePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let transactionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The pop-ups' toolbar items (a toolbar item's tooltip is its view's).
    private var popupItems: [NSPopUpButton: NSToolbarItem] = [:]

    init(model: AppModel) {
        self.model = model
        super.init()
        connectionPopup.target = self
        connectionPopup.action = #selector(connectionChosen(_:))
        connectionPopup.setAccessibilityIdentifier("toolbar.connection")
        connectionPopup.setAccessibilityLabel("Connection")
        databasePopup.setAccessibilityIdentifier("toolbar.database")
        databasePopup.setAccessibilityLabel("Database")
        transactionPopup.setAccessibilityIdentifier("toolbar.transactionMode")
        transactionPopup.setAccessibilityLabel("Transaction mode")
        // The mode shown is the console's (`validateResponders`); the console ticks its mode and isolation level.
        (transactionPopup.cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false
        for command in [Commands.autoCommit, Commands.manualCommit] {
            let item = command.item()
            transactionPopup.menu?.addItem(item)
        }
        transactionPopup.menu?.addItem(.separator())
        let levels = NSMenuItem(title: "Isolation Level", action: nil, keyEquivalent: "")
        levels.toolTip = Commands.isolation.tip
        transactionPopup.menu?.addItem(levels)
        MainMenu.isolationItems().forEach { transactionPopup.menu?.addItem($0) }
        // The database a double-click in the navigator makes current, and the schema's databases, show at once.
        NotificationCenter.default.addObserver(self, selector: #selector(openConnectionChanged), name: .openConnectionDidChange,
                                               object: nil)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.connection, .database, .space, .run, .runAll, .explain, .space, .transactionMode, .commit, .rollback, .cancel, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        // The customizing sheet shows its own copies: the pop-ups stay in the toolbar.
        case .connection: return popupItem(identifier, flag ? connectionPopup : NSPopUpButton(), label: "Connection", width: (140, 220))
        case .database: return popupItem(identifier, flag ? databasePopup : NSPopUpButton(), label: "Database", width: (110, 170))
        case .transactionMode: return popupItem(identifier, flag ? transactionPopup : NSPopUpButton(), label: "Transaction Mode",
                                                width: (110, 130))
        case .run: return CommandToolbarItem(identifier, Commands.runStatement, title: "Run", symbol: "play.fill", primary: true,
                                             reason: "Open a query tab (⌘T) to run SQL")
        case .runAll: return CommandToolbarItem(identifier, Commands.runAll, title: "Run All", symbol: "play.square.stack",
                                                iconOnly: true, reason: "Open a query tab (⌘T) to run SQL")
        case .explain: return CommandToolbarItem(identifier, Commands.explain, title: "Explain", symbol: "text.magnifyingglass",
                                                 iconOnly: true, reason: "Open a query tab (⌘T) to explain a statement")
        // In words: the riskiest buttons here, and a tick or an arrow reads as OK or Undo.
        case .commit: return CommandToolbarItem(identifier, Commands.commit, title: "Commit", symbol: nil,
                                                reason: "No transaction is open in this tab")
        case .rollback: return CommandToolbarItem(identifier, Commands.rollback, title: "Roll Back", symbol: nil,
                                                  reason: "No transaction is open in this tab")
        case .cancel: return CommandToolbarItem(identifier, Commands.cancelQuery, title: "Cancel", symbol: "stop.fill",
                                                iconOnly: true, reason: "Nothing is running in this tab")
        default: return nil
        }
    }

    private func popupItem(_ identifier: NSToolbarItem.Identifier, _ popup: NSPopUpButton, label: String,
                           width: (CGFloat, CGFloat)) -> NSToolbarItem {
        let item = PopupToolbarItem(itemIdentifier: identifier)
        item.view = popup
        item.label = label
        item.paletteLabel = label
        item.owner = self
        popupItems[popup] = item
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: width.0).isActive = true
        popup.widthAnchor.constraint(lessThanOrEqualToConstant: width.1).isActive = true
        update()
        return item
    }

    /// Brings the pop-ups up to date: the connections (the active one chosen), the database, the transaction mode.
    func update() {
        let active = main?.activeConnection
        connectionPopup.removeAllItems()
        if model.data.connections.isEmpty {
            connectionPopup.addItem(withTitle: "No Connections")
            connectionPopup.isEnabled = false
            connectionPopup.toolTip = "Add a connection first (File ▸ New Connection…)"
        } else {
            if active == nil { connectionPopup.addItem(withTitle: "Choose a Connection") }
            let sorted = model.data.connections.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            for connection in sorted {
                let item = NSMenuItem(title: connection.displayName, action: nil, keyEquivalent: "")
                item.representedObject = connection.id
                item.image = connection.colour.color.map(ConnectionMenus.dotImage)
                item.toolTip = "Show “\(connection.displayName)”"
                connectionPopup.menu?.addItem(item)
                if connection.id == active?.id { connectionPopup.select(item) }
            }
            connectionPopup.isEnabled = true
            connectionPopup.toolTip = "Choose the connection this window works on"
        }
        let open = model.openConnection(active?.id)
        // The cached databases (the current one too, when the list leaves it out), the current one chosen.
        let names = open?.snapshot.databases.map(\.name) ?? []
        let current = open?.currentDatabase ?? "No Database"
        let titles = names.contains(current) ? names : [current] + names
        if databasePopup.itemTitles != titles {
            databasePopup.removeAllItems()
            for title in titles {
                let item = NSMenuItem(title: title, action: names.contains(title) ? #selector(databaseChosen(_:)) : nil, keyEquivalent: "")
                item.target = self
                item.toolTip = names.contains(title) ? "Run this query tab's statements in \(title) from now on"
                    : "Not one of the databases listed: choose one"
                databasePopup.menu?.addItem(item)
            }
        }
        databasePopup.selectItem(withTitle: current)
        databasePopup.isEnabled = !names.isEmpty
        databasePopup.toolTip = active == nil ? "Choose a connection first"
            : open == nil ? "Connect first: the list shows the server's databases"
            : open?.snapshot.databases.isEmpty != false ? "No databases to choose: the schema is loading, or none can be shown"
            : "Choose the database this query tab's statements run in (USE); the sidebar shows it in bold"
        validateResponders()
        for (popup, item) in popupItems { item.toolTip = popup.toolTip }
    }

    /// What depends on where the focus is (the toolbar validates as it changes): the shown console's transaction mode,
    /// asked as the menu bar asks (the console ticks its mode and isolation level, or says why they can't change).
    func validateResponders() {
        let manual = Commands.manualCommit.item()
        let (canSetMode, why) = Commands.manualCommit.availability(from: transactionPopup, item: manual,
                                                                   otherwise: "Open a query tab (⌘T) to choose how it commits")
        transactionPopup.selectItem(at: manual.state == .on ? 1 : 0)
        transactionPopup.isEnabled = canSetMode
        transactionPopup.toolTip = canSetMode ? "Choose Auto-commit or Manual, and how this query tab's transactions see others' "
            + "changes (the isolation level)" : why
        popupItems[transactionPopup]?.toolTip = transactionPopup.toolTip
    }

    @objc private func openConnectionChanged() { update() }

    /// Makes the database chosen current for the connection: the navigator shows it in bold, and its consoles USE it
    /// before their next statement (`ConsoleViewController.perform`).
    @objc private func databaseChosen(_ sender: Any?) {
        guard let database = (sender as? NSMenuItem ?? (sender as? NSPopUpButton)?.selectedItem)?.title else { return }
        model.openConnection(main?.activeConnection?.id)?.currentDatabase = database
    }

    @objc private func connectionChosen(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? UUID, let main else { return }
        main.sidebar.select([id])
        main.refresh()
    }
}

/// A pop-up in the toolbar: what depends on the focus is brought up to date as the toolbar validates.
final class PopupToolbarItem: NSToolbarItem {
    weak var owner: MainToolbar?

    override func validate() {
        owner?.validateResponders()
    }
}

/// A command's button in the toolbar: its symbol and title, its tooltip (with its shortcut), enabled only while
/// something in the responder chain can do it now, as its menu item would be, and otherwise saying why not (the
/// handler's reason, else `reason`).
final class CommandToolbarItem: NSToolbarItem {
    let command: Command
    let reason: String
    private let button: NSButton

    init(_ identifier: NSToolbarItem.Identifier, _ command: Command, title: String, symbol: String?, primary: Bool = false,
         iconOnly: Bool = false, reason: String) {
        self.command = command
        self.reason = reason
        button = NSButton(title: title, target: nil, action: command.action)
        super.init(itemIdentifier: identifier)
        button.bezelStyle = .texturedRounded
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            button.imagePosition = iconOnly ? .imageOnly : .imageLeading
        }
        button.setAccessibilityLabel(title)
        if primary { button.bezelColor = .accent }
        button.setAccessibilityIdentifier("toolbar." + identifier.rawValue)
        button.tag = command.tag
        view = button
        label = title
        paletteLabel = title
        toolTip = tip
        button.toolTip = tip
    }

    private var tip: String {
        command.tip + (command.shortcut.isEmpty ? "" : " (\(command.shortcut))")
    }

    override func validate() {
        let (enabled, why) = command.availability(from: button, otherwise: reason)
        button.isEnabled = enabled
        button.toolTip = enabled ? tip : why
        // The item's own tooltip too: AppKit gives it to the button as its accessibility help (what VoiceOver reads).
        if toolTip != button.toolTip { toolTip = button.toolTip }
        isEnabled = enabled
    }
}

extension Command {
    /// Whether the responder chain (from `sender`) can do the command now, asked as the menu bar asks its item (the
    /// target's validateMenuItem or validateUserInterfaceItem), and why not: the target's reason, else `otherwise`.
    /// `item`: the menu item to ask with (its state is what the target ticks), else a new one.
    @MainActor
    func availability(from sender: Any?, item probe: NSMenuItem? = nil, otherwise: String) -> (Bool, String) {
        guard let target = NSApp.target(forAction: action, to: nil, from: sender) else { return (false, otherwise) }
        let probe = probe ?? item()
        let enabled = (target as? NSMenuItemValidation)?.validateMenuItem(probe)
            ?? (target as? NSUserInterfaceValidations)?.validateUserInterfaceItem(probe) ?? true
        return (enabled, enabled || probe.toolTip == tip ? otherwise : probe.toolTip ?? otherwise)
    }
}
