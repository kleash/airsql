import AppKit

extension MainMenu {
    /// MongoDB (mongo-plan.md): Data ▸ Collection, what a collection tab and the tree's collections do. Run, Cancel,
    /// Refresh, Load More, Count and the history are the console's and grid's commands under a collection's names (the
    /// same shortcuts, which the menus before this one answer first); SQL's own commands say "Not for MongoDB"
    /// (`NotForMongo`).
    static func addMongoItems(_ menus: Menus) {
        func shared(_ command: Command, _ title: String) -> NSMenuItem {
            let item = command.item()
            item.title = title
            item.target = CollectionMenu.shared
            return item
        }
        menus.data.addItem(.separator())
        menus.data.addItem(submenu("Collection", [
            Commands.openCollection.item(), .separator(), shared(Commands.runStatement, "Run Query"), shared(Commands.cancelQuery, "Cancel"),
            shared(Commands.refresh, "Refresh"), shared(Commands.loadMore, "Load More"), shared(Commands.countRows, "Count Documents Exactly"),
            shared(Commands.history, "Query History"), .separator(), Commands.collectionDocuments.item(), Commands.collectionJSON.item(),
            Commands.collectionSchema.item(), Commands.expandField.item(), .separator(), Commands.copyDocuments.item(),
        ]))
    }
}

/// The target of Data ▸ Collection's items that share their action with SQL's (Run Statement, Cancel…): they reach only
/// the MongoDB collection tab in front, so Run Query never runs a console's SQL.
@MainActor
final class CollectionMenu: NSObject, NSMenuItemValidation {
    static let shared = CollectionMenu()

    private var tab: MongoCollectionController? {
        // The frontmost main window's, as the Window menu finds it (AirSQL needn't be the active app).
        let windows = [NSApp.mainWindow, NSApp.keyWindow].compactMap { $0 } + NSApp.orderedWindows
        let main = windows.lazy.compactMap { $0.windowController as? MainWindowController }.first
        return main?.selectedTab?.shown as? MongoCollectionController
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let tab else {
            item.toolTip = "Open a MongoDB collection first: double-click one in the tree"
            return false
        }
        let enabled = tab.validateMenuItem(item)
        if item.action == Commands.runStatement.action { item.toolTip = "Find the documents the query bar describes" }
        return enabled
    }

    @objc func runStatement(_ sender: Any?) { tab?.runStatement(sender) }
    @objc func cancelQuery(_ sender: Any?) { tab?.cancelQuery(sender) }
    @objc func refresh(_ sender: Any?) { tab?.refresh(sender) }
    @objc func loadMore(_ sender: Any?) { tab?.loadMore(sender) }
    @objc func countRows(_ sender: Any?) { tab?.countRows(sender) }
    @objc func showHistory(_ sender: Any?) { tab?.showHistory(sender) }
}

// MARK: Export and import (lane M5)

extension MainMenu {
    /// Data ▸ Collection ▸ Export Documents… and Import Documents…, which act on the tree's collection or the tab in front.
    static func addMongoTransferItems(_ menus: Menus) {
        guard let collection = menus.data.items.last(where: { $0.title == "Collection" })?.submenu else { return }
        collection.addItem(.separator())
        for command in Commands.mongoTransferCommands {
            let item = command.item()
            item.target = MongoTransferMenu.shared
            collection.addItem(item)
        }
    }
}
