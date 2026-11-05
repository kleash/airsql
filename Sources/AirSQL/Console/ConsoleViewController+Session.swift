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

    /// Reports, on this tab, a session that ended without the person closing it: the connection or the session dropped, or
    /// a Disconnect took an open transaction with it. Until they answer (`askAboutLostSession`) nothing runs here.
    func noticeLostSession() {
        guard lostSession == nil, let id = connectionID, let record = Self.shared[sessionKey], let old = record.session,
              !old.isConnected || Self.openConnection(id) == nil, old.wasLost || old.inTransaction else { return }
        var dropped = old.wasLost
        if case .failed? = model.states[id] { dropped = true }
        let lost = LostSession(transaction: old.inTransaction, changes: record.changes, manual: !old.autocommit, isolation: record.isolation,
                               dropped: dropped, server: connection?.displayName ?? "the server")
        lostSession = lost
        note(.error, lost.message)
        contentChanged()
    }

    /// The explicit step before a new session: the sheet says what went, and only its button lets the next Run through.
    func askAboutLostSession(_ lost: LostSession) {
        guard let window = view.window, window.attachedSheet == nil else { return NSSound.beep() }
        ConsoleClosing.alert(window, lost.heading, lost.message + " Nothing ran. A new session starts empty"
                                + (lost.manual ? ", in Manual Commit as this one was." : "."),
                             buttons: [("Open New Session", "Leave what was lost behind; the next Run opens a new session"),
                                       ("Cancel", "Open no session and run nothing")], destructive: nil) { [weak self] choice in
            // The gate (plan §2.8): saying the lost work is gone is the person's to do.
            guard choice == 0, let self, !AgentGuard.refuses("Only the person at the Mac can leave a lost transaction behind.") else { return }
            self.lostSession = nil
            self.carried = lost
            if Self.shared[self.sessionKey]?.session?.isConnected != true { Self.shared[self.sessionKey] = nil }
            self.sharing = nil
            self.note(.info, "The lost session is left behind: the next Run opens a new one.")
            self.contentChanged()
        }
    }

    /// The session to run on, opened and set up as the connection says if it isn't yet.
    func sessionForRun(on connection: Connection) async throws -> DBConnection {
        if let session { return session }
        var opened: DBConnection?
        if !sharesSession, await connection.hasRoom() {
            do {
                opened = try await connection.toolsSession(role: .query)
            } catch let error as AirSQLError where [1040, 1203, 1226].contains(error.code) {
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
        // Before it counts as the tab's: one that failed to start as asked must not go on to run in Auto-commit.
        let level = carried?.isolation ?? self.connection?.startIsolation
        do {
            if self.connection?.startsManual == true || carried?.manual == true { _ = try await session.query("SET autocommit = 0") }
            if let level { _ = try await session.query(level.sql) }
        } catch {
            await opened?.close()
            throw error
        }
        carried = nil
        sharing = sharesSession
        changeShared {
            $0.session = session
            $0.runner = documentID
            $0.isolation = level ?? $0.isolation
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

/// What went with a session that ended without the person closing it.
struct LostSession {
    var transaction: Bool
    /// Rows changed in that transaction.
    var changes: UInt64
    /// It was in Manual Commit, and at this isolation level: its replacement starts the same.
    var manual: Bool
    var isolation: IsolationLevel?
    /// It dropped, rather than being closed by Disconnect.
    var dropped: Bool
    var server: String

    var heading: String { transaction ? "This tab's transaction was rolled back" : "This tab's session was lost" }

    var message: String {
        let how = dropped ? "The connection to \(server) was lost" : "The connection to \(server) was closed"
        guard transaction else { return how + ", and this tab's session with it." }
        let rows = changes == 0 ? "Everything in it is gone" : "Its \(changes.formatted()) row change\(changes == 1 ? " is" : "s are") gone"
        return how + ", and the server rolled back this tab's open transaction. \(rows): nothing since the last Commit was kept."
    }
}
