import Foundation

/// A connected connection's sessions (plan §2.2, R12), each a `DBConnection` of its own:
/// - main: the login's own, and what the query tabs share on a connection set to share one session;
/// - query: a query tab's own, opened by its first run (`toolsSession(role: .query)`), so it has its own transaction and
///   database and runs while the others do;
/// - data: table tabs, grid paging and Apply, so Apply's own transaction never commits the console's;
/// - schema: introspection;
/// - agent: read-only, opened on first agent use;
/// - tools: client tools and recon each open their own (`toolsSession`);
/// - and Cancel's short side connection, which each `DBConnection` opens itself.
/// The options, password included, stay here in memory until `disconnect`, through a drop too.
public final class Connection: @unchecked Sendable {
    public var options: ConnectOptions { lock.locked { _options } }
    private var _options: ConnectOptions
    private let log: SQLLog
    private let lock = NSLock()
    private var opening: [DBConnection.Role: Task<DBConnection, Error>] = [:]
    private var tools: [DBConnection] = []
    private var isDropped = false

    public init(options: ConnectOptions, log: SQLLog = .shared) {
        _options = options
        self.log = log
    }

    /// Opens the main session: the connect the person waits for (login, TLS check, startup SQL).
    @discardableResult
    public func connect() async throws -> ServerInfo {
        let main = try await session(.main)
        guard let server = main.server else { throw AirSQLError.disconnected }
        return server
    }

    /// The session for `role` (main, data, schema or agent), opened on first use. Callers asking at the same time share
    /// one connect; a connect that failed is tried again by the next call.
    public func session(_ role: DBConnection.Role) async throws -> DBConnection {
        precondition(![.tools, .query, .cancel].contains(role), "these sessions come from toolsSession(); Cancel opens its own")
        let task: Task<DBConnection, Error> = try lock.locked {
            if isDropped, role != .main { throw AirSQLError.disconnected }
            if let task = opening[role] { return task }
            var sessionOptions = _options
            if role == .agent { sessionOptions.readOnly = true }
            let log = self.log
            let task = Task {
                let session = DBConnection(options: sessionOptions, role: role, log: log)
                do {
                    try await session.connect()
                } catch {
                    await session.close()
                    throw error
                }
                return session
            }
            opening[role] = task
            return task
        }
        do {
            return try await task.value
        } catch {
            lock.locked {
                if opening[role] == task { opening[role] = nil }
            }
            throw error
        }
    }

    /// A new session of its own for a client tool, recon or (`role: .query`) a query tab. Close it when done; `disconnect`
    /// closes it too.
    public func toolsSession(role: DBConnection.Role = .tools) async throws -> DBConnection {
        if lock.locked({ isDropped }) { throw AirSQLError.disconnected }
        let session = DBConnection(options: options, role: role, log: log)
        do {
            try await session.connect()
        } catch {
            await session.close()
            throw error
        }
        lock.locked {
            tools.removeAll { !$0.isConnected }
            tools.append(session)
        }
        return session
    }

    /// Every session open now.
    public func sessions() async -> [DBConnection] {
        (await openSessions() + lock.locked { tools }).filter(\.isConnected)
    }

    /// When a statement last ran on any session but the schema's, whose timed reads aren't the person's; nil while one
    /// runs or a transaction is open: that isn't idle.
    public func idleSince() async -> Date? {
        let open = await sessions().filter { $0.role != .schema }
        guard !open.contains(where: { $0.isBusy || $0.inTransaction }) else { return nil }
        return open.map(\.lastUsed).max()
    }

    /// Whether `used` of the server's `limit` connections leave room for one more, and for other clients.
    static func hasRoom(used: Int, limit: Int) -> Bool { used + 5 < limit }

    /// Whether the server can take another session without crowding out others, as far as the main session can tell;
    /// busy, or refused the figures, it doesn't hold up a tab: the server still says no by itself (error 1040).
    public func hasRoom() async -> Bool {
        guard let main = try? await session(.main), !main.isBusy,
              let limit = try? await main.query("SELECT @@max_connections").first?.rows?.string(0, 0).flatMap({ Int($0) }),
              let used = try? await main.query("SHOW GLOBAL STATUS LIKE 'Threads_connected'").first?.rows?.string(0, 1)
                .flatMap({ Int($0) }) else { return true }
        return Self.hasRoom(used: used, limit: limit)
    }

    /// Reconnects after a drop (plan §2.2, R8): the main session is set up again through the same route, the thread
    /// the server may still have is killed so its locks go, and the result says whether an open transaction was rolled
    /// back. The other sessions are closed and forgotten, so they open again, fresh, on next use.
    public func reconnect() async throws -> Reconnected {
        let main = try await session(.main)
        let report = try await main.reconnect()
        let others: [Task<DBConnection, Error>] = lock.locked {
            isDropped = false
            let tasks = opening.filter { $0.key != .main }.map(\.value)
            opening = opening.filter { $0.key == .main }
            return tasks
        }
        for task in others { if let session = try? await task.value { await session.close() } }
        return report
    }

    /// The connection dropped: the sessions other than main close, so none outlives the drop with a transaction the tabs
    /// report as gone. Main and the password stay for `reconnect`, and nothing else opens until then: no silent reconnect.
    public func dropped() {
        let (tasks, toolSessions): ([Task<DBConnection, Error>], [DBConnection]) = lock.locked {
            defer {
                isDropped = true
                opening = opening.filter { $0.key == .main }
                tools = []
            }
            return (opening.filter { $0.key != .main }.map(\.value), tools)
        }
        Task.detached {
            for task in tasks { if let session = try? await task.value { await session.close() } }
            for session in toolSessions { await session.close() }
        }
    }

    /// Pings the open sessions that are idle, so firewalls and wait_timeout don't drop them, except a session whose
    /// transaction has been open longer than `transactionLimit` (the Safety setting, 15 minutes by default): that one is
    /// left for the server to time out, and the Tx badge warns.
    public func keepAlive(transactionLimit: TimeInterval) async {
        let sessions = lock.locked { tools } + (await openSessions())
        for session in sessions where session.isConnected && !session.isBusy {
            if let started = session.transactionStarted, Date().timeIntervalSince(started) > transactionLimit { continue }
            try? await session.ping()
        }
    }

    /// Closes every session (a running statement is broken off) and forgets the password.
    public func disconnect() async {
        let (tasks, toolSessions): ([Task<DBConnection, Error>], [DBConnection]) = lock.locked {
            defer {
                opening = [:]
                tools = []
                _options.password = ""
            }
            return (Array(opening.values), tools)
        }
        for task in tasks {
            if let session = try? await task.value { await session.close() }
        }
        for session in toolSessions { await session.close() }
    }

    private func openSessions() async -> [DBConnection] {
        var sessions: [DBConnection] = []
        for task in lock.locked({ Array(opening.values) }) {
            if let session = try? await task.value { sessions.append(session) }
        }
        return sessions
    }
}
