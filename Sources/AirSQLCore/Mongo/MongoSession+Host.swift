import Foundation

/// The host page's and Disk Usage's commands (mongo-plan, Phase 2 "host"): each read with a time limit, as the page
/// polls them, over a route too, and must never queue behind a slow one.
extension MongoSession {
    /// How long a host page's read may take on the server.
    static let hostTimeLimit = 3_000

    /// serverStatus: the server's version, uptime, connections, counters, memory and network.
    public func serverStatus() async throws -> BSONDocument {
        try await command(BSONDocument([("serverStatus", .int32(1)), ("maxTimeMS", .int64(Int64(Self.hostTimeLimit)))]), database: "admin")
    }

    /// replSetGetStatus: the replica set's members with their states, optimes and pings. A standalone refuses it (76).
    public func replicaSetStatus() async throws -> BSONDocument {
        try await command(BSONDocument([("replSetGetStatus", .int32(1)), ("maxTimeMS", .int64(Int64(Self.hostTimeLimit)))]), database: "admin")
    }

    /// The operations running on the server this session reads from (the primary): this login's own (`$ownOps`, which
    /// needs no privilege), or everyone's (`all`, which needs `inprog`). The listing's own currentOp is left out.
    public func currentOperations(all: Bool) async throws -> [BSONDocument] {
        let reply = try await command(BSONDocument([
            ("currentOp", .int32(1)), ("$ownOps", .bool(!all)),
            ("command.currentOp", .document(BSONDocument([("$exists", .bool(false))]))),
            ("maxTimeMS", .int64(Int64(Self.hostTimeLimit))),
        ]), database: "admin")
        guard case .array(let ops)? = reply["inprog"] else { return [] }
        return ops.compactMap { if case .document(let op) = $0 { return op } else { return nil } }
    }

    /// Ends the operation `opid` (as currentOp gave it) at its next chance; one that has finished is no error.
    public func killOperation(_ opid: BSONValue) async throws {
        _ = try await command(BSONDocument([("killOp", .int32(1)), ("op", opid)]), database: "admin")
    }

    /// dbStats with the free space kept for reuse (`freeStorage`), for Disk Usage.
    public func storageStats(database: String) async throws -> BSONDocument {
        try await command(BSONDocument([("dbStats", .int32(1)), ("freeStorage", .int32(1))]), database: database)
    }
}
