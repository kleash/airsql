import AirSQLCore
import AppKit

/// A connected MongoDB connection as the windows share it (mongo-plan.md, decision 4): `AppModel.openMongo[id]`, beside
/// `AppModel.open` for MySQL. Its sessions (`connection.session(.data)`, …) share the route under them.
@MainActor
final class OpenMongoConnection {
    let saved: SavedConnection
    let connection: MongoConnection
    /// What the server said it is at connect: version, replica set, primary.
    let server: MongoServerInfo

    init(saved: SavedConnection, connection: MongoConnection, server: MongoServerInfo) {
        self.saved = saved
        self.connection = connection
        self.server = server
    }

    /// The tree's databases with their size on disk (listDatabases), nil until read.
    private(set) var databases: [(name: String, size: Int64?)]?
    /// Each opened database's collections, views and time-series, and its dbStats.
    private(set) var collections: [String: [MongoCollectionInfo]] = [:]
    private(set) var stats: [String: BSONDocument] = [:]
    /// Each opened collection's indexes, by "database.collection".
    private(set) var indexes: [String: [BSONDocument]] = [:]
    /// What went wrong reading the tree, by what was read ("" for the databases).
    private(set) var loadErrors: [String: String] = [:]
    /// What is being read now, by the same keys.
    private(set) var loading: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    /// The connector's keep-alive (`Connector.watch`), stopped by `close`.
    var keepAlive: Timer?

    /// Closes the sessions, then the route.
    func close() {
        keepAlive?.invalidate()
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        let connection = self.connection
        Task.detached { await connection.close() }
    }

    // MARK: The tree, read on the main session as it opens (mongo-plan, Tree): no stats for every collection at load

    /// The databases (again): the person's first, then MongoDB's own (admin, local, config).
    func load() {
        read("") { session in try await session.listDatabases() } done: { [weak self] found in
            let all = found.compactMap { info -> (name: String, size: Int64?)? in
                guard case .string(let name)? = info["name"] else { return nil }
                return (name, info["sizeOnDisk"]?.integer)
            }
            let (own, theirs) = (all.filter { !Self.isInternal($0.name) }, all.filter { Self.isInternal($0.name) })
            self?.databases = own + theirs
        }
    }

    /// admin, local and config: MongoDB's own, which the tree lists last and quieter.
    static func isInternal(_ database: String) -> Bool { MongoAgentGuard.internalDatabases.contains(database.lowercased()) }

    /// A database's collections and its sizes (dbStats), the first time it opens or again.
    func loadDatabase(_ name: String, again: Bool = false) {
        guard again || collections[name] == nil, !loading.contains(name) || again else { return }
        read(name) { session in
            (try await session.listCollections(database: name), try? await session.databaseStats(database: name))
        } done: { [weak self] found in
            // system.* (views, profile, buckets, js…) are the server's own, left out as Compass does.
            self?.collections[name] = found.0.filter { !$0.name.hasPrefix("system.") }
            self?.stats[name] = found.1
        }
    }

    /// A collection's indexes, the first time it opens or again.
    func loadIndexes(_ database: String, _ collection: String, again: Bool = false) {
        let key = database + "." + collection
        guard again || indexes[key] == nil, !loading.contains(key) || again else { return }
        read(key) { session in try await session.listIndexes(database: database, collection: collection) } done: { [weak self] found in
            self?.indexes[key] = found
        }
    }

    /// Forgets what was read under a database (nil: everything) and reads it again.
    func refresh(_ database: String? = nil) {
        connection.samples.invalidate(database: database)
        if let database {
            indexes = indexes.filter { !$0.key.hasPrefix(database + ".") }
            loadDatabase(database, again: true)
        } else {
            (collections, stats, indexes) = ([:], [:], [:])
            load()
        }
    }

    var isLoading: Bool { !loading.isEmpty }

    private func read<T>(_ key: String, _ work: @escaping (MongoSession) async throws -> T, done: @escaping (T) -> Void) {
        tasks[key]?.cancel()
        loading.insert(key)
        changed()
        let connection = self.connection
        tasks[key] = Task { [weak self] in
            let result: Result<T, Error>
            do { result = .success(try await work(connection.session(.main))) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let value):
                loadErrors[key] = nil
                done(value)
            case .failure(let error):
                loadErrors[key] = error.localizedDescription
            }
            loading.remove(key)
            tasks[key] = nil
            changed()
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: .openConnectionDidChange, object: self)
    }
}

extension Connector {
    /// Logs in to the MongoDB server or replica set of `saved` through its route (`MongoRoute`: a forward or relay per
    /// member), for Connect and Test Connection: asks for the password when the server refuses the one it has, and pins
    /// a certificate the person trusts (saved with the connection), once per connect: a replica set's members each
    /// show their own, which a pin can't cover (the CA file can).
    func logInMongo(_ saved: inout SavedConnection, password typed: String?, sessionToken: String?, proxyPassword: String,
                    askpass: AskpassServer?, on window: NSWindow?) async throws -> (MongoConnection, MongoServerInfo) {
        let route = MongoRoute(saved, proxyPassword: proxyPassword, askpass: askpass)
        let connection = MongoConnection(uri: saved.mongoURI.string, user: saved.user.isEmpty ? nil : saved.user,
                                         tls: saved.tls, route: route, name: saved.displayName)
        var trusted = false
        do {
            // An X.509 login has no password: the client certificate logs in.
            if saved.mongoX509 {
                connection.password = nil
            } else if let typed {
                connection.password = typed
            } else {
                connection.password = try await databasePassword(&saved, on: window, retry: false)
            }
            connection.user = saved.user.isEmpty ? nil : saved.user
            if saved.mongoAWS {
                connection.awsSessionToken = sessionToken
                if sessionToken == nil { connection.awsSessionToken = await secret(saved.awsSessionTokenKey) }
            }
            while true {
                do {
                    let server = try await withTaskCancellationHandler { try await connection.connect() } onCancel: { route.close() }
                    return (connection, server)
                } catch let error as AirSQLError {
                    try Task.checkCancellation()
                    switch error.kind {
                    case .untrustedCertificate(let certificate), .certificateChanged(let certificate):
                        guard !trusted else {
                            throw AirSQLError(.tls, "The servers of this connection show different certificates, so trusting "
                                + "one isn't enough. Choose the file of the authority that signed them in the TLS tab.")
                        }
                        var changed = false
                        if case .certificateChanged = error.kind { changed = true }
                        guard let window, await askTrust(certificate, server: saved, changed: changed, on: window) else {
                            throw AirSQLError(.cancelled, "Not trusted.")
                        }
                        trusted = true
                        saved.tls.pinnedFingerprint = certificate.fingerprint
                        connection.tls = saved.tls
                        if var stored = model.connection(saved.id) {
                            stored.tls.pinnedFingerprint = certificate.fingerprint
                            model.save(stored)
                        }
                    case .authFailed where !saved.mongoX509:
                        connection.password = try await databasePassword(&saved, on: window, retry: true)
                        connection.user = saved.user.isEmpty ? nil : saved.user
                    default:
                        throw error
                    }
                }
            }
        } catch {
            await connection.close()
            throw error
        }
    }
}
