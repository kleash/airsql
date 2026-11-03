import AirSQLCore
import AppKit

extension SidebarNode {
    /// The row's name quoted for SQL (Copy Name and dragging into the editor).
    var quotedName: String? {
        switch kind {
        case .database(_, let name): return SQLQuote.identifier(name)
        case .object(_, let object): return SQLQuote.identifier(object.name)
        default: return nil
        }
    }
}

/// The navigator's side of the sidebar (plan §2.12): what a click shows, what a double-click opens, the tree's menus and
/// the commands they send, acting on the selected rows of one connected connection.
extension SidebarController: NSMenuItemValidation {
    /// The selected tree rows, when they are all on one connected connection.
    var treeSelection: (open: OpenConnection, nodes: [SidebarNode])? {
        let nodes = selectedNodes.filter { $0.connectionOfTree != nil }
        guard let id = nodes.first?.connectionOfTree, nodes.allSatisfy({ $0.connectionOfTree == id }),
              let open = model.openConnection(id) else { return nil }
        return (open, nodes)
    }

    var selectedObjects: [DatabaseObject] { treeSelection?.nodes.compactMap(\.object) ?? [] }

    var selectedDatabases: [String] {
        treeSelection?.nodes.compactMap { node in
            if case .database(_, let name) = node.kind { return name }
            return nil
        } ?? []
    }

    /// The connected connection a connection-wide command (New Database, Find Text, Process List) acts on: the tree's,
    /// else the selected connection's, else the window's.
    var targetOpen: OpenConnection? {
        if let open = treeSelection?.open { return open }
        let ids = selectedConnectionIDs
        if ids.count == 1 { return model.openConnection(ids[0]) }
        return model.openConnection(main?.activeConnection?.id)
    }

    /// A single click shows the row in the preview tab: a database's tables, a table's rows, an object's definition.
    func showSelectedObject() {
        guard let main, let (open, nodes) = treeSelection, nodes.count == 1 else { return }
        switch nodes[0].kind {
        case .database(_, let name):
            main.preview(DatabaseViewController(open, name), title: name, connection: open.id)
        case .object(_, let object):
            let content = object.kind.isTableLike ? NavigatorHooks.tableData(open, object, nil) : TextContent.definition(open, object)
            main.preview(content, title: object.name, connection: open.id)
        default:
            break
        }
    }

    /// A double-click makes a database current and opens it, opens or closes a group, opens an object in its own tab.
    func treeDoubleClicked(_ node: SidebarNode) {
        switch node.kind {
        case .database(let id, let name):
            model.openConnection(id)?.currentDatabase = name
            outline.expandItem(node)
        case .category:
            if outline.isItemExpanded(node) { outline.animator().collapseItem(node) } else { outline.animator().expandItem(node) }
        case .object(_, let object):
            if object.kind.isTableLike { openData(nil) } else { openObject(nil) }
        default:
            break
        }
    }

    /// The right-click menu of the selected tree rows (plan §2.12), by the kind of the first.
    func treeMenu(_ nodes: [SidebarNode]) -> NSMenu {
        let menu = NSMenu(title: "Navigator")
        switch nodes[0].kind {
        case .database:
            menu.add([Commands.newQuery, Commands.newDatabase, Commands.createTable, nil, Commands.export, Commands.restore,
                      Commands.generateLiquibase, Commands.compare, nil, Commands.refresh, Commands.drop])
        case .category:
            menu.add([Commands.createObject, Commands.refresh, nil, Commands.expandAll, Commands.collapseAll])
        case .object(_, let object) where object.kind.isTableLike:
            menu.add([Commands.openData, Commands.openStructure, Commands.copyName, nil, Commands.generateSelect,
                      Commands.generateInsert, Commands.generateUpdate, nil, Commands.export, Commands.copyTable,
                      Commands.bulkEdit])
            menu.addItem(NavigatorMenus.maintenance())
            menu.add([nil, Commands.truncate, Commands.rename, Commands.drop, nil, Commands.refresh])
        default:
            menu.add([Commands.openObject, Commands.runRoutine, Commands.copyCreate, nil, Commands.drop, Commands.refresh])
        }
        return menu
    }

    // MARK: Commands

    @objc func openData(_ sender: Any?) {
        guard let main, let open = treeSelection?.open else { return }
        for table in selectedObjects where table.kind.isTableLike {
            main.open(NavigatorHooks.tableData(open, table, nil), title: table.name, connection: open.id)
        }
    }

    @objc func openStructure(_ sender: Any?) {
        guard let main, let open = treeSelection?.open else { return }
        for table in selectedObjects where table.kind.isTableLike {
            let content = NavigatorHooks.tableEditor?(open, table) ?? TextContent.definition(open, table)
            main.open(content, title: table.name + " · structure", connection: open.id)
        }
    }

    @objc func openObject(_ sender: Any?) {
        guard let main, let open = treeSelection?.open else { return }
        for object in selectedObjects where !object.kind.isTableLike {
            main.open(NavigatorHooks.objectEditor?(open, object) ?? TextContent.definition(open, object), title: object.name,
                      connection: open.id)
        }
    }

    @objc func copyName(_ sender: Any?) {
        let names = selectedNodes.compactMap(\.quotedName)
        guard !names.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: ", "), forType: .string)
    }

    @objc func copyCreateStatement(_ sender: Any?) {
        guard let open = treeSelection?.open, let object = selectedObjects.first else { return }
        NavigatorActions.copyCreate(object, on: open, window: view.window)
    }

    @objc func refresh(_ sender: Any?) {
        if let (open, nodes) = treeSelection {
            let databases = Set(nodes.compactMap(\.database))
            let objects = nodes.compactMap(\.object)
            if nodes.allSatisfy({ $0.object != nil }) {
                open.refresh(objects.map(\.schemaObject))
            } else {
                open.refresh(databases.sorted().map { .database($0) })
            }
            databases.filter { open.snapshot.database($0)?.statistics != nil }.forEach(open.loadStatistics)
        } else {
            for id in selectedConnectionIDs { model.openConnection(id)?.load() }
        }
    }

    @objc func expandAll(_ sender: Any?) {
        for node in selectedNodes { outline.expandItem(node, expandChildren: true) }
    }

    @objc func collapseAll(_ sender: Any?) {
        for node in selectedNodes { outline.collapseItem(node, collapseChildren: true) }
    }

    @objc func newDatabase(_ sender: Any?) {
        guard let open = targetOpen else { return }
        NavigatorActions.newDatabase(on: open, window: view.window)
    }

    @objc func dropObject(_ sender: Any?) {
        guard let open = treeSelection?.open else { return }
        let databases = selectedDatabases
        if !databases.isEmpty {
            NavigatorActions.dropDatabases(databases, on: open, window: view.window)
        } else {
            NavigatorActions.drop(selectedObjects, on: open, window: view.window)
        }
    }

    @objc func truncateTable(_ sender: Any?) {
        guard let open = treeSelection?.open else { return }
        NavigatorActions.truncate(selectedObjects, on: open, window: view.window)
    }

    @objc func renameObject(_ sender: Any?) {
        guard let open = treeSelection?.open, let object = selectedObjects.first else { return }
        NavigatorActions.rename(object, on: open, window: view.window)
    }

    @objc func copyTable(_ sender: Any?) {
        guard let open = treeSelection?.open, let table = selectedObjects.first else { return }
        NavigatorActions.copyTable(table, on: open, window: view.window)
    }

    @objc func bulkEditTables(_ sender: Any?) {
        guard let open = treeSelection?.open else { return }
        NavigatorActions.bulkEdit(selectedObjects, on: open, window: view.window)
    }

    @objc func runMaintenance(_ sender: Any?) {
        guard let open = treeSelection?.open, let operation = NavigatorMenus.operation(sender) else { return }
        NavigatorActions.maintain(selectedObjects, operation, on: open, main: main)
    }

    @objc func findOnServer(_ sender: Any?) {
        guard let open = targetOpen, let main else { return }
        let database = treeSelection?.nodes.first?.database
        main.open(FindTextContent(open, database: database), title: "Find Text", connection: open.id)
    }

    @objc func showProcessList(_ sender: Any?) {
        guard let main else { return }
        guard let open = targetOpen else {
            // The footer's Processes button isn't checked as menu items are: say why nothing opens.
            return showError("Connect to a server first: the process list shows what a connected server is running.",
                             title: "No connected server", on: view.window)
        }
        if let tab = main.tabs.first(where: { ($0.content as? ProcessListContent)?.open === open }) {
            main.select(tab)
        } else {
            main.open(ProcessListContent(open), title: "Processes", connection: open.id)
        }
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let selection = treeSelection
        var reason: String?
        switch item.action {
        case Commands.refresh.action?:
            let open = selection != nil || selectedConnectionIDs.contains { model.openConnection($0) != nil }
            reason = open ? nil : "Select a connected connection or something in its tree first"
        case Commands.expandAll.action?, Commands.collapseAll.action?:
            reason = selectedNodes.contains { !$0.children.isEmpty } ? nil : "Select a row that has rows under it first"
        default:
            reason = NavigatorActions.reason(for: item.action, objects: selectedObjects, databases: selectedDatabases,
                                             open: selection?.open, target: targetOpen, model: model)
        }
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }
}
