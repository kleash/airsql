import AirSQLCore
import AppKit

/// File ▸ New Connection from URL…, Import Connections… and Export Connections…: connections in and out of AirSQL,
/// never with their passwords.
extension MainWindowController {
    /// Asks for a `mysql://` or `mongodb://` address (the clipboard's, when it holds one) and opens the editor on it,
    /// unsaved.
    @objc func newConnectionFromURL(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        let known = ConnectionImport.connection(fromURL: copied) != nil || (try? MongoURI(copied)) != nil
        let field = textField(known ? copied : "", placeholder: "mysql://user@host:3306/database",
                              id: "import.url", tip: "Type or paste the connection's mysql://, mariadb://, mongodb:// or "
                                + "mongodb+srv:// address")
        field.translatesAutoresizingMaskIntoConstraints = true
        field.frame.size = NSSize(width: 360, height: 22)
        let alert = NSAlert()
        alert.messageText = "New connection from a URL"
        alert.informativeText = "AirSQL opens the connection's settings to check before saving. A password in a MySQL "
            + "address is left out: AirSQL asks for it when you connect. A MongoDB address's goes to your Keychain when you save."
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue").toolTip = "Open the connection's settings with this address"
        alert.addButton(withTitle: "Cancel").toolTip = "Make no connection"
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if field.stringValue.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("mongodb") {
                var connection = SavedConnection()
                connection.engine = .mongodb
                connection.folderID = self.sidebar.selectedFolderID
                self.edit(connection, isNew: true)?.applyMongoAddress(field.stringValue)
                return
            }
            guard var connection = ConnectionImport.connection(fromURL: field.stringValue) else {
                return showError("That isn't a mysql:// or mariadb:// address with a host, such as "
                                 + "mysql://user@host:3306/database.", title: "Nothing to import", on: window)
            }
            connection.folderID = self.sidebar.selectedFolderID
            self.edit(connection, isNew: true)
        }
    }

    /// Offers the other apps found on this Mac, or a file.
    @objc func importConnections(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let home = NSHomeDirectory()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = ConnectionImport.sources.filter { FileManager.default.fileExists(atPath: home + "/" + $0.path) }
            DispatchQueue.main.async { self?.askImportSource(found, home: home, on: window) }
        }
    }

    private func askImportSource(_ sources: [ConnectionImport.Source], home: String, on window: NSWindow) {
        guard !sources.isEmpty else { return chooseImportFile(on: window) }
        let menu = popup(sources.map(\.title) + ["Another File…"], selected: 0, id: "import.source",
                         tip: "Choose the app to read saved connections from, or a file", target: nil, action: nil)
        menu.translatesAutoresizingMaskIntoConstraints = true
        menu.frame.size = NSSize(width: 240, height: 26)
        let alert = NSAlert()
        alert.messageText = "Import connections from"
        alert.informativeText = "AirSQL reads the app's saved connections, never its passwords. Nothing changes in the app."
        alert.accessoryView = menu
        alert.addButton(withTitle: "Continue").toolTip = "Read the chosen app's connections and list them"
        alert.addButton(withTitle: "Cancel").toolTip = "Import nothing"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            if menu.indexOfSelectedItem < sources.count {
                self?.importConnections(from: URL(fileURLWithPath: home + "/" + sources[menu.indexOfSelectedItem].path))
            } else {
                self?.chooseImportFile(on: window)
            }
        }
    }

    private func chooseImportFile(on window: NSWindow) {
        let panel = NSOpenPanel()
        panel.message = "Choose an AirSQL export, or a connections file of Sequel Ace, TablePlus, DBeaver, MySQL Workbench or "
            + "HeidiSQL (its exported settings)."
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importConnections(from: url)
        }
    }

    /// Reads `url` off the main thread, then lists its connections to import.
    func importConnections(from url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = try? Data(contentsOf: url)
            DispatchQueue.main.async {
                guard let self, let window = self.window else { return }
                let found = data.map(ConnectionImport.connections(in:)) ?? []
                guard !found.isEmpty else {
                    return showError(data == nil ? "AirSQL can't read that file. If macOS refused, copy the file to another "
                                     + "folder and choose it there." : "That file holds no MySQL or MariaDB connections AirSQL understands.",
                                     title: "Nothing to import", on: window)
                }
                self.showImport(found, on: window)
            }
        }
    }

    /// Lists `found` with ticks; one already here (the same server, login and database) starts unticked.
    private func showImport(_ found: [SavedConnection], on window: NSWindow) {
        func same(_ connection: SavedConnection) -> [String] {
            [connection.host, connection.port.map(String.init) ?? "", connection.socket, connection.user, connection.database]
        }
        let known = Set(model.data.connections.map(same))
        let boxes = found.enumerated().map { index, connection -> NSButton in
            let summary = (connection.user.isEmpty ? "" : connection.user + "@") + connection.host
            let box = checkbox(connection.displayName + "   " + summary, id: "import.connection.\(index)",
                               tip: "Add \(connection.displayName), \(summary)"
                                   + (known.contains(same(connection)) ? " (a connection already goes there)" : ""),
                               on: !known.contains(same(connection)), target: nil, action: nil)
            box.lineBreakMode = .byTruncatingTail
            return box
        }
        let alert = NSAlert()
        alert.messageText = "Import connections"
        alert.informativeText = "Passwords aren't imported: AirSQL asks for each when you connect. Programs, startup SQL and "
            + "agent access stay as new connections have them."
        alert.accessoryView = tickList(boxes)
        alert.addButton(withTitle: "Import").toolTip = "Add each ticked connection"
        alert.addButton(withTitle: "Cancel").toolTip = "Add no connections"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let folder = self.sidebar.selectedFolderID
            let made = zip(found, boxes).filter { $0.1.state == .on }.map { saved, _ -> SavedConnection in
                var connection = saved
                connection.folderID = folder
                return connection
            }
            made.forEach(self.model.save)
            self.sidebar.reload()
            self.sidebar.select(made.map(\.id))
            self.sidebarSelectionChanged()
        }
    }

    /// Saves the selected connections, or all when none is selected, to a file that holds no passwords.
    @objc func exportConnections(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let connections = selectedConnections.isEmpty ? model.data.connections : selectedConnections
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AirSQL Connections.json"
        panel.message = "Choose where to save \(connections.count) connection\(connections.count == 1 ? "" : "s"). Passwords stay in "
            + "your Keychain."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try ConnectionImport.export(connections).write(to: url, options: .atomic)
                } catch {
                    DispatchQueue.main.async { showError(error.localizedDescription, title: "Can't export the connections", on: window) }
                }
            }
        }
    }
}
