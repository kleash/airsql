import AirSQLCore
import AppKit

/// The window's connection commands (lane L1): Connect, Disconnect, Edit…, the folders and the ~/.ssh/config import.
extension MainWindowController {
    /// Connects the selected connections; one that is connected is shown.
    @objc func connect(_ sender: Any?) {
        for connection in targetConnections where !isConnected(connection.id) {
            model.connector.connect(connection.id, on: window)
        }
    }

    /// Connected or connecting, as the sidebar shows it.
    func isConnected(_ id: UUID) -> Bool {
        switch model.states[id] {
        case .connected?, .connecting?: return true
        default: return false
        }
    }

    /// Disconnects the selected connections, asking first when a tab of theirs has an open transaction or edits.
    @objc func disconnect(_ sender: Any?) {
        let ids = targetConnections.map(\.id).filter(isConnected)
        let busy = tabs.filter { tab in
            ids.contains(tab.connectionID ?? UUID()) && (tab.tabContent?.isEdited == true || tab.tabContent?.transactionBadge != nil
                || (tab.content as? ConsoleViewController)?.pendingResultRows ?? 0 > 0)
        }
        guard !busy.isEmpty, let window else { return ids.forEach(model.connector.disconnect) }
        let alert = NSAlert()
        alert.messageText = ids.count == 1 ? "Disconnect “\(model.connection(ids[0])?.displayName ?? "")”?" : "Disconnect \(ids.count) connections?"
        alert.informativeText = "\(busy.count == 1 ? "A tab has" : "\(busy.count) tabs have") an open transaction or edits "
            + "that aren't applied. Disconnecting rolls the transaction back and the edits can't be applied any more."
        let disconnect = alert.addButton(withTitle: "Disconnect")
        disconnect.hasDestructiveAction = true
        disconnect.toolTip = "Close the connection; the open transaction is rolled back"
        alert.addButton(withTitle: "Cancel").toolTip = "Stay connected"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            ids.forEach { self?.model.connector.disconnect($0) }
        }
    }

    /// Opens the connection editor on the selected connection.
    @objc func editConnection(_ sender: Any?) {
        guard targetConnections.count == 1, let connection = targetConnections.first, window?.attachedSheet == nil else { return }
        edit(connection, isNew: false)
    }

    /// The editor sheet on `connection` (on `sheetWindow`, else this window; at `tab`); Save keeps it (and selects it),
    /// Save and Connect connects too.
    func edit(_ connection: SavedConnection, isNew: Bool, on sheetWindow: NSWindow? = nil, tab: ConnectionEditor.Tab = .general) {
        guard let window = sheetWindow ?? window else { return }
        let editor = ConnectionEditor.show(connection, isNew: isNew, model: model, on: window) { [weak self] saved, connect in
            guard let self else { return }
            self.sidebar.reload()
            self.sidebar.select([saved.id])
            self.sidebarSelectionChanged()
            if connect { self.model.connector.connect(saved.id, on: self.window) }
        }
        if tab != .general { editor.show(tab) }
    }

    // MARK: Folders

    @objc func newFolder(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let moving = selectedConnections.map(\.id)
        askFolderName(title: "New Folder", action: "Create", tip: "Create the folder", name: "", on: window) { [weak self] name in
            guard let self else { return }
            let folder = ConnectionFolder(name: name)
            self.model.data.folders.append(folder)
            for id in moving {
                guard var connection = self.model.connection(id) else { continue }
                connection.folderID = folder.id
                self.model.save(connection)
            }
            self.sidebar.reload()
        }
    }

    @objc func renameFolder(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, let id = sidebar.selectedFolderNodeID,
              let index = model.data.folders.firstIndex(where: { $0.id == id }) else { return }
        askFolderName(title: "Rename Folder", action: "Rename", tip: "Give the folder this name",
                      name: model.data.folders[index].name, on: window) { [weak self] name in
            guard let self, let index = self.model.data.folders.firstIndex(where: { $0.id == id }) else { return }
            self.model.data.folders[index].name = name
            self.sidebar.reload()
        }
    }

    @objc func deleteFolder(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, let id = sidebar.selectedFolderNodeID,
              let folder = model.data.folders.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the folder “\(folder.name)”?"
        let count = model.data.connections.filter { $0.folderID == id }.count
        alert.informativeText = count == 0 ? "It is empty." : "Its \(count == 1 ? "connection stays" : "\(count) connections stay"), "
            + "outside any folder."
        alert.addButton(withTitle: "Delete").toolTip = "Remove the folder; its connections stay"
        alert.addButton(withTitle: "Cancel").toolTip = "Keep the folder"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            for var connection in self.model.data.connections where connection.folderID == id {
                connection.folderID = nil
                self.model.save(connection)
            }
            self.model.data.folders.removeAll { $0.id == id }
            self.sidebar.reload()
        }
    }

    private func askFolderName(title: String, action: String, tip: String, name: String, on window: NSWindow,
                               done: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Folders group connections in the sidebar, as HeidiSQL's session folders do."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = name
        field.placeholderString = "Folder name"
        field.toolTip = "Type the folder's name"
        field.setAccessibilityIdentifier("folder.name")
        alert.accessoryView = field
        alert.addButton(withTitle: action).toolTip = tip
        alert.addButton(withTitle: "Cancel").toolTip = "Leave the folders as they are"
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if response == .alertFirstButtonReturn, !text.isEmpty { done(text) }
        }
    }

    // MARK: Validation

    /// Whether a connection command can run now, and why not; nil for commands that aren't these.
    func validateConnectionItem(_ item: NSMenuItem) -> (Bool, String?)? {
        let connections = targetConnections, sheet = window?.attachedSheet != nil
        switch item.action {
        case Commands.connect.action?:
            return (!connections.isEmpty, "Select a connection in the sidebar first")
        case Commands.disconnect.action?:
            let any = connections.contains { isConnected($0.id) }
            return (any, connections.isEmpty ? "Select a connection in the sidebar first" : "Not connected")
        case Commands.editConnection.action?:
            return (connections.count == 1 && !sheet, sheet ? "A sheet is open: answer it first"
                : connections.isEmpty ? "Select a connection in the sidebar first" : "Select only one connection to edit")
        case Commands.newFolder.action?, Commands.importSSHConfig.action?:
            return (!sheet, "A sheet is open: answer it first")
        case Commands.renameFolder.action?, Commands.deleteFolder.action?:
            return (sidebar.selectedFolderNodeID != nil && !sheet, sheet ? "A sheet is open: answer it first"
                : "Select a folder in the sidebar first")
        default:
            return nil
        }
    }
}

extension SidebarController {
    /// The folder selected in the sidebar (the row itself), if one is.
    var selectedFolderNodeID: UUID? {
        guard selectedNodes.count == 1, case .folder(let id) = selectedNodes[0].kind else { return nil }
        return id
    }

    /// Where a new connection goes: the selected folder, or the selected connection's.
    var selectedFolderID: UUID? {
        selectedFolderNodeID ?? (selectedNodes.count == 1 ? selectedNodes[0].connectionID.flatMap { main?.model.connection($0)?.folderID } : nil)
    }
}
