import CMongoC
import Darwin
import Foundation

/// One session with a MongoDB server or replica set: a single-threaded `mongoc_client_t` whose calls run in order on
/// the session's own thread (`Worker`, as `DBConnection`), never on the main thread. Every command is logged first
/// (`MongoLog`), sent to a server chosen here (its id given to the driver) and tagged with a `comment`, so that
/// `cancel` can find it on that member with `currentOp` and end it with `killOp` from a side session. Replies stay
/// BSON (`BSONDocument`) from the wire on. The driver retries a read or a write once after a network error; a write
/// that still fails that way says its outcome is unknown (`.outcomeUnknown`), never sent again by AirSQL.
public final class MongoSession: @unchecked Sendable {
    /// The session's job, as `DBConnection.Role`: main (the tree, listings, sizes, explain), data (a collection tab's
    /// pages, Apply and its transaction), agent (agents' read-only tools), cancel (Cancel's side session).
    public enum Role: String, Sendable {
        case main, data, agent, cancel
    }

    public let role: Role
    let connection: MongoConnection
    private let uri: String
    private let worker: Worker
    /// Tags this session's commands apart from every other's: "airsql:main:1a2b3c4d:12".
    private let tagPrefix: String
    private let lock = NSLock()
    private var routeError: AirSQLError?
    /// The command on the wire: its tag and its server, for `cancel`.
    private var running: (tag: String, server: String)?
    private var _inTransaction = false
    // On the session's thread only:
    private var client: OpaquePointer?
    private var transaction: OpaquePointer?
    private var number = 0
    /// Cursors not destroyed yet: `close` destroys them before their client, as the driver requires.
    private var cursors: Set<OpaquePointer> = []

    private static let setUp: Void = {
        mongoc_init()
        // The driver's own log goes nowhere: what matters reaches AirSQL as errors.
        mongoc_log_set_handler(nil, nil)
    }()

    init(connection: MongoConnection, role: Role, uri: String) {
        _ = Self.setUp
        self.connection = connection
        self.role = role
        self.uri = uri
        worker = Worker(name: "AirSQL MongoDB \(role.rawValue) session")
        tagPrefix = "airsql:\(role.rawValue):" + UUID().uuidString.prefix(8).lowercased()
    }

    deinit {
        let (client, transaction) = (self.client, self.transaction)
        worker.submit {
            if let transaction { mongoc_client_session_destroy(transaction) }
            if let client { mongoc_client_destroy(client) }
        }
        worker.stop()
    }

    /// Whether a transaction is open (`startTransaction`).
    public var inTransaction: Bool { lock.locked { _inTransaction } }

    /// Makes the client (a mongodb+srv name is looked up here, on this Mac) and pings the server it selects.
    func open() async throws {
        try await worker.perform { [self] in
            guard client == nil else { return }
            let route = connection.route
            if role == .main && route.findsMembersFirst {
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
            _ = try commandHere(BSONDocument([("ping", .int32(1))]), database: "admin")
        }
    }

    private func makeClient() throws -> OpaquePointer {
        var error = bson_error_t()
        // The login goes into the string, which the driver checks authMechanism against as it reads it; the string
        // stays in memory (the driver's log is off), and `uri` and the command log keep none of it.
        var text = uri
        if let user = connection.user, let scheme = text.range(of: "://") {
            let login = [user] + (connection.password.map { [$0] } ?? [])
            text.insert(contentsOf: login.map(MongoURI.encode).joined(separator: ":") + "@", at: scheme.upperBound)
        }
        guard let parsed = mongoc_uri_new_with_error(text, &error) else { throw MongoErrorMapping.map(error) }
        defer { mongoc_uri_destroy(parsed) }
        mongoc_uri_set_appname(parsed, "AirSQL")
        guard let made = mongoc_client_new_from_uri_with_error(parsed, &error) else { throw MongoErrorMapping.map(error) }
        mongoc_client_set_error_api(made, Int32(MONGOC_ERROR_API_VERSION_2))
        mongoc_client_set_stream_initiator(made, Self.initiator, Unmanaged.passUnretained(self).toOpaque())
        var seeds: [(host: String, port: Int)] = []
        var host = mongoc_uri_get_hosts(mongoc_client_get_uri(made))
        while let current = host {
            seeds.append((Self.text(current.pointee.host), Int(current.pointee.port)))
            host = UnsafePointer(current.pointee.next)
        }
        if role != .cancel { connection.route.seed(seeds) }
        return made
    }

    /// Ends the command running now, if any: `killOp` on the member running it, from a side session of its own. The
    /// command then fails as cancelled.
    public func cancel() async {
        guard let running = lock.locked({ running }), let uri = try? connection.direct(to: running.server) else { return }
        let side = MongoSession(connection: connection, role: .cancel, uri: uri)
        do {
            try await side.open()
            _ = try await side.killOperations(tagged: running.tag)
        } catch {
            connection.log.write("-- cancel failed: \(error.localizedDescription)", context: connection.name + " cancel")
        }
        await side.close()
    }

    /// Ends the operations tagged `tag` on this session's server (a cancel session's single member): `currentOp`
    /// finds them, a getMore by the command it continues; `killOp` ends each. How many it ended.
    func killOperations(tagged tag: String) async throws -> Int {
        let filter: BSONValue = .array([.document(BSONDocument([("command.comment", .string(tag))])),
                                        .document(BSONDocument([("cursor.originatingCommand.comment", .string(tag))]))])
        // $ownOps: a login without the inprog privilege (a read-only one) may still list and end its own operations.
        let reply = try await command(BSONDocument([("currentOp", .int32(1)), ("$all", .bool(true)), ("$ownOps", .bool(true)),
                                                    ("$or", filter)]),
                                      database: "admin")
        guard case .array(let ops)? = reply["inprog"] else { return 0 }
        var ended = 0
        for case .document(let op) in ops {
            guard let id = op["opid"] else { continue }
            _ = try await command(BSONDocument([("killOp", .int32(1)), ("op", id)]), database: "admin")
            ended += 1
        }
        return ended
    }

    /// Destroys the client (its sockets) and an open transaction, which the server then aborts.
    public func close() async {
        try? await worker.perform { [self] in
            cursors.forEach { mongoc_cursor_destroy($0) }
            cursors = []
            if let transaction { mongoc_client_session_destroy(transaction) }
            if let client { mongoc_client_destroy(client) }
            transaction = nil
            client = nil
        }
        lock.locked { _inTransaction = false }
    }

    // MARK: Commands

    /// Runs `command` on `database` and returns the reply. Internal: agents and the UI get the typed methods only.
    /// `reading`: a read, sent where the connection string's readPreference says.
    func command(_ command: BSONDocument, database: String, reading: Bool = false) async throws -> BSONDocument {
        try await worker.perform { [self] in try commandHere(command, database: database, reading: reading) }
    }

    private func commandHere(_ command: BSONDocument, database: String, reading: Bool = false,
                             logged: Bool = true) throws -> BSONDocument {
        try withCommand(command, database: database, reading: reading, logged: logged) { reply, _, _ in try BSONDocument(bson: reply) }
    }

    /// The keep-alive: `hello`, left out of the command log, which it would fill once a minute.
    public func ping() async throws {
        _ = try await worker.perform { [self] in try commandHere(BSONDocument([("hello", .int32(1))]), database: "admin", logged: false) }
    }

    /// On the session's thread: tags `command` (a read's or a command's), logs it, sends it to the server chosen here,
    /// and gives `body` the reply, that server and the tag. A read goes where the connection string's readPreference
    /// says, except in a transaction (the primary).
    private func withCommand<T>(_ command: BSONDocument, database: String, reading: Bool = false, logged: Bool = true,
                                _ body: (UnsafeMutablePointer<bson_t>, Server, String) throws -> T) throws -> T {
        let client = try current()
        var command = command
        let tag = nextTag()
        if command["comment"] == nil { command.fields.append(("comment", .string(tag))) }
        let preference = reading && transaction == nil ? mongoc_client_get_read_prefs(client) : nil
        let server = try select(client, forWrites: false, preference: preference)
        let sent = try command.bson()
        let options = try self.options(server: server.id)
        defer { [sent, options].forEach { bson_destroy($0) } }
        if logged { log(command, database: database) }
        return try Self.withReply { reply in
            var error = bson_error_t()
            try sending(tag, server: server.name) {
                let done = preference.map { mongoc_client_read_command_with_opts(client, database, sent, $0, options, reply, &error) }
                    ?? mongoc_client_read_write_command_with_opts(client, database, sent, nil, options, reply, &error)
                guard done else {
                    throw lock.locked { routeError } ?? MongoErrorMapping.map(error, reply: reply)
                }
            }
            return try body(reply, server, tag)
        }
    }

    /// A command that answers with a cursor (find, aggregate, listCollections, listIndexes): its first batch and the
    /// rest through getMore.
    func cursor(_ command: BSONDocument, database: String) async throws -> MongoCursor {
        try await worker.perform { [self] in
            try withCommand(command, database: database, reading: true) { reply, server, tag in
                let options = try self.options(server: server.id)
                defer { bson_destroy(options) }
                // It takes the copy and destroys it.
                guard let made = mongoc_cursor_new_from_command_reply_with_opts(client, bson_copy(reply), options) else {
                    throw AirSQLError(.other, "The server's reply had no cursor.")
                }
                cursors.insert(made)
                return MongoCursor(session: self, cursor: made, tag: tag, secondary: server.secondary ? server.name : nil)
            }
        }
    }

    /// The opts every command gets: the server chosen, and the open transaction's session.
    private func options(server: UInt32) throws -> UnsafeMutablePointer<bson_t> {
        let options = bson_new()!
        var error = bson_error_t()
        bson_append_int32(options, "serverId", -1, Int32(server))
        if let transaction, !mongoc_client_session_append(transaction, options, &error) {
            bson_destroy(options)
            throw MongoErrorMapping.map(error)
        }
        return options
    }

    /// Marks `tag` as on the wire at `server` while `body` runs: what `cancel` ends.
    private func sending<T>(_ tag: String, server: String, _ body: () throws -> T) rethrows -> T {
        lock.locked {
            routeError = nil
            running = (tag, server)
        }
        defer { lock.locked { running = nil } }
        return try body()
    }

    private func nextTag() -> String {
        number += 1
        return "\(tagPrefix):\(number)"
    }

    private func log(_ command: BSONDocument, database: String) {
        connection.log.write("\(database): " + MongoLog.line(command), context: "\(connection.name) \(role.rawValue):\(number)")
    }

    /// A server chosen for a command: its id, "host:port", and whether it is a replica set's secondary.
    typealias Server = (id: UInt32, name: String, secondary: Bool)

    /// The primary, or the member `preference` (a read preference) chooses.
    private func select(_ client: OpaquePointer, forWrites: Bool, preference: OpaquePointer? = nil) throws -> Server {
        var error = bson_error_t()
        lock.locked { routeError = nil }
        guard let server = mongoc_client_select_server(client, forWrites, preference, &error) else {
            throw lock.locked { routeError } ?? MongoErrorMapping.map(error)
        }
        defer { mongoc_server_description_destroy(server) }
        return (mongoc_server_description_id(server), Self.text(mongoc_server_description_host(server)!.pointee.host_and_port),
                String(cString: mongoc_server_description_type(server)) == "RSSecondary")
    }

    private func current() throws -> OpaquePointer {
        guard let client else { throw AirSQLError.disconnected }
        return client
    }

    // MARK: Reads

    /// Finds documents: a cursor over them, read by `MongoCursor.next`.
    public func find(database: String, collection: String, _ query: MongoFind = MongoFind()) async throws -> MongoCursor {
        try await cursor(query.command(collection: collection), database: database)
    }

    /// Runs an aggregation pipeline: a cursor over what it gives.
    public func aggregate(database: String, collection: String, pipeline: [BSONDocument], maxTimeMS: Int? = nil,
                          collation: BSONDocument? = nil, hint: BSONValue? = nil) async throws -> MongoCursor {
        try await cursor(Self.aggregateCommand(collection: collection, pipeline: pipeline, maxTimeMS: maxTimeMS,
                                               collation: collation, hint: hint), database: database)
    }

    /// How many documents match `filter` (countDocuments: an aggregation, so it runs in a transaction too).
    public func count(database: String, collection: String, filter: BSONDocument = BSONDocument(),
                      maxTimeMS: Int? = nil) async throws -> Int64 {
        let pipeline = [BSONDocument([("$match", .document(filter))]),
                        BSONDocument([("$group", .document(BSONDocument([("_id", .int32(1)), ("n", .document(BSONDocument([("$sum", .int32(1))])))])))])]
        let found = try await all(aggregate(database: database, collection: collection, pipeline: pipeline, maxTimeMS: maxTimeMS))
        return found.first?["n"]?.integer ?? 0
    }

    /// The collection's document count from its metadata: fast, and maybe a little off after an unclean shutdown.
    public func estimatedCount(database: String, collection: String) async throws -> Int64 {
        try await command(BSONDocument([("count", .string(collection))]), database: database, reading: true)["n"]?.integer ?? 0
    }

    /// The distinct values of `key` (a dotted path) among the documents matching `filter`.
    public func distinct(database: String, collection: String, key: String, filter: BSONDocument = BSONDocument(),
                         maxTimeMS: Int? = nil) async throws -> [BSONValue] {
        var fields: [(key: String, value: BSONValue)] = [("distinct", .string(collection)), ("key", .string(key)),
                                                         ("query", .document(filter))]
        if let maxTimeMS { fields.append(("maxTimeMS", .int64(Int64(maxTimeMS)))) }
        guard case .array(let values)? = try await command(BSONDocument(fields), database: database, reading: true)["values"] else {
            return []
        }
        return values
    }

    /// The databases: each with name, sizeOnDisk and empty.
    public func listDatabases() async throws -> [BSONDocument] {
        let reply = try await command(BSONDocument([("listDatabases", .int32(1))]), database: "admin")
        guard case .array(let databases)? = reply["databases"] else { return [] }
        return databases.compactMap { if case .document(let database) = $0 { return database } else { return nil } }
    }

    /// The collections and views of a database, by name.
    public func listCollections(database: String) async throws -> [MongoCollectionInfo] {
        try await all(cursor(BSONDocument([("listCollections", .int32(1))]), database: database)).compactMap { info in
            guard case .string(let name)? = info["name"] else { return nil }
            let kind: MongoCollectionInfo.Kind
            switch info["type"] {
            case .string("view")?: kind = .view
            case .string("timeseries")?: kind = .timeseries
            default: kind = .collection
            }
            guard case .document(let options)? = info["options"] else { return MongoCollectionInfo(name: name, kind: kind) }
            return MongoCollectionInfo(name: name, kind: kind, options: options)
        }.sorted { $0.name < $1.name }
    }

    /// The collection's indexes as the server describes them (v, key, name, and their options).
    public func listIndexes(database: String, collection: String) async throws -> [BSONDocument] {
        try await all(cursor(BSONDocument([("listIndexes", .string(collection))]), database: database))
    }

    /// `$collStats`' storageStats: sizes, counts and each index's size.
    public func collectionStats(database: String, collection: String) async throws -> BSONDocument {
        let stage = BSONDocument([("$collStats", .document(BSONDocument([("storageStats", .document(BSONDocument()))])))])
        let found = try await all(aggregate(database: database, collection: collection, pipeline: [stage]))
        guard case .document(let stats)? = found.first?["storageStats"] else { return BSONDocument() }
        return stats
    }

    /// dbStats: the database's sizes and counts.
    public func databaseStats(database: String) async throws -> BSONDocument {
        try await command(BSONDocument([("dbStats", .int32(1))]), database: database)
    }

    /// The plan of a find with executionStats: the query runs to measure it (nothing is changed).
    public func explain(database: String, collection: String, _ query: MongoFind) async throws -> BSONDocument {
        try await explain(query.command(collection: collection), database: database)
    }

    /// The plan of an aggregation with executionStats: the pipeline runs to measure it, without its $out or $merge.
    public func explain(database: String, collection: String, pipeline: [BSONDocument], maxTimeMS: Int? = nil,
                        collation: BSONDocument? = nil) async throws -> BSONDocument {
        try await explain(Self.aggregateCommand(collection: collection, pipeline: pipeline, maxTimeMS: maxTimeMS, collation: collation),
                          database: database)
    }

    func explain(_ inner: BSONDocument, database: String) async throws -> BSONDocument {
        try await command(BSONDocument([("explain", .document(inner)), ("verbosity", .string("executionStats"))]), database: database)
    }

    func all(_ cursor: MongoCursor) async throws -> [BSONDocument] {
        var found: [BSONDocument] = []
        while !cursor.isExhausted {
            found += try await cursor.next(maxCount: 1000).map { try BSONDocument(bytes: $0) }
        }
        await cursor.close()
        return found
    }

    static func aggregateCommand(collection: String, pipeline: [BSONDocument], maxTimeMS: Int? = nil,
                                 collation: BSONDocument? = nil, hint: BSONValue? = nil) -> BSONDocument {
        var fields: [(key: String, value: BSONValue)] = [("aggregate", .string(collection)),
                                                         ("pipeline", .array(pipeline.map { .document($0) })),
                                                         ("cursor", .document(BSONDocument()))]
        if let maxTimeMS { fields.append(("maxTimeMS", .int64(Int64(maxTimeMS)))) }
        if let collation { fields.append(("collation", .document(collation))) }
        if let hint { fields.append(("hint", hint)) }
        return BSONDocument(fields)
    }

    // MARK: Writes

    /// Inserts one document.
    public func insertOne(database: String, collection: String, _ document: BSONDocument) async throws {
        _ = try await insertMany(database: database, collection: collection, [document])
    }

    /// Inserts documents in order, stopping at the first that fails; how many went in.
    public func insertMany(database: String, collection: String, _ documents: [BSONDocument]) async throws -> Int64 {
        let logged = BSONDocument([("insert", .string(collection)), ("documents", .array(documents.map { .document($0) }))])
        return try await write(logged, database: database, collection: collection, count: "insertedCount") { target, options, reply, error in
            let made = try documents.map { try $0.bson() }
            defer { made.forEach { bson_destroy($0) } }
            var pointers = made.map { UnsafePointer($0) as UnsafePointer<bson_t>? }
            return mongoc_collection_insert_many(target, &pointers, made.count, options, reply, error)
        }
    }

    /// An import's insert: `ordered` stops at the first document the server refuses, unordered tries every one. How many
    /// went in, and each refused document's index in `documents` with why; anything else (a lost connection) throws.
    public func insertMany(database: String, collection: String, _ documents: [BSONDocument],
                           ordered: Bool) async throws -> (inserted: Int64, refused: [(index: Int, error: AirSQLError)]) {
        let logged = BSONDocument([("insert", .string(collection)), ("documents", .array(documents.map { .document($0) })),
                                   ("ordered", .bool(ordered))])
        var refused: [(index: Int, error: AirSQLError)] = []
        let inserted = try await write(logged, database: database, collection: collection, count: "insertedCount") { target, options, reply, error in
            let made = try documents.map { try $0.bson() }
            defer { made.forEach { bson_destroy($0) } }
            var pointers = made.map { UnsafePointer($0) as UnsafePointer<bson_t>? }
            bson_append_bool(options, "ordered", -1, ordered)
            if mongoc_collection_insert_many(target, &pointers, made.count, options, reply, error) { return true }
            // Write errors come with the reply's insertedCount: counted here, not thrown. A write concern error isn't one.
            guard case .array(let errors)? = (try? BSONDocument(bson: reply))?["writeErrors"], !errors.isEmpty else { return false }
            refused = errors.compactMap { entry in
                guard case .document(let e) = entry, let index = e["index"]?.integer, let code = e["code"]?.integer else { return nil }
                let message: String
                if case .string(let text)? = e["errmsg"] { message = text } else { message = "" }
                return (Int(index), MongoErrorMapping.map(domain: MONGOC_ERROR_SERVER.rawValue, code: UInt32(truncatingIfNeeded: code),
                                                          message: message))
            }
            return true
        }
        return (inserted, refused)
    }

    /// Changes the one document `filter` matches (Apply's filter names its _id and old values) with `update`'s
    /// operators; matched and modified counts, which Apply checks.
    public func updateOne(database: String, collection: String, filter: BSONDocument, update: BSONDocument,
                          collation: BSONDocument? = nil) async throws -> (matched: Int64, modified: Int64) {
        var statement: [(key: String, value: BSONValue)] = [("q", .document(filter)), ("u", .document(update))]
        if let collation { statement.append(("collation", .document(collation))) }
        let logged = BSONDocument([("update", .string(collection)), ("updates", .array([.document(BSONDocument(statement))]))])
        var modified: Int64 = 0
        let matched = try await write(logged, database: database, collection: collection, count: "matchedCount",
                                      collation: collation) { target, options, reply, error in
            let (selector, change) = (try filter.bson(), try update.bson())
            defer { [selector, change].forEach { bson_destroy($0) } }
            let ok = mongoc_collection_update_one(target, selector, change, options, reply, error)
            if ok { modified = (try? BSONDocument(bson: reply))?["modifiedCount"]?.integer ?? 0 }
            return ok
        }
        return (matched, modified)
    }

    /// Deletes the one document `filter` matches; how many went (0 or 1).
    public func deleteOne(database: String, collection: String, filter: BSONDocument,
                          collation: BSONDocument? = nil) async throws -> Int64 {
        var statement: [(key: String, value: BSONValue)] = [("q", .document(filter)), ("limit", .int32(1))]
        if let collation { statement.append(("collation", .document(collation))) }
        let logged = BSONDocument([("delete", .string(collection)), ("deletes", .array([.document(BSONDocument(statement))]))])
        return try await write(logged, database: database, collection: collection, count: "deletedCount",
                               collation: collation) { target, options, reply, error in
            let selector = try filter.bson()
            defer { bson_destroy(selector) }
            return mongoc_collection_delete_one(target, selector, options, reply, error)
        }
    }

    /// Creates an index on `keys` ({field: 1}); `options` such as name, unique, partialFilterExpression.
    public func createIndex(database: String, collection: String, keys: BSONDocument,
                            options: BSONDocument = BSONDocument()) async throws {
        _ = try await command(MongoIndex.createCommand(collection: collection, keys: keys, options: options), database: database)
    }

    public func dropIndex(database: String, collection: String, name: String) async throws {
        _ = try await command(MongoIndex.dropCommand(collection: collection, name: name), database: database)
    }

    /// A write through the driver's collection helpers, which retry once after a network error (retryable writes) and
    /// turn write errors into errors; logged as the command it sends. The reply's `count`.
    func write(_ logged: BSONDocument, database: String, collection: String, count: String,
                       collation: BSONDocument? = nil,
                       _ body: @escaping (OpaquePointer, UnsafeMutablePointer<bson_t>, UnsafeMutablePointer<bson_t>,
                                          UnsafeMutablePointer<bson_error_t>) throws -> Bool) async throws -> Int64 {
        try await worker.perform { [self] in
            let client = try current()
            let tag = nextTag()
            let server = try select(client, forWrites: true)
            guard let target = mongoc_client_get_collection(client, database, collection) else { throw AirSQLError.disconnected }
            defer { mongoc_collection_destroy(target) }
            let options = bson_new()!
            defer { bson_destroy(options) }
            var error = bson_error_t()
            bson_append_utf8(options, "comment", -1, tag, -1)
            if let collation {
                let made = try collation.bson()
                defer { bson_destroy(made) }
                bson_append_document(options, "collation", -1, made)
            }
            if let transaction, !mongoc_client_session_append(transaction, options, &error) { throw MongoErrorMapping.map(error) }
            log(BSONDocument(logged.fields + [("comment", .string(tag))]), database: database)
            return try Self.withReply { reply in
                try sending(tag, server: server.name) {
                    guard try body(target, options, reply, &error) else {
                        throw lock.locked { routeError } ?? MongoErrorMapping.map(error, reply: reply, write: true)
                    }
                }
                return try BSONDocument(bson: reply)[count]?.integer ?? 0
            }
        }
    }

    // MARK: Transactions

    /// Starts a transaction (replica sets only): what this session runs until commit or abort is part of it.
    public func startTransaction() async throws {
        try await worker.perform { [self] in
            let client = try current()
            guard transaction == nil else { throw AirSQLError(.other, "A transaction is already open in this session.") }
            var error = bson_error_t()
            guard let started = mongoc_client_start_session(client, nil, &error) else { throw MongoErrorMapping.map(error) }
            guard mongoc_client_session_start_transaction(started, nil, &error) else {
                mongoc_client_session_destroy(started)
                throw MongoErrorMapping.map(error)
            }
            transaction = started
            lock.locked { _inTransaction = true }
            connection.log.write("-- start transaction", context: "\(connection.name) \(role.rawValue)")
        }
    }

    /// Commits the open transaction. An unknown result (the connection failed during the commit) says so.
    public func commitTransaction() async throws {
        try await endTransaction(commit: true)
    }

    /// Aborts the open transaction (nothing open: nothing to do).
    public func abortTransaction() async throws {
        try await endTransaction(commit: false)
    }

    private func endTransaction(commit: Bool) async throws {
        try await worker.perform { [self] in
            guard let open = transaction else {
                if commit { throw AirSQLError(.other, "No transaction is open in this session.") }
                return
            }
            defer {
                mongoc_client_session_destroy(open)
                transaction = nil
                lock.locked { _inTransaction = false }
            }
            connection.log.write("-- \(commit ? "commit" : "abort") transaction", context: "\(connection.name) \(role.rawValue)")
            var error = bson_error_t()
            if commit {
                try Self.withReply { reply in
                    guard mongoc_client_session_commit_transaction(open, reply, &error) else {
                        throw MongoErrorMapping.map(error, reply: reply, write: true)
                    }
                }
            } else if !mongoc_client_session_abort_transaction(open, &error) {
                throw MongoErrorMapping.map(error)
            }
        }
    }

    // MARK: Cursors

    /// The next documents of `cursor` (raw BSON), at most `maxCount` and about `maxBytes` (at least one).
    fileprivate func next(_ cursor: MongoCursor, maxCount: Int, maxBytes: Int) async throws -> [[UInt8]] {
        try await worker.perform { [self] in
            guard let pointer = cursor.pointer else { return [] }
            guard cursors.contains(pointer) else { throw AirSQLError.disconnected }  // the session closed under it
            mongoc_cursor_set_batch_size(pointer, UInt32(clamping: maxCount))
            var found: [[UInt8]] = [], bytes = 0
            var document: UnsafePointer<bson_t>?
            try sending(cursor.tag, server: cursorServer(pointer)) {
                while found.count < maxCount && bytes < maxBytes && mongoc_cursor_next(pointer, &document) {
                    let raw = Array(UnsafeBufferPointer(start: bson_get_data(document!), count: Int(document!.pointee.len)))
                    bytes += raw.count
                    found.append(raw)
                }
                var error = bson_error_t()
                var reply: UnsafePointer<bson_t>?
                if mongoc_cursor_error_document(pointer, &error, &reply) {
                    throw lock.locked { routeError } ?? MongoErrorMapping.map(error, reply: reply)
                }
            }
            if !mongoc_cursor_more(pointer) { cursor.exhausted() }
            return found
        }
    }

    private func cursorServer(_ cursor: OpaquePointer) -> String {
        var host = mongoc_host_list_t()
        mongoc_cursor_get_host(cursor, &host)
        return Self.text(host.host_and_port)
    }

    /// Destroys the cursor, which ends it on the server (killCursors) when it has more.
    fileprivate func close(_ pointer: OpaquePointer) {
        worker.submit { [self] in
            // Gone already when the session closed first.
            if cursors.remove(pointer) != nil { mongoc_cursor_destroy(pointer) }
        }
    }

    // MARK: The stream initiator

    private static let initiator: mongoc_stream_initiator_t = { uri, host, context, errorOut in
        guard let uri, let host, let context else { return nil }
        let session = Unmanaged<MongoSession>.fromOpaque(context).takeUnretainedValue()
        do {
            return try session.open(uri, host: MongoSession.text(host.pointee.host), port: Int(host.pointee.port))
        } catch {
            let failure = error as? AirSQLError ?? AirSQLError(.other, error.localizedDescription)
            session.lock.locked { session.routeError = failure }
            MongoSession.set(error: failure.message, in: errorOut)
            return nil
        }
    }

    /// A stream to host:port as the driver asks for it: the route's socket for it, else TCP, and TLS on top when the
    /// connection string asks for TLS. Runs on the session's thread, inside the driver.
    private func open(_ uri: OpaquePointer, host: String, port: Int) throws -> UnsafeMutablePointer<mongoc_stream_t> {
        let timeout = Int64(mongoc_uri_get_option_as_int32(uri, MONGOC_URI_CONNECTTIMEOUTMS, 10_000))
        let expire = bson_get_monotonic_time() + timeout * 1000
        let base = try connection.route.socket(host: host, port: port).map { try Self.unixStream($0, expire: expire) }
            ?? Self.tcpStream(host, port: port, expire: expire)
        guard mongoc_uri_get_tls(uri) else { return base }

        var options = mongoc_ssl_opt_get_default().pointee
        options.weak_cert_validation = true  // TLSCheck below checks instead (and no OCSP request leaves the route)
        // The client certificate (X.509 login, or a server that asks for one): its key in the same PEM file, as the
        // driver reads both from one file (mongosh's --tlsCertificateKeyFile).
        let tls = connection.tls
        if let key = tls.keyFile, !key.isEmpty, key != tls.certFile {
            mongoc_stream_destroy(base)
            throw AirSQLError(.tls, "MongoDB takes the client certificate and its key in one PEM file: choose that file as the "
                              + "TLS tab's Certificate and leave Key empty.")
        }
        let pem = tls.certFile.flatMap { $0.isEmpty ? nil : strdup($0) }
        defer { free(pem) }
        options.pem_file = UnsafePointer(pem)
        guard let stream = mongoc_stream_tls_new_with_hostname(base, host, &options, 1) else {
            mongoc_stream_destroy(base)
            throw AirSQLError(.tls, "AirSQL couldn't set up TLS to \(host)" + (pem == nil ? "." : ": check that the client "
                                                                                 + "certificate's file holds it and its key, in PEM."))
        }
        var error = bson_error_t()
        guard mongoc_stream_tls_handshake_block(stream, host, Int32(timeout), &error) else {
            mongoc_stream_destroy(stream)
            throw AirSQLError(.tls, "The TLS handshake with \(host) failed.", details: Self.text(error.message))
        }
        let check = TLSCheck(host: host, options: connection.tls)
        guard check.verify(Self.peerChain(stream)) else {
            mongoc_stream_destroy(stream)
            throw check.failure ?? AirSQLError(.tls, "AirSQL couldn't check the certificate of \(host).")
        }
        if let certificate = check.certificate { connection.checked(certificate, server: "\(host):\(port)") }
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

/// A find's options, as the query bar has them.
public struct MongoFind: Sendable {
    public var filter = BSONDocument()
    public var projection: BSONDocument?
    public var sort: BSONDocument?
    public var skip: Int64?
    public var limit: Int64?
    public var collation: BSONDocument?
    /// An index's name (a string) or its keys (a document).
    public var hint: BSONValue?
    public var maxTimeMS: Int?

    public init(filter: BSONDocument = BSONDocument(), projection: BSONDocument? = nil, sort: BSONDocument? = nil,
                skip: Int64? = nil, limit: Int64? = nil, collation: BSONDocument? = nil, hint: BSONValue? = nil,
                maxTimeMS: Int? = nil) {
        self.filter = filter
        self.projection = projection
        self.sort = sort
        self.skip = skip
        self.limit = limit
        self.collation = collation
        self.hint = hint
        self.maxTimeMS = maxTimeMS
    }

    func command(collection: String) -> BSONDocument {
        var fields: [(key: String, value: BSONValue)] = [("find", .string(collection)), ("filter", .document(filter))]
        if let projection { fields.append(("projection", .document(projection))) }
        if let sort { fields.append(("sort", .document(sort))) }
        if let skip { fields.append(("skip", .int64(skip))) }
        if let limit { fields.append(("limit", .int64(limit))) }
        if let collation { fields.append(("collation", .document(collation))) }
        if let hint { fields.append(("hint", hint)) }
        if let maxTimeMS { fields.append(("maxTimeMS", .int64(Int64(maxTimeMS)))) }
        return BSONDocument(fields)
    }
}

/// A server-side cursor (find, aggregate): read it in batches with `next`, then `close` it (or read it to the end).
/// Its getMores run on its session's thread, tagged as the command that opened it, so Cancel finds them too.
public final class MongoCursor: @unchecked Sendable {
    private let session: MongoSession
    let tag: String
    /// The member that answered, "host:port", when it is a secondary (the connection string's readPreference chose it).
    public let secondary: String?
    private let lock = NSLock()
    private var _pointer: OpaquePointer?

    fileprivate init(session: MongoSession, cursor: OpaquePointer, tag: String, secondary: String?) {
        self.session = session
        self.tag = tag
        self.secondary = secondary
        _pointer = cursor
    }

    deinit { if let pointer = _pointer { session.close(pointer) } }

    fileprivate var pointer: OpaquePointer? { lock.locked { _pointer } }

    /// Read to the end (or closed): `next` returns nothing more.
    public var isExhausted: Bool { pointer == nil }

    /// The next documents as raw BSON (`BSONDocument(bytes:)`, or `BSONDocument.value(at:in:)` for one value): at most
    /// `maxCount`, and no more once `maxBytes` is reached (at least one). Empty when there are no more.
    public func next(maxCount: Int = 1000, maxBytes: Int = 4 << 20) async throws -> [[UInt8]] {
        try await session.next(self, maxCount: max(1, maxCount), maxBytes: maxBytes)
    }

    fileprivate func exhausted() {
        if let pointer = lock.locked({ () -> OpaquePointer? in defer { _pointer = nil }; return _pointer }) {
            session.close(pointer)
        }
    }

    /// Ends the cursor on the server.
    public func close() async { exhausted() }
}

/// A collection or view as listCollections describes it.
public struct MongoCollectionInfo: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case collection, view, timeseries
    }

    public var name: String
    public var kind: Kind
    /// Its options: a view's viewOn and pipeline, a time-series' timeseries, a collation, validator, capped…
    public var options: BSONDocument

    public init(name: String, kind: Kind, options: BSONDocument = BSONDocument()) {
        self.name = name
        self.kind = kind
        self.options = options
    }
}

extension BSONDocument {
    /// A copy in libbson's form (bson_destroy it).
    func bson() throws -> UnsafeMutablePointer<bson_t> {
        let bytes = try bytes()
        guard let made = bson_new_from_data(bytes, bytes.count) else { throw BSONError("libbson refused the document") }
        return made
    }

    init(bson: UnsafePointer<bson_t>) throws {
        try self.init(bytes: UnsafeBufferPointer(start: bson_get_data(bson), count: Int(bson.pointee.len)))
    }
}

extension BSONValue {
    /// A whole number of any of BSON's number types (a reply's counts and sizes), exactly; nil otherwise.
    public var integer: Int64? {
        switch self {
        case .int32(let value): return Int64(value)
        case .int64(let value): return value
        case .double(let value): return Int64(exactly: value)
        default: return nil
        }
    }

    /// How an index's name shows a key's direction or kind: 1, -1, "text", "2dsphere".
    var indexNamePart: String {
        switch self {
        case .string(let text): return text
        default: return integer.map(String.init) ?? shellForm()
        }
    }
}
