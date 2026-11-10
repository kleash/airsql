import AirSQLCore
import AppKit

/// A connected MongoDB connection as the windows share it (mongo-plan.md, decision 4): `AppModel.openMongo[id]`, beside
/// `AppModel.open` for MySQL. For now only what was saved and the route under it; the driver's client comes with it.
@MainActor
final class OpenMongoConnection {
    let saved: SavedConnection
    /// Its private socket (nil for Direct) is where the driver connects.
    let route: OpenRoute

    init(saved: SavedConnection, route: OpenRoute) {
        self.saved = saved
        self.route = route
    }

    func close() { route.close() }
}

extension Connector {
    /// Logs in to the MongoDB server at the end of `route` (`establish`, so Connect and Test Connection), never MySQL.
    /// shortcut: always fails until the MongoDB driver lands (lane M1), which returns an `OpenMongoConnection` for
    /// `AppModel.attach(mongo:)` instead.
    func logInMongo(_ saved: SavedConnection, route: OpenRoute) async throws -> Never {
        throw AirSQLError(.other, "MongoDB support is being built: AirSQL can't log in to a MongoDB server yet.")
    }
}
