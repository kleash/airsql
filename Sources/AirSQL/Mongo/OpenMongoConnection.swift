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

    /// Closes the sessions, then the route.
    func close() {
        let connection = self.connection
        Task.detached { await connection.close() }
    }
}

extension Connector {
    /// Logs in to the MongoDB server or replica set of `saved` through its route (`MongoRoute`: a forward or relay per
    /// member), for Connect and Test Connection: asks for the password when the server refuses the one it has, and pins
    /// a certificate the person trusts (saved with the connection), once per connect: a replica set's members each
    /// show their own, which a pin can't cover (the CA file can).
    func logInMongo(_ saved: inout SavedConnection, password typed: String?, proxyPassword: String, askpass: AskpassServer?,
                    on window: NSWindow?) async throws -> (MongoConnection, MongoServerInfo) {
        let route = MongoRoute(saved, proxyPassword: proxyPassword, askpass: askpass)
        let connection = MongoConnection(uri: saved.mongoURI.string, user: saved.user.isEmpty ? nil : saved.user,
                                         tls: saved.tls, route: route, name: saved.displayName)
        var trusted = false
        do {
            if let typed { connection.password = typed } else { connection.password = try await databasePassword(&saved, on: window, retry: false) }
            connection.user = saved.user.isEmpty ? nil : saved.user
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
                    case .authFailed:
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
