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
                if let tab = tabs.first(where: { $0.tabContent?.fileURL == url }) { rename(tab, to: connection.displayName + " console") }
            case .failure(let error):
                showError(error.localizedDescription, title: "AirSQL couldn't open the default console", on: window)
            }
        }
    }

    /// Consoles…: the query tabs of the connection, then a new one or its default console.
    @objc func showConsoleList(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, let connection = activeConnection else { return }
        let consoles = tabs.filter { $0.content is ConsoleViewController && $0.connectionID == connection.id }.map { tab in
            QuickOpenSheet.Item(name: tab.title, place: tab.tabContent?.fileURL?.path ?? "Query tab") { [weak self] in self?.select(tab) }
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
        case Commands.consoleList.action?, Commands.defaultConsole.action?:
            if window?.attachedSheet != nil { return (false, "A sheet is open: answer it first") }
            return (activeConnection != nil, "Select one connection in the sidebar first")
        default:
            return nil
        }
    }
}
