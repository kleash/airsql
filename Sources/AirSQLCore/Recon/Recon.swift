import Foundation

/// One side of a compare: a session of its own on the connection (`Connection.toolsSession()`) and the database.
public struct ReconSide {
    /// The connection's name, as the report shows it.
    public var name: String
    public var database: String
    public var session: DBConnection

    public init(name: String, database: String, session: DBConnection) {
        self.name = name
        self.database = database
        self.session = session
    }
}

/// How far a compare is, for the compare window's progress.
public struct ReconProgress: Equatable {
    /// What is under way, in plain words: "Reading the schemas", "orders".
    public var step: String
    /// The table whose data is being compared, its chunk and (estimated) chunks.
    public var table: String?
    public var chunk = 0
    public var chunks = 0
    /// Tables whose data is compared so far, of all to compare.
    public var tablesDone = 0
    public var tables = 0
    public var rowsChecked = 0
    public var rowsFetched = 0

    public init(step: String) { self.step = step }

    /// Done so far, 0 to 1, counting each table as one share and its chunks within it.
    public var fraction: Double {
        guard tables > 0 else { return 0 }
        let inTable = chunks > 0 ? min(1, Double(chunk) / Double(chunks)) : 0
        return min(1, (Double(tablesDone) + inTable) / Double(tables))
    }
}

/// A compare couldn't start.
public struct ReconError: LocalizedError {
    public var message: String
    public var errorDescription: String? { message }
}

/// Compares two databases (plan §2.9, R6), or the pair in `options.only`: reads both schemas fresh through each side's
/// own session, compares their structure, then the rows of every table both have. Off the main thread; cancel the task
/// to stop (a running statement is stopped on its server). `runServer` does it for every database of two servers.
public enum Recon {
    public static func run(source: ReconSide, target: ReconSide, options: ReconOptions,
                           progress: @escaping (ReconProgress) -> Void = { _ in }) async throws -> ReconResult {
        let started = Date()
        var options = options
        if let only = options.only, only.kind != .table { options.mode = .structure }  // only tables have rows
        progress(ReconProgress(step: "Reading the schemas"))
        // UTC on both sides: TIMESTAMP values, and TIMESTAMP defaults in SHOW CREATE TABLE, then read the same.
        async let left = schema(source)
        async let right = schema(target)
        let ((sourceServer, sourceDB), (targetServer, targetDB)) = try await (left, right)
        let structure = ReconStructure(source: sourceDB, target: targetDB, sourceServer: sourceServer,
                                       targetServer: targetServer, options: options)
        var result = ReconResult(
            source: ReconEnd(name: source.name, database: source.database, version: sourceServer.versionString,
                             noBackslashEscapes: source.session.noBackslashEscapes),
            target: ReconEnd(name: target.name, database: target.database, version: targetServer.versionString,
                             noBackslashEscapes: target.session.noBackslashEscapes),
            options: options)

        progress(ReconProgress(step: "Comparing the structure"))
        let (pairs, onlyInTarget) = structure.tablePairs()
        if let only = options.only, only.kind == .table {
            guard let pair = pairs.first else { throw missing(only.kind, only.source, source) }
            guard pair.target != nil else { throw missing(only.kind, only.target, target) }
        }
        var tables: [ReconObject] = []
        for (left, right) in pairs {
            var object = ReconObject(kind: .table, name: left.name, targetName: right?.name, status: .onlyInSource)
            object.references = references(left, in: sourceDB.name)
            object.targetEngine = right?.engine
            if let right {
                object.parts = structure.compare(left, right)
                object.status = object.parts.isEmpty ? .same : .different
            }
            tables.append(object)
        }
        for table in onlyInTarget {
            var object = ReconObject(kind: .table, name: table.name, status: .onlyInTarget)
            object.references = references(table, in: targetDB.name)
            object.targetEngine = table.engine
            tables.append(object)
        }
        if options.mode != .data {
            for index in tables.indices where tables[index].status != .same {
                try await define(&tables[index], source: source, target: target, sourceDB: sourceDB)
            }
            result.objects = tables + (try await definitions(structure, source: source, target: target))
        } else {
            result.objects = tables
        }

        if options.mode != .structure {
            let compared = tables.indices.filter { tables[$0].status != .onlyInSource && tables[$0].status != .onlyInTarget }
            for (done, index) in compared.enumerated() {
                let object = tables[index]
                guard let left = sourceDB.table(object.name), let right = targetDB.table(object.targetName) else { continue }
                var step = ReconProgress(step: object.name)
                step.table = object.name
                step.tablesDone = done
                step.tables = compared.count
                step.rowsChecked = result.rowsChecked
                step.rowsFetched = result.rowsFetched
                progress(step)
                let (data, checked, fetched) = try await compareData(
                    left, right, source: source, target: target, choice: options.choice(object.name),
                    estimatedRows: sourceDB.statistics?[left.name]?.rows ?? 0) { chunk in
                        var current = step
                        current.chunk = chunk.chunk
                        current.chunks = chunk.chunks
                        current.rowsChecked = step.rowsChecked + chunk.rowsChecked
                        current.rowsFetched = step.rowsFetched + chunk.rowsFetched
                        progress(current)
                    }
                if let position = result.objects.firstIndex(where: { $0.kind == .table && $0.name == object.name }) {
                    result.objects[position].data = data
                }
                result.rowsChecked += checked
                result.rowsFetched += fetched
            }
        }
        if options.mode == .both {
            // New tables get their rows too. (New columns of existing tables get their defaults: compare again after
            // running the structure steps to copy their values.)
            for index in result.objects.indices where result.objects[index].kind == .table
                && result.objects[index].status == .onlyInSource {
                guard let table = sourceDB.table(result.objects[index].name) else { continue }
                var step = ReconProgress(step: table.name)
                step.table = table.name
                progress(step)
                let data = try await sourceRows(table, source: source, choice: options.choice(table.name))
                result.objects[index].data = data
                result.rowsFetched += data.missing.count
            }
        }
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    private static func missing(_ kind: ReconObject.Kind, _ name: String, _ side: ReconSide) -> ReconError {
        ReconError(message: "There is no \(kind.rawValue) \(name) in \(side.database) on \(side.name), or this login can't see it.")
    }

    /// A side's server and database, details and statistics loaded, read fresh through its session (in UTC).
    private static func schema(_ side: ReconSide) async throws -> (SchemaServer, SchemaDatabase) {
        _ = try await ReconQuery.store(side.session, "SET time_zone = '+00:00'")
        let database = side.database
        let cache = SchemaCache(source: side.session, includes: { $0 == database })
        try await cache.load()
        try await cache.loadDetails([database])
        try await cache.loadStatistics(database)
        let snapshot = cache.snapshot
        guard let server = snapshot.server, let found = snapshot.database(database) else {
            throw ReconError(message: "There is no database \(database) on \(side.name), or this login can't see it.")
        }
        return (server, found)
    }

    /// Tables of its own database a table's foreign keys point at.
    private static func references(_ table: SchemaTable, in database: String) -> [String] {
        table.foreignKeys.filter { $0.referencedDatabase == database && $0.referencedTable != table.name }
            .map(\.referencedTable)
    }

    /// Reads SHOW CREATE TABLE where the table differs or is on one side only, and gives each part the source's own
    /// definition.
    private static func define(_ object: inout ReconObject, source: ReconSide, target: ReconSide,
                               sourceDB: SchemaDatabase) async throws {
        if object.status != .onlyInTarget {
            object.sourceDDL = try await showCreate(source, "TABLE", object.name, column: 1)
        }
        if object.status != .onlyInSource {
            object.targetDDL = try await showCreate(target, "TABLE", object.targetName, column: 1)
        }
        guard let text = object.sourceDDL, let create = ReconCreateTable(text),
              let table = sourceDB.table(object.name) else { return }
        for index in object.parts.indices where object.parts[index].change != .dropped && object.parts[index].kind != .options {
            let part = object.parts[index]
            switch part.kind {
            case .column: object.parts[index].definition = create.definition(.column, part.name) ?? ""
            case .index: object.parts[index].definition = create.definition(.index, part.name) ?? ""
            case .foreignKey: object.parts[index].definition = create.definition(.foreignKey, part.name) ?? ""
            case .check:
                // MariaDB writes a column's own check inside the column's line.
                let clause = table.checks.first { $0.name == part.name }?.clause ?? ""
                object.parts[index].definition = create.definition(.check, part.name)
                    ?? "CONSTRAINT \(SQLQuote.identifier(part.name)) CHECK (\(clause))"
            case .options: break
            }
        }
    }

    /// The views, sequences, routines, triggers and events of both sides, compared by their definitions.
    private static func definitions(_ structure: ReconStructure, source: ReconSide,
                                    target: ReconSide) async throws -> [ReconObject] {
        let left = structure.source, right = structure.target
        typealias Kind = (kind: ReconObject.Kind, show: String, column: Int, names: (SchemaDatabase) -> [String])
        let kinds: [Kind] = [
            (.view, "VIEW", 1, { $0.tables.filter { $0.kind == .view }.map(\.name) }),
            (.sequence, "SEQUENCE", 1, { $0.tables.filter { $0.kind == .sequence }.map(\.name) }),
            (.procedure, "PROCEDURE", 2, { $0.routines.filter { $0.kind == .procedure }.map(\.name) }),
            (.function, "FUNCTION", 2, { $0.routines.filter { $0.kind == .function }.map(\.name) }),
            (.trigger, "TRIGGER", 2, { $0.triggers.map(\.name) }),
            (.event, "EVENT", 3, { $0.events.map(\.name) }),
        ]
        var objects: [ReconObject] = []
        if let only = structure.options.only {
            guard let kind = kinds.first(where: { $0.kind == only.kind }) else { return [] }
            guard kind.names(left).contains(only.source) else { throw missing(only.kind, only.source, source) }
            guard kind.names(right).contains(only.target) else { throw missing(only.kind, only.target, target) }
            let sourceText = try await showCreate(source, kind.show, only.source, column: kind.column)
            let targetText = try await showCreate(target, kind.show, only.target, column: kind.column)
            return [structure.definition(only.kind, name: only.source, targetName: only.target, source: sourceText, target: targetText)]
                .compactMap { $0 }
        }
        for kind in kinds {
            let ours = kind.names(left), theirs = kind.names(right)
            for name in ours + theirs.filter({ !ours.contains($0) }) {
                let sourceText = ours.contains(name) ? try await showCreate(source, kind.show, name, column: kind.column) : nil
                let targetText = theirs.contains(name) ? try await showCreate(target, kind.show, name, column: kind.column) : nil
                if let object = structure.definition(kind.kind, name: name, source: sourceText, target: targetText) {
                    objects.append(object)
                }
            }
        }
        return objects
    }

    /// SHOW CREATE … of an object: its CREATE statement, or "" when the server won't show it to this login.
    private static func showCreate(_ side: ReconSide, _ kind: String, _ name: String, column: Int) async throws -> String {
        do {
            let store = try await ReconQuery.store(side.session, "SHOW CREATE \(kind) " + SQLQuote.identifier(side.database, name))
            return store.rowCount > 0 && column < store.columns.count ? store.string(0, column) ?? "" : ""
        } catch let error as AirSQLError where error.kind != .cancelled && error.kind != .disconnected {
            return ""
        }
    }
}
