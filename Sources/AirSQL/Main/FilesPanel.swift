import AirSQLCore
import AppKit
import Combine

/// A row of the Files panel: a scratch or attached folder at the top, what's inside under it.
@MainActor
final class FileNode: NSObject {
    let url: URL
    let isFolder: Bool
    /// Nil until the folder is opened.
    var children: [FileNode]?

    init(_ url: URL, isFolder: Bool) {
        self.url = url
        self.isFolder = isFolder
    }
}

/// The Files panel, in the sidebar in the tree's place: scratch files and attached folders of scripts. Folders are read
/// off the main thread as they open and again as AirSQL comes to the front. A click selects, a double-click opens a file
/// in a query tab or opens a folder, a right-click opens the menu, whose Run On goes through Run SQL File….
@MainActor
final class FilesPanelController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuItemValidation {
    let model: AppModel
    let outline = FilesOutlineView()
    private(set) var roots: [FileNode] = []
    private var nodes: [URL: FileNode] = [:]
    private var observers: [AnyCancellable] = []
    private var main: MainWindowController? { (parent as? SidebarController)?.main }

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = SurfaceView(.side)
        root.setAccessibilityIdentifier("files")
        let heading = label("Files", font: .systemFont(ofSize: 11.5, weight: .semibold), color: .secondaryLabelColor)
        let scratch = iconButton("doc.badge.plus", Commands.newScratch, id: "files.newScratch")
        let attach = iconButton("folder.badge.plus", Commands.attachFolder, id: "files.attach")
        let top = NSStackView(views: [heading, NSView(), scratch, attach])
        top.spacing = Spacing.half
        top.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.rowHeight = 22
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.allowsMultipleSelection = true
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.panel = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.setAccessibilityIdentifier("files.outline")
        outline.setAccessibilityLabel("Files")
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(top)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.unit),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: Spacing.half),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        observers.append(model.$data.map(\.settings.tree.attachedFolders).removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        })
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    private func iconButton(_ symbol: String, _ command: Command, id: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: command.title) ?? NSImage(), target: nil,
                              action: command.action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = command.tip
        button.setAccessibilityIdentifier(id)
        return button
    }

    @objc private func appBecameActive() { if !view.isHidden { reload() } }

    private func node(_ url: URL, isFolder: Bool) -> FileNode {
        if let known = nodes[url], known.isFolder == isFolder { return known }
        let made = FileNode(url, isFolder: isFolder)
        nodes[url] = made
        return made
    }

    /// Reads again the folders opened so far, and the top ones.
    @discardableResult
    func reload() -> Task<Void, Never> {
        let top = [ScriptFiles.scratchFolder] + model.data.settings.tree.attachedFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
        roots = top.map { node($0, isFolder: true) }
        for root in roots where root.children == nil { root.children = [] }
        let opened = nodes.values.filter { $0.children != nil }.map(\.url)
        return Task {
            let listed = await Task.detached { opened.map { ($0, ScriptFiles.entries(in: $0)) } }.value
            for (url, entries) in listed { nodes[url]?.children = entries.map { node($0.url, isFolder: $0.isFolder) } }
            _ = view  // read before the panel has first shown, as in a test
            outline.reloadData()
            roots.forEach { if $0.children?.isEmpty == false, !outlineKnowsExpanded.contains($0.url) { outline.expandItem($0); outlineKnowsExpanded.insert($0.url) } }
        }
    }

    /// Top folders opened once: they open by themselves the first time, then stay as the person leaves them.
    private var outlineKnowsExpanded = Set<URL>()

    // MARK: The outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? roots.count : (item as? FileNode)?.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        item == nil ? roots[index] : (item as? FileNode)?.children?[index] as Any
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileNode)?.isFolder == true }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode, node.children == nil else { return }
        let url = node.url
        node.children = []
        Task {
            let entries = await Task.detached { ScriptFiles.entries(in: url) }.value
            node.children = entries.map { self.node($0.url, isFolder: $0.isFolder) }
            outline.reloadItem(node, reloadChildren: true)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SidebarRowView() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("FileCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let image = NSImageView(), text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.font = .systemFont(ofSize: 12.5)
            image.translatesAutoresizingMaskIntoConstraints = false
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.addSubview(text)
            cell.imageView = image
            cell.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: Spacing.half),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Spacing.half),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.imageView?.image = NSImage(systemSymbolName: node.isFolder ? "folder" : "doc.text", accessibilityDescription: nil)
        cell.imageView?.contentTintColor = .secondaryLabelColor
        cell.textField?.stringValue = node.url == ScriptFiles.scratchFolder ? "Scratches" : node.url.lastPathComponent
        cell.toolTip = (node.url.path as NSString).abbreviatingWithTildeInPath
        return cell
    }

    // MARK: Commands

    /// The rows acted on (a right-click selects its row first).
    var chosen: [FileNode] { outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode } }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let node = outline.item(atRow: outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow) as? FileNode else { return }
        guard node.isFolder else { return open(chosen.contains(node) ? chosen : [node]) }
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }

    private func open(_ nodes: [FileNode]) {
        let files = nodes.filter { !$0.isFolder }.map(\.url)
        if !files.isEmpty { main?.openFiles(files) }
    }

    @objc func openChosen(_ sender: Any?) { open(chosen) }

    @objc func detachFolder(_ sender: Any?) {
        let paths = Set(chosen.map(\.url.path))
        model.data.settings.tree.attachedFolders.removeAll { paths.contains($0) }
    }

    /// Run On ▸ a connection: the file, or the .sql files of the folders in order, in Run SQL File…, which shows the
    /// file's target and waits for its Run.
    @objc func runChosen(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID, let saved = model.connection(id), let main else { return }
        let picked = chosen
        Task {
            let files = await Task.detached { [urls = picked.map { ($0.url, $0.isFolder) }] in
                urls.flatMap { url, isFolder in isFolder ? ScriptFiles.scripts(in: url) : [url] }
            }.value
            guard !files.isEmpty else {
                return showError("Only .sql and .sql.gz files run, and there are none there.", title: "Nothing to run", on: main.window)
            }
            sequence(first: main as NSResponder, next: \.nextResponder).lazy.compactMap { $0 as? ToolsResponder }.first?.open(files: files, on: saved)
        }
    }

    @objc func revealInFinder(_ sender: Any?) { NSWorkspace.shared.activateFileViewerSelecting(chosen.map(\.url)) }

    @objc func copyPath(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(chosen.map(\.url.path).joined(separator: "\n"), forType: .string)
    }

    /// Only scratch files: the folders you attach are yours, and this panel doesn't change them.
    @objc func trashChosen(_ sender: Any?) {
        guard !AgentGuard.refuses("Files on this Mac are the person's: only they can move one to the Trash.") else { return }
        let urls = chosen.map(\.url).filter { ScriptFiles.isScratch($0) }
        Task {
            await Task.detached { urls.forEach { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) } }.value
            reload()
        }
    }

    @objc func refresh(_ sender: Any?) { reload() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let picked = chosen
        var enabled = !picked.isEmpty, reason = "Select a file or folder first"
        switch item.action {
        case Commands.openFile.action?:
            enabled = picked.contains { !$0.isFolder }
            reason = "Select a file first"
        case Commands.detachFolder.action?:
            let attached = model.data.settings.tree.attachedFolders
            enabled = !picked.isEmpty && picked.allSatisfy { attached.contains($0.url.path) }
            reason = "Select attached folders, at the top of the list"
        case Commands.trashScratch.action?:
            enabled = !picked.isEmpty && picked.allSatisfy { ScriptFiles.isScratch($0.url) }
            reason = "Only scratch files go to the Trash from here: your own folders stay as they are"
        case Commands.refresh.action?:
            enabled = true
        default:
            break
        }
        item.explain(enabled: enabled, reason: enabled ? nil : reason)
        return enabled
    }

    /// The menu of the rows chosen; on the empty part, what makes rows.
    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ commands: [Command?]) {
            for command in commands {
                let item = command?.item() ?? .separator()
                if command?.action != Commands.newScratch.action, command?.action != Commands.attachFolder.action { item.target = self }
                menu.addItem(item)
            }
        }
        if !chosen.isEmpty {
            add([Commands.openFile])
            let connections = model.sections(filter: "").flatMap(\.connections).map { connection -> NSMenuItem in
                let item = Commands.runFileOn.item()
                item.title = connection.displayName
                item.target = self
                item.representedObject = connection.id
                return item
            }
            menu.addItem(MainMenu.submenu("Run On", connections))
            add([nil, Commands.revealInFinder, Commands.copyPath, nil, Commands.trashScratch, Commands.detachFolder, nil])
        }
        add([Commands.newScratch, Commands.attachFolder, Commands.refresh])
        return menu
    }
}

/// The Files panel's outline: a right-click selects the row under the pointer first; Return opens.
@MainActor
final class FilesOutlineView: NSOutlineView {
    weak var panel: FilesPanelController?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row < 0 {
            deselectAll(nil)
        } else if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return panel?.contextMenu()
    }

    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode) { panel?.openChosen(nil) } else { super.keyDown(with: event) }
    }
}
