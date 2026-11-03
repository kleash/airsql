import AirSQLCore
import AppKit

/// File ▸ Import from ~/.ssh/config…: the person picks the file (AirSQL reads nothing in ~/.ssh by itself), ticks its
/// hosts, and gets a connection that tunnels through each.
extension MainWindowController {
    @objc func importSSHConfig(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose your ssh config file: AirSQL makes a connection for each host you tick."
        panel.prompt = "Choose"
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh", isDirectory: true)
        panel.nameFieldStringValue = "config"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importHosts(from: url)
        }
    }

    /// Reads `url` off the main thread, then lists its hosts to import.
    func importHosts(from url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = try? String(contentsOf: url, encoding: .utf8)
            DispatchQueue.main.async {
                guard let self, let window = self.window else { return }
                let hosts = SSHConfigImport.hosts(in: text ?? "")
                guard !hosts.isEmpty else {
                    return showError(text == nil ? "AirSQL can't read that file." : "That file names no hosts (only patterns "
                                     + "such as Host *).", title: "Nothing to import", on: window)
                }
                self.showImport(hosts, on: window)
            }
        }
    }

    private func showImport(_ hosts: [SSHConfigImport.Host], on window: NSWindow) {
        let known = Set(model.data.connections.filter { $0.route != .direct }.map(\.sshHost.host))
        let boxes = hosts.map { host -> NSButton in
            // The tooltip has the whole of a shortened title.
            let box = checkbox(host.alias + "   " + host.summary, id: "import.host." + host.alias,
                               tip: "Make a connection that tunnels through \(host.alias), \(host.summary)"
                                   + (known.contains(host.alias) ? " (a connection goes through it already)" : ""),
                               on: !known.contains(host.alias), target: nil, action: nil)
            box.lineBreakMode = .byTruncatingTail
            return box
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        let flipped = FlippedView()
        flipped.addSubview(stack)
        stack.frame.size = stack.fittingSize
        flipped.frame.size = NSSize(width: max(340, stack.fittingSize.width), height: stack.fittingSize.height)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: min(260, flipped.frame.height + 4)))
        scroll.documentView = flipped
        scroll.hasVerticalScroller = flipped.frame.height > 256
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        let alert = NSAlert()
        alert.messageText = "Import hosts from your ssh config"
        alert.informativeText = "Each host you tick becomes a connection that tunnels through it to a database on its "
            + "127.0.0.1:3306. Its settings stay in your ~/.ssh/config, which AirSQL's ssh reads."
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Import").toolTip = "Make a connection for each ticked host"
        alert.addButton(withTitle: "Cancel").toolTip = "Make no connections"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let folder = self.sidebar.selectedFolderID
            let made = zip(hosts, boxes).filter { $0.1.state == .on }.map { SSHConfigImport.connection(for: $0.0, folder: folder) }
            made.forEach(self.model.save)
            self.sidebar.reload()
            self.sidebar.select(made.map(\.id))
            self.sidebarSelectionChanged()
        }
    }
}
