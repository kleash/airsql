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
        databasePopup.addItem(withTitle: "No Database")
        transactionPopup.setAccessibilityIdentifier("toolbar.transactionMode")
        transactionPopup.setAccessibilityLabel("Transaction mode")
        for command in [Commands.autoCommit, Commands.manualCommit] {
            let item = command.item()
            item.title = "Tx: " + command.title
            transactionPopup.menu?.addItem(item)
        }
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
        case .connection: return popupItem(identifier, connectionPopup, label: "Connection", width: (140, 220))
        case .database: return popupItem(identifier, databasePopup, label: "Database", width: (110, 170))
        case .transactionMode: return popupItem(identifier, transactionPopup, label: "Transaction Mode", width: (110, 130))
        case .run: return CommandToolbarItem(identifier, Commands.runStatement, title: "Run", symbol: "play.fill", primary: true,
                                             reason: "Open a console tab to run SQL")
        case .runAll: return CommandToolbarItem(identifier, Commands.runAll, title: "Run All", symbol: "forward.end.fill",
                                                iconOnly: true, reason: "Open a console tab to run SQL")
        case .explain: return CommandToolbarItem(identifier, Commands.explain, title: "Explain", symbol: "list.bullet.indent",
                                                 iconOnly: true, reason: "Open a console tab to explain a statement")
        case .commit: return CommandToolbarItem(identifier, Commands.commit, title: "Commit", symbol: "checkmark.circle",
                                                iconOnly: true, reason: "No transaction is open in this tab")
        case .rollback: return CommandToolbarItem(identifier, Commands.rollback, title: "Rollback",
                                                  symbol: "arrow.uturn.backward.circle", iconOnly: true,
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
            connectionPopup.toolTip = "The connection this window works on: choose another to show it"
        }
        databasePopup.isEnabled = false
        databasePopup.toolTip = active == nil ? "Choose a connection first"
            : model.openConnection(active?.id) == nil ? "Connect to choose the database the console uses"
            : "Change the console's database with USE in the console"
        validateResponders()
        for (popup, item) in popupItems { item.toolTip = popup.toolTip }
    }

    /// What depends on where the focus is (the toolbar validates as it changes): the transaction mode.
    func validateResponders() {
        let canSetMode = NSApp.target(forAction: Commands.autoCommit.action, to: nil, from: transactionPopup) != nil
        transactionPopup.isEnabled = canSetMode
        transactionPopup.toolTip = canSetMode ? Commands.autoCommit.tip : "Open a console tab to choose how it commits"
        popupItems[transactionPopup]?.toolTip = transactionPopup.toolTip
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
/// something in the responder chain handles its action, and then saying why not (`reason`).
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
        let enabled = NSApp.target(forAction: command.action, to: nil, from: button) != nil
        button.isEnabled = enabled
        button.toolTip = enabled ? tip : reason
        isEnabled = enabled
    }
}
