// Ported from AirSCP 1.4.0 Sources/AirSCP/AppModel.swift (the saved data shared by the windows, saved on every change).
import AirSQLCore
import Combine
import Foundation
import os

let log = Logger(subsystem: "com.kleash.airsql", category: "app")

extension Notification.Name {
    /// Settings ▸ Grid's NULL text or text size changed (the old settings are the user info's "old"): open grids follow.
    static let gridSettingsDidChange = Notification.Name("AirSQLGridSettingsDidChange")
}

/// What the windows share: the saved connections, folders and settings (airsql.json, written on every change, off the
/// main thread), where each connection is (`states`), the work running now (`activity`) and the agents' chip.
@MainActor
final class AppModel: ObservableObject {
    @Published var data: AirSQLData {
        didSet {
            guard data != oldValue, !reverting else { return }
            // What an agent's request would change here is refused (plan §2.8): the data goes back as it was (setting it
            // here runs this again).
            guard AgentGuard.allows(changing: oldValue, to: data) else {
                reverting = true
                data = oldValue
                reverting = false
                return
            }
            store(data)
            if data.settings.nullText != oldValue.settings.nullText || data.settings.gridFontSize != oldValue.settings.gridFontSize {
                NotificationCenter.default.post(name: .gridSettingsDidChange, object: self, userInfo: ["old": oldValue.settings])
            }
        }
    }
    private var reverting = false
    /// Connections that aren't idle: connecting, connected, or failed. Set by whatever connects.
    @Published var states: [UUID: ConnectionState] = [:]
    /// The connected connections: their sessions and schema caches (`attach`, `detach`).
    @Published var open: [UUID: OpenConnection] = [:]
    /// What the status bar's agent chip says ("Claude Code · reading schema"); nil hides it. Set by agent access.
    @Published var agentStatus: String?
    let activity: ActivityCenter
    /// Connects and disconnects; the connected connections' sessions are `connector.open[id]?.connection`.
    lazy var connector = Connector(model: self)
    /// Saved passwords by Keychain key (a connection's id): the Keychain, off the main thread; tests replace them.
    var savedPassword: (String) -> String? = { Keychain.password(forKey: $0) }
    var setSavedPassword: (String, String?) -> Void = { Keychain.setPassword($1, forKey: $0) }
    /// Saves the data (the store's queue); tests record it instead.
    private let store: (AirSQLData) -> Void

    init(data: AirSQLData, activity: ActivityCenter? = nil, store: ((AirSQLData) -> Void)? = nil) {
        self.data = data
        self.activity = activity ?? .shared
        self.store = store ?? { data in
            Store.saveLater(data) { error in
                log.error("can't save airsql.json: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func connection(_ id: UUID?) -> SavedConnection? { data.connection(id) }

    /// Saves a new or changed connection.
    func save(_ connection: SavedConnection) {
        if let index = data.connections.firstIndex(where: { $0.id == connection.id }) {
            data.connections[index] = connection
        } else {
            data.connections.append(connection)
        }
    }

    /// The connections in the sidebar's order: by folder (folders by name, connections without one first), then by
    /// name, matching `filter` (part of a name, a host or a folder's name) when it isn't empty.
    func sections(filter: String) -> [(folder: ConnectionFolder?, connections: [SavedConnection])] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        func matches(_ connection: SavedConnection, _ folder: ConnectionFolder?) -> Bool {
            text.isEmpty || connection.displayName.localizedCaseInsensitiveContains(text)
                || connection.host.localizedCaseInsensitiveContains(text) || (folder?.name.localizedCaseInsensitiveContains(text) ?? false)
        }
        let sorted = data.connections.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let folders = data.folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let known = Set(folders.map(\.id))
        var result: [(folder: ConnectionFolder?, connections: [SavedConnection])] = []
        let loose = sorted.filter { ($0.folderID.map { !known.contains($0) } ?? true) && matches($0, nil) }
        if !loose.isEmpty { result.append((nil, loose)) }
        for folder in folders {
            let inside = sorted.filter { $0.folderID == folder.id && matches($0, folder) }
            if !inside.isEmpty || text.isEmpty { result.append((folder, inside)) }
        }
        return result
    }

    /// Puts these connections in a folder (nil: outside any).
    func move(_ ids: [UUID], toFolder folder: UUID?) {
        for id in ids {
            guard var connection = connection(id), connection.folderID != folder else { continue }
            connection.folderID = folder
            save(connection)
        }
    }

    /// A copy of a connection named "<name> copy", with its saved passwords (the database's, its SSH hosts', its
    /// proxy's), saved after it.
    @discardableResult
    func duplicate(_ id: UUID) -> SavedConnection? {
        guard let original = connection(id) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.name = copy.displayName + " copy"
        guard AgentGuard.allows(changing: data, to: AirSQLData(connections: data.connections + [copy], folders: data.folders,
                                                               settings: data.settings)) else { return nil }
        save(copy)
        let read = savedPassword, write = setSavedPassword, keys = Array(zip(original.secretKeys, copy.secretKeys))
        // The Keychain may wait for the person (a locked keychain): not on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            for (from, to) in keys {
                if let password = read(from) { write(to, password) }
            }
        }
        return copy
    }

    /// Forgets connections and their saved passwords and table settings.
    func delete(_ ids: Set<UUID>) {
        var remaining = data
        remaining.connections.removeAll { ids.contains($0.id) }
        guard AgentGuard.allows(changing: data, to: remaining) else { return }  // and its passwords stay
        let keys = data.connections.filter { ids.contains($0.id) }.flatMap(\.secretKeys)
        for id in ids { connector.disconnect(id) }
        data = remaining
        for id in ids {
            states[id] = nil
            detach(id)
        }
        let write = setSavedPassword
        DispatchQueue.global(qos: .userInitiated).async {
            for key in keys { write(key, nil) }
            for id in ids { TableViewSettingsStore.shared.removeAll(connection: id) }
        }
    }
}
