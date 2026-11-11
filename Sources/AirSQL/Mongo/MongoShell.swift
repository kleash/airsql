import AirSQLCore
import AppKit

/// The target of Open mongosh in Terminal (Connection menu, and a MongoDB connection's menu in the sidebar): the
/// selected MongoDB connection, through its route. `MongoShell` builds the command; mongosh asks for the password.
@MainActor
final class MongoShellMenu: NSObject, NSMenuItemValidation {
    static let shared = MongoShellMenu()
    static let downloadPage = URL(string: "https://www.mongodb.com/try/download/shell")!

    private var main: MainWindowController? {
        let windows = [NSApp.mainWindow, NSApp.keyWindow].compactMap { $0 } + NSApp.orderedWindows
        return windows.lazy.compactMap { $0.windowController as? MainWindowController }.first
    }

    /// The connection selected in the sidebar, else the tab's.
    private func connection(in main: MainWindowController) -> SavedConnection? {
        main.selectedConnections.count == 1 ? main.selectedConnections.first : main.activeConnection
    }

    /// The sidebar's menu for MongoDB connections: Open mongosh in Terminal where SQL's Open in Terminal is.
    static func replaceTerminal(in menu: NSMenu, connections: [SavedConnection]) {
        guard connections.count == 1, connections[0].engine == .mongodb,
              let index = menu.items.firstIndex(where: { $0.action == Commands.openInTerminal.action }) else { return }
        menu.removeItem(at: index)
        let item = Commands.openMongosh.item()
        item.target = shared
        menu.insertItem(item, at: index)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        var reason: String?
        if let main, let saved = connection(in: main), saved.engine == .mongodb {
            if main.window?.attachedSheet != nil {
                reason = "A sheet is open: answer it first"
            } else if saved.route != .direct, main.model.openMongo[saved.id] == nil {
                reason = "Connect to \(saved.displayName) first: mongosh goes through its SSH or proxy route"
            }
        } else {
            reason = "Select a MongoDB connection in the sidebar first"
        }
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }

    @objc func openMongosh(_ sender: Any?) {
        guard let main, let window = main.window, let saved = connection(in: main), saved.engine == .mongodb else { return }
        // The gate (plan §2.8): it hands over a client no gate stands in front of.
        guard !AgentGuard.refuses("Only the person at the Mac can open mongosh in Terminal.") else { return }
        let open = main.model.openMongo[saved.id]
        let (route, primary) = (open?.connection.route, open?.server.primary)
        let work = main.model.activity.start("Opening mongosh on \(saved.displayName)", connection: saved.id)
        Task {
            defer { work.end() }
            do {
                let found = try await Task.detached { () -> (String, String?)? in
                    guard let mongosh = MongoShell.find() else { return nil }
                    return (mongosh, try route.flatMap { try MongoShell.socket($0, saved: saved, primary: primary) })
                }.value
                guard let (mongosh, socket) = found else { return Self.notInstalled(on: window) }
                let (argv, nameUnchecked) = MongoShell.arguments(saved, mongosh: mongosh, socket: socket)
                var notes: [String] = []
                if nameUnchecked {
                    notes.append("over this connection's route mongosh reaches the server through a socket on this Mac, so it can't "
                                 + "check the server's name in its certificate: only that an authority it trusts signed it.")
                }
                if saved.tls.pinnedFingerprint != nil {
                    notes.append("mongosh can't check the certificate you trusted in AirSQL; if it refuses the server, choose the "
                                 + "authority's file in the connection's TLS tab.")
                }
                try await MongoShell.openInTerminal(argv, notes: notes, name: saved.displayName)
            } catch {
                showError(error.localizedDescription, title: "Can't open mongosh", on: window)
            }
        }
    }

    /// mongosh isn't on this Mac: where to get it (AirSQL downloads nothing).
    private static func notInstalled(on window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "mongosh isn't installed"
        alert.informativeText = "AirSQL opens your own MongoDB Shell (mongosh) and found none on this Mac. Download it from "
            + "MongoDB's website (mongodb.com/try/download/shell) or install it with Homebrew (brew install mongosh), then try again."
        alert.addButton(withTitle: "OK").toolTip = "Close this message"
        alert.addButton(withTitle: "Open Download Page").toolTip = "Open MongoDB's download page for mongosh in your browser"
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { NSWorkspace.shared.open(downloadPage) }
        }
    }
}
