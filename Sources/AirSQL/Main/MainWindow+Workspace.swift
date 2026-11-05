import AirSQLCore
import AppKit

/// The window's commands for files outside any server: the Files panel, scratch files, and a connection's consoles.
extension MainWindowController {
    @objc func toggleFilesPanel(_ sender: Any?) {
        let shown = !sidebar.filesShown
        sidebar.setFilesShown(shown)
        model.data.settings.tree.showsFiles = shown
        window?.makeFirstResponder(shown ? sidebar.files.outline : sidebar.outline)
    }

    @objc func attachFolder(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Attach folders of .sql files to the Files panel"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.attach(panel.urls)
        }
    }

    /// Adds `folders` to the Files panel and shows it.
    func attach(_ folders: [URL]) {
        let known = model.data.settings.tree.attachedFolders
        model.data.settings.tree.attachedFolders = known + folders.map(\.path).filter { !known.contains($0) }
        if !sidebar.filesShown { toggleFilesPanel(nil) } else { sidebar.files.reload() }
    }

    @objc func newScratchFile(_ sender: Any?) {
        // The gate (plan §2.8): files on this Mac are the person's to write.
        guard !AgentGuard.refuses("Making a file on this Mac is the person's: only they can start a scratch file.") else { return }
        Task {
            switch await Task.detached(operation: { Result { try ScriptFiles.newScratch() } }).value {
            case .success(let url):
                await openFiles([url]).value
                sidebar.files.reload()
            case .failure(let error):
                showError(error.localizedDescription, title: "AirSQL couldn't make a scratch file", on: window)
            }
        }
    }

    /// The tab this connection keeps for good: a scratch file of its own, opened or shown.
    @objc func openDefaultConsole(_ sender: Any?) {
        guard let connection = activeConnection else { return NSSound.beep() }
        guard !AgentGuard.refuses("Making a file on this Mac is the person's: only they can open a default console.") else { return }
        Task {
            let id = connection.id
            switch await Task.detached(operation: { Result { try ScriptFiles.defaultConsole(of: id) } }).value {
            case .success(let url):
                ConsoleViewController.rememberConnection(of: url, id)
                await openFiles([url]).value
                if let tab = model.allTabs.first(where: { $0.tabContent?.fileURL == url }) { tab.title = connection.displayName + " console"; refreshAll() }
            case .failure(let error):
                showError(error.localizedDescription, title: "AirSQL couldn't open the default console", on: window)
            }
        }
    }

    /// Consoles…: the query tabs of the connection, then a new one or its default console.
    @objc func showConsoleList(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, let connection = activeConnection else { return }
        let consoles = model.allTabs.filter { $0.content is ConsoleViewController && $0.connectionID == connection.id }.map { tab in
            QuickOpenSheet.Item(name: tab.title, place: tab.tabContent?.fileURL?.path ?? "Query tab") { [weak self] in self?.show(tab) }
        }
        let others: [QuickOpenSheet.Item] = [
            .init(name: Commands.newQuery.title, place: "New on " + connection.displayName) { [weak self] in self?.newQuery(nil) },
            .init(name: Commands.defaultConsole.title, place: "Kept for " + connection.displayName) { [weak self] in self?.openDefaultConsole(nil) },
        ]
        QuickOpenSheet.show(consoles + others, title: "Consoles of \(connection.displayName)", prompt: "Console", on: window)
    }

    func validateWorkspaceItem(_ item: NSMenuItem) -> (Bool, String?)? {
        switch item.action {
        case Commands.filesPanel.action?:
            item.state = sidebar.filesShown ? .on : .off
            return (true, nil)
        case Commands.splitRight.action?:
            item.state = splitPanes != nil ? .on : .off
            return (selectedTab != nil, "Open a tab first")
        case Commands.showBeside.action?:
            return (selectedTab != nil, "Open a tab first")
        case Commands.otherPane.action?:
            return (splitPanes != nil, "Split the window first: View ▸ Split Right")
        case Commands.moveTabToNewWindow.action?:
            return (selectedTab != nil, "No tab is open")
        case Commands.moveTabToNextWindow.action?:
            if selectedTab == nil { return (false, "No tab is open") }
            return (model.windows.count > 1, "Only one window is open: File ▸ New Window")
        case Commands.consoleList.action?, Commands.defaultConsole.action?:
            if window?.attachedSheet != nil { return (false, "A sheet is open: answer it first") }
            return (activeConnection != nil, "Select one connection in the sidebar first")
        default:
            return nil
        }
    }
}

/// Several main windows. Each has its own tabs and sidebar; `AppModel.windows` lists them.
extension MainWindowController {
    /// Another window on the same model, wired as the first one is.
    func anotherWindow() -> MainWindowController {
        let window = MainWindowController(model: model)
        agents?.adopt(window)
        return window
    }

    @objc func newWindow(_ sender: Any?) {
        let window = anotherWindow()
        window.sidebar.select(selectedConnections.map(\.id))
        window.showWindow(nil)
    }

    /// Shows `tab` in whichever window has it, and brings that window up.
    func show(_ tab: Tab) {
        let holder = model.windows.first { $0.tabs.contains { $0 === tab } } ?? self
        if holder !== self { holder.showWindow(nil) }
        holder.select(tab)
    }

    @objc func moveTabToNewWindow(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        let window = anotherWindow()
        hand(tab, to: window)
        window.showWindow(nil)
    }

    @objc func moveTabToNextWindow(_ sender: Any?) {
        guard let tab = selectedTab, let index = model.windows.firstIndex(where: { $0 === self }), model.windows.count > 1 else { return }
        let next = model.windows[(index + 1) % model.windows.count]
        hand(tab, to: next)
        next.showWindow(nil)
    }

    func refreshAll() { model.windows.forEach { $0.refresh() } }

    /// With one window, Window ▸ AirSQL stands for it; with several, the Window menu lists them.
    func windowsChanged() {
        for main in model.windows { main.window?.isExcludedFromWindowsMenu = model.windows.count == 1 }
    }

    /// This window closed for good: the others take over.
    func windowGone() {
        model.windows.removeAll { $0 === self }
        windowsChanged()
        ConsoleDocuments.shared.windowClosed(self)
        window?.close()
    }
}
