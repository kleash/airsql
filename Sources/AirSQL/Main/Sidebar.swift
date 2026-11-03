import AirSQLCore
import AppKit
import Combine

/// A row of the sidebar's outline: the connections in their folders and, under a connected one, the navigator's tree
/// (its databases, each object kind's group, the objects, and a message while it loads).
@MainActor
final class SidebarNode: NSObject {
    enum Kind: Hashable {
        case header
        case folder(UUID)
        case connection(UUID)
        case database(UUID, String)
        case category(UUID, String, DatabaseObject.Kind)
        case object(UUID, DatabaseObject)
        case message(UUID, String)
    }

    let kind: Kind
    var children: [SidebarNode] = []

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
/// summary, a double-click connects, a right-click opens its menu; ⌘ and ⇧ select several.
@MainActor
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    let model: AppModel
    weak var main: MainWindowController?
    let outline = SidebarOutlineView()
    let filter = NSSearchField()
    private let header = SidebarNode(.header)
    private var folders: [UUID: SidebarNode] = [:]
    private var connections: [UUID: SidebarNode] = [:]
    /// The tree's rows by kind, kept across reloads so they stay selected and expanded.
    private(set) var treeNodes: [SidebarNode.Kind: SidebarNode] = [:]
    /// Connections whose tree has been opened once since they connected.
    private var treeShown: Set<UUID> = []
    private var observers: [AnyCancellable] = []
    private var reloading = false
    /// Called when the selected connections change.
    var onSelect: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = SurfaceView(.side)
        root.setAccessibilityIdentifier("sidebar")
        filter.placeholderString = "Filter by name"
        filter.toolTip = Commands.filterSidebar.tip + " (⌥⌘J)"
        filter.setAccessibilityIdentifier("sidebar.filter")
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        filter.target = self
        filter.action = #selector(filterChanged)
        filter.translatesAutoresizingMaskIntoConstraints = false

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
        add.toolTip = Commands.newConnection.tip + " (⌘N)"
        add.setAccessibilityIdentifier("sidebar.newConnection")
        add.translatesAutoresizingMaskIntoConstraints = false
        let processes = NSButton(title: "Processes", target: nil, action: Commands.processList.action)
        processes.isBordered = false
        processes.font = .systemFont(ofSize: 11.5)
        processes.contentTintColor = .secondaryLabelColor
        processes.toolTip = Commands.processList.tip + " (⌥⌘P)"
        processes.setAccessibilityIdentifier("sidebar.processes")
        processes.translatesAutoresizingMaskIntoConstraints = false
        let footerLine = Hairline()

        [filter, scroll, footerLine, add, processes].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            filter.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.unit),
            filter.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            filter.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: Spacing.half),
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
            processes.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            processes.leadingAnchor.constraint(greaterThanOrEqualTo: add.trailingAnchor, constant: Spacing.unit),
        ])
        view = root
        observers.append(model.$data.map(\.connections).removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        })
        observers.append(model.$data.map(\.folders).removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        })
        observers.append(model.$states.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshRows() }
        })
        observers.append(model.$open.sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        })
        NotificationCenter.default.addObserver(self, selector: #selector(openConnectionChanged), name: .openConnectionDidChange,
                                               object: nil)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        reload()
    }

    // MARK: Contents

    /// Rebuilds the rows from the model and the filter, keeping the selection and what is expanded. While filtering, a
    /// connected connection whose name doesn't match shows the objects that do, expanded.
    func reload() {
        let selected = selectedNodes.map(\.kind)
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
        treeShown.formIntersection(model.open.keys)
        reloading = true
        outline.reloadData()
        outline.expandItem(header)
        for (id, row) in folders where firstLoad || !text.isEmpty || expanded.contains(.folder(id)) { outline.expandItem(row) }
        // A tree opens the first time it shows (with the connection's database), keeps what was open, and opens all of
        // a filtered one.
        for row in open {
            guard let id = row.connectionID else { continue }
            let filtered = !text.isEmpty && !named.contains(id)
            let first = !treeShown.contains(id)
            treeShown.insert(id)
            guard first || filtered || expanded.contains(row.kind) else { continue }
            outline.expandItem(row)
            for database in row.children {
                let current = first && database.database == model.openConnection(id)?.currentDatabase
                guard filtered || current || expanded.contains(database.kind) else { continue }
                outline.expandItem(database)
                for group in database.children where filtered || expanded.contains(group.kind) { outline.expandItem(group) }
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

    // MARK: Selection

    var selectedNodes: [SidebarNode] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? SidebarNode }
    }

    /// The selected connections, in the sidebar's order.
    var selectedConnectionIDs: [UUID] { selectedNodes.compactMap(\.connectionID) }

    /// Selects these connections (none: no selection).
    func select(_ ids: [UUID]) {
        let rows = IndexSet(ids.compactMap { connections[$0] }.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { outline.scrollRowToVisible(first) }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !reloading else { return }
        onSelect?()
        showSelectedObject()
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        if case .message = node.kind { return false }
        return node.kind != .header
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode, case .database(let id, let name) = node.kind else { return }
        model.openConnection(id)?.loadDetails(name)
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard let node = item as? SidebarNode else { return nil }
        switch node.kind {
        case .connection(let id): return model.connection(id)?.displayName
        case .folder(let id): return model.data.folders.first { $0.id == id }?.name
        default: return node.name
        }
    }

    /// Dragging tree rows puts their names, quoted for SQL, on the pasteboard (into the editor).
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? SidebarNode, let text = node.quotedName else { return nil }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        return item
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard let node = outline.item(atRow: row) as? SidebarNode else { return }
        switch node.kind {
        case .header: break
        case .folder:
            if outline.isItemExpanded(node) { outline.animator().collapseItem(node) } else { outline.animator().expandItem(node) }
        case .connection:
            // Connect (or show it when connected): whatever connects implements it.
            outline.sendCommand(Commands.connect.action)
        case .database, .category, .object:
            treeDoubleClicked(node)
        case .message:
            break
        }
    }

    /// The menu of the selected rows (plan §2.12), for a right-click: a connection's commands, or a folder's.
    func contextMenu() -> NSMenu? {
        let nodes = selectedNodes
        guard !nodes.isEmpty else { return nil }
        let menu = NSMenu(title: "Connection")
        if nodes.allSatisfy({ $0.connectionID != nil }) {
            menu.add([Commands.connect, Commands.disconnect, nil, Commands.editConnection, Commands.duplicateConnection,
                      Commands.newQuery, Commands.openInTerminal, nil, Commands.export, Commands.restore, Commands.compare, nil])
            menu.addItem(ConnectionMenus.colourMenu())
            menu.add([nil, Commands.deleteConnection])
        } else if nodes.allSatisfy({ $0.connectionOfTree != nil }) {
            return treeMenu(nodes)
        } else {
            menu.add([Commands.newConnection, Commands.newFolder, nil, Commands.renameFolder, Commands.deleteFolder])
        }
        return menu
    }

    // MARK: Data source and rows

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? SidebarNode else { return 1 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? SidebarNode else { return header }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        if case .folder = node.kind { return true }
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
                cell.show(connection, state: model.states[id], busy: model.openConnection(id)?.loading.contains(.schema) == true)
            }
        case .database, .category, .object, .message:
            return treeCell(node, in: outlineView)
        }
        return cell
    }
}

/// The outline: a right-click selects the row under the pointer first (unless it is part of the selection) and opens
/// the menu of the selection; Return connects, Delete forgets.
@MainActor
final class SidebarOutlineView: NSOutlineView {
    weak var sidebar: SidebarController?

    override func menu(for event: NSEvent) -> NSMenu? {
        let header = (item(atRow: row(at: convert(event.locationInWindow, from: nil))) as? SidebarNode)?.kind == .header
        return !header && selectsRow(for: event) ? sidebar?.contextMenu() : nil
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
    private let state = DotView(diameter: 6)
    private let badge = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        badge.font = .systemFont(ofSize: 11)
        badge.textColor = .tertiaryLabelColor
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        shield.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "Custom safety")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        shield.contentTintColor = .statusWarning
        shield.toolTip = "Custom safety: this connection has safety settings of its own (its Safety tab)"
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Loading the schema")
        let stack = NSStackView(views: [icon, dot, name, shield, spinner, state, badge])
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
        name.textColor = .labelColor
        shield.isHidden = !connection.hasCustomSafety
        badge.isHidden = false
        badge.stringValue = connection.routeBadge
        switch connectionState {
        case .connected?: state.color = .statusOK
        case .connecting?: state.color = .statusWarning
        case .failed?: state.color = .statusBad
        case nil: state.color = nil
        }
        let where_ = connection.route == .direct && !connection.socket.isEmpty ? connection.socket
            : connection.host + (connection.port.map { ":\($0)" } ?? "")
        toolTip = name.stringValue + (where_.isEmpty ? "" : " — " + where_) + " · " + connection.routeBadge
            + ": double-click to connect, right-click for more"
        setAccessibilityLabel(name.stringValue)
    }

    func showFolder(_ title: String, count: Int) {
        spinner.isHidden = true
        icon.isHidden = false
        dot.isHidden = true
        name.stringValue = title
        name.font = .systemFont(ofSize: 13)
        name.textColor = .labelColor
        shield.isHidden = true
        state.color = nil
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
        name.textColor = .tertiaryLabelColor
        shield.isHidden = true
        state.color = nil
        badge.isHidden = true
        toolTip = nil
    }
}
