import Foundation

extension MongoSession {
    /// Runs one of `MongoAdmin`'s commands (create, drop, rename, collMod): its names were checked when it was made.
    public func run(_ admin: MongoAdminCommand) async throws {
        // A rename names two collections, a dropDatabase all of one: rare enough to forget every sample.
        defer { connection.samples.invalidate() }
        _ = try await command(admin.command, database: admin.database)
    }

    /// How many documents of the collection `validator` would refuse.
    public func countFailing(database: String, collection: String, validator: BSONDocument) async throws -> Int64 {
        try await count(database: database, collection: collection, filter: MongoAdmin.failing(validator))
    }
}
