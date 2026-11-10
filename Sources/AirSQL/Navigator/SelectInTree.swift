import AirSQLCore
import AppKit

extension Tab {
    /// The tree's row of what the tab shows, on a connected connection (a console has `SelectInTree.row(of:)`).
    func treeRow(in open: OpenConnection) -> SidebarNode.Kind {
        if let view = shown as? DatabaseViewController { return .database(open.id, view.database) }
        guard let place, let database = place.database, let name = place.object else { return .connection(open.id) }
        // A table tab's place doesn't say table or view; a routine may share a table's name.
        var kind = DatabaseObject.Kind(rawValue: place.kind.rawValue) ?? .table
        if kind == .table, let table = open.snapshot.table(database, name) { kind = DatabaseObject.Kind(rawValue: table.kind.rawValue) ?? .table }
        return .object(open.id, DatabaseObject(kind, database, name))
    }

    /// A MongoDB collection or aggregation tab's collection in the tree.
    var mongoTreeItem: MongoTreeItem? {
        if let collection = shown as? MongoCollectionController { return MongoTreeItem(database: collection.database, collection: collection.name) }
        if let aggregation = shown as? MongoAggregationController {
            return MongoTreeItem(database: aggregation.database, collection: aggregation.collection)
        }
        return nil
    }
}

extension MainWindowController {
    /// Select in Tree: the tab's table or object; in a query tab, the name at the cursor, else the tab's database.
    @objc func selectInTree(_ sender: Any?) {
        if let id = selectedTab?.connectionID, let mongo = model.openMongo[id] {
            guard let item = selectedTab?.mongoTreeItem else { return reveal(.connection(id), sender) }
            // Its database's collections may not be read yet: the database then, which reads them as it opens.
            mongo.loadDatabase(item.database)
            if sidebar.reveal(.mongo(id, item)) { return focusSidebar(sender) }
            return reveal(.mongo(id, MongoTreeItem(database: item.database)), sender)
        }
        guard let tab = selectedTab, let open = model.openConnection(tab.connectionID) else { return }
        guard let console = tab.shown as? ConsoleViewController else {
            return reveal(tab.treeRow(in: open), sender)
        }
        console.editor.withInsight { [weak self] analysis in
            let symbol = analysis.reference(at: console.editor.selectedRange().location)?.symbol
            self?.reveal(Self.treeRow(of: symbol, in: open) ?? (console.chosenDatabase ?? open.currentDatabase).map { .database(open.id, $0) } ?? .connection(open.id), sender)
        }
    }

    /// Favourites Only, the database filter or View ▸ Tree can leave the row out.
    private func reveal(_ row: SidebarNode.Kind, _ sender: Any?) {
        if sidebar.reveal(row) { focusSidebar(sender) } else { NSSound.beep() }
    }

    /// The tree's row of a name in SQL: a column's is its table's.
    private static func treeRow(of symbol: SQLSymbol?, in open: OpenConnection) -> SidebarNode.Kind? {
        guard let symbol else { return nil }
        if symbol.kind == .database { return .database(open.id, symbol.name) }
        return open.object(of: symbol).map { .object(open.id, $0) }
    }
}

extension OpenConnection {
    /// The table, view or routine a name in SQL means: a column's table.
    func object(of symbol: SQLSymbol) -> DatabaseObject? {
        guard let database = symbol.database else { return nil }
        switch symbol.kind {
        case .table, .column:
            let name = symbol.table ?? symbol.name
            guard let table = snapshot.table(database, name), let kind = DatabaseObject.Kind(rawValue: table.kind.rawValue) else { return nil }
            return DatabaseObject(kind, database, name)
        case .routine:
            guard let routine = snapshot.database(database)?.routines.first(where: { $0.name == symbol.name }) else { return nil }
            return DatabaseObject(routine.kind == .function ? .function : .procedure, database, routine.name)
        default: return nil
        }
    }
}
