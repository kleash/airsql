import Foundation

/// A connected MongoDB connection (plan decision 2): its sessions by role (`MongoSession`, each a single-threaded
/// mongoc client on a thread of its own) over one route (`MongoRoute`), as `Connection` keeps MySQL's. Every connection
/// a session's driver makes goes through its stream initiator: the server's socket on the route, or TCP for Direct;
/// then TLS, with the certificate checked by `TLSCheck` against that server's own name before the driver sends
/// anything. The login stays here in memory until `close`.
public final class MongoConnection: @unchecked Sendable {
    /// The connection string without user or password.
    public let uri: String
    public let route: MongoRoute
    /// The saved connection's name, for the command log.
    public let name: String
    let log: SQLLog
    private let lock = NSLock()
    private var _user: String?
    private var _password: String?
    private var _tls: TLSOptions
    private var _certificates: [String: TLSCertificate] = [:]
    private var _server: MongoServerInfo?
    private var opening: [MongoSession.Role: Task<MongoSession, Error>] = [:]
    private var closed = false

    public init(uri: String, user: String? = nil, password: String? = nil, tls: TLSOptions = TLSOptions(), route: MongoRoute,
                name: String = "", log: SQLLog = .shared) {
        self.uri = uri
        _user = user
        _password = password
        _tls = tls
        self.route = route
        self.name = name
        self.log = log
    }

    /// Another user for the next connect (typed at the login prompt).
    public var user: String? {
        get { lock.locked { _user } }
        set { lock.locked { _user = newValue } }
    }
    /// Another password for the next connect (the server refused the one before).
    public var password: String? {
        get { lock.locked { _password } }
        set { lock.locked { _password = newValue } }
    }
    /// Other TLS settings for the next connect (a certificate the person trusted).
    public var tls: TLSOptions {
        get { lock.locked { _tls } }
        set { lock.locked { _tls = newValue } }
    }
    /// The certificate each server showed, by "host:port", once checked.
    public var certificates: [String: TLSCertificate] { lock.locked { _certificates } }
    /// What `connect` found.
    public var server: MongoServerInfo? { lock.locked { _server } }

    func checked(_ certificate: TLSCertificate, server: String) {
        lock.locked { _certificates[server] = certificate }
    }

    /// Opens the main session (on an SSH route it first finds the replica set's members, so ssh restarts once at
    /// most) and asks the server what it is. After a failure (a wrong password, a certificate to trust) it can be
    /// called again with other `password` or `tls`, over the same route.
    @discardableResult
    public func connect() async throws -> MongoServerInfo {
        let main = try await session(.main)
        let hello = try await main.command(BSONDocument([("hello", .int32(1))]), database: "admin")
        let build = try await main.command(BSONDocument([("buildInfo", .int32(1))]), database: "admin")
        guard case .string(let version)? = build["version"] else { throw AirSQLError(.other, "The server didn't say its version.") }
        func text(_ key: String) -> String? { if case .string(let value)? = hello[key] { return value } else { return nil } }
        let server = MongoServerInfo(version: version, setName: text("setName"), primary: text("primary"),
                                     isMongos: text("msg") == "isdbgrid")
        lock.locked { _server = server }
        log.write("-- connected: \(server.summary)", context: name + " main")
        return server
    }

    /// The session for `role`, opened on first use (main first: `connect`). Callers asking at the same time share one
    /// connect; a connect that failed is tried again by the next call.
    public func session(_ role: MongoSession.Role) async throws -> MongoSession {
        precondition(role != .cancel, "Cancel opens its own")
        let task: Task<MongoSession, Error> = try lock.locked {
            guard !closed else { throw AirSQLError.disconnected }
            if let task = opening[role] { return task }
            let task = Task { [self] in
                let session = MongoSession(connection: self, role: role, uri: uri)
                do {
                    try await session.open()
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
            lock.locked { if opening[role] == task { opening[role] = nil } }
            throw error
        }
    }

    /// The connection string to `server` ("host:port") alone, for Cancel's side session on the member running an
    /// operation: same login and options, `directConnection`.
    func direct(to server: String) throws -> String {
        var uri = try MongoURI(self.uri)
        if uri.srv {
            // What the SRV name's TXT record would add, and the TLS it implies.
            if uri.option("tls") == nil && uri.option("ssl") == nil { uri.setOption("tls", "true") }
            if uri.option("authSource") == nil { uri.setOption("authSource", "admin") }
            uri.srv = false
        }
        uri.hosts = [server]
        uri.setOption("replicaSet", nil)
        uri.setOption("directConnection", "true")
        return uri.string
    }

    /// Closes every session, then the route; the password is forgotten.
    public func close() async {
        let tasks = lock.locked {
            defer {
                closed = true
                opening = [:]
                _password = nil
            }
            return Array(opening.values)
        }
        for task in tasks { await (try? task.value)?.close() }
        route.close()
    }
}

/// What a MongoDB server said it is at connect.
public struct MongoServerInfo: Sendable, Equatable {
    public var version: String
    /// The replica set's name; nil: a standalone or mongos.
    public var setName: String?
    /// The primary's "host:port", as the replica set names it.
    public var primary: String?
    public var isMongos: Bool

    public init(version: String, setName: String? = nil, primary: String? = nil, isMongos: Bool = false) {
        self.version = version
        self.setName = setName
        self.primary = primary
        self.isMongos = isMongos
    }

    /// "MongoDB 7.0.45, replica set rs0", as the sidebar and the status bar show it.
    public var summary: String {
        "MongoDB \(version), " + (setName.map { "replica set \($0)" } ?? (isMongos ? "sharded cluster" : "standalone"))
    }
}
