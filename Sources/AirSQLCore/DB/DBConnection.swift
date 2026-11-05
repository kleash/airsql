import CMariaDB
import Foundation

/// Everything `DBConnection` needs to reach a server and log in.
public struct ConnectOptions: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Where the driver's bytes go.
    public enum Endpoint: Equatable, Sendable {
        /// TCP to `host`:`port`.
        case tcp
        /// The server's own Unix socket on this Mac (MAMP, Homebrew): nothing in between.
        case socket(String)
        /// A route's private Unix socket (plan §2.3): an SSH tunnel or proxy relay whose far end is TCP to `host`:`port`.
        case route(String)
    }

    /// The saved connection's name, for the SQL log.
    public var name: String
    /// The database server's host name as typed. TCP goes there, and TLS checks the certificate against it, through a
    /// route too.
    public var host: String
    public var port: Int
    public var endpoint: Endpoint
    public var user: String
    /// Never logged, never in SQL; held in memory while the connection is open.
    public var password: String
    /// The default database, if any.
    public var database: String?
    public var tls: TLSOptions
    /// A PAM or LDAP account: its login sends the password as plain text (mysql_clear_password, dialog), so AirSQL
    /// allows it only when this is on and TLS proves the server.
    public var cleartextLogin: Bool
    /// The compressed protocol (zlib).
    public var compress: Bool
    /// SET time_zone after logging in ("+00:00", "Europe/Paris"); nil keeps the server's.
    public var timeZone: String?
    /// The connection's startup SQL, one statement per element (the console's splitter splits it).
    public var startupSQL: [String]
    /// SET SESSION TRANSACTION READ ONLY: read-only connections and the agent session.
    public var readOnly: Bool
    /// Seconds to wait for the server while connecting.
    public var connectTimeout: Int

    public init(name: String = "", host: String, port: Int = 3306, endpoint: Endpoint = .tcp, user: String,
                password: String = "", database: String? = nil, tls: TLSOptions = TLSOptions(), cleartextLogin: Bool = false,
                compress: Bool = false, timeZone: String? = nil, startupSQL: [String] = [], readOnly: Bool = false,
                connectTimeout: Int = 15) {
        self.name = name
        self.host = host
        self.port = port
        self.endpoint = endpoint
        self.user = user
        self.password = password
        self.database = database
        self.tls = tls
        self.cleartextLogin = cleartextLogin
        self.compress = compress
        self.timeZone = timeZone
        self.startupSQL = startupSQL
        self.readOnly = readOnly
        self.connectTimeout = connectTimeout
    }

    /// Without the password, wherever options get printed.
    public var description: String { "\(user)@\(host):\(port)" }
    public var debugDescription: String { description }
}

/// What the server said about itself when a session connected.
public struct ServerInfo: Equatable, Sendable {
    public enum Flavor: String, Sendable {
        case mysql, mariadb

        public var title: String { self == .mysql ? "MySQL" : "MariaDB" }
    }

    public var flavor: Flavor
    /// The version string, "8.4.13" or "11.8.9-MariaDB-ubu2404".
    public var version: String
    /// 80413, 110809.
    public var versionNumber: Int
    /// The session's thread on the server (CONNECTION_ID()), as the process list shows it.
    public var threadID: UInt64
    /// "TLSv1.3, TLS_AES_256_GCM_SHA384"; nil without TLS.
    public var tls: String?
    /// The certificate the server showed, when TLS is on.
    public var certificate: TLSCertificate?

    /// The server is this version or later, as `SchemaServer.atLeast` asks it.
    public func atLeast(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) -> Bool {
        versionNumber >= major * 10_000 + minor * 100 + patch
    }
}

/// One result of a statement: its rows, or what it changed. A procedure (CALL) gives one per result set and one for
/// the CALL itself.
public struct StatementResult {
    /// The rows, for SELECT, SHOW and a procedure's result sets.
    public var rows: ResultStore?
    /// Rows changed; for UPDATE, rows matched (CLIENT_FOUND_ROWS), which grid Apply checks exactly.
    public var affectedRows: UInt64
    public var insertID: UInt64
    public var warnings: Int
    /// The server's note, such as "Rows matched: 1  Changed: 1  Warnings: 0".
    public var info: String?
    /// Rows really changed: an UPDATE's "Changed:" from `info`, or else `affectedRows`.
    public var changedRows: UInt64 {
        guard let info, let range = info.range(of: "Changed: ") else { return affectedRows }
        return UInt64(info[range.upperBound...].prefix(while: \.isNumber)) ?? affectedRows
    }
    /// From sending the statement until this result was read.
    public var duration: TimeInterval
}

/// What Cancel did.
public enum CancelResult: Equatable, Sendable {
    /// The server was told to stop the statement (KILL QUERY).
    case cancelled
    /// Nothing of this session's was running any more.
    case notRunning
    /// AirSQL couldn't make sure the server would stop this statement and nothing else (a proxy or load balancer in
    /// between): the reason, for offering Disconnect instead.
    case unsafe(String)
}

/// What Reconnect found.
public struct Reconnected: Sendable {
    public var server: ServerInfo
    /// A transaction was open when the connection dropped: it is rolled back (the server does that to a session it
    /// loses, and to the old session AirSQL killed).
    public var rolledBack: Bool
    /// The old session was still on the server (holding its locks) and has been killed.
    public var killedOldSession: Bool
}

/// One session with a server (plan §2.2): libmariadb's blocking calls run in order on the session's own thread, behind
/// an async API, so nothing waits on the network on the main thread. Every session is set up the same way each time it
/// connects (`connect`), sends one statement at a time (no multi-statements) tagged /* airsql:<role>:<n> */, reads
/// results promptly into `ResultStore`s, writes each statement to the SQL log first, and never reconnects behind the
/// user's back: a lost connection is reported, and `reconnect` is explicit. Thread-safe: what other threads read is
/// under `state`, the rest belongs to the session's thread.
public final class DBConnection: @unchecked Sendable {
    /// The session's job (plan §2.2's session model, `Connection`): it names the session in tags and the SQL log.
    public enum Role: String, Sendable {
        case main, data, schema, agent, tools, cancel, query
    }

    public let role: Role
    /// Kept (password included) for Reconnect and Cancel's side connection, in memory only; `close` forgets the password.
    public var options: ConnectOptions { state.locked { _options } }
    private var _options: ConnectOptions
    private let log: SQLLog
    private let worker: Worker

    // Shared with other threads (Cancel, Disconnect, the UI's reads), under `state`.
    private let state = NSCondition()
    private var mysql: UnsafeMutablePointer<MYSQL>?
    private var _server: ServerInfo?
    private var _lastUsed = Date()
    private var serverStatus: UInt32 = 0
    private var _transactionStarted: Date?
    /// The tag of the statement on the wire, and its text.
    private var running: String?
    private var runningSQL: String?
    /// Cancels under way: a new statement waits for them, so a KILL QUERY meant for the last one can't hit it.
    private var cancels = 0
    /// The user-level lock the session holds (GET_LOCK) so another session can tell it apart from every other: Cancel
    /// and Reconnect find its thread with IS_USED_LOCK.
    private var lockName: String?
    /// Set when the connection dropped: what Reconnect needs to clean up after it.
    private var lost: (threadID: UInt64, lockName: String?, inTransaction: Bool)?

    /// Statements sent (the n in the tag); on the session's thread only.
    private var number = 0

    public init(options: ConnectOptions, role: Role, log: SQLLog = .shared) {
        _options = options
        self.role = role
        self.log = log
        worker = Worker(name: "AirSQL \(role.rawValue) session")
    }

    deinit {
        let mysql = self.mysql
        worker.submit { if let mysql { mysql_close(mysql) } }
        worker.stop()
    }

    // MARK: The async API

    /// Connects and sets the session up: utf8mb4, the time zone, the startup SQL, read-only where asked.
    @discardableResult
    public func connect() async throws -> ServerInfo {
        try await worker.perform { [self] in try connectHere() }
    }

    /// Runs one statement and reads all of its results. A result set stops at `rowCap` rows: then the statement is
    /// stopped on the server and the store is marked `capped` ("first N rows"). What an agent's request sends passes the
    /// agents' gate first (`AgentGate`).
    public func query(_ sql: String, rowCap: Int = 100_000) async throws -> [StatementResult] {
        try await AgentGate.check(sql, on: self)
        return try await worker.perform { [self] in try queryHere(sql, rowCap: rowCap) }
    }

    /// Runs a statement and hands its rows over in batches as they arrive, keeping none: Export all's way, for results
    /// of any size. `batch` runs on the session's thread with each batch (`batchRows` rows, or fewer past 16 MB);
    /// throwing from it stops the statement on the server, as Cancel does, and the error comes back here.
    public func stream(_ sql: String, batchRows: Int = 10_000, batch: @escaping (ResultStore) throws -> Void) async throws {
        try await AgentGate.check(sql, on: self)
        try await worker.perform { [self] in
            let mysql = try current()
            guard let server = state.locked({ _server }) else { throw AirSQLError.disconnected }
            _ = try noticingDrops(mysql) {
                try run(mysql, sql, flavor: server.flavor, rowCap: .max, batch: (max(1, batchRows), batch))
            }
        }
    }

    /// Stops the running statement: through a short side connection that checks it reaches the same server and that
    /// the session's thread still runs this statement (by its tag), then KILL QUERY (MariaDB: KILL QUERY ID). With
    /// `statement`, only if that is what runs: the table tabs share a session, and one must not stop another's Apply.
    public func cancel(statement: String? = nil) async throws -> CancelResult {
        let target: (tag: String, threadID: UInt64, lockName: String?, flavor: ServerInfo.Flavor)? = state.locked {
            guard let running, let server = _server, statement == nil || statement == runningSQL else { return nil }
            cancels += 1
            return (running, server.threadID, lockName, server.flavor)
        }
        guard let target else { return .notRunning }
        defer {
            state.locked {
                cancels -= 1
                state.broadcast()
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { [self] in
                continuation.resume(with: Result { try kill(target.tag, thread: target.threadID, lockName: target.lockName,
                                                            flavor: target.flavor) })
            }
        }
    }

    /// Checks the connection is still there (mysql_ping, which never reconnects); a dropped one is reported.
    public func ping() async throws {
        try await worker.perform { [self] in
            let mysql = try current()
            try noticingDrops(mysql) {
                if mysql_ping(mysql) != 0 { throw failure(mysql) }
            }
        }
    }

    /// Connects again and sets the session up again. If a transaction was open, it is gone: the old session, if the
    /// server still has it, is killed so its locks go, and the result says so.
    public func reconnect() async throws -> Reconnected {
        try await worker.perform { [self] in try reconnectHere() }
    }

    /// Closes the session for good (a new one is a new `DBConnection`). A statement still running is broken off: the
    /// server stops it and rolls back.
    public func close() async {
        state.locked {
            if running != nil, let mysql { mariadb_cancel(mysql) }
        }
        try? await worker.perform { [self] in closeHere() }
        worker.stop()
        state.locked { _options.password = "" }
    }

    // MARK: State

    public var server: ServerInfo? { state.locked { _server } }
    public var isConnected: Bool { state.locked { mysql != nil } }
    /// The connection dropped, and nothing has reconnected or closed it.
    public var wasLost: Bool { state.locked { lost != nil } }
    /// When a statement last started here (or the session opened).
    public var lastUsed: Date { state.locked { _lastUsed } }
    /// A statement is running.
    public var isBusy: Bool { state.locked { running != nil } }
    /// A transaction is open on the server (SERVER_STATUS_IN_TRANS).
    public var inTransaction: Bool { state.locked { serverStatus & UInt32(SERVER_STATUS_IN_TRANS) != 0 } }
    /// When the open transaction started (as AirSQL saw it), for the Tx badge and keep-alive.
    public var transactionStarted: Date? { state.locked { _transactionStarted } }
    public var autocommit: Bool { state.locked { serverStatus & UInt32(SERVER_STATUS_AUTOCOMMIT) != 0 } }
    /// The session's sql_mode has NO_BACKSLASH_ESCAPES: `SQLQuote.string` must double quotes instead.
    public var noBackslashEscapes: Bool { state.locked { serverStatus & UInt32(SERVER_STATUS_NO_BACKSLASH_ESCAPES) != 0 } }

    // MARK: On the session's thread (or, for Cancel's side connection, the thread that uses it)

    /// Connector/C's one-time setup (its default character set, TLS, plugins), before any of its calls.
    static let library: Void = { _ = mysql_server_init(0, nil, nil) }()

    private var context: String { "\(options.name) \(role.rawValue)" }

    private var isRouteWithoutTLS: Bool {
        if case .route = options.endpoint { return options.tls.mode == .off }
        return false
    }

    /// The login methods allowed (MARIADB_OPT_RESTRICTED_AUTH): native, caching_sha2, sha256 and ed25519; the plain
    /// text ones (PAM, LDAP) only when asked for and over TLS that proves the server. caching_sha2_password treats any
    /// Unix socket as secure and sends the password as plain text on it: through a route without TLS that text would
    /// cross the route's last hop, so there it isn't allowed.
    private func loginMethods() throws -> [String] {
        var methods = ["mysql_native_password", "client_ed25519", "sha256_password"]
        if !isRouteWithoutTLS { methods.append("caching_sha2_password") }
        if options.cleartextLogin {
            guard options.tls.verified else {
                throw AirSQLError(.loginMethodNotAllowed, "A PAM or LDAP login sends the password as plain text, so AirSQL "
                                  + "uses it only over TLS that proves the server: set TLS to Verify identity, or trust the "
                                  + "server's certificate.")
            }
            methods += ["mysql_clear_password", "dialog"]
        }
        return methods
    }

    private func connectHere() throws -> ServerInfo {
        if let server = state.locked({ mysql != nil ? _server : nil }) { return server }
        _ = Self.library
        guard let mysql = mysql_init(nil) else { throw AirSQLError(.other, "Out of memory.") }
        var connected = false
        defer {
            if !connected {
                state.locked {
                    if self.mysql == mysql { self.mysql = nil }
                }
                mysql_close(mysql)
            }
        }
        try configure(mysql)
        let check = options.tls.mode == .off ? nil : TLSCheck(host: options.host, options: options.tls, mysql: mysql)
        TLSCheck.current = check
        defer { TLSCheck.current = nil }

        var host = options.host, socket: String?
        switch options.endpoint {
        case .tcp: break
        case .socket(let path), .route(let path):
            host = "localhost"
            socket = path
        }
        // CLIENT_FOUND_ROWS: an UPDATE's affected rows are the rows it matched (Apply checks them exactly).
        // CLIENT_MULTI_RESULTS: procedures' result sets. Never CLIENT_MULTI_STATEMENTS (R4).
        let flags = UInt(CLIENT_FOUND_ROWS) | UInt(CLIENT_MULTI_RESULTS)
        guard mysql_real_connect(mysql, host, options.user, options.password, options.database, UInt32(options.port), socket,
                                 flags) != nil else {
            let error = check?.failure ?? loginFailure(mysql)
            log.note("connect failed: " + (error.code == 0 ? error.message : "error \(error.code)"), context: context)
            throw error
        }
        let cipher = mysql_get_ssl_cipher(mysql).map { String(cString: $0) }
        if options.tls.mode != .off && cipher == nil {
            throw AirSQLError(.tls, "The server didn't encrypt the connection.")
        }
        var version: UnsafePointer<CChar>?
        mariadb_get_info(mysql, MARIADB_CONNECTION_TLS_VERSION, &version)
        state.locked {
            self.mysql = mysql
            serverStatus = mysql.pointee.server_status
        }
        var server = ServerInfo(flavor: mariadb_connection(mysql) != 0 ? .mariadb : .mysql,
                                version: String(cString: mysql_get_server_info(mysql)),
                                versionNumber: Int(mysql_get_server_version(mysql)),
                                threadID: UInt64(mysql_thread_id(mysql)),
                                tls: cipher.map { c in version.map { String(cString: $0) + ", " + c } ?? c },
                                certificate: check?.certificate)

        // The session's setup, every time it connects.
        var set = "SET NAMES utf8mb4"
        if let zone = options.timeZone { set += ", time_zone = " + SQLQuote.string(zone) }
        _ = try run(mysql, set, flavor: server.flavor)
        // The lock lets Cancel and Reconnect tell this session's thread from every other, on the same server. A server
        // that refuses user locks (MariaDB Galera) leaves the session without one: Cancel then offers Disconnect.
        var lock = role == .cancel ? nil : "airsql:" + UUID().uuidString.lowercased()
        var identity: [StatementResult]
        if let name = lock, let rows = try? run(mysql, "SELECT CONNECTION_ID(), GET_LOCK(\(SQLQuote.string(name)), 0)",
                                                flavor: server.flavor) {
            identity = rows
        } else {
            lock = nil
            identity = try run(mysql, "SELECT CONNECTION_ID()", flavor: server.flavor)
        }
        if let rows = identity.first?.rows, rows.rowCount == 1, let id = rows.string(0, 0).flatMap(UInt64.init) {
            server.threadID = id
        }
        let locked = lock != nil && identity.first?.rows?.string(0, 1) == "1"
        if !options.startupSQL.isEmpty {
            log.note("startup SQL (\(options.startupSQL.count) statement\(options.startupSQL.count == 1 ? "" : "s"))",
                     context: context)
            for (index, statement) in options.startupSQL.enumerated() {
                do {
                    _ = try run(mysql, statement, flavor: server.flavor, logged: false)
                } catch var error as AirSQLError {
                    error.message = "Startup SQL statement \(index + 1) failed: " + error.message
                    throw error
                }
            }
        }
        if options.readOnly { _ = try run(mysql, "SET SESSION TRANSACTION READ ONLY", flavor: server.flavor) }

        state.locked {
            _server = server
            lockName = locked ? lock : nil
            lost = nil
        }
        log.note("connected: \(server.flavor.title) \(server.version), thread \(server.threadID)"
                 + (server.tls.map { ", " + $0 } ?? ", no TLS"), context: context)
        connected = true
        return server
    }

    private func configure(_ mysql: UnsafeMutablePointer<MYSQL>) throws {
        func set(_ option: mysql_option, _ value: UnsafeRawPointer?) throws {
            if mysql_options(mysql, option, value) != 0 { throw AirSQLError(.other, "Connector/C refused option \(option.rawValue).") }
        }
        func set(_ option: mysql_option, text: String) throws {
            try text.withCString { try set(option, $0) }
        }
        var zero: UInt32 = 0, timeout = UInt32(max(1, options.connectTimeout))
        var on: my_bool = 1, off: my_bool = 0
        var protocolType = (options.endpoint == .tcp ? MYSQL_PROTOCOL_TCP : MYSQL_PROTOCOL_SOCKET).rawValue
        try set(MYSQL_SET_CHARSET_NAME, text: "utf8mb4")
        try set(MYSQL_OPT_LOCAL_INFILE, &zero)  // and the library is built without it (R5)
        try set(MYSQL_OPT_PROTOCOL, &protocolType)
        try set(MYSQL_OPT_CONNECT_TIMEOUT, &timeout)
        let methods = try loginMethods()
        try set(MARIADB_OPT_RESTRICTED_AUTH, text: methods.joined(separator: ","))
        // Without caching_sha2 the login starts with native, so the server can say which method the account uses
        // before Connector/C checks the list (it checks the greeting's method first).
        if !methods.contains("caching_sha2_password") { try set(MYSQL_DEFAULT_AUTH, text: "mysql_native_password") }
        // A login method that isn't built in is looked for in the plugin folder, before the list is checked: an empty
        // folder only root can write to (also overriding MARIADB_PLUGIN_DIR in the environment).
        try set(MYSQL_PLUGIN_DIR, text: "/var/empty")
        try "program_name".withCString { name in
            try "AirSQL".withCString { value in
                if mysql_options4(mysql, MYSQL_OPT_CONNECT_ATTR_ADD, name, value) != 0 {
                    throw AirSQLError(.other, "Connector/C refused the connection attributes.")
                }
            }
        }
        if options.compress { try set(MYSQL_OPT_COMPRESS, nil) }
        // Never MYSQL_OPT_RECONNECT (R8): it is off by default and stays off.

        guard options.tls.mode != .off else {
            try set(MYSQL_OPT_SSL_ENFORCE, &off)
            try set(MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &off)
            return
        }
        // TLS or no connection (the library errs when the server doesn't offer it); TLSCheck decides about the
        // certificate. The CA file is read by TLSCheck, not handed to OpenSSL.
        try set(MYSQL_OPT_SSL_ENFORCE, &on)
        try set(MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &on)
        try set(MARIADB_OPT_TLS_VERIFICATION_CALLBACK, unsafeBitCast(TLSCheck.callback, to: UnsafeRawPointer.self))
        if let pin = options.tls.pinnedFingerprint { try set(MARIADB_OPT_TLS_PEER_FP, text: pin) }
        if let cert = options.tls.certFile { try set(MYSQL_OPT_SSL_CERT, text: cert) }
        if let key = options.tls.keyFile { try set(MYSQL_OPT_SSL_KEY, text: key) }
    }

    /// A failed login's error, with AirSQL's reason when it refused the login method itself.
    private func loginFailure(_ mysql: UnsafeMutablePointer<MYSQL>) -> AirSQLError {
        var error = ErrorMapping.map(mysql, mariaDB: false)
        if error.code == Int(CR_PLUGIN_NOT_ALLOWED) {
            let text = String(cString: mysql_error(mysql))
            if text.contains("caching_sha2_password") && isRouteWithoutTLS {
                error.message = "This account logs in with caching_sha2_password, which through a tunnel without TLS would "
                    + "send the password as plain text on the tunnel's last stretch. Turn on TLS for this connection."
            } else if text.contains("mysql_clear_password") || text.contains("dialog") {
                error.message = "This account logs in with PAM or LDAP, which sends the password as plain text. Turn on "
                    + "“PAM or LDAP login” for this connection, with TLS that proves the server."
            }
        }
        if error.kind == .disconnected {
            error.message = "The server closed the connection during the login. Check that the port is a MySQL or MariaDB "
                + "server's."
        }
        return error
    }

    private func queryHere(_ sql: String, rowCap: Int) throws -> [StatementResult] {
        let mysql = try current()
        guard let server = state.locked({ _server }) else { throw AirSQLError.disconnected }
        return try noticingDrops(mysql) { try run(mysql, sql, flavor: server.flavor, rowCap: rowCap) }
    }

    /// Runs `body`; when it finds the connection gone, the session is closed and remembered for Reconnect.
    private func noticingDrops<T>(_ mysql: UnsafeMutablePointer<MYSQL>, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as AirSQLError where error.kind == .disconnected {
            dropped(mysql)
            throw error
        }
    }

    /// The open connection, or the error that says it is gone.
    private func current() throws -> UnsafeMutablePointer<MYSQL> {
        guard let mysql = state.locked({ self.mysql }) else { throw AirSQLError.disconnected }
        return mysql
    }

    /// Sends one statement and reads its results: the heart of the session. Logged first (unless it is startup SQL),
    /// tagged, and never sent while a Cancel for the statement before is still under way.
    private func run(_ mysql: UnsafeMutablePointer<MYSQL>, _ sql: String, flavor: ServerInfo.Flavor, rowCap: Int = 1000,
                     logged: Bool = true, batch: (rows: Int, deliver: (ResultStore) throws -> Void)? = nil) throws
        -> [StatementResult] {
        number += 1
        let tag = "/* airsql:\(role.rawValue):\(number) */"
        let noBackslashEscapes = state.locked {
            while cancels > 0 { state.wait() }
            running = tag
            runningSQL = sql
            _lastUsed = Date()
            return serverStatus & UInt32(SERVER_STATUS_NO_BACKSLASH_ESCAPES) != 0
        }
        defer { state.locked { (running, runningSQL) = (nil, nil) } }
        if logged { log.statement(sql, context: "\(context):\(number)", noBackslashEscapes: noBackslashEscapes) }
        let text = tag + " " + sql
        let start = Date()
        if mysql_real_query(mysql, text, UInt(text.utf8.count)) != 0 { throw failure(mysql, flavor: flavor) }

        var results: [StatementResult] = []
        var stopped = false  // a result set reached its cap: the rest of the statement's output is read and dropped
        repeat {
            if mysql_field_count(mysql) > 0 {
                guard let result = mysql_use_result(mysql) else { throw failure(mysql, flavor: flavor) }
                if stopped {
                    mysql_free_result(result)
                } else {
                    var store = ResultStore(columns: columns(result))
                    var delivered = false, refused: Error?  // what `batch` threw
                    while let row = mysql_fetch_row(result) {
                        if let batch, store.rowCount == batch.rows || store.storedBytes > 16 << 20 {
                            store.finish()
                            do {
                                try batch.deliver(store)
                            } catch {
                                refused = error
                                stopped = true
                                break
                            }
                            delivered = true
                            store = ResultStore(columns: store.columns)
                        }
                        guard store.rowCount < rowCap, store.append(row, lengths: mysql_fetch_lengths(result)) else {
                            store.capped = true
                            stopped = true
                            break
                        }
                    }
                    if stopped {
                        // Stop the statement rather than read rows nobody asked for, unless it can't be done safely.
                        if (try? kill(tag, thread: state.locked({ _server?.threadID }) ?? 0,
                                      lockName: state.locked({ lockName }), flavor: flavor)) != .cancelled {
                            log.note("reading the rest of \(role.rawValue):\(number) to drop it", context: context)
                        }
                        mysql_free_result(result)  // reads what is left until the server stops
                    } else if mysql_errno(mysql) != 0 {
                        let error = failure(mysql, flavor: flavor)
                        mysql_free_result(result)
                        throw error
                    } else {
                        mysql_free_result(result)
                    }
                    store.finish()
                    if let refused { throw refused }
                    if let batch {
                        if store.rowCount > 0 || !delivered { try batch.deliver(store) }
                    } else {
                        results.append(StatementResult(rows: store, affectedRows: 0, insertID: 0,
                                                       warnings: Int(mysql_warning_count(mysql)), info: nil,
                                                       duration: Date().timeIntervalSince(start)))
                    }
                }
            } else if !stopped {
                results.append(StatementResult(rows: nil, affectedRows: mysql_affected_rows(mysql), insertID: mysql_insert_id(mysql),
                                               warnings: Int(mysql_warning_count(mysql)),
                                               info: mysql_info(mysql).map { String(cString: $0) },
                                               duration: Date().timeIntervalSince(start)))
            }
            let next = mysql_next_result(mysql)
            if next > 0 && !stopped { throw failure(mysql, flavor: flavor) }
            if next != 0 { break }
        } while true
        statusChanged(mysql)
        return results
    }

    private func columns(_ result: UnsafeMutablePointer<MYSQL_RES>) -> [ResultStore.Column] {
        let count = Int(mysql_num_fields(result))
        guard count > 0, let fields = mysql_fetch_fields(result) else { return [] }
        func text(_ pointer: UnsafeMutablePointer<CChar>?, _ length: UInt32) -> String {
            guard let pointer else { return "" }
            return pointer.withMemoryRebound(to: UInt8.self, capacity: Int(length)) {
                String(decoding: UnsafeBufferPointer(start: $0, count: Int(length)), as: UTF8.self)
            }
        }
        return (0..<count).map { index in
            let field = fields[index]
            return ResultStore.Column(name: text(field.name, field.name_length),
                                      originalName: text(field.org_name, field.org_name_length),
                                      table: text(field.table, field.table_length),
                                      originalTable: text(field.org_table, field.org_table_length),
                                      database: text(field.db, field.db_length), type: field.type, flags: field.flags,
                                      charset: field.charsetnr, length: UInt64(field.length), decimals: field.decimals)
        }
    }

    /// The error a call left behind (logged by number), and the session's state after it. A connection that dropped
    /// keeps its last state, which Reconnect reports (Connector/C forgets the transaction).
    private func failure(_ mysql: UnsafeMutablePointer<MYSQL>, flavor: ServerInfo.Flavor? = nil) -> AirSQLError {
        let error = ErrorMapping.map(mysql, mariaDB: (flavor ?? state.locked { _server?.flavor }) == .mariadb)
        log.note("error \(error.code)", context: "\(context):\(number)")
        if error.kind != .disconnected { statusChanged(mysql) }
        return error
    }

    private func statusChanged(_ mysql: UnsafeMutablePointer<MYSQL>) {
        let status = mysql.pointee.server_status
        state.locked {
            serverStatus = status
            let open = status & UInt32(SERVER_STATUS_IN_TRANS) != 0
            if !open { _transactionStarted = nil } else if _transactionStarted == nil { _transactionStarted = Date() }
        }
    }

    /// The connection dropped: it is closed and remembered for Reconnect, and every call says so until then.
    private func dropped(_ mysql: UnsafeMutablePointer<MYSQL>) {
        let wasOpen: Bool = state.locked {
            guard self.mysql == mysql else { return false }
            lost = (_server?.threadID ?? 0, lockName, serverStatus & UInt32(SERVER_STATUS_IN_TRANS) != 0)
            self.mysql = nil
            return true
        }
        guard wasOpen else { return }
        log.note("connection lost", context: context)
        mysql_close(mysql)
    }

    private func reconnectHere() throws -> Reconnected {
        // Kept as `lost` until the new session is up, so a failed attempt can be tried again with the same report.
        let before: (threadID: UInt64, lockName: String?, inTransaction: Bool)? = state.locked {
            if lost == nil, let server = _server, mysql != nil {
                lost = (server.threadID, lockName, serverStatus & UInt32(SERVER_STATUS_IN_TRANS) != 0)
            }
            return lost
        }
        closeHere()
        let server = try connectHere()
        var killed = false
        // The old session may still be on the server (a dropped network goes unnoticed there): its lock names its thread.
        if let before, before.inTransaction, let lockName = before.lockName, let mysql = state.locked({ self.mysql }) {
            let holder = try run(mysql, "SELECT IS_USED_LOCK(\(SQLQuote.string(lockName)))", flavor: server.flavor)
            if let id = holder.first?.rows?.string(0, 0).flatMap(UInt64.init), id == before.threadID {
                do {
                    _ = try run(mysql, "KILL CONNECTION \(id)", flavor: server.flavor)
                    killed = true
                } catch let error as AirSQLError where error.code == 1094 {
                    // It ended meanwhile ("Unknown thread id"): nothing left to kill.
                }
            }
        }
        log.note("reconnected" + (before?.inTransaction == true ? "; the open transaction was rolled back" : "")
                 + (killed ? "; the old session was killed" : ""), context: context)
        return Reconnected(server: server, rolledBack: before?.inTransaction ?? false, killedOldSession: killed)
    }

    private func closeHere() {
        guard let mysql = state.locked({ () -> UnsafeMutablePointer<MYSQL>? in
            defer { self.mysql = nil }
            return self.mysql
        }) else { return }
        mysql_close(mysql)
        log.note("disconnected", context: context)
    }

    /// Cancel's side connection: opened, used and closed on the calling thread. KILL QUERY only for the statement with
    /// this tag, on the thread that holds this session's lock: never another statement or another server's thread.
    private func kill(_ tag: String, thread: UInt64, lockName: String?, flavor: ServerInfo.Flavor) throws -> CancelResult {
        let unsafe = CancelResult.unsafe("AirSQL can't make sure the server would stop this statement and nothing else: "
                                         + "the server answering isn't the one running it (a proxy or load balancer in "
                                         + "between). Disconnect to stop it.")
        guard let lockName, thread != 0 else { return unsafe }
        var sideOptions = options
        sideOptions.database = nil
        sideOptions.startupSQL = []
        sideOptions.timeZone = nil
        sideOptions.readOnly = false
        let side = DBConnection(options: sideOptions, role: .cancel, log: log)
        defer { side.closeHere() }
        _ = try side.connectHere()
        guard let mysql = side.state.locked({ side.mysql }) else { return unsafe }
        // MySQL's process list has no query id; MariaDB's lets KILL name the statement itself. The second value is our
        // tagged statement when its tag still shows in INFO; the third is whatever query the thread runs now, for a
        // procedure the tagged CALL started, where INFO shows the inner statement, not the CALL's tag.
        let statement = flavor == .mariadb ? "QUERY_ID" : "ID"
        let check = try side.run(mysql, "SELECT IS_USED_LOCK(\(SQLQuote.string(lockName))), (SELECT \(statement) FROM "
                                 + "information_schema.PROCESSLIST WHERE ID = \(thread) AND LEFT(INFO, \(tag.count)) = "
                                 + "\(SQLQuote.string(tag))), (SELECT \(statement) FROM information_schema.PROCESSLIST "
                                 + "WHERE ID = \(thread) AND COMMAND = 'Query')", flavor: flavor)
        guard let rows = check.first?.rows, rows.rowCount == 1 else { return unsafe }
        guard rows.string(0, 0) == String(thread) else { return unsafe }
        if let id = rows.string(0, 1) {
            _ = try side.run(mysql, flavor == .mariadb ? "KILL QUERY ID \(id)" : "KILL QUERY \(thread)", flavor: flavor)
            return .cancelled
        }
        // The tag isn't in INFO: a statement inside a procedure the tagged CALL started is running. Kill it only while
        // the thread still runs a query and this session hasn't moved on to another statement (a new one can't start
        // while a cancel is under way, since run() waits for cancels == 0), so KILL QUERY still hits the CALL alone.
        if let id = rows.string(0, 2), state.locked({ running }) == tag {
            _ = try side.run(mysql, flavor == .mariadb ? "KILL QUERY ID \(id)" : "KILL QUERY \(thread)", flavor: flavor)
            return .cancelled
        }
        return .notRunning
    }
}

/// A session's own thread: libmariadb's calls block, so each session runs them in order on a thread of its own, never
/// on the main thread or Swift's shared pool.
final class Worker: @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [() -> Void] = []
    private var stopping = false

    init(name: String) {
        let thread = Thread { [self] in run() }
        thread.name = name
        thread.start()
    }

    private func run() {
        while true {
            condition.lock()
            while jobs.isEmpty && !stopping { condition.wait() }
            guard !jobs.isEmpty else {
                condition.unlock()
                return
            }
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }

    /// False once the worker is stopping: the job won't run.
    @discardableResult
    func submit(_ job: @escaping () -> Void) -> Bool {
        condition.locked {
            guard !stopping else { return false }
            jobs.append(job)
            condition.signal()
            return true
        }
    }

    /// Ends the thread once the jobs submitted so far have run.
    func stop() {
        condition.locked {
            stopping = true
            condition.signal()
        }
    }

    func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            if !submit({ continuation.resume(with: Result(catching: body)) }) {
                continuation.resume(throwing: AirSQLError.disconnected)
            }
        }
    }
}

extension NSLocking {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
