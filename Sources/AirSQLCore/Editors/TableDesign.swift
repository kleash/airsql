import Foundation

// The table editor's model (scope: "Table and object editors"): a table as the person edits it. It starts as what the
// server has (`TableDesign(_:options:columnChecks:server:)`) or as a new table, and `statements(database:from:server:)`
// (TableSQL.swift) compares it with where it started to write the ALTER TABLE, or the CREATE TABLE, that makes it so.
// Each part keeps its name on the server (`original`, nil for a new one), so a rename is a rename, not a drop and an add.

public struct TableDesign: Hashable {
    public var name: String
    public var columns: [ColumnDesign] = []
    public var indexes: [IndexDesign] = []
    public var foreignKeys: [ForeignKeyDesign] = []
    /// Table checks. MariaDB's column checks are the columns' (`ColumnDesign.check`).
    public var checks: [CheckDesign] = []
    public var options = TableOptions()

    public init(name: String) { self.name = name }

    /// What the server has: the cached table, its options, and on MariaDB the names of its column checks (a check
    /// written in a column's definition belongs to the column there: MODIFY without it would drop it). Without those
    /// names, a check named after a column is that column's.
    public init(_ table: SchemaTable, options: TableOptions, columnChecks: Set<String>? = nil, server: SchemaServer) {
        name = table.name
        self.options = options
        let columnChecks = columnChecks ?? Set(table.columns.map(\.name))
        let ownChecks = server.flavour == .mariadb
            ? Dictionary(table.checks.filter { columnChecks.contains($0.name) }.map { ($0.name, $0.clause) }) { first, _ in first }
            : [:]
        columns = table.columns.map { ColumnDesign($0, check: ownChecks[$0.name], server: server) }
        // On MEMORY a BTREE index is a choice (HASH is its default); elsewhere it's what an index is.
        let memory = ["MEMORY", "HEAP"].contains(options.engine?.uppercased() ?? "")
        indexes = table.indexes.map { index in
            var design = IndexDesign(index)
            if memory, index.type.uppercased() == "BTREE" { design.algorithm = "BTREE" }
            return design
        }
        foreignKeys = table.foreignKeys.map(ForeignKeyDesign.init)
        checks = table.checks.filter { ownChecks[$0.name] == nil }.map(CheckDesign.init)
    }

    /// The columns renamed in this design: their names on the server, and now.
    public var renamedColumns: [String: String] {
        var renamed: [String: String] = [:]
        for column in columns { if let original = column.original, original != column.name { renamed[original] = column.name } }
        return renamed
    }

    /// The original's index (or key) with its columns under their new names, to compare with this design's: the server
    /// renames a column in its keys by itself.
    public func renamingColumns(of index: IndexDesign) -> IndexDesign {
        let renamed = renamedColumns
        var index = index
        index.parts = index.parts.map { part in
            var part = part
            part.column = part.column.map { renamed[$0] ?? $0 }
            return part
        }
        return index
    }

    public func renamingColumns(of key: ForeignKeyDesign) -> ForeignKeyDesign {
        let renamed = renamedColumns
        var key = key
        key.columns = key.columns.map { renamed[$0] ?? $0 }
        return key
    }

    /// Renames a column, and its mentions in keys (not in check or generated expressions, which are SQL: the server
    /// refuses the rename when one of those needs it).
    public mutating func renameColumn(at index: Int, to name: String) {
        let old = columns[index].name
        columns[index].name = name
        for key in indexes.indices {
            for part in indexes[key].parts.indices where indexes[key].parts[part].column == old {
                indexes[key].parts[part].column = name
            }
        }
        for key in foreignKeys.indices {
            foreignKeys[key].columns = foreignKeys[key].columns.map { $0 == old ? name : $0 }
        }
    }

    /// Removes a column, and the keys it was in: from an index (the index goes with its last column, as on the server)
    /// and every foreign key that uses it.
    public mutating func removeColumn(at index: Int) {
        let name = columns.remove(at: index).name
        for key in indexes.indices { indexes[key].parts.removeAll { $0.column == name } }
        indexes.removeAll { $0.parts.isEmpty }
        foreignKeys.removeAll { $0.columns.contains(name) }
    }
}

public struct ColumnDesign: Hashable {
    /// Its name on the server; nil for a new column.
    public var original: String?
    public var name: String
    public var type: TypeSpec
    public var nullable = true
    public var defaultValue = SchemaDefault.none
    public var autoIncrement = false
    /// ON UPDATE CURRENT_TIMESTAMP, with its precision.
    public var onUpdate: String?
    public var generated: SchemaColumn.Generated?
    public var invisible = false
    public var charset: String?
    public var collation: String?
    public var comment = ""
    /// MariaDB: the CHECK written in the column's definition, as SQL.
    public var check: String?

    public init(name: String, type: TypeSpec) {
        self.name = name
        self.type = type
    }

    init(_ column: SchemaColumn, check: String?, server: SchemaServer) {
        original = column.name
        name = column.name
        type = TypeSpec(columnType: column.columnType)
        nullable = column.nullable
        defaultValue = column.defaultValue
        autoIncrement = column.autoIncrement
        onUpdate = column.onUpdate
        generated = column.generated
        invisible = column.invisible
        charset = column.charset
        collation = column.collation
        comment = column.comment
        self.check = check
        // MariaDB's JSON is LONGTEXT with a json_valid check and a binary collation, all of which JSON gives again.
        if server.flavour == .mariadb, column.isJSON, type.name == "longtext",
           check == "json_valid(" + SQLQuote.identifier(column.name) + ")" {
            type = TypeSpec(name: "json")
            self.check = nil
            charset = nil
            collation = nil
        }
    }

    /// The column's type as the editor offers it (nil for one it doesn't know).
    public var columnType: EditorColumnType? { ColumnTypes.type(type.name) }
}

public struct IndexDesign: Hashable {
    public enum Kind: String, CaseIterable {
        case primary, unique, index, fulltext, spatial, vector

        /// As the Indexes tab names it.
        public var title: String {
            switch self {
            case .primary: return "PRIMARY"
            case .unique: return "UNIQUE"
            case .index: return "INDEX"
            case .fulltext: return "FULLTEXT"
            case .spatial: return "SPATIAL"
            case .vector: return "VECTOR"
            }
        }
    }

    public struct Part: Hashable {
        /// nil for a functional key part (MySQL 8.0.13+), whose SQL is `expression`.
        public var column: String?
        public var expression: String?
        public var prefixLength: Int?
        public var descending = false

        public init(column: String?, expression: String? = nil, prefixLength: Int? = nil, descending: Bool = false) {
            self.column = column
            self.expression = expression
            self.prefixLength = prefixLength
            self.descending = descending
        }
    }

    /// Its name on the server; nil for a new index.
    public var original: String?
    /// PRIMARY for the primary key.
    public var name: String
    public var kind: Kind
    public var parts: [Part]
    public var comment = ""
    /// False for MySQL's INVISIBLE and MariaDB's IGNORED indexes.
    public var visible = true
    /// USING BTREE or HASH; nil leaves it to the engine.
    public var algorithm: String?

    public init(name: String, kind: Kind, parts: [Part]) {
        self.name = name
        self.kind = kind
        self.parts = parts
    }

    init(_ index: SchemaIndex) {
        original = index.name
        name = index.name
        switch index.type.uppercased() {
        case _ where index.isPrimary: kind = .primary
        case "FULLTEXT": kind = .fulltext
        case "SPATIAL", "RTREE": kind = .spatial
        case "VECTOR": kind = .vector
        default: kind = index.unique ? .unique : .index
        }
        parts = index.parts.map { Part(column: $0.column, expression: $0.expression, prefixLength: $0.prefixLength,
                                       descending: $0.descending) }
        comment = index.comment
        visible = index.visible
        if index.type.uppercased() == "HASH" { algorithm = "HASH" }
    }

    /// Only these kinds of index can say how they are stored.
    public var takesAlgorithm: Bool { [.primary, .unique, .index].contains(kind) }

    /// The choices of USING, with what stands for none first.
    public static let algorithms = ["", "BTREE", "HASH"]
}

public struct ForeignKeyDesign: Hashable {
    /// What a foreign key does when the row it points at changes or goes.
    public static let rules = ["RESTRICT", "CASCADE", "SET NULL", "NO ACTION", "SET DEFAULT"]

    /// Its name on the server; nil for a new key.
    public var original: String?
    public var name: String
    public var columns: [String]
    public var referencedDatabase: String
    public var referencedTable: String
    public var referencedColumns: [String]
    public var onUpdate = "RESTRICT"
    public var onDelete = "RESTRICT"

    public init(name: String, columns: [String], referencedDatabase: String, referencedTable: String,
                referencedColumns: [String]) {
        self.name = name
        self.columns = columns
        self.referencedDatabase = referencedDatabase
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
    }

    init(_ key: SchemaForeignKey) {
        self.init(name: key.name, columns: key.columns, referencedDatabase: key.referencedDatabase,
                  referencedTable: key.referencedTable, referencedColumns: key.referencedColumns)
        original = key.name
        onUpdate = key.onUpdate
        onDelete = key.onDelete
    }
}

public struct CheckDesign: Hashable {
    /// Its name on the server; nil for a new check.
    public var original: String?
    public var name: String
    /// The condition as SQL.
    public var clause: String
    /// MySQL only: false for NOT ENFORCED.
    public var enforced = true

    public init(name: String, clause: String) {
        self.name = name
        self.clause = clause
    }

    init(_ check: SchemaCheck) {
        self.init(name: check.name, clause: check.clause)
        original = check.name
        enforced = check.enforced
    }
}

/// The options of a table: nil (and empty) leave the server's default.
public struct TableOptions: Hashable {
    public var engine: String?
    /// The default collation of new columns; the character set is the collation's.
    public var collation: String?
    public var comment = ""
    /// The next AUTO_INCREMENT value.
    public var autoIncrement: UInt64?
    public var rowFormat: String?
    /// The PARTITION BY clause as SQL; nil for a table without partitions.
    public var partitioning: String?

    public init(engine: String? = nil, collation: String? = nil, comment: String = "", autoIncrement: UInt64? = nil,
                rowFormat: String? = nil) {
        self.engine = engine
        self.collation = collation
        self.comment = comment
        self.autoIncrement = autoIncrement
        self.rowFormat = rowFormat
    }

    /// The row formats a table can have.
    public static let rowFormats = ["DEFAULT", "DYNAMIC", "COMPACT", "REDUNDANT", "COMPRESSED", "FIXED", "PAGE"]
}

extension SchemaColumn.Generated {
    /// A generated column's expression for a design (the editor makes them).
    public init(_ expression: String, stored: Bool) {
        self.expression = expression
        self.stored = stored
    }
}
