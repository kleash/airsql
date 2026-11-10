import CMongoC
import Darwin
import Foundation

/// One session with a MongoDB server or replica set (plan decision 2): a single-threaded `mongoc_client_t` whose calls
/// run in order on the session's own thread (`Worker`, as `DBConnection`), never on the main thread. Every connection the
/// driver makes goes through `open` (its stream initiator): the server's socket on the route (`MongoRoute`), or TCP for
/// Direct; then TLS, with the certificate checked by `TLSCheck` (SecTrust: the Mac's roots and trust settings, the CA
/// file, or the pinned fingerprint) against that server's own name, before the driver sends anything. The driver's own
/// certificate checks are off (`weak_cert_validation`), and with them its OCSP requests, which would bypass the route.
public final class MongoConnection: @unchecked Sendable {
    /// The connection string without user or password.
    public let uri: String
    private let user: String?
    private let password: String?
    private let tls: TLSOptions
    public let route: MongoRoute
    private let worker = Worker(name: "AirSQL MongoDB session")
    private let lock = NSLock()
    /// Touched on the worker only.
    private var client: OpaquePointer?
    private var _routeError: AirSQLError?
    private var _certificates: [String: TLSCertificate] = [:]

    /// The certificate each server showed, by "host:port", once checked.
    public var certificates: [String: TLSCertificate] { lock.locked { _certificates } }

    private static let setUp: Void = {
        mongoc_init()
        // The driver's own log goes nowhere: what matters reaches AirSQL as errors.
        mongoc_log_set_handler(nil, nil)
    }()

    public init(uri: String, user: String? = nil, password: String? = nil, tls: TLSOptions = TLSOptions(), route: MongoRoute) {
        _ = Self.setUp
        self.uri = uri
        self.user = user
        self.password = password
        self.tls = tls
        self.route = route
    }

    deinit {
        let client = self.client
        worker.submit { if let client { mongoc_client_destroy(client) } }
        worker.stop()
    }

    /// Makes the client (a mongodb+srv name is looked up here, on this Mac) and pings the server it selects. On an SSH
    /// route that restarts ssh for each new server, a first client finds the members through the seeds' forwards, so
    /// that ssh restarts once at most, before this client connects anywhere.
    public func connect() async throws {
        try await worker.perform { [self] in
            guard client == nil else { return }
            if route.findsMembersFirst {
                let probe = try makeClient()
                defer { mongoc_client_destroy(probe) }
                try route.findMembers {
                    var error = bson_error_t()
                    mongoc_client_select_server(probe, false, nil, &error).map { mongoc_server_description_destroy($0) }
                    var count = 0
                    guard let found = mongoc_client_get_server_descriptions(probe, &count) else { return [] }
                    defer { mongoc_server_descriptions_destroy_all(found, count) }
                    return (0..<count).compactMap { found[$0] }.map { server in
                        let host = mongoc_server_description_host(server)!.pointee
                        return (Self.text(host.host), Int(host.port))
                    }
                }
            }
            client = try makeClient()
            _ = try commandHere(#"{"ping": 1}"#, database: "admin")
        }
    }

    private func makeClient() throws -> OpaquePointer {
        var error = bson_error_t()
        // The login goes into the string, which the driver checks authMechanism against as it reads it; the string
        // stays in memory (the driver's log is off) and `uri` keeps none of it.
        var text = uri
        if let user, let scheme = text.range(of: "://") {
            let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let login = [user] + (password.map { [$0] } ?? [])
            text.insert(contentsOf: login.map { $0.addingPercentEncoding(withAllowedCharacters: plain) ?? "" }
                .joined(separator: ":") + "@", at: scheme.upperBound)
        }
        guard let parsed = mongoc_uri_new_with_error(text, &error) else { throw Self.failure(error) }
        defer { mongoc_uri_destroy(parsed) }
        mongoc_uri_set_appname(parsed, "AirSQL")
        guard let made = mongoc_client_new_from_uri_with_error(parsed, &error) else { throw Self.failure(error) }
        mongoc_client_set_error_api(made, Int32(MONGOC_ERROR_API_VERSION_2))
        mongoc_client_set_stream_initiator(made, Self.initiator, Unmanaged.passUnretained(self).toOpaque())
        var seeds: [(host: String, port: Int)] = []
        var host = mongoc_uri_get_hosts(mongoc_client_get_uri(made))
        while let current = host {
            seeds.append((Self.text(current.pointee.host), Int(current.pointee.port)))
            host = UnsafePointer(current.pointee.next)
        }
        route.seed(seeds)
        return made
    }

    /// Runs a command (Extended JSON) on the primary, or on the server `serverID`; the reply as relaxed Extended JSON.
    public func command(_ json: String, database: String = "admin", serverID: UInt32? = nil) async throws -> String {
        try await worker.perform { [self] in try commandHere(json, database: database, serverID: serverID) }
    }

    /// Runs `body` with the driver's client on the session's thread, for what has no method here yet.
    public func withClient<T>(_ body: @escaping (OpaquePointer) throws -> T) async throws -> T {
        try await worker.perform { [self] in try body(try current()) }
    }

    /// Ends the operations tagged `comment` on this connection's server (connect it to the member running them, with
    /// directConnection=true): `currentOp` finds them, `killOp` ends each. How many it ended.
    public func killOperations(comment: String) async throws -> Int {
        try await worker.perform { [self] in
            // A command's name comes first: the JSON is written out, as a dictionary has no order.
            let tag = String(decoding: try JSONSerialization.data(withJSONObject: comment, options: .fragmentsAllowed),
                             as: UTF8.self)
            let reply = try commandHere(#"{"currentOp": 1, "$all": true, "command.comment": \#(tag)}"#, database: "admin")
            let ops = (Self.object(reply)?["inprog"] as? [[String: Any]]) ?? []
            for op in ops {
                guard let id = op["opid"] as? NSNumber else { continue }
                _ = try commandHere(#"{"killOp": 1, "op": \#(id)}"#, database: "admin")
            }
            return ops.count
        }
    }

    /// Destroys the client (its sockets) and ends the route.
    public func close() async {
        try? await worker.perform { [self] in
            if let client { mongoc_client_destroy(client) }
            client = nil
        }
        route.close()
    }

    private func current() throws -> OpaquePointer {
        guard let client else { throw AirSQLError.disconnected }
        return client
    }

    private func commandHere(_ json: String, database: String, serverID: UInt32? = nil) throws -> String {
        let client = try current()
        var error = bson_error_t()
        guard let command = bson_new_from_json(json, -1, &error) else { throw Self.failure(error) }
        defer { bson_destroy(command) }
        lock.locked { _routeError = nil }
        return try Self.withReply { reply in
            let ok = serverID.map { mongoc_client_command_simple_with_server_id(client, database, command, nil, $0, reply, &error) }
                ?? mongoc_client_command_simple(client, database, command, nil, reply, &error)
            guard ok else { throw lock.locked { _routeError } ?? Self.failure(error) }
            return Self.json(reply)
        }
    }

    // MARK: The stream initiator

    private static let initiator: mongoc_stream_initiator_t = { uri, host, context, errorOut in
        guard let uri, let host, let context else { return nil }
        let connection = Unmanaged<MongoConnection>.fromOpaque(context).takeUnretainedValue()
        do {
            return try connection.open(uri, host: MongoConnection.text(host.pointee.host), port: Int(host.pointee.port))
        } catch {
            let failure = error as? AirSQLError ?? AirSQLError(.other, error.localizedDescription)
            connection.lock.locked { connection._routeError = failure }
            MongoConnection.set(error: failure.message, in: errorOut)
            return nil
        }
    }

    /// A stream to host:port as the driver asks for it: the route's socket for it, else TCP, and TLS on top when the
    /// connection string asks for TLS. Runs on the session's thread, inside the driver.
    private func open(_ uri: OpaquePointer, host: String, port: Int) throws -> UnsafeMutablePointer<mongoc_stream_t> {
        let timeout = Int64(mongoc_uri_get_option_as_int32(uri, MONGOC_URI_CONNECTTIMEOUTMS, 10_000))
        let expire = bson_get_monotonic_time() + timeout * 1000
        let base = try route.socket(host: host, port: port).map { try Self.unixStream($0, expire: expire) }
            ?? Self.tcpStream(host, port: port, expire: expire)
        guard mongoc_uri_get_tls(uri) else { return base }

        var options = mongoc_ssl_opt_get_default().pointee
        options.weak_cert_validation = true  // TLSCheck below checks instead (and no OCSP request leaves the route)
        guard let stream = mongoc_stream_tls_new_with_hostname(base, host, &options, 1) else {
            mongoc_stream_destroy(base)
            throw AirSQLError(.tls, "AirSQL couldn't set up TLS to \(host).")
        }
        var error = bson_error_t()
        guard mongoc_stream_tls_handshake_block(stream, host, Int32(timeout), &error) else {
            mongoc_stream_destroy(stream)
            throw AirSQLError(.tls, "The TLS handshake with \(host) failed.", details: Self.text(error.message))
        }
        let check = TLSCheck(host: host, options: tls)
        guard check.verify(Self.peerChain(stream)) else {
            mongoc_stream_destroy(stream)
            throw check.failure ?? AirSQLError(.tls, "AirSQL couldn't check the certificate of \(host).")
        }
        if let certificate = check.certificate { lock.locked { _certificates["\(host):\(port)"] = certificate } }
        return stream
    }

    private static func unixStream(_ path: String, expire: Int64) throws -> UnsafeMutablePointer<mongoc_stream_t> {
        guard let socket = mongoc_socket_new(AF_UNIX, SOCK_STREAM, 0), var address = Askpass.unixAddress(path) else {
            throw AirSQLError(.noRoute, "The route's socket \(path) can't be used.")
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                mongoc_socket_connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size), expire)
            }
        }
        guard connected == 0, let stream = mongoc_stream_socket_new(socket) else {
            mongoc_socket_destroy(socket)
            throw AirSQLError(.noRoute, "The route didn't take the connection.")
        }
        return stream
    }

    private static func tcpStream(_ host: String, port: Int, expire: Int64) throws -> UnsafeMutablePointer<mongoc_stream_t> {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &found) == 0 else {
            throw AirSQLError(.unknownHost, "The server's name \(host) isn't known.")
        }
        defer { freeaddrinfo(found) }
        var address = found
        while let current = address {
            if let socket = mongoc_socket_new(current.pointee.ai_family, SOCK_STREAM, 0) {
                if mongoc_socket_connect(socket, current.pointee.ai_addr, current.pointee.ai_addrlen, expire) == 0,
                   let stream = mongoc_stream_socket_new(socket) {
                    return stream
                }
                mongoc_socket_destroy(socket)
            }
            address = current.pointee.ai_next
        }
        throw AirSQLError(.refused, "Nothing answers at \(host):\(port).")
    }

    /// The certificates the server sent (DER), its own first.
    private static func peerChain(_ stream: UnsafeMutablePointer<mongoc_stream_t>) -> [Data] {
        var ders = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: 16), lengths = [Int32](repeating: 0, count: 16)
        let count = airsql_mongoc_peer_chain(stream, &ders, &lengths, 16)
        defer { ders.forEach { free($0) } }
        return (0..<max(0, Int(count))).map { Data(bytes: ders[$0]!, count: Int(lengths[$0])) }
    }

    // MARK: libbson

    /// A reply document the driver fills (bson_t wants 128-byte alignment), destroyed after `body`.
    private static func withReply<T>(_ body: (UnsafeMutablePointer<bson_t>) throws -> T) rethrows -> T {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<bson_t>.size,
                                                   alignment: max(128, MemoryLayout<bson_t>.alignment))
        let reply = raw.bindMemory(to: bson_t.self, capacity: 1)
        bson_init(reply)
        defer {
            bson_destroy(reply)
            raw.deallocate()
        }
        return try body(reply)
    }

    static func json(_ document: UnsafePointer<bson_t>) -> String {
        guard let text = bson_as_relaxed_extended_json(document, nil) else { return "{}" }
        defer { bson_free(text) }
        return String(cString: text)
    }

    /// shortcut: Foundation's JSON for the few small replies this file reads; the BSON lane's value type replaces it.
    static func object(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    static func failure(_ error: bson_error_t) -> AirSQLError {
        let message = text(error.message)
        if error.domain == MONGOC_ERROR_CLIENT.rawValue && error.code == MONGOC_ERROR_CLIENT_AUTHENTICATE.rawValue {
            return AirSQLError(.authFailed, "The server refused the login.", details: message, code: Int(error.code))
        }
        return AirSQLError(.other, message, code: Int(error.code))
    }

    /// A fixed-size C string field as a String.
    static func text<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }

    private static func set(error message: String, in error: UnsafeMutablePointer<bson_error_t>?) {
        guard let error else { return }
        error.pointee.domain = MONGOC_ERROR_STREAM.rawValue
        error.pointee.code = MONGOC_ERROR_STREAM_CONNECT.rawValue
        withUnsafeMutableBytes(of: &error.pointee.message) { buffer in
            let bytes = Array(message.utf8.prefix(buffer.count - 1)) + [0]
            buffer.copyBytes(from: bytes)
        }
    }
}
