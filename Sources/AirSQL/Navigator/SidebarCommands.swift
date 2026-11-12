import AirSQLCore
import AppKit

extension SidebarNode {
    /// The row's name quoted for SQL (Copy Name and dragging into the editor).
    var quotedName: String? {
        switch kind {
        case .database(_, let name): return SQLQuote.identifier(name)
        case .object(_, let object): return SQLQuote.identifier(object.name)
        case .detail(_, _, _, let name): return SQLQuote.identifier(name)
        case .mongo: return name  // MongoDB's names are never quoted
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
    var tablesToOpen: [DatabaseObject] {
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
        if let main, selectedConnectionIDs.count == 1, selectedNodes.count == 1, let mongo = model.openMongo[selectedConnectionIDs[0]] {
            return main.showMongoHost(mongo)
        }
        if showMongoSelection() { return }
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
    /// own tab (a table or view opens or closes in the tree too), and a row under a table opens that table's structure (a
    /// trigger, its own editor).
    func treeDoubleClicked(_ node: SidebarNode) {
        switch node.kind {
        case .database(let id, let name):
            model.openConnection(id)?.currentDatabase = name
            fallthrough
        case .category, .part, .prefix:
            if outline.isItemExpanded(node) { gently(outline).collapseItem(node) } else { gently(outline).expandItem(node) }
        case .object(let id, let object):
            // The double-click's first click showed it in the preview: its own tab takes over, leaving no second copy.
            let preview = main?.tabs.first {
                $0.content is PreviewContent && $0.tabContent?.isEdited == false && $0.title == object.name && $0.connectionID == id
            }
            if object.kind.isTableLike { openData(nil) } else { openObject(nil) }
            if let preview { main?.close(preview) }
            // Its columns and keys open and close with it, as any row with an arrow does.
            if object.kind.hasParts {
                if outline.isItemExpanded(node) { gently(outline).collapseItem(node) } else { gently(outline).expandItem(node) }
            }
        case .detail(let id, let object, let part, let name):
            guard let open = model.openConnection(id) else { return }
            main?.openEditor(part == .triggers ? DatabaseObject(.trigger, object.database, name) : object, of: open)
        case .mongo(_, let item):
            mongoDoubleClicked(node, item)
        default:
            break
        }
    }

    /// The right-click menu of the selected tree rows (plan §2.12), by the kind of the first.
    func treeMenu(_ nodes: [SidebarNode]) -> NSMenu {
        let menu = NSMenu(title: "Navigator")
        switch nodes[0].kind {
        case .mongo(_, let item):
            menu.add(Self.mongoMenu(item))
            // Export and Import act on the selected collection (Import also on a database) through their own target.
            let transfer = item.index != nil ? [] : item.collection != nil ? Commands.mongoTransferCommands : [Commands.importDocuments]
            if !transfer.isEmpty { menu.addItem(.separator()) }
            for command in transfer {
                let entry = command.item()
                entry.target = MongoTransferMenu.shared
                menu.addItem(entry)
            }
            MongoDumpMenu.addItems(to: menu, for: item)
        case .database:
            menu.add([Commands.newQuery, Commands.newDatabase, Commands.createTable, Commands.copyName, Commands.copyPlainName, nil,
                      Commands.export, Commands.restore,
                      Commands.generateLiquibase, Commands.sqlGenerator, Commands.compareWith, Commands.compareRows, Commands.diskUsage, Commands.modifyGrants, nil, Commands.editDatabase,
                      Commands.refresh, Commands.drop])
        case .category:
            menu.add([Commands.createObject, Commands.refresh, nil, Commands.expandAll, Commands.collapseAll])
        case .object(_, let object) where object.kind.isTableLike:
            menu.add([Commands.openData, Commands.openStructure, Commands.selectTop, Commands.copyName, Commands.copyPlainName,
                      Commands.copyCreate, Commands.createToConsole, Commands.sqlGenerator, Commands.favourite, Commands.findUsedBy, nil,
                      Commands.newColumn, Commands.newIndex, Commands.newForeignKey, Commands.editComment, nil, Commands.generateSelect,
                      Commands.generateInsert, Commands.generateUpdate, nil, Commands.export, Commands.copyTable,
                      Commands.bulkEdit, Commands.compareWith, Commands.compareRows, Commands.diagramOfSelection, Commands.diagramOfNeighbours])
            menu.addItem(NavigatorMenus.maintenance())
            menu.add([nil, Commands.truncate, Commands.rename, Commands.drop, nil, Commands.diskUsage, Commands.modifyGrants, Commands.refresh])
        case .users:
            menu.add([Commands.users])
        case .part:
            menu.add([Commands.openStructure, Commands.openData])
        case .detail(_, _, let part, _):
            menu.add([Commands.openStructure, Commands.openData, nil, Commands.copyName, Commands.copyPlainName, Commands.findUsedBy])
            if nodes.allSatisfy(\.isDroppablePart) { menu.add([nil, Commands.drop]) }
            if part == .triggers { menu.add([nil, Commands.compareWith, Commands.compareRows]) }
        default:
            menu.add([Commands.openObject, Commands.runRoutine, Commands.copyCreate, Commands.createToConsole, Commands.sqlGenerator, Commands.favourite,
                      Commands.findUsedBy, Commands.editComment, nil, Commands.compareWith, Commands.compareRows, Commands.modifyGrants, nil, Commands.drop,
                      Commands.refresh])
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
        guard let open = treeSelection?.open, !selectedObjects.isEmpty else { return }
        NavigatorActions.copyCreate(selectedObjects, on: open, window: view.window)
    }

    @objc func openCreateInConsole(_ sender: Any?) {
        guard let open = treeSelection?.open, !selectedObjects.isEmpty else { return }
        NavigatorActions.openCreate(selectedObjects, on: open, main: main)
    }

    /// The SQL Generator on the objects selected, or everything in the databases selected.
    @objc func showSQLGenerator(_ sender: Any?) {
        guard let open = treeSelection?.open, let context = Editors.context(model.connection(open.id), in: model) else { return }
        main?.openSQLGenerator(selectedObjects, databases: selectedDatabases, context: context)
    }

    @objc func refresh(_ sender: Any?) {
        if refreshMongo() { return }
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
        guard let (open, nodes) = treeSelection else { return }
        if nodes.allSatisfy(\.isDroppablePart) { return NavigatorActions.dropParts(nodes, on: open, window: view.window) }
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
        if let tab = model.allTabs.first(where: { ($0.content as? ProcessListContent)?.open === open }) {
            main.show(tab)
        } else {
            main.open(ProcessListContent(open), title: "Processes", connection: open.id)
        }
    }

    // MARK: View ▸ Tree

    @objc func toggleTreeOption(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSButton)?.tag, let option = TreeOption(rawValue: tag) else { return }
        switch option {
        case .flat: model.data.settings.tree.flat.toggle()
        case .favouritesOnly: model.data.settings.tree.favouritesOnly.toggle()
        case .sizes: model.data.settings.tree.showsSizes.toggle()
        case .comments: model.data.settings.tree.showsComments.toggle()
        case .prefixes: model.data.settings.tree.groupsByPrefix.toggle()
        case .followTab: model.data.settings.tree.followsTab.toggle()
        case .databaseBox:
            databaseFilter.isHidden.toggle()
            databaseFilter.stringValue = ""
            reload()
            if !databaseFilter.isHidden { view.window?.makeFirstResponder(databaseFilter) }
        }
    }

    private func isOn(_ option: TreeOption) -> Bool {
        let tree = model.data.settings.tree
        switch option {
        case .flat: return tree.flat
        case .favouritesOnly: return tree.favouritesOnly
        case .sizes: return tree.showsSizes
        case .comments: return tree.showsComments
        case .prefixes: return tree.groupsByPrefix
        case .followTab: return tree.followsTab
        case .databaseBox: return !databaseFilter.isHidden
        }
    }

    /// The item's tag is the kind's place in `allCases`.
    @objc func toggleTreeKind(_ sender: Any?) {
        guard let kind = DatabaseObject.Kind.allCases[safe: (sender as? NSMenuItem)?.tag ?? -1]?.rawValue else { return }
        if model.data.settings.tree.hiddenKinds.contains(kind) {
            model.data.settings.tree.hiddenKinds.removeAll { $0 == kind }
        } else {
            model.data.settings.tree.hiddenKinds.append(kind)
        }
    }

    @objc func hideTreeNames(_ sender: Any?) {
        guard let window = view.window else { return }
        let field = AirSQL.textField(model.data.settings.tree.hiddenNames, placeholder: "tmp_*, *_old", id: "tree.hiddenNames",
                              tip: "Type names or patterns with * and ?, separated by commas", width: 280)
        NavigatorActions.ask("Hide Names", "Objects with these names stay out of the tree, on every connection. Leave it empty to show them all.",
                             field: field, action: "Hide", tip: "Leave these names out of the tree", on: window) { [weak self] in
            self?.model.data.settings.tree.hiddenNames = field.stringValue
        }
    }

    /// Databases Shown…: writes the connection's database filter, which a tree follows at once. The names ticked are what
    /// the server showed at connect, so one left out then comes back only through the connection's own settings.
    @objc func chooseDatabases(_ sender: Any?) {
        guard let window = view.window, let open = targetOpen, var saved = model.connection(open.id) else { return }
        let names = open.snapshot.databases.map(\.name)
        let boxes = names.map { name -> NSButton in
            let box = NSButton(checkboxWithTitle: name, target: nil, action: nil)
            box.state = saved.showsDatabase(name) ? .on : .off
            box.toolTip = "Show \(name) in the tree"
            return box
        }
        let list = NSStackView(views: boxes)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = Spacing.half
        let scroll = NSScrollView()
        scroll.documentView = FlippedView()
        scroll.documentView?.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView?.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        if let document = scroll.documentView {
            list.pin(to: document)
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        }
        scroll.widthAnchor.constraint(equalToConstant: 300).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: min(CGFloat(names.count) * 22 + 8, 280)).isActive = true
        scroll.setAccessibilityIdentifier("tree.databases")
        NavigatorActions.ask("Databases Shown", "Tick the databases the tree shows on \(saved.displayName).", field: scroll, action: "Show",
                             tip: "Show the databases ticked", on: window) { [weak self] in
            let chosen = zip(names, boxes).filter { $0.1.state == .on }.map(\.0)
            guard !chosen.isEmpty else { return NSSound.beep() }
            saved.databaseFilter = chosen.count == names.count ? "" : chosen.joined(separator: ", ")
            self?.model.save(saved)
        }
    }

    @objc func showTreeOptions(_ sender: NSButton) {
        let menu = NSMenu(title: "Tree")
        Commands.treeMenuItems().forEach(menu.addItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc func toggleFavourite(_ sender: Any?) {
        guard let id = treeSelection?.open.id else { return }
        let objects = selectedObjects
        setFavourite(objects, !isFavourite(objects, id), on: id)
    }

    /// Every one of them is a favourite.
    private func isFavourite(_ objects: [DatabaseObject], _ id: UUID) -> Bool {
        let favourites = model.connection(id)?.favourites ?? []
        return !objects.isEmpty && objects.allSatisfy(favourites.contains)
    }

    func setFavourite(_ objects: [DatabaseObject], _ on: Bool, on id: UUID) {
        guard var saved = model.connection(id) else { return }
        saved.favourites.removeAll(where: objects.contains)
        if on { saved.favourites += objects }
        model.save(saved)
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
        if let enabled = validateMongo(item) { return enabled }
        if NotForMongo.applies(item, main?.activeConnection) { return false }
        let selection = treeSelection
        var reason: String?
        switch item.action {
        case Commands.drop.action? where selection?.nodes.allSatisfy(\.isDroppablePart) == true:
            reason = NavigatorActions.readOnlyReason(selection?.open, model)
        case Commands.findUsedBy.action?:
            reason = usageName == nil ? "Select one object or column in the tree first" : nil
        case Commands.editComment.action?:
            let kinds: [DatabaseObject.Kind] = [.table, .procedure, .function]
            reason = selectedObjects.count == 1 && kinds.contains(selectedObjects[0].kind)
                ? NavigatorActions.readOnlyReason(selection?.open, model)
                : "Select one table or routine first"
        case Commands.newColumn.action?:
            reason = selectedObjects.count == 1 && selectedObjects[0].kind == .table
                ? NavigatorActions.readOnlyReason(selection?.open, model)
                : "Select one table first"
        case Commands.moveConnectionUp.action?, Commands.moveConnectionDown.action?:
            reason = selectedConnectionIDs.count == 1 ? nil : "Select one connection in the sidebar first"
        case Commands.quickDocumentation.action?, Commands.quickDefinition.action?, Commands.goToDDL.action?:
            reason = notedObject == nil && !(item.action == Commands.quickDocumentation.action && selectedDatabases.count == 1)
                ? "Select an object in the tree first" : nil
        case Commands.openNameData.action?:
            reason = tablesToOpen.isEmpty && selectedCategory == nil ? "Select a table, or a group of tables, in the tree first" : nil
        case Commands.treeFlat.action?:
            item.state = TreeOption(rawValue: item.tag).map(isOn) == true ? .on : .off
        case Commands.treeKind.action?:
            let kind = DatabaseObject.Kind.allCases[safe: item.tag]?.rawValue ?? ""
            item.state = model.data.settings.tree.hiddenKinds.contains(kind) ? .off : .on
        case Commands.hideNames.action?:
            break
        case Commands.databasesShown.action?:
            reason = targetOpen == nil ? "Connect first: this lists a connected server's databases" : nil
        case Commands.favourite.action?:
            let favourite = selection.map { isFavourite(selectedObjects, $0.open.id) } == true
            item.title = favourite ? "Remove from Favourites" : "Add to Favourites"
            reason = selectedObjects.isEmpty ? "Select objects in the tree first" : nil
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
