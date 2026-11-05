import AirSQLCore
import AppKit

extension SidebarNode {
    /// The row's name quoted for SQL (Copy Name and dragging into the editor).
    var quotedName: String? {
        switch kind {
        case .database(_, let name): return SQLQuote.identifier(name)
        case .object(_, let object): return SQLQuote.identifier(object.name)
        case .detail(_, _, _, let name): return SQLQuote.identifier(name)
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

    /// What Open Data and Open Structure open: the selected tables and views, and those of the rows under one, once each.
    private var tablesToOpen: [DatabaseObject] {
        var seen = Set<DatabaseObject>()
        return (treeSelection?.nodes ?? []).compactMap { $0.object ?? $0.owner }.filter { $0.kind.isTableLike && seen.insert($0).inserted }
    }

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

    /// The database of the selected tree rows while the tree has the focus, so its menus' New Query, Export… and
    /// Restore… start there: their connection and database, when they are all in one.
    var focusedDatabase: (open: OpenConnection, name: String)? {
        guard view.window?.firstResponder === outline, let (open, nodes) = treeSelection else { return nil }
        let names = Set(nodes.compactMap(\.database))
        guard names.count == 1, let name = names.first else { return nil }
        return (open, name)
    }

    /// A single click shows the row in the preview tab: a database's tables, a table's rows, an object's definition.
    @objc func showSelectedObject() {
        if let main, selectedConnectionIDs.count == 1, selectedNodes.count == 1, let open = model.openConnection(selectedConnectionIDs[0]) {
            return main.showHost(open)
        }
        guard let main, let (open, nodes) = treeSelection, nodes.count == 1 else { return }
        switch nodes[0].kind {
        case .database(_, let name):
            main.preview(DatabaseViewController(open, name), title: name, connection: open.id)
        case .object(_, let object):
            let content = object.kind.isTableLike ? NavigatorHooks.tableData(open, object, nil) : TextContent.definition(open, object)
            main.preview(content, title: object.name, connection: open.id)
        case .users:
            main.showUsers(open)
        default:
            break
        }
    }

    /// A double-click makes a database current and opens or closes it, opens or closes a group, opens an object in its
    /// own tab, and a row under a table opens that table's structure (a trigger, its own editor).
    func treeDoubleClicked(_ node: SidebarNode) {
        switch node.kind {
        case .database(let id, let name):
            model.openConnection(id)?.currentDatabase = name
            fallthrough
        case .category, .part:
            if outline.isItemExpanded(node) { gently(outline).collapseItem(node) } else { gently(outline).expandItem(node) }
        case .object(let id, let object):
            // The double-click's first click showed it in the preview: its own tab takes over, leaving no second copy.
            let preview = main?.tabs.first {
                $0.content is PreviewContent && $0.tabContent?.isEdited == false && $0.title == object.name && $0.connectionID == id
            }
            if object.kind.isTableLike { openData(nil) } else { openObject(nil) }
            if let preview { main?.close(preview) }
        case .detail(let id, let object, let part, let name):
            guard let open = model.openConnection(id) else { return }
            main?.openEditor(part == .triggers ? DatabaseObject(.trigger, object.database, name) : object, of: open)
        default:
            break
        }
    }

    /// The right-click menu of the selected tree rows (plan §2.12), by the kind of the first.
    func treeMenu(_ nodes: [SidebarNode]) -> NSMenu {
        let menu = NSMenu(title: "Navigator")
        switch nodes[0].kind {
        case .database:
            menu.add([Commands.newQuery, Commands.newDatabase, Commands.createTable, Commands.copyName, Commands.copyPlainName, nil,
                      Commands.export, Commands.restore,
                      Commands.generateLiquibase, Commands.compareWith, Commands.compareRows, Commands.diskUsage, Commands.modifyGrants, nil, Commands.editDatabase,
                      Commands.refresh, Commands.drop])
        case .category:
            menu.add([Commands.createObject, Commands.refresh, nil, Commands.expandAll, Commands.collapseAll])
        case .object(_, let object) where object.kind.isTableLike:
            menu.add([Commands.openData, Commands.openStructure, Commands.selectTop, Commands.copyName, Commands.copyPlainName,
                      Commands.copyCreate, nil, Commands.generateSelect,
                      Commands.generateInsert, Commands.generateUpdate, nil, Commands.export, Commands.copyTable,
                      Commands.bulkEdit, Commands.compareWith, Commands.compareRows])
            menu.addItem(NavigatorMenus.maintenance())
            menu.add([nil, Commands.truncate, Commands.rename, Commands.drop, nil, Commands.diskUsage, Commands.modifyGrants, Commands.refresh])
        case .users:
            menu.add([Commands.users])
        case .part:
            menu.add([Commands.openStructure, Commands.openData])
        case .detail(_, _, let part, _):
            menu.add([Commands.openStructure, Commands.openData, nil, Commands.copyName, Commands.copyPlainName])
            if part == .triggers { menu.add([nil, Commands.compareWith, Commands.compareRows]) }
        default:
            menu.add([Commands.openObject, Commands.runRoutine, Commands.copyCreate, nil, Commands.compareWith, Commands.compareRows,
                      Commands.modifyGrants, nil, Commands.drop, Commands.refresh])
        }
        return menu
    }

    // MARK: Commands

    @objc func openData(_ sender: Any?) {
        guard let main, let open = treeSelection?.open else { return }
        for table in tablesToOpen { main.openTableData(table, of: open) }
    }

    @objc func openStructure(_ sender: Any?) {
        guard let main, let open = treeSelection?.open else { return }
        for table in tablesToOpen { main.openEditor(table, of: open) }
    }

    @objc func openObject(_ sender: Any?) {
        guard let main, let open = treeSelection?.open else { return }
        for object in selectedObjects where !object.kind.isTableLike { main.openEditor(object, of: open) }
    }

    @objc func selectTop(_ sender: Any?) {
        if let open = treeSelection?.open { NavigatorActions.selectTop(selectedObjects, on: open, main: main) }
    }

    @objc func editDatabase(_ sender: Any?) {
        if let open = treeSelection?.open, let name = selectedDatabases.first {
            NavigatorActions.editDatabase(name, on: open, window: view.window)
        }
    }

    @objc func generateSelect(_ sender: Any?) { generate(.select) }
    @objc func generateInsert(_ sender: Any?) { generate(.insert) }
    @objc func generateUpdate(_ sender: Any?) { generate(.update) }

    private func generate(_ kind: NavigatorActions.Generated) {
        guard let open = treeSelection?.open else { return }
        NavigatorActions.generate(kind, selectedObjects, on: open, main: main)
    }

    @objc func runRoutine(_ sender: Any?) {
        guard let open = treeSelection?.open, let routine = selectedObjects.first else { return }
        NavigatorActions.runRoutine(routine, on: open, main: main)
    }

    @objc func copyName(_ sender: Any?) { put(selectedNodes.compactMap(\.quotedName)) }
    @objc func copyPlainName(_ sender: Any?) { put(selectedNodes.filter { $0.quotedName != nil }.compactMap(\.name)) }

    /// ⌘C: the names of the rows selected, connections' too.
    @objc func copy(_ sender: Any?) { put(copyableNames) }

    private var copyableNames: [String] {
        selectedNodes.compactMap { $0.quotedName ?? model.connection($0.connectionID)?.displayName }
    }

    private func put(_ names: [String]) {
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

    /// Down to the objects: opening every table too would bury the tree in columns.
    @objc func expandAll(_ sender: Any?) {
        func expand(_ node: SidebarNode) {
            outline.expandItem(node)
            node.children.filter { $0.object == nil }.forEach(expand)
        }
        selectedNodes.forEach(expand)
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

    /// F2 in the sidebar: Rename Folder… on a folder, Edit… on a connection (its name is the first field), else Rename…
    /// on the tree's table or view.
    @objc func renameSelection(_ sender: Any?) {
        if selectedFolderNodeID != nil {
            main?.renameFolder(sender)
        } else if selectedConnectionIDs.count == 1 {
            main?.editConnection(sender)
        } else {
            renameObject(sender)
        }
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

    /// A pane of the connection's host page, by the menu item's tag.
    @objc func showServerHome(_ sender: Any?) {
        guard let open = targetOpen else { return }
        main?.showHost(open, pane: HostContent.Pane(rawValue: (sender as? NSMenuItem)?.tag ?? 0))
    }

    @objc func showUsers(_ sender: Any?) {
        if let open = targetOpen { main?.showUsers(open) }
    }

    /// Who may do what on the selected database, table or routine, from the connection's Users tab.
    @objc func modifyGrants(_ sender: Any?) {
        guard let open = targetOpen else { return }
        let level: GrantLevel
        if let object = selectedObjects.first {
            switch object.kind {
            case .procedure, .function: level = .routine(object.database, object.name, isFunction: object.kind == .function)
            default: level = .table(object.database, object.name)
            }
        } else if let database = selectedDatabases.first {
            level = .database(database)
        } else {
            return
        }
        main?.showUsers(open)?.modifyGrants(on: level)
    }

    /// Disk Usage of the selected table, database or else the server, in the connection's Disk Usage tab.
    @objc func showDiskUsage(_ sender: Any?) {
        guard let main else { return }
        guard let open = targetOpen else {
            return showError("Connect to a server first: Disk Usage shows what a connected server holds.",
                             title: "No connected server", on: view.window)
        }
        var level = DiskUsageContent.Level.server
        if let object = selectedObjects.first(where: { $0.kind == .table }), selectedObjects.count == 1 {
            level = .table(object.database, object.name)
        } else if selectedDatabases.count == 1, let database = selectedDatabases.first {
            level = .database(database)
        }
        main.showDiskUsage(open, level: level)
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let selection = treeSelection
        var reason: String?
        switch item.action {
        case Commands.refresh.action?:
            let open = selection != nil || selectedConnectionIDs.contains { model.openConnection($0) != nil }
            reason = open ? nil : "Select a connected connection or something in its tree first"
        case Commands.copy.action?:
            reason = copyableNames.isEmpty ? "Select a connection, database or object first" : nil
        case Commands.expandAll.action?, Commands.collapseAll.action?:
            reason = selectedNodes.contains { outline.isExpandable($0) } ? nil : "Select a row that has rows under it first"
        case Commands.openData.action?, Commands.openStructure.action?:
            reason = tablesToOpen.isEmpty ? "Select a table or view in the tree first" : nil
        case Commands.copyName.action? where selectedNodes.contains { $0.detail != nil },
             Commands.copyPlainName.action? where selectedNodes.contains { $0.detail != nil }:
            reason = nil
        case Commands.renameF2.action? where selectedFolderNodeID != nil || selectedConnectionIDs.count == 1:
            reason = nil
        case Commands.renameF2.action?:
            reason = NavigatorActions.reason(for: Commands.rename.action, objects: selectedObjects, databases: selectedDatabases,
                                             open: selection?.open, target: targetOpen, model: model)
        default:
            reason = NavigatorActions.reason(for: item.action, objects: selectedObjects, databases: selectedDatabases,
                                             open: selection?.open, target: targetOpen, model: model)
        }
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }
}
