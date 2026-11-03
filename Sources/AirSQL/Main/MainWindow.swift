// The window's shape follows AirSCP 1.4.0 Sources/AirSCP/MainWindow.swift (MainWindowController, NSWindow.open,
// layoutName); its parts are AirSQL's own (plan §2.4).
import AirSQLCore
import AppKit
import Combine

/// AirSQL's window (plan §2.4): the toolbar, the connection's colour under it, the sidebar, the tabs, the content
/// (the selected tab, a connection's summary, or the first-run screen) and the status bar. Lanes open their tabs with
/// `open(_:title:connection:)`; commands reach the focused content through the responder chain.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let model: AppModel
    let sidebar: SidebarController
    let tabBar = TabBarView()
    let statusBar = StatusBarView()
    let toolbarController: MainToolbar
    private let tint = SurfaceView(.clear)
    private var tintHeight: NSLayoutConstraint!
    private let contentHolder = NSView()
    private let split = MainSplitViewController()
    /// Holds the split view controller (in the responder chain after its view); the window's content view is its view.
    private var root: NSViewController?
    private(set) var tabs: [Tab] = []
    private(set) var selectedTab: Tab?
    /// What the content area shows now: "firstRun", "summary", "select" or "tab" (tests and the snapshot read it).
    private(set) var contentKind = ""
    private var shownContent: NSView?
    private var observers: [AnyCancellable] = []
    nonisolated static let minimumSize = NSSize(width: 900, height: 560)
    nonisolated static let defaultSize = NSSize(width: 1180, height: 720)

    init(model: AppModel) {
        self.model = model
        sidebar = SidebarController(model: model)
        toolbarController = MainToolbar(model: model)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = "AirSQL"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isExcludedFromWindowsMenu = true  // Window ▸ AirSQL stands for it
        window.tabbingMode = .disallowed
        super.init(window: window)
        sidebar.main = self
        toolbarController.main = self
        tabBar.controller = self
        window.delegate = self
        // The content view, not a content view controller: a window with one is sized to its view's smallest fitting
        // size at every layout.
        let root = makeRoot()
        self.root = root
        window.contentView = root.view
        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = toolbarController
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.open(size: Self.defaultSize, autosave: layoutName("Main"))
        if split.splitView.autosaveName == nil || UserDefaults.standard.object(forKey: "NSSplitView Subview Frames Sidebar") == nil {
            window.layoutIfNeeded()
            split.splitView.setPosition(236, ofDividerAt: 0)
        }
        sidebar.onSelect = { [weak self] in self?.sidebarSelectionChanged() }
        observers.append(model.$data.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } })
        observers.append(model.$states.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } })
        observers.append(model.$agentStatus.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatus() } })
        observers.append(model.activity.$running.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatus() } })
        NotificationCenter.default.addObserver(self, selector: #selector(tabContentChanged(_:)), name: .tabContentDidChange,
                                               object: nil)
        configureStatusItems()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeRoot() -> NSViewController {
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        let column = NSViewController()
        let columnView = NSView()
        contentHolder.translatesAutoresizingMaskIntoConstraints = false
        [tabBar, contentHolder, statusBar].forEach(columnView.addSubview)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: columnView.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: columnView.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: columnView.trailingAnchor),
            contentHolder.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentHolder.leadingAnchor.constraint(equalTo: columnView.leadingAnchor),
            contentHolder.trailingAnchor.constraint(equalTo: columnView.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: contentHolder.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: columnView.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: columnView.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: columnView.bottomAnchor),
            columnView.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
        ])
        column.view = columnView
        let columnItem = NSSplitViewItem(viewController: column)
        split.splitViewItems = [sidebarItem, columnItem]
        split.splitView.dividerStyle = .thin
        split.splitView.autosaveName = layoutName("Sidebar")

        let root = NSViewController()
        let rootView = NSView()
        tint.translatesAutoresizingMaskIntoConstraints = false
        tint.setAccessibilityIdentifier("tint")
        rootView.addSubview(tint)
        rootView.addSubview(split.view)
        root.addChild(split)
        split.view.translatesAutoresizingMaskIntoConstraints = false
        tintHeight = tint.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: rootView.topAnchor),
            tint.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            tintHeight,
            split.view.topAnchor.constraint(equalTo: tint.bottomAnchor),
            split.view.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            split.view.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        root.view = rootView
        return root
    }

    // MARK: What is active

    /// The connection the window is about: the selected tab's, else the one selected in the sidebar.
    var activeConnection: SavedConnection? {
        if let tab = selectedTab, let id = tab.connectionID { return model.connection(id) }
        return selectedConnections.count == 1 ? selectedConnections.first : nil
    }

    /// The connections selected in the sidebar.
    var selectedConnections: [SavedConnection] { sidebar.selectedConnectionIDs.compactMap { model.connection($0) } }

    /// The connections a command acts on: the sidebar's selection, else the selected tab's connection.
    private var targetConnections: [SavedConnection] {
        let selected = selectedConnections
        if !selected.isEmpty { return selected }
        return activeConnection.map { [$0] } ?? []
    }

    // MARK: Tabs (the embedding API)

    /// Opens `content` in a new tab after the selected one and shows it.
    @discardableResult
    func open(_ content: NSViewController, title: String, connection: UUID?) -> Tab {
        let tab = Tab(title: title, connectionID: connection, content: content)
        let index = selectedTab.flatMap { selected in tabs.firstIndex { $0 === selected } }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: index)
        select(tab)
        return tab
    }

    func select(_ tab: Tab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        selectedTab = tab
        refresh()
    }

    /// Closes `tab` once its content agrees (it may ask about unsaved work first).
    func close(_ tab: Tab) {
        let content = tab.tabContent
        let finish = { [weak self] (ok: Bool) in
            guard ok, let self, let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.tabs.remove(at: index)
            if self.selectedTab === tab {
                self.selectedTab = self.tabs.isEmpty ? nil : self.tabs[min(index, self.tabs.count - 1)]
            }
            self.refresh()
        }
        if let content { content.shouldClose(finish) } else { finish(true) }
    }

    func rename(_ tab: Tab, to title: String) {
        tab.title = title
        refresh()
    }

    @objc private func tabContentChanged(_ notification: Notification) {
        guard tabs.contains(where: { $0.content === notification.object as AnyObject }) else { return }
        refresh()
    }

    // MARK: Showing

    private func sidebarSelectionChanged() {
        let selected = sidebar.selectedConnectionIDs
        // A connection with tabs shows its latest tab; one without shows its summary.
        if selected.count == 1, let tab = tabs.last(where: { $0.connectionID == selected[0] }) {
            selectedTab = tab
        } else if !selected.isEmpty {
            selectedTab = nil
        }
        refresh()
    }

    /// Brings every part up to date with the model, the tabs and the selection.
    func refresh() {
        tabBar.show(tabs, selected: selectedTab) { [weak self] tab in self?.model.connection(tab.connectionID)?.colour.color }
        updateContent()
        updateTint()
        updateStatus()
        toolbarController.update()
        window?.toolbar?.validateVisibleItems()
        window?.title = activeConnection.map { connection in
            connection.displayName + (connection.database.isEmpty ? "" : " · " + connection.database)
        } ?? "AirSQL"
    }

    private func updateContent() {
        let kind: String
        var view: NSView?
        if let tab = selectedTab {
            kind = "tab:" + tab.id.uuidString
            view = tab.content.view
        } else if model.data.connections.isEmpty {
            kind = "firstRun"
        } else if selectedConnections.count == 1, let connection = selectedConnections.first {
            kind = "summary:" + connection.id.uuidString + "\(connection.hashValue)" + stateText(model.states[connection.id])
        } else {
            kind = "select"
        }
        guard kind != contentKindKey else { return }
        contentKindKey = kind
        contentKind = kind.components(separatedBy: ":").first ?? kind
        if view == nil {
            switch contentKind {
            case "firstRun": view = firstRunView()
            case "summary":
                if let connection = selectedConnections.first {
                    view = summaryView(connection, data: model.data, state: model.states[connection.id])
                }
            default: view = selectConnectionView()
            }
        }
        shownContent?.removeFromSuperview()
        if let view {
            contentHolder.addSubview(view)
            view.pin(to: contentHolder)
        }
        shownContent = view
    }

    private var contentKindKey = ""

    private func updateTint() {
        let colour = activeConnection?.colour.color
        tint.color = colour ?? .clear
        tintHeight.constant = colour == nil ? 0 : 3
        tint.toolTip = activeConnection.map { "\($0.displayName) is marked \($0.colour.title)" }
    }

    // MARK: Status bar

    private func configureStatusItems() {
        statusBar.route.popover = { [weak self] in
            guard let self, let connection = self.activeConnection else { return nil }
            return InfoPopover(id: "popover.route", heading: "Route", lines: [routeText(connection),
                                                                               "Connection: " + connection.displayName])
        }
        statusBar.server.popover = { [weak self] in
            guard let self, let connection = self.activeConnection else { return nil }
            return InfoPopover(id: "popover.server", heading: connection.displayName, lines: [stateText(self.model.states[connection.id])])
        }
        statusBar.transaction.popover = { [weak self] in
            guard let self, let badge = self.selectedTab?.tabContent?.transactionBadge else { return nil }
            let commit = button("Commit", id: "popover.commit", tip: Commands.commit.tip, target: nil, action: Commands.commit.action)
            let rollback = button("Rollback", id: "popover.rollback", tip: Commands.rollback.tip, target: nil,
                                  action: Commands.rollback.action)
            return InfoPopover(id: "popover.transaction", heading: "Transaction", lines: [badge], buttons: [commit, rollback])
        }
        statusBar.transaction.menuItems = { [Commands.commit.item(), Commands.rollback.item()] }
        statusBar.activity.popover = { [weak self] in
            guard let self else { return nil }
            return ActivityPopover(center: self.model.activity) { [weak self] id in self?.model.connection(id)?.displayName }
        }
        statusBar.activity.menuItems = { [Commands.cancelAll.item()] }
        statusBar.agent.popover = { [weak self] in
            guard let self, let status = self.model.agentStatus else { return nil }
            let off = button("Turn Agents Off", id: "popover.turnAgentsOff", tip: Commands.turnAgentsOff.tip, target: nil,
                             action: Commands.turnAgentsOff.action)
            return InfoPopover(id: "popover.agent", heading: "Agents", lines: [status], buttons: [off])
        }
        statusBar.agent.menuItems = { [Commands.agentActivity.item(), Commands.turnAgentsOff.item()] }
        statusBar.sqlLog.toolTip = Commands.sqlLog.tip + " (⌥⌘L)"
    }

    func updateStatus() {
        let connection = activeConnection
        statusBar.route.show(connection.map(routeText) ?? "", tip: "the route to the server: click for details, right-click to copy")
        let state = connection.flatMap { model.states[$0.id] }
        var server = ""
        if connection != nil {
            if case .connected(let name)? = state { server = name } else { server = stateText(state) }
        }
        statusBar.server.show(server, tip: "the server's software and version once connected: click for details")
        let badge = selectedTab?.tabContent?.transactionBadge ?? ""
        statusBar.transaction.show(badge, tip: "this tab's transaction: click to commit or roll back")
        let running = model.activity.running
        statusBar.activity.show(running.isEmpty ? "" : running.count == 1 ? running[0].title : "\(running.count) tasks running",
                                tip: "work running now: click to see it and cancel it")
        statusBar.activity.setSpinning(!running.isEmpty)
        statusBar.agent.show(model.agentStatus ?? "", tip: "what agents are doing: click for more, or to turn them off")
        statusBar.setAccessory(selectedTab?.tabContent?.statusAccessory)
        let canShowLog = statusBar.sqlLog.commandTarget(Commands.sqlLog.action) != nil
        statusBar.sqlLog.isEnabled = canShowLog
        statusBar.sqlLog.attributedTitle = NSAttributedString(string: "SQL log", attributes: [
            .foregroundColor: canShowLog ? NSColor.accent : NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 11.5)])
        statusBar.sqlLog.toolTip = canShowLog ? Commands.sqlLog.tip + " (⌥⌘L)"
            : "Nothing has been sent yet: the SQL log lists every statement once you connect"
    }

    // MARK: Commands

    /// shortcut: saves a connection with the defaults and selects it; the connection editor (L1) replaces this with its
    /// sheet.
    @objc func newConnection(_ sender: Any?) {
        guard window?.attachedSheet == nil else { return }
        let connection = SavedConnection(name: "New Connection", host: "127.0.0.1", user: "root")
        model.save(connection)
        sidebar.reload()
        sidebar.select([connection.id])
        sidebarSelectionChanged()
    }

    @objc func duplicateConnection(_ sender: Any?) {
        let copies = targetConnections.compactMap { model.duplicate($0.id) }
        sidebar.reload()
        sidebar.select(copies.map(\.id))
        sidebarSelectionChanged()
    }

    @objc func setConnectionColour(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let colour = ConnectionColour(rawValue: raw) else { return }
        for var connection in targetConnections {
            connection.colour = colour
            model.save(connection)
        }
    }

    @objc func deleteConnection(_ sender: Any?) {
        let doomed = targetConnections
        guard !doomed.isEmpty, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = doomed.count == 1 ? "Delete “\(doomed[0].displayName)”?" : "Delete \(doomed.count) connections?"
        alert.informativeText = "AirSQL forgets \(doomed.count == 1 ? "it and its saved password" : "them and their saved passwords"). "
            + "Nothing on the server\(doomed.count == 1 ? "" : "s") changes."
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        delete.toolTip = "Forget the connection\(doomed.count == 1 ? "" : "s") and saved password\(doomed.count == 1 ? "" : "s")"
        alert.addButton(withTitle: "Cancel").toolTip = "Keep \(doomed.count == 1 ? "it" : "them")"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let ids = Set(doomed.map(\.id))
            self.tabs.filter { ids.contains($0.connectionID ?? UUID()) }.forEach { self.close($0) }
            self.model.delete(ids)
        }
    }

    @objc func closeTab(_ sender: Any?) {
        if let tab = selectedTab { close(tab) }
    }

    @objc func closeOtherTabs(_ sender: Any?) {
        guard let keep = selectedTab else { return }
        tabs.filter { $0 !== keep }.forEach(close)
    }

    @objc func duplicateTab(_ sender: Any?) {
        guard let tab = selectedTab, let copy = tab.tabContent?.duplicate() else { return }
        open(copy, title: tab.title, connection: tab.connectionID)
    }

    @objc func renameTab(_ sender: Any?) {
        guard let tab = selectedTab, let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabBar.buttons[safe: index]?.beginRename()
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = selectedTab?.tabContent?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func showNextTab(_ sender: Any?) { step(1) }
    @objc func showPreviousTab(_ sender: Any?) { step(-1) }

    private func step(_ offset: Int) {
        guard let tab = selectedTab, let index = tabs.firstIndex(where: { $0 === tab }), tabs.count > 1 else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    @objc func selectTabNumber(_ sender: Any?) {
        guard let number = (sender as? NSMenuItem)?.tag, number >= 1, number <= tabs.count else { return }
        select(tabs[number - 1])
    }

    @objc func filterSidebar(_ sender: Any?) {
        if split.splitViewItems.first?.isCollapsed == true { split.toggleSidebar(nil) }
        window?.makeFirstResponder(sidebar.filter)
    }

    @objc func showActivity(_ sender: Any?) {
        guard !model.activity.running.isEmpty else { return }
        statusBar.activity.showPopover()
    }

    @objc func cancelAllActivities(_ sender: Any?) { model.activity.cancelAll() }

    @objc func turnAgentsOff(_ sender: Any?) { model.data.settings.agentsAllowed = false }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let connections = targetConnections
        var enabled = true, reason: String?
        switch item.action {
        case Commands.duplicateConnection.action?, Commands.deleteConnection.action?:
            enabled = !connections.isEmpty && window?.attachedSheet == nil
            reason = window?.attachedSheet != nil ? "A sheet is open: answer it first" : "Select a connection in the sidebar first"
        case Commands.colour.action?:
            enabled = !connections.isEmpty
            reason = "Select a connection in the sidebar first"
            let raw = item.representedObject as? String
            item.state = !connections.isEmpty && connections.allSatisfy({ $0.colour.rawValue == raw }) ? .on : .off
        case Commands.newConnection.action?:
            enabled = window?.attachedSheet == nil
            reason = "A sheet is open: answer it first"
        case Commands.closeTab.action?, Commands.renameTab.action?:
            enabled = selectedTab != nil
            reason = "No tab is open"
            if item.action == Commands.renameTab.action, let tab = selectedTab, tab.tabContent?.canRename != true {
                enabled = false
                reason = "This tab is named after what it shows"
            }
        case Commands.closeOtherTabs.action?:
            enabled = tabs.count > 1
            reason = "Only one tab is open"
        case Commands.duplicateTab.action?:
            enabled = selectedTab?.tabContent?.canDuplicate == true
            reason = selectedTab == nil ? "No tab is open" : "This kind of tab can't be duplicated"
        case Commands.revealInFinder.action?:
            enabled = selectedTab?.tabContent?.fileURL != nil
            reason = "This tab isn't saved in a file"
        case Commands.nextTab.action?, Commands.previousTab.action?:
            enabled = tabs.count > 1
            reason = "Only one tab is open"
        case Commands.tab(1).action?:
            enabled = item.tag <= tabs.count
            reason = "No tab has this number"
        case Commands.activity.action?:
            enabled = !model.activity.running.isEmpty
            reason = "Nothing is running"
        case Commands.cancelAll.action?:
            enabled = model.activity.running.contains { $0.canCancel }
            reason = "Nothing that can be cancelled is running"
        case Commands.turnAgentsOff.action?:
            enabled = model.data.settings.agentsAllowed
            reason = "Agents are off already"
        default:
            if let check = validateEditorItem(item) { (enabled, reason) = check }
        }
        item.explain(enabled: enabled, reason: enabled ? nil : reason)
        return enabled
    }

    /// Window ▸ the tabs (⌘1…⌘9) named after them; the others hidden, their shortcuts kept.
    func updateWindowMenu(_ menu: NSMenu) {
        for item in menu.items where item.action == Commands.tab(1).action {
            let index = item.tag - 1
            item.title = index < tabs.count ? tabs[index].title : ""
            item.isHidden = index >= tabs.count
        }
        // AppKit's own items there (the windows' list) say what they do too.
        for item in menu.items where item.toolTip == nil && !item.isSeparatorItem {
            item.toolTip = Commands.tip(for: item) ?? "Bring this window to the front"
        }
    }

    // MARK: Window

    /// Shows the window, its toolbar's items (made as it is first shown) brought up to date.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refresh()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { true }
}

/// The split between the sidebar and the content: Hide Sidebar collapses the sidebar (it isn't a source-list sidebar,
/// so AppKit's own toggle wouldn't).
final class MainSplitViewController: NSSplitViewController {
    override func toggleSidebar(_ sender: Any?) {
        guard let item = splitViewItems.first else { return }
        item.animator().isCollapsed = !item.isCollapsed
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleSidebar(_:)), let menuItem = item as? NSMenuItem {
            menuItem.title = splitViewItems.first?.isCollapsed == true ? "Show Sidebar" : "Hide Sidebar"
            return true
        }
        return super.validateUserInterfaceItem(item)
    }
}

extension NSWindow {
    /// Opens in the middle of the screen at `size` (of its content), made smaller on a small screen: at most 85 % of
    /// its width and 80 % of its height. With an autosave name, at the size and place it had when last used instead,
    /// as long as that frame still fits on a screen.
    func open(size: NSSize, autosave name: String? = nil) {
        setContentSize(size)
        if let visible = NSScreen.main?.visibleFrame {
            let fitted = NSSize(width: max(minSize.width, min(frame.width, (visible.width * 0.85).rounded(.down))),
                                height: max(minSize.height, min(frame.height, (visible.height * 0.8).rounded(.down))))
            setFrame(NSRect(origin: frame.origin, size: fitted), display: false)
        }
        center()
        guard let name else { return }
        let key = "NSWindow Frame " + name
        if let saved = UserDefaults.standard.string(forKey: key) {
            let numbers = saved.split(separator: " ").compactMap { Double($0) }
            let frame = numbers.count >= 4 ? NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]) : .zero
            if frame.isEmpty || !NSScreen.screens.contains(where: { $0.visibleFrame.contains(frame) }) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        setFrameAutosaveName(name)
    }
}

/// The name under which AppKit saves a window's frame or the sidebar's width in AirSQL's defaults; nil (nothing read
/// or saved) in a throwaway AirSQL, which shares those defaults with the person's own and would change their sizes.
func layoutName(_ name: String) -> String? {
    Env.isThrowaway() ? nil : name
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
