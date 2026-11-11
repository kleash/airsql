import AirSQLCore
import AppKit
import Combine

/// A row of the sidebar's outline: the connections in their folders and, under a connected one, the navigator's tree
/// (its databases, each object kind's group, the objects, what a table holds, and a message while it loads).
@MainActor
final class SidebarNode: NSObject {
    enum Kind: Hashable {
        case header
        case folder(UUID)
        case connection(UUID)
        case database(UUID, String)
        case category(UUID, String, DatabaseObject.Kind)
        case object(UUID, DatabaseObject)
        /// A group under a table or view, and a row of that group, by its name.
        case part(UUID, DatabaseObject, TablePart)
        case detail(UUID, DatabaseObject, TablePart, String)
        /// Group by Prefix: objects of a database and kind that share a name's first part.
        case prefix(UUID, String, DatabaseObject.Kind, String)
        case message(UUID, String)
        /// Users and Roles, the last row of a connected connection's tree.
        case users(UUID)
        /// A MongoDB connection's database, collection or index (`MongoTree`).
        case mongo(UUID, MongoTreeItem)
    }

    let kind: Kind
    var children: [SidebarNode] = []
    /// What a `detail` row shows.
    var detail: TablePart.Row?

    init(_ kind: Kind) {
        self.kind = kind
    }

    var connectionID: UUID? {
        if case .connection(let id) = kind { return id }
        return nil
    }
}

/// The sidebar (plan §2.4, §2.12): a filter field, the connections in their folders (the navigator's tree goes under
/// a connected one), and a footer with New Connection and the process list. A click selects a connection and shows its
/// summary, a double-click connects it (or, connected, opens or closes its tree), a right-click opens its menu; ⌘ and ⇧
/// select several.
@MainActor
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    let model: AppModel
    weak var main: MainWindowController?
    let outline = SidebarOutlineView()
    let filter = NSSearchField()
    /// The second box (View ▸ Tree ▸ Database Filter): which databases show.
    let databaseFilter = NSSearchField()
    /// The favourites-only switch beside the filter.
    let favouritesButton = NSButton()
    private let header = SidebarNode(.header)
    private var folders: [UUID: SidebarNode] = [:]
    private var connections: [UUID: SidebarNode] = [:]
    /// The tree's rows by kind, kept across reloads so they stay selected and expanded.
    var treeNodes: [SidebarNode.Kind: SidebarNode] = [:]
    /// What each database's sizes add up to, worked out as rows show; a reload starts again.
    var treeSizes: [String: (largest: Int, total: Int)] = [:]
    /// Connections whose tree has been opened once since they connected.
    private var treeShown: Set<UUID> = []
    private var observers: [AnyCancellable] = []
    /// The connections open at the last look, to tell which one just connected.
    private var knownConnections = Set<UUID>()
    private var reloading = false
    /// A right-click is choosing the row its menu acts on: that shows nothing, so the tab in front stays.
    fileprivate var openingMenu = false
    /// A tab's own row is being selected: the tab stays as it is.
    private var revealing = false
    /// Quick Documentation or Definition on show, and what it says.
    var treeNote: NSPopover?
    var shownTreeNote = ""
    /// Called when the selected connections change.
    var onSelect: (() -> Void)?
    /// The attached folders and scratch files: in the tree's place while `showsFiles` (`setFilesShown`).
    private(set) lazy var files = FilesPanelController(model: model)
    private var treeViews: [NSView] = []

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var filesBottom: NSLayoutYAxisAnchor?

    /// Shows the Files panel in the tree's place, or the tree again.
    func setFilesShown(_ shown: Bool) {
        if shown, files.view.superview == nil, let filesBottom {
            view.addSubview(files.view)
            files.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                files.view.topAnchor.constraint(equalTo: view.topAnchor), files.view.bottomAnchor.constraint(equalTo: filesBottom),
                files.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), files.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            addChild(files)
        }
        if shown { files.reload() }
        if files.isViewLoaded { files.view.isHidden = !shown }
        treeViews.forEach { $0.isHidden = shown }
    }

    var filesShown: Bool { files.isViewLoaded && !files.view.isHidden }

    override func loadView() {
        let root = SurfaceView(.side)
        root.setAccessibilityIdentifier("sidebar")
        filter.placeholderString = "Filter by name"
        filter.toolTip = Commands.filterSidebar.tipWithShortcut
        filter.setAccessibilityIdentifier("sidebar.filter")
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        filter.target = self
        filter.action = #selector(filterChanged)
        // What was searched comes back under the field's magnifying glass.
        filter.recentsAutosaveName = layoutName("SidebarFilter")
        filter.searchMenuTemplate = Self.recentsMenu()
        databaseFilter.placeholderString = "Filter databases"
        databaseFilter.toolTip = "Type part of a database's name, or /a regular expression/, to show only those databases"
        databaseFilter.setAccessibilityIdentifier("sidebar.databaseFilter")
        databaseFilter.delegate = self
        databaseFilter.sendsSearchStringImmediately = true
        databaseFilter.target = self
        databaseFilter.action = #selector(filterChanged)
        databaseFilter.isHidden = true
        favouritesButton.bezelStyle = .texturedRounded
        favouritesButton.isBordered = false
        favouritesButton.setButtonType(.toggle)
        favouritesButton.image = NSImage(systemSymbolName: "star", accessibilityDescription: "Favourites only")
        favouritesButton.alternateImage = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favourites only")
        favouritesButton.toolTip = Commands.treeFavouritesOnly.tip
        favouritesButton.setAccessibilityIdentifier("sidebar.favourites")
        favouritesButton.tag = TreeOption.favouritesOnly.rawValue
        favouritesButton.target = self
        favouritesButton.action = #selector(toggleTreeOption(_:))
        let options = NSButton()
        options.bezelStyle = .texturedRounded
        options.isBordered = false
        options.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Tree options")
        options.toolTip = "Choose how the tree shows things: flat, sizes, comments, kinds and more"
        options.setAccessibilityIdentifier("sidebar.options")
        options.target = self
        options.action = #selector(showTreeOptions(_:))
        let filterRow = NSStackView(views: [filter, favouritesButton, options])
        filterRow.spacing = Spacing.half
        let filters = NSStackView(views: [filterRow, databaseFilter])
        filters.orientation = .vertical
        filters.spacing = Spacing.half
        filters.translatesAutoresizingMaskIntoConstraints = false
        for row in [filterRow, databaseFilter] { row.widthAnchor.constraint(equalTo: filters.widthAnchor).isActive = true }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.rowHeight = 22
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false  // deep tree rows truncate instead of widening the column past the sidebar
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.floatsGroupRows = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.sidebar = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.setAccessibilityIdentifier("sidebar.connections")
        outline.setAccessibilityLabel("Connections")
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let add = NSButton(title: "New Connection", target: nil, action: Commands.newConnection.action)
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.imagePosition = .imageLeading
        add.isBordered = false
        add.font = .systemFont(ofSize: 11.5)
        add.contentTintColor = .secondaryLabelColor
        add.toolTip = Commands.newConnection.tipWithShortcut
        add.setAccessibilityIdentifier("sidebar.newConnection")
        add.translatesAutoresizingMaskIntoConstraints = false
        let processes = NSButton(title: "Process List", target: nil, action: Commands.processList.action)
        processes.isBordered = false
        processes.font = .systemFont(ofSize: 11.5)
        processes.contentTintColor = .secondaryLabelColor
        processes.toolTip = Commands.processList.tipWithShortcut
        processes.setAccessibilityIdentifier("sidebar.processes")
        processes.translatesAutoresizingMaskIntoConstraints = false
        let filesButton = NSButton(image: NSImage(systemSymbolName: "folder", accessibilityDescription: "Files") ?? NSImage(), target: nil,
                                   action: Commands.filesPanel.action)
        filesButton.isBordered = false
        filesButton.contentTintColor = .secondaryLabelColor
        filesButton.toolTip = Commands.filesPanel.tip
        filesButton.setAccessibilityIdentifier("sidebar.files")
        filesButton.translatesAutoresizingMaskIntoConstraints = false
        let footerLine = Hairline()
        treeViews = [filters, scroll]

        [filters, scroll, footerLine, add, processes, filesButton].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            filters.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.unit),
            filters.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            filters.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: Spacing.half),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerLine.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            footerLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerLine.heightAnchor.constraint(equalToConstant: 1),
            add.topAnchor.constraint(equalTo: footerLine.bottomAnchor, constant: 6),
            add.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            add.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            processes.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            filesButton.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            filesButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            processes.trailingAnchor.constraint(equalTo: filesButton.leadingAnchor, constant: -Spacing.unit),
            processes.leadingAnchor.constraint(greaterThanOrEqualTo: add.trailingAnchor, constant: Spacing.unit),
        ])
        view = root
        filesBottom = footerLine.topAnchor
        setFilesShown(model.data.settings.tree.showsFiles)
        observers.append(model.$data.map(\.connections).removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        })
        observers.append(model.$data.map(\.folders).removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        })
        observers.append(model.$data.map(\.settings.tree).removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        })
        observers.append(model.$states.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshRows() }
        })
        observers.append(model.$openMongo.sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        })
        observers.append(model.$open.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.reload()
                self?.showHostOfNewConnection()
            }
        })
        NotificationCenter.default.addObserver(self, selector: #selector(openConnectionChanged), name: .openConnectionDidChange,
                                               object: nil)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.registerForDraggedTypes([.sidebarConnection, .sidebarTable])
        reload()
    }

    // MARK: Contents

    /// Rebuilds the rows from the model and the filter, keeping the selection and what is expanded. While filtering, a
    /// connected connection whose name doesn't match shows the objects that do, expanded.
    func reload() {
        let selected = selectedNodes.map(\.kind)
        treeSizes = [:]
        favouritesButton.state = model.data.settings.tree.favouritesOnly ? .on : .off
        let expanded = Set((0..<outline.numberOfRows).compactMap { row -> SidebarNode.Kind? in
            guard let node = outline.item(atRow: row) as? SidebarNode, outline.isItemExpanded(node) else { return nil }
            return node.kind
        })
        let firstLoad = folders.isEmpty && connections.isEmpty
        let text = filter.stringValue.trimmingCharacters(in: .whitespaces)
        let named = Set(model.sections(filter: text).flatMap { $0.connections.map(\.id) })
        var fresh: [SidebarNode.Kind: SidebarNode] = [:]
        func node(_ kind: SidebarNode.Kind) -> SidebarNode {
            let node = fresh[kind] ?? treeNodes[kind] ?? SidebarNode(kind)
            fresh[kind] = node
            return node
        }
        header.children = []
        var newFolders: [UUID: SidebarNode] = [:], newConnections: [UUID: SidebarNode] = [:]
        var open: [SidebarNode] = []
        for section in model.sections(filter: "") {
            let rows = section.connections.compactMap { connection -> SidebarNode? in
                let tree = tree(connection.id, matching: named.contains(connection.id) ? "" : text, node: node)
                guard named.contains(connection.id) || !tree.isEmpty else { return nil }
                let row = connections[connection.id] ?? SidebarNode(.connection(connection.id))
                row.children = tree
                newConnections[connection.id] = row
                if !tree.isEmpty { open.append(row) }
                return row
            }
            if let folder = section.folder {
                guard !rows.isEmpty || text.isEmpty else { continue }
                let row = folders[folder.id] ?? SidebarNode(.folder(folder.id))
                row.children = rows
                newFolders[folder.id] = row
                header.children.append(row)
            } else {
                header.children += rows
            }
        }
        // Nothing matches: say so, and how to see every connection again.
        if !text.isEmpty && header.children.isEmpty {
            header.children = ["Nothing matches “\(text)”", "Esc in the filter shows everything"].map { SidebarNode(.message(UUID(), $0)) }
        }
        folders = newFolders
        connections = newConnections
        treeNodes = fresh
        treeShown.formIntersection(Set(model.open.keys).union(model.openMongo.keys))
        reloading = true
        outline.reloadData()
        outline.expandItem(header)
        for (id, row) in folders where firstLoad || !text.isEmpty || expanded.contains(.folder(id)) { outline.expandItem(row) }
        // A tree opens the first time it shows (with the connection's database), keeps what was open, and opens all of
        // a filtered one.
        for row in open {
            guard let id = row.connectionID else { continue }
            let filtered = (!text.isEmpty && !named.contains(id)) || model.data.settings.tree.favouritesOnly
            let first = !treeShown.contains(id)
            treeShown.insert(id)
            guard first || filtered || expanded.contains(row.kind) else { continue }
            outline.expandItem(row)
            // What was open opens again; a filter opens the groups, not the tables.
            func restore(_ node: SidebarNode) {
                for child in node.children where (filtered && child.object == nil) || expanded.contains(child.kind) {
                    outline.expandItem(child)
                    restore(child)
                }
            }
            for database in row.children {
                let current = first && database.database == model.openConnection(id)?.currentDatabase
                guard filtered || current || expanded.contains(database.kind) else { continue }
                outline.expandItem(database)
                restore(database)
            }
        }
        let rows = IndexSet(selected.compactMap { kind -> Int? in
            let row: SidebarNode?
            switch kind {
            case .connection(let id): row = connections[id]
            case .folder(let id): row = folders[id]
            default: row = treeNodes[kind]
            }
            return row.map { outline.row(forItem: $0) }.flatMap { $0 >= 0 ? $0 : nil }
        })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        reloading = false
    }

    @objc private func openConnectionChanged(_ notification: Notification) {
        if let mongo = notification.object as? OpenMongoConnection, model.openMongo[mongo.saved.id] === mongo { return reload() }
        guard let open = notification.object as? OpenConnection, model.open[open.id] === open else { return }
        reload()
    }

    /// Redraws the rows (a connection's state changed).
    func refreshRows() {
        let rows = IndexSet(0..<outline.numberOfRows)
        outline.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    @objc private func filterChanged() { reload() }

    func controlTextDidChange(_ notification: Notification) { reload() }

    /// ↓ in the filter goes to the list, on the first row that matches; Return opens that row, as it does in the list.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let opens = selector == #selector(NSResponder.insertNewline(_:))
        guard opens || selector == #selector(NSResponder.moveDown(_:)) else { return false }
        let text = filter.stringValue.trimmingCharacters(in: .whitespaces)
        guard !opens || !text.isEmpty else { return false }
        let rows = (0..<outline.numberOfRows).filter { row in
            guard let node = outline.item(atRow: row) as? SidebarNode, outlineView(outline, shouldSelectItem: node) else { return false }
            if case .folder = node.kind { return false }
            return true
        }
        let named = rows.first { outlineView(outline, typeSelectStringFor: nil, item: outline.item(atRow: $0) as Any)?
            .localizedCaseInsensitiveContains(text) == true }
        guard let row = named ?? rows.first else { return !opens }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        view.window?.makeFirstResponder(outline)
        // Return kept what was typed for the field's recent searches.
        if opens { filter.recentSearches = [text] + filter.recentSearches.filter { $0 != text }.prefix(9) }
        if opens { doubleClicked(nil) }
        return true
    }

    // MARK: Selection

    var selectedNodes: [SidebarNode] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? SidebarNode }
    }

    /// The selected connections, in the sidebar's order.
    var selectedConnectionIDs: [UUID] { selectedNodes.compactMap(\.connectionID) }

    /// What the next launch selects: the connections and folders selected, a row of a connection's tree standing for the
    /// connection (its tree isn't there until it connects).
    var selectedRowIDs: [UUID] {
        selectedNodes.compactMap { node in
            switch node.kind {
            case .header: return nil
            case .folder(let id), .connection(let id), .database(let id, _), .category(let id, _, _), .object(let id, _),
                 .part(let id, _, _), .detail(let id, _, _, _), .prefix(let id, _, _, _), .message(let id, _), .users(let id),
                 .mongo(let id, _): return id
            }
        }
    }

    /// Selects these connections and folders (none: no selection).
    func select(_ ids: [UUID]) {
        let rows = IndexSet(ids.compactMap { connections[$0] ?? folders[$0] }.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { outline.scrollRowToVisible(first) }
    }

    /// Selects a row of a connected connection's tree and scrolls to it: the filter goes if only it hides the row (false: the row can't be shown), and what's
    /// above the row opens. `showing`: what a click on it shows appears too.
    @discardableResult func reveal(_ kind: SidebarNode.Kind, showing: Bool = false) -> Bool {
        func row() -> SidebarNode? {
            if case .connection(let id) = kind { return connections[id] }
            return treeNodes[kind]
        }
        let typed = filter.stringValue
        if row() == nil, !typed.isEmpty {
            filter.stringValue = ""
            reload()
            // Left out by something else too (Favourites Only, the database filter): the person's filter stays.
            if row() == nil {
                filter.stringValue = typed
                reload()
            }
        }
        guard let node = row(), let id = node.connectionOfTree ?? node.connectionID else { return false }
        var above = [model.connection(id)?.folderID.flatMap { folders[$0] }, connections[id]]
        if case .mongo(_, let item) = kind, item.collection != nil {
            above += [treeNodes[.mongo(id, MongoTreeItem(database: item.database))],
                      item.index == nil ? nil : treeNodes[.mongo(id, MongoTreeItem(database: item.database, collection: item.collection))]]
        } else if let database = node.database, kind != .database(id, database) {
            above.append(treeNodes[.database(id, database)])
            if let object = node.object {
                above.append(treeNodes[.category(id, database, object.kind)])
                above.append(TreeGrouping.prefix(of: object.name).flatMap { treeNodes[.prefix(id, database, object.kind, $0)] })
            }
        }
        above.compactMap { $0 }.forEach(outline.expandItem)
        let index = outline.row(forItem: node)
        guard index >= 0 else { return false }
        revealing = !showing
        outline.selectRowIndexes([index], byExtendingSelection: false)
        revealing = false
        outline.scrollRowToVisible(index)
        return true
    }

    /// Follow Tab: a row the tree shows now, selected unless it is already; the filter stays.
    func follow(_ kind: SidebarNode.Kind) {
        guard treeNodes[kind] != nil, selectedNodes.map(\.kind) != [kind] else { return }
        reveal(kind)
    }

    /// Connecting leads to the server's host page, unless a tab of that connection is showing (the one that asked).
    private func showHostOfNewConnection() {
        let connected = Set(model.open.keys)
        defer { knownConnections = connected }
        guard selectedConnectionIDs.count == 1, selectedNodes.count == 1, let id = selectedConnectionIDs.first,
              connected.subtracting(knownConnections).contains(id), main?.selectedTab?.connectionID != id else { return }
        showSelectedObject()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !reloading else { return }
        onSelect?()
        guard !openingMenu, !revealing else { return }
        // Arrowing passes over rows: only the one it stops on is read, or the others would queue ahead of it.
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(showSelectedObject), object: nil)
        if NSApp.currentEvent?.type == .keyDown {
            perform(#selector(showSelectedObject), with: nil, afterDelay: 0.3)
        } else {
            showSelectedObject()
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        if case .message = node.kind { return false }
        return node.kind != .header
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        switch node.kind {
        case .database(let id, let name): model.openConnection(id)?.loadDetails(name)
        case .object(let id, let object): model.openConnection(id)?.loadDetails(object.database)
        case .mongo(let id, let item): mongoOpened(id, item)
        default: break
        }
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard let node = item as? SidebarNode else { return nil }
        switch node.kind {
        case .connection(let id): return model.connection(id)?.displayName
        case .folder(let id): return model.data.folders.first { $0.id == id }?.name
        default: return node.name
        }
    }

    /// Dragging tree rows puts their names, quoted for SQL, on the pasteboard (into the editor); a connection's row
    /// goes to a folder.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? SidebarNode else { return nil }
        let item = NSPasteboardItem()
        if let id = node.connectionID {
            item.setString(id.uuidString, forType: .sidebarConnection)
        } else if let text = NSEvent.modifierFlags.contains(.shift) ? node.object?.quoted ?? node.quotedName : node.quotedName {
            // ⇧ adds the database to the name; a table dropped on a database row copies there.
            item.setString(text, forType: .string)
            if let object = node.object, object.kind == .table { item.setString(object.database + "\u{0}" + object.name, forType: .sidebarTable) }
        } else {
            return nil
        }
        return item
    }

    /// The row a connection dropped on `node` lands in: a folder, a connection's folder, or the list outside any
    /// folder (the heading); the tree's rows take nothing.
    func dropRow(on node: SidebarNode?) -> SidebarNode? {
        switch node?.kind {
        case nil, .header?: return header
        case .folder?: return node
        case .connection(let id)?:
            return model.connection(id)?.folderID.flatMap { folders[$0] } ?? header
        default: return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        if info.draggingSource as AnyObject === outline, info.draggingPasteboard.availableType(from: [.sidebarTable]) != nil {
            // A table goes to a database of its own connection, by way of Copy Table's questions.
            guard let row = item as? SidebarNode, case .database = row.kind, row.connectionOfTree == treeSelection?.open.id else { return [] }
            outlineView.setDropItem(row, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }
        guard info.draggingSource as AnyObject === outline, info.draggingPasteboard.availableType(from: [.sidebarConnection]) != nil,
              let row = dropRow(on: item as? SidebarNode) else { return [] }
        outlineView.setDropItem(row, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let row = item as? SidebarNode else { return false }
        if case .database(let id, let database) = row.kind {
            guard let open = model.openConnection(id), let text = info.draggingPasteboard.string(forType: .sidebarTable) else { return false }
            let parts = text.split(separator: "\u{0}", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return false }
            NavigatorActions.copyTable(DatabaseObject(.table, parts[0], parts[1]), on: open, window: view.window, into: database)
            return true
        }
        var folder: UUID?
        if case .folder(let id) = row.kind { folder = id }
        let ids = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .sidebarConnection).flatMap(UUID.init) }
        model.move(ids, toFolder: folder)
        return !ids.isEmpty
    }

    @objc fileprivate func doubleClicked(_ sender: Any?) {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard let node = outline.item(atRow: row) as? SidebarNode else { return }
        switch node.kind {
        case .header: break
        case .folder:
            if outline.isItemExpanded(node) { gently(outline).collapseItem(node) } else { gently(outline).expandItem(node) }
        case .connection(let id):
            // Connected, it opens and closes as the tree's rows do; else whatever connects implements Connect.
            guard model.openConnection(id) != nil || model.openMongo[id] != nil else {
                outline.sendCommand(Commands.connect.action)
                return
            }
            if outline.isItemExpanded(node) { gently(outline).collapseItem(node) } else { gently(outline).expandItem(node) }
        case .database, .category, .object, .part, .detail, .prefix, .mongo:
            treeDoubleClicked(node)
        case .message, .users:
            break  // a click already showed Users and Roles
        }
    }

    /// The menu of the selected rows (plan §2.12), for a right-click: a connection's commands, or a folder's.
    func contextMenu() -> NSMenu? {
        let nodes = selectedNodes
        guard !nodes.isEmpty else { return nil }
        let menu = NSMenu(title: "Connection")
        if nodes.allSatisfy({ $0.connectionID != nil }) {
            menu.add([Commands.connect, Commands.disconnect, nil, Commands.editConnection, Commands.duplicateConnection,
                      Commands.newQuery, Commands.openInTerminal, nil, Commands.export, Commands.restore, Commands.compareWith,
                      Commands.compareRows, Commands.diskUsage, Commands.users, nil])
            if nodes.count == 1, let id = nodes[0].connectionID, model.openMongo[id] != nil { Self.addMongoHostItems(to: menu) }
            menu.addItem(ConnectionMenus.colourMenu())
            menu.addItem(ConnectionMenus.moveMenu())
            menu.add([Commands.moveConnectionUp, Commands.moveConnectionDown, Commands.databasesShown])
            menu.add([nil, Commands.deleteConnection])
            let connections = nodes.compactMap { $0.connectionID.flatMap(model.connection) }
            MongoShellMenu.replaceTerminal(in: menu, connections: connections)
            MongoDumpMenu.replaceExportRestore(in: menu, connections: connections)
        } else if nodes.allSatisfy({ $0.connectionOfTree != nil }) {
            return treeMenu(nodes)
        } else {
            menu.add([Commands.newConnection, Commands.newFolder, nil, Commands.renameFolder, Commands.deleteFolder])
        }
        return menu
    }

    /// The menu of the list's empty space: what can be made there.
    fileprivate func blankMenu() -> NSMenu {
        outline.deselectAll(nil)  // or New Folder… would take the selected connections with it
        let menu = NSMenu(title: "Connections")
        menu.add([Commands.newConnection, Commands.newFolder])
        return menu
    }

    // MARK: Data source and rows

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? SidebarNode else { return 1 }
        // A table's rows are made when it opens: reloads leave them out, a server can have thousands of tables.
        if node.children.isEmpty, case .object(let id, let object) = node.kind, object.kind.hasParts {
            node.children = tableParts(id, object)
        }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? SidebarNode else { return header }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        if case .folder = node.kind { return true }
        if case .object(_, let object) = node.kind { return object.kind.hasParts }
        return node.kind == .header || !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind == .header
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind != .header
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let cell = (outlineView.makeView(withIdentifier: SidebarCell.identifier, owner: nil) as? SidebarCell) ?? SidebarCell()
        switch node.kind {
        case .header:
            cell.showHeader("CONNECTIONS")
        case .folder(let id):
            let folder = model.data.folders.first { $0.id == id }
            cell.showFolder(folder?.name ?? "", count: node.children.count)
        case .connection(let id):
            if let connection = model.connection(id) {
                cell.show(connection, state: model.states[id], busy: model.openConnection(id)?.loading.contains(.schema) == true
                    || model.openMongo[id]?.loading.contains("") == true)
                if let shown = shownDatabases(id) { cell.showDatabases(shown) }
            }
        case .database, .category, .object, .part, .detail, .prefix, .message, .users, .mongo:
            return treeCell(node, in: outlineView)
        }
        return cell
    }
}

extension NSPasteboard.PasteboardType {
    /// A connection's row dragged inside the sidebar: its id.
    static let sidebarConnection = NSPasteboard.PasteboardType("com.airsql.sidebar-connection")
    /// A table's row dragged inside the sidebar: its database and name.
    static let sidebarTable = NSPasteboard.PasteboardType("com.airsql.sidebar-table")
}

/// The outline: a right-click selects the row under the pointer first (unless it is part of the selection) and opens
/// the menu of the selection (the empty space has its own); Return connects, Delete forgets.
@MainActor
final class SidebarOutlineView: NSOutlineView {
    weak var sidebar: SidebarController?

    override func menu(for event: NSEvent) -> NSMenu? {
        let header = (item(atRow: row(at: convert(event.locationInWindow, from: nil))) as? SidebarNode)?.kind == .header
        sidebar?.openingMenu = true
        defer { sidebar?.openingMenu = false }
        return !header && selectsRow(for: event) ? sidebar?.contextMenu() : sidebar?.blankMenu()
    }

    /// ⌘F here goes to the filter, unless the tab shown has a find of its own (the window sends it on).
    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(performTextFinderAction(_:)), sidebar?.main?.selectedTab?.shown.responds(to: selector) == true { return false }
        return super.responds(to: selector)
    }

    override func performTextFinderAction(_ sender: Any?) { sidebar?.main?.filterSidebar(sender) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(performTextFinderAction(_:)) else { return super.validateUserInterfaceItem(item) }
        return item.tag == NSTextFinder.Action.showFindInterface.rawValue
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:  // Return, Enter: as a double-click
            if let action = doubleAction { NSApp.sendAction(action, to: target, from: self) }
        case 51, 117:  // Delete, Forward Delete
            if sidebar?.selectedConnectionIDs.isEmpty == false {
                sendCommand(Commands.deleteConnection.action)
            } else if sidebar?.selectedNodes.contains(where: { $0.connectionOfTree != nil }) == true {
                sendCommand(Commands.drop.action)
            } else if sidebar?.selectedFolderNodeID != nil {
                sendCommand(Commands.deleteFolder.action)
            }
        default:
            super.keyDown(with: event)
        }
    }
}

/// A sidebar row: the selection as an accent-coloured rounded pill (grey while the list doesn't have the focus).
final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 6, dy: 0)
        (isEmphasized ? NSColor.accent : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: rect, xRadius: Radius.cell + 1, yRadius: Radius.cell + 1).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected && isEmphasized ? .emphasized : .normal }
}

/// A sidebar cell: a connection (its colour dot, name, the custom-safety mark, its state and route), a folder, or the
/// section heading.
final class SidebarCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
    private let dot = DotView(diameter: 9)
    private let name = NSTextField(labelWithString: "")
    private let shield = NSImageView()
    private let state = NSImageView()
    private let lock = NSImageView()
    private let mongo = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    /// The name's colour off the selection (the heading's is quieter).
    private var nameColour = NSColor.labelColor

    /// On the selection's accent: the accent's own text colour, as the mockups give it (AppKit's white is 2.4:1 on Deep
    /// Water's petrol).
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { colour() }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        badge.font = .systemFont(ofSize: 11)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        shield.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Custom safety")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        shield.contentTintColor = .statusWarning
        shield.toolTip = "Custom safety: this connection has safety settings of its own (its Safety tab)"
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Read-only")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        lock.contentTintColor = .secondaryLabelColor
        lock.toolTip = "Read-only: AirSQL refuses writes on this connection"
        mongo.image = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "MongoDB")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        mongo.contentTintColor = .secondaryLabelColor
        mongo.toolTip = "MongoDB: this connection is to a MongoDB server"
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Loading the schema")
        let stack = NSStackView(views: [icon, dot, mongo, name, lock, shield, spinner, state, badge])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.setVisibilityPriority(.detachOnlyIfNecessary, for: badge)
        addSubview(stack)
        textField = name
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// `busy`: its schema is loading (the spinner shows).
    func show(_ connection: SavedConnection, state connectionState: ConnectionState?, busy: Bool = false) {
        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        icon.isHidden = true
        dot.isHidden = false
        dot.color = connection.colour.color ?? .tertiaryLabelColor
        name.stringValue = connection.displayName.isEmpty ? "Untitled" : connection.displayName
        name.font = .systemFont(ofSize: 13)
        nameColour = .labelColor
        colour()
        shield.isHidden = !connection.hasCustomSafety
        lock.isHidden = !connection.readOnly
        mongo.isHidden = connection.engine != .mongodb
        badge.isHidden = false
        badge.stringValue = (connection.isProduction ? "PROD · " : "") + connection.routeBadge
        // Each state its own shape, not only its own colour.
        let symbol: (name: String, colour: NSColor)?
        var next = "double-click to connect"
        switch connectionState {
        case .connected?:
            symbol = ("checkmark.circle.fill", .statusOK)
            next = "double-click to show it"
        case .connecting?:
            symbol = ("ellipsis.circle.fill", .statusWarning)
            next = "connecting"
        case .failed?:
            symbol = ("exclamationmark.triangle.fill", .statusBad)
            next = "double-click to try again"
        case nil: symbol = nil
        }
        let status = stateText(connectionState)
        state.isHidden = symbol == nil
        state.image = symbol.flatMap { NSImage(systemSymbolName: $0.name, accessibilityDescription: status) }?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        state.contentTintColor = symbol?.colour
        state.toolTip = status
        let where_ = connection.route == .direct && !connection.socket.isEmpty ? connection.socket
            : connection.host + (connection.port.map { ":\($0)" } ?? "")
        toolTip = name.stringValue + (where_.isEmpty ? "" : " — " + where_) + " · " + connection.routeBadge
            + (connection.marks.isEmpty ? "" : " · " + connection.marks) + ": " + next + ", right-click for more"
        setAccessibilityLabel([name.stringValue, connection.engine == .mongodb ? "MongoDB" : "", connection.marks, status].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// Adds how many of the server's databases the tree shows, when not all ("3 of 12").
    func showDatabases(_ text: String) {
        badge.stringValue = text + " · " + badge.stringValue
    }

    func showFolder(_ title: String, count: Int) {
        spinner.isHidden = true
        icon.isHidden = false
        dot.isHidden = true
        name.stringValue = title
        name.font = .systemFont(ofSize: 13)
        nameColour = .labelColor
        colour()
        shield.isHidden = true
        mongo.isHidden = true
        lock.isHidden = true
        state.isHidden = true
        badge.isHidden = false
        badge.stringValue = "\(count)"
        toolTip = "\(title): \(count) connection\(count == 1 ? "" : "s"); double-click to open or close the folder"
    }

    func showHeader(_ title: String) {
        spinner.isHidden = true
        icon.isHidden = true
        dot.isHidden = true
        name.stringValue = title
        name.font = .systemFont(ofSize: 11, weight: .semibold)
        nameColour = .quietText
        colour()
        shield.isHidden = true
        mongo.isHidden = true
        lock.isHidden = true
        state.isHidden = true
        badge.isHidden = true
        toolTip = nil
    }

    private func colour() {
        let selected = backgroundStyle == .emphasized
        name.textColor = selected ? .onAccent : nameColour
        badge.textColor = selected ? .onAccent : .quietText
        icon.contentTintColor = selected ? .onAccent : .secondaryLabelColor
    }
}

extension SidebarController {
    /// The menu of a filter's magnifying glass: what was searched lately.
    static func recentsMenu() -> NSMenu {
        let menu = NSMenu(title: "Recent")
        for (title, tag) in [("Recent Filters", NSSearchField.recentsTitleMenuItemTag), ("", NSSearchField.recentsMenuItemTag),
                             ("No Recent Filters", NSSearchField.noRecentsMenuItemTag), ("Clear Recent Filters", NSSearchField.clearRecentsMenuItemTag)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = tag
            menu.addItem(item)
        }
        return menu
    }
}
