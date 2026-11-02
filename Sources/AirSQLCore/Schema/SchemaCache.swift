import Foundation

/// An object that DDL changed, for `SchemaCache.refresh(_:)`.
public enum SchemaObject: Hashable {
    case database(String)
    /// A table, view or sequence (its triggers come with it).
    case table(database: String, name: String)
    case routine(database: String, name: String)
    case trigger(database: String, name: String)
    case event(database: String, name: String)

    public var database: String {
        switch self {
        case .database(let name): return name
        case .table(let database, _), .routine(let database, _), .trigger(let database, _), .event(let database, _):
            return database
        }
    }
}

/// The server didn't answer `SELECT VERSION()`.
public struct SchemaError: LocalizedError {
    public var errorDescription: String? {
        "The server didn't say which version it is, so AirSQL can't read its schema."
    }
}

/// A connection's schema: the names of every database its filter allows, then details and statistics when needed.
///
/// At connect and on Refresh, `load()` reads the names (databases, tables, views, routines, triggers and events), one
/// query per kind for every database, and publishes them; then the details (columns, indexes, foreign keys and checks),
/// again one query per kind for every database, unless the server has more tables than `tableThreshold`: then a
/// database's details load when something needs them (`loadDetails`: an expanded tree node, completion, an editor, an
/// agent). Statistics load for the database being viewed (`loadStatistics`). After DDL, `refresh(_:)` reads again only
/// the objects it names. Every change comes with schema hashes.
///
/// The cache belongs to the connection, not to a session: it survives reconnects, and Disconnect calls `clear()`.
/// Operations run one at a time, in the order they were called, off the main thread, through the schema session;
/// `snapshot` can be read on any thread at any time.
public final class SchemaCache {
    public static let defaultTableThreshold = 3_000

    /// The schema session.
    public let source: SchemaQuerying
    /// Above this many tables (with views and sequences) in the databases the filter allows, details load per database.
    public let tableThreshold: Int
    /// The connection's database filter: whether a database is shown. Called off the main thread.
    public let includes: (String) -> Bool
    /// The new snapshot after each change, on the main queue.
    public var onChange: ((SchemaSnapshot) -> Void)?

    private let lock = NSLock()
    private var current = SchemaSnapshot()
    /// Bumped by `clear()`: an operation queued before doesn't publish what it read.
    private var generation = 0
    /// The last operation queued; the next one starts when it ends.
    private var last: Task<Void, Never>?

    public init(source: SchemaQuerying, tableThreshold: Int = defaultTableThreshold,
                includes: @escaping (String) -> Bool = { _ in true }) {
        self.source = source
        self.tableThreshold = tableThreshold
        self.includes = includes
    }

    public var snapshot: SchemaSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Reads the schema again from the start (at connect and on Refresh). The first load publishes the names before the
    /// details; a reload publishes once, at the end, so the tree doesn't flicker, and reads again the details and
    /// statistics that were loaded before.
    public func load() async throws {
        try await serially { [self] old, publish in
            guard let server = SchemaIntrospection.server(try await source.rows(SchemaIntrospection.serverSQL)) else {
                throw SchemaError()
            }
            let introspection = SchemaIntrospection(server: server)
            let all = SchemaIntrospection.databases(try await source.rows(introspection.databasesSQL(nil)))
            let allowed = all.filter { includes($0.name) }.sorted(by: Self.byName)
            let allowedNames = allowed.map(\.name)
            var snapshot = SchemaSnapshot()
            snapshot.server = server
            if !allowed.isEmpty {
                snapshot.databases = try await names(introspection, allowed.count == all.count ? nil : allowedNames,
                                                     into: allowed)
            }
            snapshot.detailsUpfront = snapshot.tableCount <= tableThreshold
            if old.server == nil {
                publish(Self.hashed(snapshot, all: true))
            }

            let detailed = snapshot.detailsUpfront
                ? allowedNames : allowedNames.filter { old.database($0)?.detailsLoaded == true }
            if !detailed.isEmpty {
                let details = try await self.details(
                    introspection, .databases(snapshot.detailsUpfront && allowed.count == all.count ? nil : detailed))
                for index in snapshot.databases.indices where detailed.contains(snapshot.databases[index].name) {
                    snapshot.databases[index].setDetails(details)
                }
            }
            for (index, database) in snapshot.databases.enumerated()
            where old.database(database.name)?.statistics != nil {
                snapshot.databases[index].statistics = try await statistics(introspection, database.name)
            }
            publish(Self.hashed(snapshot, all: true))
        }
    }

    /// Loads the details of these databases where they aren't loaded yet.
    public func loadDetails(_ databases: [String]) async throws {
        try await serially { [self] old, publish in
            guard let server = old.server else { return }
            var names: [String] = []
            for name in databases {
                if let database = old.database(name), !database.detailsLoaded, !names.contains(database.name) {
                    names.append(database.name)
                }
            }
            guard !names.isEmpty else { return }
            let details = try await self.details(SchemaIntrospection(server: server), .databases(names))
            var snapshot = old
            for index in snapshot.databases.indices where names.contains(snapshot.databases[index].name) {
                snapshot.databases[index].setDetails(details)
                snapshot.databases[index].hash = SchemaHash.of(snapshot.databases[index])
            }
            publish(Self.hashed(snapshot, all: false))
        }
    }

    /// Reads the statistics of a database's tables (again).
    public func loadStatistics(_ database: String) async throws {
        try await serially { [self] old, publish in
            guard let server = old.server, let name = old.database(database)?.name,
                  let index = old.databases.firstIndex(where: { $0.name == name }) else { return }
            var snapshot = old
            snapshot.databases[index].statistics = try await statistics(SchemaIntrospection(server: server), name)
            publish(snapshot)
        }
    }

    /// Reads again the objects that DDL changed (created, altered, renamed or dropped; a rename names both), and the
    /// details of tables whose foreign keys point at a refreshed table. A database that isn't cached yet, or
    /// `.database`, is read whole. Views that select from a changed table aren't read again (nothing tells which tables
    /// a view uses on every server): name them too, or Refresh.
    public func refresh(_ objects: [SchemaObject]) async throws {
        try await serially { [self] old, publish in
            guard let server = old.server else { return }
            let introspection = SchemaIntrospection(server: server)
            var snapshot = old
            var changed = Set<String>()
            var seen: [String] = []
            for object in objects where !seen.contains(where: { server.same($0, object.database) }) {
                seen.append(object.database)
                let group = objects.filter { server.same($0.database, object.database) }
                if group.contains(where: { if case .database = $0 { return true } else { return false } })
                    || snapshot.database(object.database) == nil {
                    changed.formUnion(try await refreshDatabase(object.database, introspection, in: &snapshot))
                } else {
                    changed.formUnion(try await refreshObjects(group, introspection, in: &snapshot))
                }
            }
            for index in snapshot.databases.indices where changed.contains(snapshot.databases[index].name) {
                snapshot.databases[index].hash = SchemaHash.of(snapshot.databases[index])
            }
            publish(Self.hashed(snapshot, all: false))
        }
    }

    /// Forgets everything (Disconnect). Operations still queued or running don't publish.
    public func clear() {
        lock.lock()
        generation += 1
        current = SchemaSnapshot()
        lock.unlock()
        DispatchQueue.main.async { self.onChange?(SchemaSnapshot()) }
    }

    // MARK: Reading

    /// The databases with their tables, routines, triggers and events: one query per kind for these databases (nil:
    /// every database).
    private func names(_ introspection: SchemaIntrospection, _ names: [String]?,
                       into databases: [SchemaDatabase]) async throws -> [SchemaDatabase] {
        let scope = SchemaScope.databases(names)
        let tables = SchemaIntrospection.tables(try await source.rows(introspection.tablesSQL(scope)))
        let routines = SchemaIntrospection.routines(try await source.rows(introspection.routinesSQL(scope)))
        let triggers = SchemaIntrospection.triggers(try await source.rows(introspection.triggersSQL(scope)))
        let events = SchemaIntrospection.events(try await source.rows(introspection.eventsSQL(scope)))
        return databases.map { database in
            var database = database
            database.tables = (tables[database.name] ?? []).sorted(by: Self.byName)
            database.routines = (routines[database.name] ?? []).sorted(by: Self.byName)
            database.triggers = (triggers[database.name] ?? []).sorted(by: Self.byName)
            database.events = (events[database.name] ?? []).sorted(by: Self.byName)
            return database
        }
    }

    private func details(_ introspection: SchemaIntrospection,
                         _ scope: SchemaScope) async throws -> [TableKey: TableDetails] {
        let columns = try await source.rows(introspection.columnsSQL(scope))
        let indexes = try await source.rows(introspection.indexesSQL(scope))
        let foreignKeys = try await source.rows(introspection.foreignKeysSQL(scope))
        let rules = try await source.rows(introspection.foreignKeyRulesSQL(scope))
        var checks: [[String?]] = []
        if let sql = introspection.checksSQL(scope) {
            checks = try await source.rows(sql)
        }
        return introspection.details(columns: columns, indexes: indexes, foreignKeys: foreignKeys,
                                     foreignKeyRules: rules, checks: checks)
    }

    private func statistics(_ introspection: SchemaIntrospection, _ database: String,
                            tables: [String]? = nil) async throws -> [String: TableStatistics] {
        if let setup = introspection.statisticsSetupSQL {
            _ = try await source.rows(setup)
        }
        let rows = try await source.rows(introspection.statisticsSQL(database, tables: tables))
        return SchemaIntrospection.statistics(rows, database: database)
    }

    // MARK: Refreshing

    /// Reads a database whole, as `load()` would; removes it if it is gone or the filter leaves it out. Returns the
    /// databases changed.
    private func refreshDatabase(_ name: String, _ introspection: SchemaIntrospection,
                                 in snapshot: inout SchemaSnapshot) async throws -> Set<String> {
        let server = introspection.server
        let rows = SchemaIntrospection.databases(try await source.rows(introspection.databasesSQL([name])))
        let previous = snapshot.database(name)
        snapshot.databases.removeAll { server.same($0.name, name) }
        guard let found = rows.first(where: { server.same($0.name, name) }), includes(found.name) else {
            return previous.map { [$0.name] } ?? []
        }
        var database = try await names(introspection, [found.name], into: [found])[0]
        if snapshot.detailsUpfront || previous?.detailsLoaded == true {
            database.setDetails(try await details(introspection, .databases([found.name])))
        }
        if previous?.statistics != nil {
            database.statistics = try await statistics(introspection, found.name)
        }
        snapshot.databases.append(database)
        snapshot.databases.sort(by: Self.byName)
        return [found.name]
    }

    /// Reads the named objects of one cached database again. Returns the databases changed.
    private func refreshObjects(_ objects: [SchemaObject], _ introspection: SchemaIntrospection,
                                in snapshot: inout SchemaSnapshot) async throws -> Set<String> {
        let server = introspection.server
        guard let index = snapshot.databases.firstIndex(where: { server.same($0.name, objects[0].database) }) else {
            return []
        }
        var database = snapshot.databases[index]
        var changed: Set<String> = [database.name]
        /// What a query returned for this database.
        func read<T>(_ sql: String, _ parse: ([[String?]]) -> [String: [T]]) async throws -> [T] {
            parse(try await source.rows(sql))[database.name] ?? []
        }
        var tables: [String] = [], routines: [String] = [], triggers: [String] = [], events: [String] = []
        for object in objects {
            switch object {
            case .table(_, let name): tables.append(name)
            case .routine(_, let name): routines.append(name)
            case .trigger(_, let name): triggers.append(name)
            case .event(_, let name): events.append(name)
            case .database: break
            }
        }

        if !tables.isEmpty {
            let refreshed = { (name: String) in tables.contains { server.same($0, name) } }
            let scope = SchemaScope.objects(database: database.name, names: tables)
            let fresh = try await read(introspection.tablesSQL(scope), SchemaIntrospection.tables)
            let theirs = try await read(introspection.triggersSQL(scope, byTable: true), SchemaIntrospection.triggers)
            database.tables = Self.replacing(database.tables, named: tables, with: fresh,
                                             caseless: server.caselessNames)
            database.triggers = (database.triggers.filter { !refreshed($0.table) }
                + theirs.filter { refreshed($0.table) }).sorted(by: Self.byName)

            // Tables whose foreign keys point at a refreshed table: renaming it, or a column of it, changes them too.
            var referencing: [String: [String]] = [:]
            for other in snapshot.databases where other.detailsLoaded {
                for table in other.tables where table.foreignKeys.contains(where: { key in
                    server.same(key.referencedDatabase, database.name) && refreshed(key.referencedTable)
                }) {
                    referencing[other.name, default: []].append(table.name)
                }
            }
            if database.detailsLoaded {
                let names = tables + (referencing.removeValue(forKey: database.name) ?? [])
                let fetched = try await details(introspection, .objects(database: database.name, names: names))
                database.setDetails(fetched) { name in names.contains { server.same($0, name) } }
            }
            for (name, names) in referencing {
                guard let other = snapshot.databases.firstIndex(where: { $0.name == name }) else { continue }
                let fetched = try await details(introspection, .objects(database: name, names: names))
                snapshot.databases[other].setDetails(fetched) { names.contains($0) }
                changed.insert(name)
            }
            if let statistics = database.statistics {
                var merged = statistics.filter { !refreshed($0.key) }
                let names = database.tables.map(\.name).filter(refreshed)
                if !names.isEmpty {
                    let fresh = try await self.statistics(introspection, database.name, tables: names)
                    merged.merge(fresh.filter { names.contains($0.key) }) { $1 }
                }
                database.statistics = merged
            }
        }
        if !routines.isEmpty {
            let scope = SchemaScope.objects(database: database.name, names: routines)
            let fresh = try await read(introspection.routinesSQL(scope), SchemaIntrospection.routines)
            database.routines = Self.replacing(database.routines, named: routines, with: fresh, caseless: true)
        }
        if !triggers.isEmpty {
            let scope = SchemaScope.objects(database: database.name, names: triggers)
            let fresh = try await read(introspection.triggersSQL(scope), SchemaIntrospection.triggers)
            database.triggers = Self.replacing(database.triggers, named: triggers, with: fresh,
                                               caseless: server.caselessNames)
        }
        if !events.isEmpty {
            let scope = SchemaScope.objects(database: database.name, names: events)
            let fresh = try await read(introspection.eventsSQL(scope), SchemaIntrospection.events)
            database.events = Self.replacing(database.events, named: events, with: fresh, caseless: true)
        }
        snapshot.databases[index] = database
        return changed
    }

    /// `items` with those named in `names` replaced by what the server returned for them (`fresh`): changed, added
    /// (created) or gone (dropped). Names compare as the server compares them (`caseless`).
    private static func replacing<T: SchemaNamed>(_ items: [T], named names: [String], with fresh: [T],
                                                  caseless: Bool) -> [T] {
        let same = { (a: String, b: String) in caseless ? a.caseInsensitiveCompare(b) == .orderedSame : a == b }
        let fresh = fresh.filter { item in names.contains { same($0, item.name) } }
        let replaced = names + fresh.map(\.name)
        return (items.filter { item in !replaced.contains { same($0, item.name) } } + fresh).sorted(by: byName)
    }

    // MARK: Plumbing

    /// Runs `work` after the operations queued before it, with the snapshot as they left it; `publish` makes a new
    /// snapshot current unless `clear()` was called since this operation was queued.
    private func serially(_ work: @escaping (SchemaSnapshot, _ publish: (SchemaSnapshot) -> Void) async throws -> Void)
        async throws {
        let task = enqueue(work)
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func enqueue(_ work: @escaping (SchemaSnapshot, _ publish: (SchemaSnapshot) -> Void) async throws -> Void)
        -> Task<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        let previous = last, generation = self.generation
        let task = Task { [self] in
            await previous?.value
            try Task.checkCancellation()
            guard let snapshot = snapshot(ifStill: generation) else { return }
            try await work(snapshot) { publish($0, ifStill: generation) }
        }
        last = Task { _ = await task.result }
        return task
    }

    private func snapshot(ifStill generation: Int) -> SchemaSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return generation == self.generation ? current : nil
    }

    private func publish(_ snapshot: SchemaSnapshot, ifStill generation: Int) {
        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            return
        }
        current = snapshot
        lock.unlock()
        DispatchQueue.main.async { self.onChange?(snapshot) }
    }

    /// The snapshot with its hash, and with every database's hash when `all` (else they are up to date).
    private static func hashed(_ snapshot: SchemaSnapshot, all: Bool) -> SchemaSnapshot {
        var snapshot = snapshot
        if all {
            for index in snapshot.databases.indices {
                snapshot.databases[index].hash = SchemaHash.of(snapshot.databases[index])
            }
        }
        snapshot.hash = SchemaHash.of(snapshot.databases)
        return snapshot
    }

    private static func byName<T: SchemaNamed>(_ a: T, _ b: T) -> Bool { a.sortKey < b.sortKey }
}

/// Cached objects have names, and are kept in name order.
protocol SchemaNamed {
    var name: String { get }
    var sortKey: String { get }
}

extension SchemaNamed {
    var sortKey: String { name }
}

extension SchemaDatabase: SchemaNamed {}
extension SchemaTable: SchemaNamed {}
extension SchemaTrigger: SchemaNamed {}
extension SchemaEvent: SchemaNamed {}
extension SchemaRoutine: SchemaNamed {
    // A procedure and a function may share a name.
    var sortKey: String { name + "\u{0}" + kind.rawValue }
}

extension SchemaDatabase {
    /// Gives every table (or those `only` accepts, by name) its details; a table the details don't mention gets none.
    mutating func setDetails(_ details: [TableKey: TableDetails], only: ((String) -> Bool)? = nil) {
        for index in tables.indices where only?(tables[index].name) ?? true {
            let found = details[TableKey(database: name, table: tables[index].name)] ?? TableDetails()
            tables[index].columns = found.columns
            tables[index].indexes = found.indexes
            tables[index].foreignKeys = found.foreignKeys
            tables[index].checks = found.checks
        }
        if only == nil {
            detailsLoaded = true
        }
    }
}

extension SchemaServer {
    /// Two database, table or trigger names are the same on this server.
    func same(_ a: String, _ b: String) -> Bool {
        caselessNames ? a.caseInsensitiveCompare(b) == .orderedSame : a == b
    }
}
