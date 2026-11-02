import Foundation

/// A statement of a sync script, with what it changes.
public struct ReconStep: Equatable {
    public enum Kind: String { case structure, data }

    public var kind: Kind
    public var sql: String
    /// DROP, DELETE or a narrowing ALTER: only in the script when the person ticks destructive steps, and marked there
    /// with a comment.
    public var destructive: Bool
    public var objectKind: ReconObject.Kind
    /// The object as the compare lists it (the source's name).
    public var object: String
    /// INSERT, UPDATE and DELETE: exactly the rows it must change, which running the script checks.
    public var expectedRows: Int?
}

extension ReconResult {
    /// The steps that make the target match the source, in dependency order: foreign keys and objects that go or
    /// change are dropped first; then new tables, ALTER TABLE, views, foreign keys, routines, triggers and events;
    /// target-only tables last; then rows: DELETE (children first), UPDATE and INSERT (parents first). Destructive steps
    /// only when `destructive`.
    public func steps(destructive: Bool = false) -> [ReconStep] {
        ReconScriptBuilder(result: self).steps().filter { step in
            (destructive || !step.destructive)
                && (step.kind == .structure ? options.mode != .data : options.mode != .structure)
        }
    }

    /// What runs, in order, and the rows each data statement must change: the target database, UTC (as the compare read
    /// TIMESTAMP values), the structure steps (each commits on its own), then the data steps in one transaction.
    public func runnable(destructive: Bool = false) -> [(sql: String, expectedRows: Int?)] {
        let steps = self.steps(destructive: destructive)
        guard !steps.isEmpty else { return [] }
        var run: [(sql: String, expectedRows: Int?)] = [("USE " + SQLQuote.identifier(target.database), nil),
                                                        ("SET time_zone = '+00:00'", nil)]
        run += steps.filter { $0.kind == .structure }.map { ($0.sql, nil) }
        let data = steps.filter { $0.kind == .data }
        if !data.isEmpty { run += [("START TRANSACTION", nil)] + data.map { ($0.sql, $0.expectedRows) } + [("COMMIT", nil)] }
        return run
    }

    /// The sync script's statements, as the SQL preview shows them.
    public func script(destructive: Bool = false) -> [String] { runnable(destructive: destructive).map(\.sql) }
}

/// Builds a result's sync script.
struct ReconScriptBuilder {
    let result: ReconResult

    /// Rows per INSERT or DELETE statement.
    static let batchRows = 100

    private var ignoreDefiner: Bool { result.options.ignore.definer }

    func steps() -> [ReconStep] {
        let tables = ordered(result.objects.filter { $0.kind == .table })
        let others = result.objects.filter { $0.kind != .table }
        var steps: [ReconStep] = []
        for table in tables where table.status == .different {
            let keys = table.parts.filter { $0.kind == .foreignKey && $0.change != .added }
            steps += alter(table, keys.filter { $0.change == .changed }.map { "DROP FOREIGN KEY " + q($0.name) })
            steps += alter(table, keys.filter { $0.change == .dropped }.map { "DROP FOREIGN KEY " + q($0.name) },
                           destructive: "drops foreign keys only the target has")
        }
        // Changed routines, triggers and events are dropped and created again; views and sequences are replaced.
        for object in others where object.status == .onlyInTarget
            || object.status == .different && ![.view, .sequence].contains(object.kind) && object.sourceDDL?.isEmpty == false {
            steps.append(step(.structure, object, drop(object), destructive: object.status == .onlyInTarget ? "drops it" : nil))
        }
        for table in tables where table.status == .onlyInSource {
            if let create = table.sourceDDL.flatMap(ReconCreateTable.init) {
                steps.append(step(.structure, table, create.withoutForeignKeys))
            }
        }
        for table in tables where table.status == .different {
            steps += alter(table, table.parts.flatMap { safeClauses($0) })
            steps += alter(table, table.parts.flatMap { destructiveClauses($0) },
                           destructive: "drops or narrows what only the target has")
        }
        for view in viewsInOrder(others) {
            if let create = create(view) { steps.append(step(.structure, view, create)) }
        }
        for table in tables {
            var keys = table.parts.filter { $0.kind == .foreignKey && $0.change != .dropped }.map { "ADD " + $0.definition }
            if table.status == .onlyInSource, let create = table.sourceDDL.flatMap(ReconCreateTable.init) {
                keys = create.foreignKeys.map { "ADD " + $0 }
            }
            steps += alter(table, keys)
        }
        for object in others where object.kind != .view && [.onlyInSource, .different].contains(object.status) {
            guard let create = create(object) else { continue }
            let resets = object.kind == .sequence && object.status == .different
            steps.append(step(.structure, object, create, destructive: resets ? "replaces the sequence, which starts again" : nil))
        }
        for table in tables.reversed() where table.status == .onlyInTarget {
            steps.append(step(.structure, table, "DROP TABLE " + q(table.targetName), destructive: "drops the table and its rows"))
        }
        for table in tables.reversed() {
            steps += deletes(table)
        }
        for table in tables {
            steps += updates(table) + inserts(table)
        }
        return steps
    }

    func q(_ name: String) -> String { SQLQuote.identifier(name) }

    func step(_ kind: ReconStep.Kind, _ object: ReconObject, _ sql: String, destructive: String? = nil,
                      rows: Int? = nil) -> ReconStep {
        ReconStep(kind: kind, sql: destructive.map { "-- Destructive: \($0)\n" + sql } ?? sql, destructive: destructive != nil,
                  objectKind: object.kind, object: object.name, expectedRows: rows)
    }

    private func alter(_ table: ReconObject, _ clauses: [String], destructive: String? = nil) -> [ReconStep] {
        guard !clauses.isEmpty else { return [] }
        return [step(.structure, table, "ALTER TABLE " + q(table.targetName) + "\n  " + clauses.joined(separator: ",\n  "),
                     destructive: destructive)]
    }

    /// ALTER TABLE clauses that keep everything the target has: new and changed (dropped, then added again) columns,
    /// keys and checks, widened columns, table options. Foreign keys come in their own steps.
    private func safeClauses(_ part: ReconPart) -> [String] {
        switch (part.kind, part.change) {
        case (.column, .added): return ["ADD COLUMN \(part.definition) " + (part.after.map { "AFTER " + q($0) } ?? "FIRST")]
        case (.column, .changed): return part.narrowing ? [] : ["MODIFY COLUMN \(part.definition)"]
        case (.index, .added): return ["ADD \(part.definition)"]
        case (.index, .changed): return [dropIndex(part.name), "ADD \(part.definition)"]
        case (.check, .added): return ["ADD \(part.definition)"]
        case (.check, .changed): return [dropCheck(part.name), "ADD \(part.definition)"]
        case (.options, _): return part.definition.isEmpty ? [] : [part.definition]
        default: return []
        }
    }

    /// ALTER TABLE clauses that lose something only the target has: columns, keys and checks it alone has, and
    /// narrowing column changes.
    private func destructiveClauses(_ part: ReconPart) -> [String] {
        switch (part.kind, part.change) {
        case (.column, .dropped): return ["DROP COLUMN " + q(part.name)]
        case (.column, .changed): return part.narrowing ? ["MODIFY COLUMN \(part.definition)"] : []
        case (.index, .dropped): return [dropIndex(part.name)]
        case (.check, .dropped): return [dropCheck(part.name)]
        default: return []
        }
    }

    private func dropIndex(_ name: String) -> String { name == "PRIMARY" ? "DROP PRIMARY KEY" : "DROP INDEX " + q(name) }

    /// MySQL 8.0.16 to 8.0.18 know only DROP CHECK; MariaDB only DROP CONSTRAINT.
    private func dropCheck(_ name: String) -> String { (result.target.isMariaDB ? "DROP CONSTRAINT " : "DROP CHECK ") + q(name) }

    private func drop(_ object: ReconObject) -> String {
        let what: String
        switch object.kind {
        case .table: return "DROP TABLE " + q(object.targetName)
        case .view: what = "VIEW"
        case .sequence: what = "SEQUENCE"
        case .procedure: what = "PROCEDURE"
        case .function: what = "FUNCTION"
        case .trigger: what = "TRIGGER"
        case .event: what = "EVENT"
        }
        return "DROP \(what) IF EXISTS " + q(object.targetName)
    }

    /// The source's CREATE statement for the target: without DEFINER when that's ignored, the source database's
    /// qualifier replaced by the target's; views and sequences as CREATE OR REPLACE.
    private func create(_ object: ReconObject) -> String? {
        guard var text = object.sourceDDL, !text.isEmpty else { return nil }
        if ignoreDefiner { text = ReconNormal.definerRemoved(text) }
        text = ReconNormal.qualifiersMapped(text, from: result.source.database, to: result.target.database)
        if object.kind == .view || object.kind == .sequence, text.hasPrefix("CREATE ") {
            text = "CREATE OR REPLACE " + text.dropFirst(7)
        }
        return text
    }

    /// New and changed views, each after the views its body names.
    private func viewsInOrder(_ objects: [ReconObject]) -> [ReconObject] {
        let views = objects.filter { $0.kind == .view && [.onlyInSource, .different].contains($0.status) }
        return topological(views) { view in
            views.filter { $0.name != view.name && view.sourceDDL?.contains(q($0.name)) == true }.map(\.name)
        }
    }

    /// Tables with each one after the tables its foreign keys point at.
    private func ordered(_ tables: [ReconObject]) -> [ReconObject] {
        topological(tables) { $0.references }
    }

    private func topological(_ objects: [ReconObject], after: (ReconObject) -> [String]) -> [ReconObject] {
        var done = Set<String>(), visiting = Set<String>(), result: [ReconObject] = []
        func visit(_ object: ReconObject) {
            guard !done.contains(object.name), !visiting.contains(object.name) else { return } // a cycle: keep going
            visiting.insert(object.name)
            for name in after(object) {
                if let other = objects.first(where: { $0.name == name }) { visit(other) }
            }
            visiting.remove(object.name)
            done.insert(object.name)
            result.append(object)
        }
        objects.forEach(visit)
        return result
    }
}
