import Foundation

/// A database's objects as SHOW CREATE gives them, for a changelog of a whole schema or of the objects picked (Tools ▸
/// Generate Liquibase Changelog…).
public struct LiquibaseSchema: Equatable {
    /// DDL, DML, or both.
    public enum Content: String, Codable, CaseIterable { case structure, data, both }

    public struct Object: Equatable {
        public enum Kind: String, CaseIterable { case sequence, table, view, function, procedure, trigger, event }

        public var kind: Kind
        public var name: String
        /// SHOW CREATE …'s statement; empty when this login can't read it.
        public var create: String
        /// A table's: the tables of this database its foreign keys point at.
        public var references: [String] = []
        /// A table's rows: the columns written (generated ones are computed), the key they are read in order of (none:
        /// the server's order), and about how many there are.
        public var columns: [String] = []
        public var key: [String] = []
        public var rows: Int64 = 0

        public init(kind: Kind, name: String, create: String, references: [String] = []) {
            self.kind = kind
            self.name = name
            self.create = create
            self.references = references
        }
    }

    public var database: String
    public var objects: [Object]

    public init(database: String, objects: [Object]) {
        self.database = database
        self.objects = objects
    }

    /// A changelog's parts in an order that runs cleanly: sequences, tables without their foreign keys, the tables'
    /// rows (before foreign keys and triggers, so neither gets in the way), foreign keys, functions and procedures,
    /// views (each after the views it reads), triggers, events. `rows` are the tables whose rows are written; objects
    /// this login can't read are left out.
    public func pieces(_ content: Content, rows: Set<String>, settings: LiquibaseSettings,
                       preconditions: Bool = false) -> [LiquibasePiece] {
        let readable = objects.filter { !$0.create.isEmpty }
        let tables = Self.ordered(readable.filter { $0.kind == .table }) { $0.references }
        let data = tables.filter { rows.contains($0.name) }.map { LiquibasePiece.rows(table: $0.name) }
        guard content != .data else { return data }
        var pieces: [LiquibasePiece] = []
        func add(_ object: Object, _ statement: String, drop: String?, check: String? = nil, runOnChange: Bool = false) {
            var changeset = LiquibaseChangeset(object: object.name, statements: [statement],
                                               rollback: settings.rollback ? drop.map { [$0] } ?? [] : [])
            changeset.runOnChange = runOnChange
            if preconditions { changeset.precondition = check }
            pieces.append(.changeset(changeset))
        }
        let q = SQLQuote.identifier, text = { SQLQuote.string($0) }
        for sequence in readable where sequence.kind == .sequence {
            add(sequence, sequence.create, drop: "DROP SEQUENCE " + q(sequence.name),
                check: Self.count("TABLES", "TABLE_SCHEMA", ["TABLE_NAME = " + text(sequence.name)]))
        }
        for table in tables {
            add(table, ReconCreateTable(table.create)?.withoutForeignKeys ?? table.create, drop: "DROP TABLE " + q(table.name),
                check: Self.count("TABLES", "TABLE_SCHEMA", ["TABLE_NAME = " + text(table.name)]))
        }
        if content == .both { pieces += data }
        for table in tables {
            for key in ReconCreateTable(table.create)?.lines.filter({ $0.kind == .foreignKey }) ?? [] {
                var changeset = LiquibaseChangeset(object: key.name, statements: ["ALTER TABLE \(q(table.name)) ADD \(key.text)"],
                                                   rollback: settings.rollback ? ["ALTER TABLE \(q(table.name)) DROP FOREIGN KEY \(q(key.name))"] : [])
                if preconditions {
                    changeset.precondition = Self.count("TABLE_CONSTRAINTS", "CONSTRAINT_SCHEMA", [
                        "TABLE_NAME = " + text(table.name), "CONSTRAINT_NAME = " + text(key.name), "CONSTRAINT_TYPE = 'FOREIGN KEY'"])
                }
                pieces.append(.changeset(changeset))
            }
        }
        let code = { (object: Object) in settings.stripDefiner ? ReconNormal.definerRemoved(object.create) : object.create }
        for routine in readable where routine.kind == .function || routine.kind == .procedure {
            let kind = routine.kind == .function ? "FUNCTION" : "PROCEDURE"
            add(routine, code(routine), drop: "DROP \(kind) " + q(routine.name),
                check: Self.count("ROUTINES", "ROUTINE_SCHEMA", ["ROUTINE_NAME = " + text(routine.name), "ROUTINE_TYPE = '\(kind)'"]))
        }
        let views = readable.filter { $0.kind == .view }
        for view in Self.ordered(views, after: { view in Self.names(in: view.create).filter { $0 != view.name }.sorted() }) {
            // Written as CREATE OR REPLACE and run again when its SQL changes: editing a view in the changelog replaces it.
            var create = code(view)
            if create.hasPrefix("CREATE ") { create = "CREATE OR REPLACE " + create.dropFirst(7) }
            add(view, create, drop: "DROP VIEW " + q(view.name), runOnChange: true)
        }
        for trigger in readable where trigger.kind == .trigger {
            add(trigger, code(trigger), drop: "DROP TRIGGER " + q(trigger.name),
                check: Self.count("TRIGGERS", "TRIGGER_SCHEMA", ["TRIGGER_NAME = " + text(trigger.name)]))
        }
        for event in readable where event.kind == .event {
            add(event, code(event), drop: "DROP EVENT " + q(event.name),
                check: Self.count("EVENTS", "EVENT_SCHEMA", ["EVENT_NAME = " + text(event.name)]))
        }
        return pieces
    }

    /// SELECT COUNT(*) of information_schema's `view` rows for the database Liquibase updates.
    static func count(_ view: String, _ schema: String, _ conditions: [String]) -> String {
        "SELECT COUNT(*) FROM information_schema.\(view) WHERE \(schema) = DATABASE() AND " + conditions.joined(separator: " AND ")
    }

    /// The names a definition holds in backticks (SHOW CREATE quotes every name), found with the lexer.
    static func names(in sql: String) -> Set<String> {
        let text = Array(sql.utf16)
        return Set(SQLLexer.tokens(sql).filter { $0.kind == .quotedName }.map {
            Liquibase.unquotedName(String(decoding: text[$0.range], as: UTF16.self))
        })
    }

    /// Objects with each after those `after` names (a cycle is broken where it closes).
    static func ordered(_ objects: [Object], after: (Object) -> [String]) -> [Object] {
        var done = Set<String>(), visiting = Set<String>(), result: [Object] = []
        func visit(_ object: Object) {
            guard !done.contains(object.name), !visiting.contains(object.name) else { return }
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

/// A part of a changelog: a changeset, or a table's rows, read from the server when the changelog is written.
public enum LiquibasePiece: Equatable {
    case changeset(LiquibaseChangeset)
    case rows(table: String)

    /// The {object} of its id.
    public var object: String {
        switch self {
        case .changeset(let changeset): return changeset.object
        case .rows(let table): return table
        }
    }
}
