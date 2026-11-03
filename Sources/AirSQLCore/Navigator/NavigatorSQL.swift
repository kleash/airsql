import Foundation

/// An object in the navigator's tree that its commands act on: a table, view or sequence, a routine, a trigger or an
/// event, in its database.
public struct DatabaseObject: Hashable {
    public enum Kind: String, CaseIterable {
        case table, view, sequence, procedure, function, trigger, event

        /// The word SQL uses for it (DROP VIEW, SHOW CREATE PROCEDURE).
        public var keyword: String { rawValue.uppercased() }
        /// Tables, views and sequences share their names and RENAME TABLE.
        public var isTableLike: Bool { self == .table || self == .view || self == .sequence }
    }

    public var kind: Kind
    public var database: String
    public var name: String

    public init(_ kind: Kind, _ database: String, _ name: String) {
        self.kind = kind
        self.database = database
        self.name = name
    }

    /// `shop`.`orders`.
    public var quoted: String { SQLQuote.identifier(database, name) }

    /// What the schema cache reads again after DDL on it.
    public var schemaObject: SchemaObject {
        switch kind {
        case .table, .view, .sequence: return .table(database: database, name: name)
        case .procedure, .function: return .routine(database: database, name: name)
        case .trigger: return .trigger(database: database, name: name)
        case .event: return .event(database: database, name: name)
        }
    }
}

/// The table maintenance statements (scope "nav": optimize, check, analyze, repair, checksum).
public enum Maintenance: String, CaseIterable {
    case analyze, check, optimize, repair, checksum

    public var title: String { rawValue.capitalized }
    /// OPTIMIZE and REPAIR rebuild tables and ANALYZE writes their statistics: they show their SQL before they run.
    public var changesTables: Bool { self != .check && self != .checksum }
}

/// The statements the navigator runs (plan §2.7, scope "nav"). Names and values only go into SQL through `SQLQuote`;
/// a WHERE condition the person typed (Copy Table) is theirs and is shown in the SQL preview before it runs.
public enum NavigatorSQL {
    public static func createDatabase(_ name: String, charset: String?, collation: String?) -> String {
        var sql = "CREATE DATABASE " + SQLQuote.identifier(name)
        if let charset, !charset.isEmpty { sql += " CHARACTER SET " + SQLQuote.identifier(charset) }
        if let collation, !collation.isEmpty { sql += " COLLATE " + SQLQuote.identifier(collation) }
        return sql
    }

    public static func dropDatabase(_ name: String) -> String { "DROP DATABASE " + SQLQuote.identifier(name) }

    /// Renames a table, view or sequence in its database.
    public static func rename(_ object: DatabaseObject, to name: String) -> String {
        "RENAME TABLE \(object.quoted) TO " + SQLQuote.identifier(object.database, name)
    }

    /// One TRUNCATE per table (it takes one).
    public static func truncate(_ tables: [DatabaseObject]) -> [String] {
        tables.map { "TRUNCATE TABLE " + $0.quoted }
    }

    /// Drops the objects: triggers and events first, then routines, views, sequences and last the tables, all the
    /// tables in one statement so foreign keys between them don't stop it.
    public static func drop(_ objects: [DatabaseObject]) -> [String] {
        let order: [DatabaseObject.Kind] = [.trigger, .event, .procedure, .function, .view, .sequence, .table]
        var statements: [String] = []
        for kind in order {
            let ofKind = objects.filter { $0.kind == kind }
            guard !ofKind.isEmpty else { continue }
            if kind.isTableLike {
                statements.append("DROP \(kind.keyword) " + ofKind.map(\.quoted).joined(separator: ", "))
            } else {
                statements += ofKind.map { "DROP \(kind.keyword) " + $0.quoted }
            }
        }
        return statements
    }

    /// A copy of `table` named `name` in `database`: its definition (CREATE TABLE … LIKE keeps columns, indexes and
    /// options but not foreign keys), then, given `columns` (the ones that aren't generated), its rows where `condition`
    /// holds.
    public static func copyTable(_ table: DatabaseObject, to database: String, name: String, columns: [String]?,
                                 where condition: String?) -> [String] {
        let target = SQLQuote.identifier(database, name)
        var statements = ["CREATE TABLE \(target) LIKE \(table.quoted)"]
        if let columns, !columns.isEmpty {
            let list = columns.map { SQLQuote.identifier($0) }.joined(separator: ", ")
            var insert = "INSERT INTO \(target) (\(list)) SELECT \(list) FROM \(table.quoted)"
            if let condition = condition?.trimmingCharacters(in: .whitespacesAndNewlines), !condition.isEmpty {
                insert += " WHERE " + condition
            }
            statements.append(insert)
        }
        return statements
    }

    /// Moves tables to another database, in one statement.
    public static func move(_ tables: [DatabaseObject], to database: String) -> String {
        "RENAME TABLE " + tables.map { "\($0.quoted) TO " + SQLQuote.identifier(database, $0.name) }.joined(separator: ", ")
    }

    public static func changeEngine(_ table: DatabaseObject, to engine: String) -> String {
        "ALTER TABLE \(table.quoted) ENGINE = " + SQLQuote.identifier(engine)
    }

    /// Converts the table and its text columns to a character set and collation.
    public static func convert(_ table: DatabaseObject, charset: String, collation: String) -> String {
        "ALTER TABLE \(table.quoted) CONVERT TO CHARACTER SET \(SQLQuote.identifier(charset)) COLLATE "
            + SQLQuote.identifier(collation)
    }

    /// One statement for all the tables (`ANALYZE TABLE a, b`).
    public static func maintenance(_ operation: Maintenance, _ tables: [DatabaseObject]) -> String {
        operation.rawValue.uppercased() + " TABLE " + tables.map(\.quoted).joined(separator: ", ")
    }

    /// The statement that shows how the object is made: its second column (or a routine's or trigger's third) holds it.
    public static func showCreate(_ object: DatabaseObject) -> String {
        "SHOW CREATE \(object.kind.keyword) " + object.quoted
    }

    /// What New Database and the bulk editor offer: the server's character sets (name, description, default collation),
    /// collations (name, character set), its own character set and collation, and its storage engines (name, support).
    public static let characterSets = "SHOW CHARACTER SET"
    public static let collations = "SHOW COLLATION"
    public static let serverCharset = "SELECT @@character_set_server, @@collation_server"
    public static let engines = "SHOW ENGINES"
}
