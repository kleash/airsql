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
        addAggregationItems(menus)
        addMongoIndexItems(menus)
        addMongoBulkItems(menus)
        addMongoAdminItems(menus)
    }
}

// MARK: Aggregation (lane M4-app)

extension MainMenu {
    /// Data ▸ Collection ▸ New Aggregation, after Open Collection: for the collection of the tab in front, else the tree's.
    static func addAggregationItems(_ menus: Menus) {
        menus.data.items.last?.submenu?.insertItem(Commands.newAggregation.item(), at: 1)
        addPipelineItems(menus)
    }
}

// MARK: Pipelines (lane P2-aggregate)

extension MainMenu {
    /// Data ▸ Collection's pipeline items after New Aggregation, for the aggregation tab in front; Connection ▸ Open mongosh
    /// in Terminal, for the selected MongoDB connection.
    static func addPipelineItems(_ menus: Menus) {
        guard let collection = menus.data.items.last?.submenu else { return }
        let items = [NSMenuItem.separator()] + [Commands.runToStage, Commands.countStages, Commands.savePipeline, Commands.renamePipeline,
                                                Commands.deletePipeline, Commands.saveAsView].map { $0.item() }
        for (offset, item) in items.enumerated() { collection.insertItem(item, at: 2 + offset) }
        let shell = Commands.openMongosh.item()
        shell.target = MongoShellMenu.shared
        menus.connection.addItem(.separator())
        menus.connection.addItem(shell)
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

// MARK: Editing documents (lane M3-app)

extension MainMenu {
    /// Data ▸ Collection's editing items: Edit Value… and Remove Field, then the grid's commands under a collection's
    /// names, which reach only the collection tab in front (`CollectionMenu`).
    static func addMongoEditItems(_ menus: Menus) {
        guard let collection = menus.data.items.last(where: { $0.title == "Collection" })?.submenu else { return }
        collection.addItem(.separator())
        for command in [Commands.editValue, Commands.removeField] { collection.addItem(command.item()) }
        for command in [Commands.addRow, Commands.duplicateRow, Commands.deleteRows, Commands.revert, Commands.apply] {
            let item = command.item()
            item.title = MongoCollectionController.editingTitles[command.action] ?? command.title
            item.toolTip = MongoCollectionController.editingTips[command.action] ?? command.tip
            item.target = CollectionMenu.shared
            collection.addItem(item)
        }
    }
}

extension CollectionMenu {
    @objc func addRow(_ sender: Any?) { tab?.addRow(sender) }
    @objc func duplicateRow(_ sender: Any?) { tab?.duplicateRow(sender) }
    @objc func deleteRows(_ sender: Any?) { tab?.deleteRows(sender) }
    @objc func revertChanges(_ sender: Any?) { tab?.revertChanges(sender) }
    @objc func applyChanges(_ sender: Any?) { tab?.applyChanges(sender) }
}

// MARK: Indexes (lane M-index)

extension MainMenu {
    /// Data ▸ Collection's index items, after the pages: the Indexes page, then Create, Drop and Hide, for the tab in front
    /// or the tree's collection or index.
    static func addMongoIndexItems(_ menus: Menus) {
        guard let collection = menus.data.items.last(where: { $0.title == "Collection" })?.submenu else { return }
        collection.addItem(.separator())
        for command in Commands.mongoIndexCommands { collection.addItem(command.item()) }
    }
}

// MARK: Update Many and Delete Many (lane P2-bulk)

extension MainMenu {
    /// Data ▸ Collection ▸ Update Many… and Delete Many…, for the collection tab in front (`CollectionMenu`).
    static func addMongoBulkItems(_ menus: Menus) {
        guard let collection = menus.data.items.last(where: { $0.title == "Collection" })?.submenu else { return }
        collection.addItem(.separator())
        for command in Commands.mongoBulkCommands {
            let item = command.item()
            item.target = CollectionMenu.shared
            collection.addItem(item)
        }
    }
}

extension CollectionMenu {
    @objc func updateMany(_ sender: Any?) { tab?.updateMany(sender) }
    @objc func deleteMany(_ sender: Any?) { tab?.deleteMany(sender) }
}

// MARK: Collections, views and databases (lane P2-admin)

extension MainMenu {
    /// Data ▸ Collection's admin items, last: for the tree's database or collection while it has the focus, else the tab
    /// in front (`MongoAdminMenu`).
    static func addMongoAdminItems(_ menus: Menus) {
        guard let collection = menus.data.items.last(where: { $0.title == "Collection" })?.submenu else { return }
        for (index, command) in Commands.mongoAdminCommands.enumerated() {
            if [0, 3, 5].contains(index) { collection.addItem(.separator()) }
            let item = command.item()
            item.target = MongoAdminMenu.shared
            collection.addItem(item)
        }
    }
}
