import AirSQLCore
import AppKit

/// The schema session as the schema cache reads it: opened on first use (and again by the next read after the
/// connection's sessions were closed).
struct SchemaSession: SchemaQuerying {
    let connection: Connection

    func rows(_ sql: String) async throws -> [[String?]] {
        try await connection.session(.schema).rows(sql)
    }
}

extension Notification.Name {
    /// Posted (object: the `OpenConnection`) when its schema, what is loading or its last error changes.
    static let openConnectionDidChange = Notification.Name("AirSQLOpenConnectionDidChange")
}

/// A connected connection as the windows share it (plan §2.7): its sessions and its schema cache. Whatever connects
/// calls `AppModel.attach` once the main session is up, which builds the cache and loads it; the cache stays while
/// the sessions reconnect, and `AppModel.detach` (Disconnect) empties it and closes the sessions.
@MainActor
final class OpenConnection {
    /// What is loading, for the tree's spinners and the database view.
    enum Load: Hashable {
        case schema, details(String), statistics(String)
    }

    let id: UUID
    /// When it connected: the status bar's popover says for how long.
    let connectedAt = Date()
    let connection: Connection
    let schema: SchemaCache
    /// The cache's latest snapshot, as the tree shows it.
    private(set) var snapshot = SchemaSnapshot()
    var loading: Set<Load> { Set(running.keys) }
    /// Why the last load failed, until one works.
    private(set) var loadError: String?
    /// The database the console works in: the connection's own at first, then the one double-clicked in the tree.
    var currentDatabase: String? {
        didSet {
            if let currentDatabase, var saved = model?.connection(id), saved.lastDatabase != currentDatabase {
                saved.lastDatabase = currentDatabase
                model?.save(saved)
            }
            changed()
        }
    }
    /// Where the person left off, gone back to once the schema shows it is still there.
    private var databaseToRestore: String?
    private(set) weak var model: AppModel?
    private var running: [Load: Int] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// How far reading every database's sizes is: 0 of the count, then on; nil when nothing reads.
    private(set) var sizesProgress: (done: Int, of: Int, database: String)?
    /// Why the last read of the sizes stopped short.
    private(set) var sizesError: String?
    private var sizesTask: Task<Void, Never>?

    /// `source`: where the schema is read (the schema session; tests replay a recording).
    init(id: UUID, connection: Connection, model: AppModel, includes: @escaping (String) -> Bool, source: SchemaQuerying? = nil) {
        self.id = id
        self.connection = connection
        self.model = model
        schema = SchemaCache(source: source ?? SchemaSession(connection: connection),
                             tableThreshold: model.data.settings.detailsTableThreshold, includes: includes)
        currentDatabase = connection.options.database
        if currentDatabase == nil { databaseToRestore = model.connection(id)?.lastDatabase }
        schema.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.snapshot = snapshot
            if snapshot.server != nil, let name = self.databaseToRestore {
                self.databaseToRestore = nil
                if self.currentDatabase == nil, snapshot.database(name) != nil { self.currentDatabase = name }
            }
            self.changed()
        }
    }

    private var name: String { model?.connection(id)?.displayName ?? "the server" }

    /// Reads the whole schema again: at connect and on Refresh.
    func load() {
        start(.schema, "Loading the schema of \(name)") { try await $0.load() }
    }

    /// Loads a database's columns, indexes and keys when the server has too many tables to load them at connect.
    func loadDetails(_ database: String) {
        guard let found = snapshot.database(database), !found.detailsLoaded, !snapshot.detailsUpfront else { return }
        start(.details(found.name), "Loading the tables of \(found.name)") { try await $0.loadDetails([found.name]) }
    }

    /// Reads a database's table statistics (rows, sizes, engine, last update) for the database view, again on Refresh.
    func loadStatistics(_ database: String) {
        start(.statistics(database), "Reading the table sizes of \(database)") { try await $0.loadStatistics(database) }
    }

    /// Reads the sizes of `databases` for Disk Usage and the host page, one database at a time because the query opens
    /// every table it names, on a session of its own, listed in the status bar with Cancel. What was read stays when it
    /// stops. Reading already: nothing more is asked.
    func readSizes(_ databases: [String]) {
        guard let model, sizesTask == nil, let first = databases.first else { return }
        sizesError = nil
        sizesProgress = (0, databases.count, first)
        changed()
        let activity = model.activity.start("Reading the sizes on \(name)", connection: id) { [weak self] in self?.stopReadingSizes() }
        let connection = self.connection, schema = self.schema
        sizesTask = Task { [weak self] in
            var session: DBConnection?
            var failure: String?
            do {
                let opened = try await connection.toolsSession()
                session = opened
                for (index, database) in databases.enumerated() {
                    try Task.checkCancellation()
                    activity.progress = Double(index) / Double(databases.count)
                    activity.detail = "\(index + 1) of \(databases.count): \(database)"
                    self?.sizesProgress = (index, databases.count, database)
                    self?.changed()
                    let read = Task { try await schema.loadStatistics(database, through: opened) }
                    try await withTaskCancellationHandler { try await read.value } onCancel: {
                        Task { _ = try? await opened.cancel() }
                    }
                }
            } catch is CancellationError {
            } catch {
                if (error as? AirSQLError)?.kind != .cancelled { failure = error.localizedDescription }
            }
            activity.end()
            if let session { await session.close() }
            self?.sizesTask = nil
            self?.sizesProgress = nil
            self?.sizesError = failure
            self?.changed()
        }
    }

    func stopReadingSizes() { sizesTask?.cancel() }

    /// Reads again what DDL changed.
    func refresh(_ objects: [SchemaObject]) {
        guard !objects.isEmpty else { return }
        start(.schema, "Reading the changes on \(name)") { try await $0.refresh(objects) }
    }

    private func start(_ load: Load, _ title: String, _ work: @escaping (SchemaCache) async throws -> Void) {
        // Schema reads queue in the cache; a database's details or statistics load once at a time.
        guard let model, load == .schema || running[load] == nil else { return }
        running[load, default: 0] += 1
        changed()
        let key = UUID(), schema = self.schema
        let activity = model.activity.start(title, connection: id) { [weak self] in self?.tasks[key]?.cancel() }
        tasks[key] = Task { [weak self] in
            var failure: String?
            do {
                try await work(schema)
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
            activity.end()
            self?.finished(load, key, failure)
        }
    }

    private func finished(_ load: Load, _ key: UUID, _ failure: String?) {
        tasks[key] = nil
        loadError = failure
        running[load] = running[load].flatMap { $0 > 1 ? $0 - 1 : nil }
        changed()
    }

    /// Runs statements in order on a session of their own (a long OPTIMIZE or copy holds up neither the schema nor the
    /// console), listed in the status bar with Cancel, which stops the running one; then reads again what they changed.
    /// Returns each statement's results; the first error stops the rest.
    func run(_ statements: [String], title: String, refreshing objects: [SchemaObject] = []) async throws -> [[StatementResult]] {
        guard let model else { throw AirSQLError.disconnected }
        var session: DBConnection?
        var cancelled = false
        let activity = model.activity.start(title, connection: id) {
            cancelled = true
            if let session { Task { _ = try? await session.cancel() } }
        }
        defer {
            activity.end()
            if let session { Task { await session.close() } }
            refresh(objects)
        }
        session = try await connection.toolsSession()
        var results: [[StatementResult]] = []
        for (index, sql) in statements.enumerated() {
            guard !cancelled, let session else { throw AirSQLError.cancelled }
            if statements.count > 1 { activity.detail = "Statement \(index + 1) of \(statements.count)" }
            results.append(try await session.query(sql))
        }
        return results
    }

    /// Disconnect: stops loading, forgets the schema and closes every session. After a drop the sessions are the
    /// connector's to keep for the reconnect.
    func close(closingSessions: Bool = true) {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        stopReadingSizes()
        running = [:]
        schema.clear()
        guard closingSessions else { return }
        let connection = self.connection
        Task.detached { await connection.disconnect() }
    }

    private func changed() {
        NotificationCenter.default.post(name: .openConnectionDidChange, object: self)
    }
}

extension AppModel {
    /// The connected connection with this id, if it is open.
    func openConnection(_ id: UUID?) -> OpenConnection? { id.flatMap { open[$0] } }

    /// Called by whatever connects, once the main session is up: builds the connection's schema cache (the database
    /// filter as `includes`) and loads it. Attaching the same connection again (after a reconnect) keeps the cache.
    @discardableResult
    func attach(_ connection: Connection, to id: UUID, includes: @escaping (String) -> Bool = { _ in true }) -> OpenConnection {
        if let existing = open[id], existing.connection === connection { return existing }
        open[id]?.close()
        let opened = OpenConnection(id: id, connection: connection, model: self, includes: includes)
        open[id] = opened
        opened.load()
        return opened
    }

    /// The same for a MongoDB connection, kept in `openMongo`.
    func attach(mongo: OpenMongoConnection, to id: UUID) {
        if let previous = openMongo.updateValue(mongo, forKey: id), previous !== mongo { previous.close() }
        if mongo.databases == nil { mongo.load() }
    }

    /// Disconnect: forgets the connection's schema and closes its sessions (a drop leaves those to the connector).
    func detach(_ id: UUID, closingSessions: Bool = true) {
        open.removeValue(forKey: id)?.close(closingSessions: closingSessions)
        if let mongo = openMongo.removeValue(forKey: id), closingSessions { mongo.close() }
    }
}
