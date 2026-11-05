import AirSQLCore
import AppKit

extension Tab {
    /// The tree's row of what the tab shows, on a connected connection (a console has `SelectInTree.row(of:)`).
    func treeRow(in open: OpenConnection) -> SidebarNode.Kind {
        if let view = shown as? DatabaseViewController { return .database(open.id, view.database) }
        guard let place, let database = place.database, let name = place.object else { return .connection(open.id) }
        let table = open.snapshot.table(database, name)
        let kind = DatabaseObject.Kind(rawValue: place.kind.rawValue) ?? table.flatMap { DatabaseObject.Kind(rawValue: $0.kind.rawValue) } ?? .table
        return .object(open.id, DatabaseObject(table.flatMap { DatabaseObject.Kind(rawValue: $0.kind.rawValue) } ?? kind, database, name))
    }
}

extension MainWindowController {
    /// Select in Tree: the tab's table or object; in a query tab, the name at the cursor, else the tab's database.
    @objc func selectInTree(_ sender: Any?) {
        guard let tab = selectedTab, let open = model.openConnection(tab.connectionID) else { return }
        guard let console = tab.shown as? ConsoleViewController else {
            sidebar.reveal(tab.treeRow(in: open))
            return focusSidebar(sender)
        }
        console.editor.withInsight { [weak self] analysis in
            let symbol = analysis.reference(at: console.editor.selectedRange().location)?.symbol
            self?.sidebar.reveal(Self.treeRow(of: symbol, in: open) ?? (console.chosenDatabase ?? open.currentDatabase).map { .database(open.id, $0) } ?? .connection(open.id))
            self?.focusSidebar(sender)
        }
    }

    /// The tree's row of a name in SQL: a column's is its table's.
    private static func treeRow(of symbol: SQLSymbol?, in open: OpenConnection) -> SidebarNode.Kind? {
        guard let symbol, let database = symbol.database else { return nil }
        switch symbol.kind {
        case .database: return .database(open.id, symbol.name)
        case .table, .column:
            let name = symbol.table ?? symbol.name
            guard let table = open.snapshot.table(database, name), let kind = DatabaseObject.Kind(rawValue: table.kind.rawValue) else { return nil }
            return .object(open.id, DatabaseObject(kind, database, name))
        case .routine:
            guard let routine = open.snapshot.database(database)?.routines.first(where: { $0.name == symbol.name }) else { return nil }
            return .object(open.id, DatabaseObject(routine.kind == .function ? .function : .procedure, database, routine.name))
        default: return nil
        }
    }
}
