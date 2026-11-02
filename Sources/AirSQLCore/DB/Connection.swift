import Foundation

/// A connected connection's sessions (plan §2.2, R12), each a `DBConnection` of its own:
/// - main: the console tabs share it (one transaction context, shown in the toolbar);
/// - data: table tabs, grid paging and Apply, so Apply's own transaction never commits the console's;
/// - schema: introspection;
/// - agent: read-only, opened on first agent use;
/// - tools: client tools and recon each open their own (`toolsSession`);
/// - and Cancel's short side connection, which each `DBConnection` opens itself.
/// The options, password included, stay here in memory until `disconnect`.
public final class Connection {
    public private(set) var options: ConnectOptions
    private let log: SQLLog
    private let lock = NSLock()
    private var opening: [DBConnection.Role: Task<DBConnection, Error>] = [:]
    private var tools: [DBConnection] = []

    public init(options: ConnectOptions, log: SQLLog = .shared) {
        self.options = options
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
        precondition(role != .tools && role != .cancel, "tools sessions come from toolsSession(); Cancel opens its own")
        let task: Task<DBConnection, Error> = lock.locked {
            if let task = opening[role] { return task }
            var sessionOptions = options
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

    /// A new session of its own for a client tool or recon. Close it when done; `disconnect` closes it too.
    public func toolsSession() async throws -> DBConnection {
        let session = DBConnection(options: options, role: .tools, log: log)
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
                options.password = ""
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
