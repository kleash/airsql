import AirSQLCore
import AppKit
import Combine

/// A row of the sidebar's outline. The navigator (L5) adds the schema tree's kinds under a connected connection.
@MainActor
final class SidebarNode: NSObject {
    enum Kind: Equatable {
        case header
        case folder(UUID)
        case connection(UUID)
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
        filter.placeholderString = "Filter connections"
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
        reload()
    }

    // MARK: Contents

    /// Rebuilds the rows from the model and the filter, keeping the selection.
    func reload() {
        let selected = selectedConnectionIDs
        var expandedFolders = Set(folders.compactMap { id, node in outline.isItemExpanded(node) ? id : nil })
        let firstLoad = folders.isEmpty && connections.isEmpty
        header.children = []
        var newFolders: [UUID: SidebarNode] = [:], newConnections: [UUID: SidebarNode] = [:]
        for section in model.sections(filter: filter.stringValue) {
            let rows = section.connections.map { connection -> SidebarNode in
                let node = connections[connection.id] ?? SidebarNode(.connection(connection.id))
                newConnections[connection.id] = node
                return node
            }
            if let folder = section.folder {
                let node = folders[folder.id] ?? SidebarNode(.folder(folder.id))
                node.children = rows
                newFolders[folder.id] = node
                header.children.append(node)
                if firstLoad || !filter.stringValue.isEmpty { expandedFolders.insert(folder.id) }
            } else {
                header.children += rows
            }
        }
        folders = newFolders
        connections = newConnections
        reloading = true
        outline.reloadData()
        outline.expandItem(header)
        for (id, node) in folders where expandedFolders.contains(id) { outline.expandItem(node) }
        select(selected.filter { connections[$0] != nil })
        reloading = false
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
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind != .header
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
            NSApp.sendAction(Commands.connect.action, to: nil, from: outline)
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
            menu.addItem(ConnectionMenus.colourMenu(delegate: main))
            menu.add([nil, Commands.deleteConnection])
        } else {
            menu.add([Commands.newConnection])
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
            if let connection = model.connection(id) { cell.show(connection, state: model.states[id]) }
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
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, (item(atRow: row) as? SidebarNode)?.kind != .header else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        window?.makeFirstResponder(self)
        return sidebar?.contextMenu()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:  // Return, Enter: as a double-click
            if let action = doubleAction { NSApp.sendAction(action, to: target, from: self) }
        case 51, 117:  // Delete, Forward Delete
            if !sidebar!.selectedConnectionIDs.isEmpty { NSApp.sendAction(Commands.deleteConnection.action, to: nil, from: self) }
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
        shield.toolTip = "Custom safety: this connection has safety settings of its own (its Options tab)"
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, dot, name, shield, state, badge])
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
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ connection: SavedConnection, state connectionState: ConnectionState?) {
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
