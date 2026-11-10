import AirSQLCore
import AppKit

/// A row of a MongoDB connection's tree: a database, a collection (with the database), or an index (with both).
struct MongoTreeItem: Hashable {
    var database: String
    var collection: String?
    var index: String?
}

/// A MongoDB connection's tree in the sidebar (mongo-plan, Tree): its databases (their sizes from dbStats once opened),
/// their collections, views and time-series (marked; views and time-series are read-only), and a collection's indexes,
/// each read on the main session the first time its row opens. A click shows a collection in the preview tab, a
/// double-click opens it in a tab of its own, a right-click opens the row's menu.
extension SidebarController {
    func mongoTree(_ mongo: OpenMongoConnection, matching text: String, node: (SidebarNode.Kind) -> SidebarNode) -> [SidebarNode] {
        let id = mongo.saved.id
        guard let databases = mongo.databases else {
            if !text.isEmpty { return [] }
            return [node(.message(id, mongo.loadErrors[""].map { "Couldn't read the databases: " + $0 } ?? "Loading the databases…"))]
        }
        let names = NameFilter(text)
        // A message is its own row each time: the same words under two databases are two rows.
        func message(_ words: String) -> SidebarNode { SidebarNode(.message(id, words)) }
        let rows = databases.compactMap { database -> SidebarNode? in
            let all = text.isEmpty || names.matches(database.name)
            let row = node(.mongo(id, MongoTreeItem(database: database.name)))
            guard let found = mongo.collections[database.name] else {
                guard all else { return nil }
                row.children = [message(mongo.loadErrors[database.name].map { "Couldn't read the collections: " + $0 } ?? "Loading the collections…")]
                return row
            }
            let shown = found.filter { all || names.matches($0.name) }
            guard all || !shown.isEmpty else { return nil }
            row.children = shown.map { info in
                let key = database.name + "." + info.name
                let collection = node(.mongo(id, MongoTreeItem(database: database.name, collection: info.name)))
                if info.kind == .view {
                    collection.children = []
                } else if let indexes = mongo.indexes[key] {
                    collection.children = indexes.compactMap { index in
                        guard case .string(let name)? = index["name"] else { return nil }
                        return node(.mongo(id, MongoTreeItem(database: database.name, collection: info.name, index: name)))
                    }
                } else {
                    collection.children = [message(mongo.loadErrors[key].map { "Couldn't read the indexes: " + $0 } ?? "Loading the indexes…")]
                }
                return collection
            }
            if row.children.isEmpty { row.children = [message("No collections yet")] }
            return row
        }
        if rows.isEmpty, text.isEmpty { return [message("No databases: create one with a tool such as mongosh")] }
        return rows
    }

    /// A row opened: reads what is under it, once.
    func mongoOpened(_ id: UUID, _ item: MongoTreeItem) {
        guard let mongo = model.openMongo[id], item.index == nil else { return }
        if let collection = item.collection { mongo.loadIndexes(item.database, collection) } else { mongo.loadDatabase(item.database) }
    }

    /// The collection's description from listCollections, as the tree last read it.
    func mongoInfo(_ id: UUID, _ item: MongoTreeItem) -> MongoCollectionInfo? {
        model.openMongo[id]?.collections[item.database]?.first { $0.name == item.collection }
    }

    func showMongo(_ item: MongoTreeItem, of mongo: OpenMongoConnection, in cell: TreeCell) {
        if let index = item.index, let collection = item.collection {
            let info = mongo.indexes[item.database + "." + collection]?.first { $0["name"] == .string(index) }
            let keys = info?["key"]?.shellForm() ?? ""
            let unique = info?["unique"] == .bool(true)
            cell.show(TreeIcon.image("I", 0x2E9E5B), index, count: keys, countGivesWay: true, busy: false,
                      tip: "\(index), an index of \(collection) on \(keys)\(unique ? ", unique" : ""): double-click to see it with its "
                        + "size and use, right-click to drop or hide it")
        } else if let collection = item.collection {
            let info = mongoInfo(mongo.saved.id, item)
            let kind = info?.kind ?? .collection
            let (letters, colour, noun): (String, UInt32, String) = switch kind {
            case .collection: ("C", 0x3A7BD9, "a collection")
            case .view: ("V", 0x8A4BAF, "a view, read-only")
            case .timeseries: ("TS", 0x0A7F91, "a time-series collection, read-only")
            }
            let busy = mongo.loading.contains(item.database + "." + collection)
            cell.show(TreeIcon.image(letters, colour), collection, count: "", busy: busy, comment: kind == .collection ? "" : "read-only",
                      tip: "\(collection), \(noun): click to see its documents, double-click to open them in a tab, right-click for more"
                        + (kind == .view ? "" : ", its arrow shows its indexes"))
        } else {
            let stats = mongo.stats[item.database]
            let size = stats.flatMap { $0["totalSize"]?.integer ?? (($0["storageSize"]?.integer ?? 0) + ($0["indexSize"]?.integer ?? 0)) }
            let collections = mongo.collections[item.database]?.count
            let own = OpenMongoConnection.isInternal(item.database)
            cell.show(TreeIcon.database, item.database, count: size.map { shortSize(Int($0)) } ?? collections.map(String.init) ?? "",
                      busy: mongo.loading.contains(item.database), quiet: own,
                      tip: "\(item.database)" + (own ? ", MongoDB's own database" : "") + (size.map { ", " + shortSize(Int($0)) + " on disk with its indexes" } ?? "")
                        + (collections.map { ", \($0) collection\($0 == 1 ? "" : "s") and views" } ?? "")
                        + ": double-click or click its arrow to see its collections, right-click for more")
        }
    }

    /// The selected rows of one MongoDB connection's tree.
    var mongoSelection: (open: OpenMongoConnection, items: [MongoTreeItem])? {
        var id: UUID?
        let items = selectedNodes.compactMap { node -> MongoTreeItem? in
            guard case .mongo(let row, let item) = node.kind, id == nil || id == row else { return nil }
            id = row
            return item
        }
        guard let id, let open = model.openMongo[id], items.count == selectedNodes.count else { return nil }
        return (open, items)
    }

    private var selectedCollections: [MongoTreeItem] {
        (mongoSelection?.items ?? []).filter { $0.collection != nil && $0.index == nil }
    }

    /// A click on a collection shows its documents in the preview tab; true when the selection is MongoDB's.
    func showMongoSelection() -> Bool {
        guard let (open, items) = mongoSelection else { return false }
        if let main, items.count == 1, let collection = items[0].collection, items[0].index == nil {
            let item = items[0]
            main.preview(MongoCollectionController(model: model, connection: open.saved.id, database: item.database,
                                                   collection: mongoInfo(open.saved.id, item) ?? MongoCollectionInfo(name: collection, kind: .collection)),
                         title: collection, connection: open.saved.id)
        }
        return true
    }

    /// A double-click opens or closes a database, opens a collection in a tab of its own (in place of its preview), and
    /// an index on its collection tab's Indexes page.
    func mongoDoubleClicked(_ node: SidebarNode, _ item: MongoTreeItem) {
        if item.collection == nil {
            if outline.isItemExpanded(node) { gently(outline).collapseItem(node) } else { gently(outline).expandItem(node) }
        } else if item.index == nil {
            openCollection(nil)
        } else {
            _ = indexesTab()
        }
    }

    static func mongoMenu(_ item: MongoTreeItem) -> [Command?] {
        if item.index != nil { return [Commands.collectionIndexes, Commands.copyName, nil, Commands.hideIndex, Commands.dropIndex, nil, Commands.refresh] }
        if item.collection != nil {
            return [Commands.openCollection, Commands.newAggregation, Commands.collectionSchema, Commands.collectionIndexes, Commands.copyName,
                    nil, Commands.createIndex, Commands.compareCollection, nil, Commands.refresh]
        }
        return [Commands.copyName, nil, Commands.refresh]
    }

    /// Open Collection: each selected collection in its own tab; the preview of the same collection goes.
    @objc func openCollection(_ sender: Any?) {
        guard let main, let open = mongoSelection?.open else { return }
        for item in selectedCollections {
            guard let collection = item.collection else { continue }
            let preview = main.tabs.first {
                ($0.content as? PreviewContent)?.shown is MongoCollectionController && $0.tabContent?.isEdited == false
                    && $0.title == collection && $0.connectionID == open.saved.id
            }
            main.openCollection(mongoInfo(open.saved.id, item) ?? MongoCollectionInfo(name: collection, kind: .collection),
                                database: item.database, connection: open.saved.id)
            if let preview { main.close(preview) }
        }
    }

    /// Schema or Indexes from the tree: the collection's tab on that page.
    @objc func showCollectionPage(_ sender: Any?) {
        if (sender as? NSMenuItem)?.tag == MongoCollectionController.Page.indexes.rawValue {
            _ = indexesTab()
            return
        }
        openCollection(sender)
        guard let tag = (sender as? NSMenuItem)?.tag, let page = MongoCollectionController.Page(rawValue: tag),
              let content = main?.selectedTab?.content as? MongoCollectionController else { return }
        content.show(page)
    }

    // MARK: Indexes

    /// The selected collection's or index's tab, on its Indexes page with the index selected; the tab does the index
    /// commands, so the tree's run exactly as the page's.
    private func indexesTab() -> (tab: MongoCollectionController, index: MongoIndex?)? {
        guard let main, let (open, items) = mongoSelection, items.count == 1, let collection = items[0].collection else { return nil }
        let item = items[0]
        main.openCollection(mongoInfo(open.saved.id, item) ?? MongoCollectionInfo(name: collection, kind: .collection),
                            database: item.database, connection: open.saved.id)
        guard let tab = main.selectedTab?.content as? MongoCollectionController else { return nil }
        tab.indexesView.wanted = item.index
        tab.show(.indexes)
        return (tab, selectedIndex)
    }

    /// The selected index row, as the tree last read it.
    private var selectedIndex: MongoIndex? {
        guard let (open, items) = mongoSelection, items.count == 1, let collection = items[0].collection, let name = items[0].index else { return nil }
        return open.indexes[items[0].database + "." + collection]?.first { $0["name"] == .string(name) }.map(MongoIndex.init)
    }

    @objc func createIndex(_ sender: Any?) { indexesTab()?.tab.createIndex(sender) }

    @objc func dropIndex(_ sender: Any?) {
        guard let (tab, index) = indexesTab(), let index else { return NSSound.beep() }
        tab.drop(index)
    }

    @objc func toggleIndexHidden(_ sender: Any?) {
        guard let (tab, index) = indexesTab(), let index else { return NSSound.beep() }
        tab.setHidden(index)
    }

    /// Refresh on MongoDB rows or connections: what is under them is read again. False when the selection isn't MongoDB's.
    func refreshMongo() -> Bool {
        if let (open, items) = mongoSelection {
            for item in items {
                if let collection = item.collection { open.loadIndexes(item.database, collection, again: true) } else { open.refresh(item.database) }
            }
            return true
        }
        let connected = selectedConnectionIDs.compactMap { model.openMongo[$0] }
        connected.forEach { $0.refresh() }
        return !connected.isEmpty
    }

    /// The tree's MongoDB commands; nil when the item isn't one of them here.
    func validateMongo(_ item: NSMenuItem) -> Bool? {
        let mongo = mongoSelection != nil
        let reason: String?
        switch item.action {
        case Commands.collectionSchema.action? where item.tag == MongoCollectionController.Page.indexes.rawValue:
            reason = mongoSelection?.items.count == 1 && mongoSelection?.items[0].collection != nil ? nil
                : "Select one collection or index of a connected MongoDB server in the tree first"
        case Commands.compareCollection.action?:
            reason = mongoSelection?.items.count == 1 && selectedCollections.count == 1 ? nil
                : "Select one collection of a connected MongoDB server in the tree first"
        case Commands.openCollection.action?, Commands.collectionSchema.action?:
            reason = selectedCollections.isEmpty ? "Select a collection of a connected MongoDB server in the tree first" : nil
        case Commands.createIndex.action?:
            if let (open, items) = mongoSelection, items.count == 1, items[0].collection != nil {
                reason = MongoCollectionController.indexesOff(model.connection(open.saved.id), mongoInfo(open.saved.id, items[0])?.kind ?? .collection)
            } else {
                reason = "Select one collection of a connected MongoDB server in the tree first"
            }
        case Commands.dropIndex.action?, Commands.hideIndex.action?:
            let hide = item.action == Commands.hideIndex.action, index = selectedIndex
            if hide { item.title = index?.isHidden == true ? "Unhide Index…" : Commands.hideIndex.title }
            if let (open, items) = mongoSelection, index != nil {
                reason = MongoCollectionController.indexesOff(model.connection(open.saved.id), mongoInfo(open.saved.id, items[0])?.kind ?? .collection)
                    ?? MongoCollectionController.whyNot(index, hide: hide)
            } else {
                reason = "Select one index of a connected MongoDB server in the tree first"
            }
        case Commands.refresh.action? where mongo || selectedConnectionIDs.contains { model.openMongo[$0] != nil }:
            reason = nil
        case Commands.copyName.action? where mongo, Commands.copy.action? where mongo:
            reason = nil
        default:
            return nil
        }
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }
}

extension MainWindowController {
    /// A collection's documents in a tab: the tab it has already, or a new one.
    func openCollection(_ info: MongoCollectionInfo, database: String, connection: UUID) {
        if let tab = tabs.first(where: { ($0.content as? MongoCollectionController)?.shows(connection, database, info.name) == true }) {
            return select(tab)
        }
        let content = MongoCollectionController(model: model, connection: connection, database: database, collection: info)
        open(content, title: info.name, connection: connection)
        window?.makeFirstResponder(content.grid)
    }
}
