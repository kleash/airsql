import AirSQLCore
import AppKit

/// A query tab's session: its own, opened by its first run and closed with the tab, or the connection's main session
/// where the connection has its tabs share one, and where a tab goes when the server has no room for another.
extension ConsoleViewController {
    var sharesSession: Bool { sharing ?? connection?.sharedQuerySession ?? false }

    /// Where what goes with its session is kept (`shared`).
    var sessionKey: UUID { sharesSession ? connectionID ?? documentID : documentID }

    /// It is the tab on show.
    var isShown: Bool { isViewLoaded && mainWindow?.selectedTab?.content === self }

    /// The navigator and the toolbar show the shown tab's database.
    func showDatabase() {
        guard !sharesSession, let chosenDatabase, let open = model.openConnection(connectionID), open.currentDatabase != chosenDatabase
        else { return }
        open.currentDatabase = chosenDatabase
    }

    /// No silent reconnect: a session that dropped is reported, and it takes another Run to open a new one.
    func sessionWasLost() -> Bool {
        guard !sharesSession, let lost = Self.shared[sessionKey]?.session, lost.wasLost else { return false }
        Self.shared[sessionKey] = nil
        sharing = nil
        note(.warning, "This tab's session was lost" + (lost.inTransaction ? ", and its open transaction was rolled back" : "")
             + ", so nothing ran. Run again to open a new session.")
        return true
    }

    /// The session to run on, opened and set up as the connection says if it isn't yet.
    func sessionForRun(on connection: Connection) async throws -> DBConnection {
        if let session { return session }
        var opened: DBConnection?
        if !sharesSession, await connection.hasRoom() {
            do {
                opened = try await connection.toolsSession(role: .query)
            } catch let error as AirSQLError where [1040, 1203].contains(error.code) {
                // Too many connections: the server's or this login's.
            }
        }
        if !sharesSession, opened == nil {
            Self.shared[documentID] = nil
            sharing = true
            note(.warning, "The server is near its limit of connections, so this tab shares the connection's main session with "
                 + "any other tab in the same position.")
        }
        let session: DBConnection
        if let opened { session = opened } else { session = try await connection.session(.main) }
        sharing = sharesSession
        changeShared {
            $0.session = session
            $0.runner = documentID
        }
        if self.connection?.startsManual == true { _ = try await session.query("SET autocommit = 0") }
        if let level = self.connection?.startIsolation {
            _ = try await session.query(level.sql)
            changeShared { $0.isolation = level }
        }
        return session
    }

    /// Closes its own session, which rolls back what wasn't committed: the tab is going, or moving to another connection.
    func endSession() {
        defer { sharing = nil }
        chosenDatabase = nil
        guard !sharesSession, let session = Self.shared.removeValue(forKey: documentID)?.session else { return }
        Task.detached { await session.close() }
    }
}
