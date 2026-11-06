import CryptoKit
import Foundation

// What the schema cache holds for a connection: names of every database the connection's filter allows, the details of
// tables (columns, indexes, foreign keys, checks) where they are loaded, and statistics for the databases being viewed.
// Plain values: a snapshot can be read on any thread and kept. Names are as the server returns them; arrays are sorted
// by name (columns, index parts and key columns in their own order), so equal schemas give equal snapshots and hashes.
// What a database's hash covers is Codable (the hash is of its JSON).

/// The server a schema was read from: MySQL and MariaDB, and their versions, show information_schema differently.
public struct SchemaServer: Hashable {
    public typealias Flavour = ServerInfo.Flavor

    public var flavour: Flavour
    /// Major, minor and patch, such as [11, 8, 9].
    public var version: [Int]
    /// `VERSION()`, such as "11.8.9-MariaDB-ubu2404" or "8.4.13".
    public var versionString: String
    /// `@@lower_case_table_names`: 0 means database and table names are case-sensitive.
    public var lowerCaseTableNames: Int
    /// The session's sql_mode has NO_BACKSLASH_ESCAPES, so a backslash in a string literal is just a backslash.
    public var noBackslashEscapes: Bool

    /// MySQL before 8.0.16 parses CHECK and ignores it.
    public var keepsChecks: Bool { flavour != .mysql || atLeast(8, 0, 16) }

    public init(version: String, lowerCaseTableNames: Int = 0, sqlMode: String = "") {
        versionString = version
        // A MariaDB behind a replication-compatible handshake may say "5.5.5-10.5.29-MariaDB".
        let text = version.hasPrefix("5.5.5-") && version.contains("MariaDB") ? String(version.dropFirst(6)) : version
        flavour = text.range(of: "MariaDB", options: .caseInsensitive) != nil ? .mariadb : .mysql
        self.version = text.prefix { $0.isNumber || $0 == "." }.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
        self.lowerCaseTableNames = lowerCaseTableNames
        noBackslashEscapes = sqlMode.uppercased().split(separator: ",").contains("NO_BACKSLASH_ESCAPES")
    }

    /// The server is this version or later (of its own flavour).
    public func atLeast(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) -> Bool {
        let own = version + Array(repeating: 0, count: max(0, 3 - version.count))
        return !own.lexicographicallyPrecedes([major, minor, patch])
    }

    /// It can keep an index from queries: MySQL 8's INVISIBLE, MariaDB 10.6's IGNORED.
    public var hidesIndexes: Bool { flavour == .mysql ? atLeast(8) : atLeast(10, 6) }

    /// Database, table and trigger names compare without case (`lower_case_table_names` 1 or 2).
    var caselessNames: Bool { lowerCaseTableNames != 0 }
}

/// A database (schema) and the objects in it.
public struct SchemaDatabase: Hashable {
    public var name: String
    public var charset: String
    public var collation: String
    /// Tables, views and sequences.
    public var tables: [SchemaTable] = []
    public var routines: [SchemaRoutine] = []
    public var triggers: [SchemaTrigger] = []
    public var events: [SchemaEvent] = []
    /// Columns, indexes, foreign keys and checks are loaded for every table.
    public var detailsLoaded = false
    /// Rows, sizes and dates by table name, once loaded for this database (`SchemaCache.loadStatistics`).
    public var statistics: [String: TableStatistics]?
    /// Changes when the structure changes: names, and the details once loaded. Statistics are left out.
    public var hash = ""

    public init(name: String, charset: String, collation: String) {
        self.name = name
        self.charset = charset
        self.collation = collation
    }

    public func table(_ name: String) -> SchemaTable? { tables.first { $0.name == name } }
}

/// A table, view or sequence. Its details are empty until its database's details are loaded.
public struct SchemaTable: Hashable, Codable {
    public enum Kind: String, Codable {
        case table, view
        /// A MariaDB sequence: listed, but not edited as a table.
        case sequence
    }

    public var name: String
    public var kind: Kind
    /// InnoDB, MyISAM, Aria, MEMORY…; nil for views.
    public var engine: String?
    public var comment: String
    /// A MariaDB system-versioned table (`WITH SYSTEM VERSIONING`).
    public var systemVersioned = false
    public var columns: [SchemaColumn] = []
    public var indexes: [SchemaIndex] = []
    public var foreignKeys: [SchemaForeignKey] = []
    public var checks: [SchemaCheck] = []

    public init(name: String, kind: Kind, engine: String? = nil, comment: String = "") {
        self.name = name
        self.kind = kind
        self.engine = engine
        self.comment = comment
    }

    public var primaryKey: SchemaIndex? { indexes.first { $0.isPrimary } }
    public func column(_ name: String) -> SchemaColumn? {
        columns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// A column's default, the same way for MySQL and MariaDB (which show defaults differently).
public enum SchemaDefault: Hashable, Codable {
    /// No default: an INSERT must give a value (unless the column is auto-increment or generated).
    case none
    /// DEFAULT NULL.
    case null
    /// A constant, as text: the string itself for strings (unquoted), "0.00" for numbers, "2020-01-02" for dates.
    case value(String)
    /// SQL to use as it is: CURRENT_TIMESTAMP, uuid(), b'101', 0x6162 (MariaDB: x'6162').
    case expression(String)
}

public struct SchemaColumn: Hashable, Codable {
    public struct Generated: Hashable, Codable {
        /// The expression as SQL, such as "upper(`name`)".
        public var expression: String
        /// STORED (MariaDB: PERSISTENT), else VIRTUAL.
        public var stored: Bool
    }

    public var name: String
    /// `DATA_TYPE`, such as "int", "varchar", "json" (MariaDB's JSON is "longtext": see `isJSON`).
    public var dataType: String
    /// `COLUMN_TYPE`, such as "int(10) unsigned" or "enum('a','b')".
    public var columnType: String
    public var nullable: Bool
    public var defaultValue: SchemaDefault
    public var autoIncrement: Bool
    /// ON UPDATE, such as "CURRENT_TIMESTAMP(3)" (MariaDB: "current_timestamp(3)").
    public var onUpdate: String?
    public var generated: Generated?
    /// Left out of `SELECT *` (MySQL 8.0.23+, MariaDB 10.3+).
    public var invisible: Bool
    /// JSON: MySQL's JSON type, or MariaDB's LONGTEXT with its `json_valid` check.
    public var isJSON: Bool
    public var charset: String?
    public var collation: String?
    public var comment: String
}

public struct SchemaIndex: Hashable, Codable {
    public struct Part: Hashable, Codable {
        /// nil for a functional key part (MySQL 8.0.13+): see `expression`.
        public var column: String?
        public var expression: String?
        /// The prefix length, as in `name(10)`.
        public var prefixLength: Int?
        public var descending: Bool
    }

    public var name: String
    public var unique: Bool
    /// `INDEX_TYPE`: BTREE, HASH, FULLTEXT, SPATIAL, RTREE, VECTOR.
    public var type: String
    public var parts: [Part]
    /// False for MySQL's INVISIBLE and MariaDB's IGNORED indexes.
    public var visible: Bool
    public var comment: String

    public var isPrimary: Bool { name == "PRIMARY" }
}

public struct SchemaForeignKey: Hashable, Codable {
    public var name: String
    public var columns: [String]
    public var referencedDatabase: String
    public var referencedTable: String
    public var referencedColumns: [String]
    /// RESTRICT, CASCADE, SET NULL, NO ACTION or SET DEFAULT.
    public var onUpdate: String
    public var onDelete: String

    public init(name: String, columns: [String], referencedDatabase: String, referencedTable: String, referencedColumns: [String],
                onUpdate: String, onDelete: String) {
        self.name = name
        self.columns = columns
        self.referencedDatabase = referencedDatabase
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }
}

/// A check constraint. MariaDB names a column's own check after the column (and its JSON columns have one); MySQL names
/// them `<table>_chk_<n>`.
public struct SchemaCheck: Hashable, Codable {
    public var name: String
    /// The condition as SQL, such as "`total` >= 0".
    public var clause: String
    /// False for MySQL's NOT ENFORCED checks.
    public var enforced: Bool
}

public struct SchemaRoutine: Hashable, Codable {
    public enum Kind: String, Codable { case procedure, function }

    public var name: String
    public var kind: Kind
    /// A function's return type, such as "int(11)".
    public var returns: String?
    public var comment: String
}

public struct SchemaTrigger: Hashable, Codable {
    public var name: String
    public var table: String
    /// BEFORE or AFTER.
    public var timing: String
    /// INSERT, UPDATE or DELETE.
    public var event: String
    /// Its place among the table's triggers for the same timing and event.
    public var order: Int
}

public struct SchemaEvent: Hashable, Codable {
    public var name: String
    /// ENABLED, DISABLED, or disabled on a replica (SLAVESIDE_DISABLED, REPLICA_SIDE_DISABLED).
    public var status: String
    public var comment: String
}

/// What the database view shows of a table. Read for one database at a time: on MariaDB and MySQL 5.7 it opens every
/// table of that database.
public struct TableStatistics: Hashable {
    /// An estimate for InnoDB.
    public var rows: Int?
    public var dataLength: Int?
    public var indexLength: Int?
    public var dataFree: Int?
    public var autoIncrement: UInt64?
    /// As the server shows them, such as "2026-11-03 01:23:45".
    public var createTime: String?
    public var updateTime: String?
    public var collation: String?
    public var rowFormat: String?
    public var createOptions: String?
}

/// Everything the cache holds at one moment.
public struct SchemaSnapshot: Hashable {
    /// nil until the first load.
    public var server: SchemaServer?
    public var databases: [SchemaDatabase] = []
    /// The server had no more tables than the threshold, so every database's details loaded with the names; else
    /// they load per database on demand (`SchemaCache.loadDetails`).
    public var detailsUpfront = false
    /// Changes when anything in the structure of any database changes.
    public var hash = ""

    public init() {}

    /// The database of that name; on a server whose names have no case (`lower_case_table_names` 1 or 2), in any case.
    public func database(_ name: String) -> SchemaDatabase? {
        databases.first { $0.name == name }
            ?? databases.first { server?.caselessNames == true && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The table, view or sequence of that name, matched as `database(_:)` matches databases.
    public func table(_ database: String, _ name: String) -> SchemaTable? {
        guard let tables = self.database(database)?.tables else { return nil }
        return tables.first { $0.name == name }
            ?? tables.first { server?.caselessNames == true && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public var tableCount: Int { databases.reduce(0) { $0 + $1.tables.count } }
}

/// Short hashes of schema content: the first 8 bytes of a SHA-256, in hex.
enum SchemaHash {
    /// What a database's hash covers: its structure, not its statistics.
    private struct Content: Encodable {
        let name: String, charset: String, collation: String
        let tables: [SchemaTable], routines: [SchemaRoutine], triggers: [SchemaTrigger], events: [SchemaEvent]
        let detailsLoaded: Bool
    }

    static func of(_ database: SchemaDatabase) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let content = Content(name: database.name, charset: database.charset, collation: database.collation,
                              tables: database.tables, routines: database.routines, triggers: database.triggers,
                              events: database.events, detailsLoaded: database.detailsLoaded)
        // Encoding plain structs of strings, numbers and arrays can't fail.
        return hex(SHA256.hash(data: (try? encoder.encode(content)) ?? Data()))
    }

    static func of(_ databases: [SchemaDatabase]) -> String {
        var hasher = SHA256()
        for database in databases {
            hasher.update(data: Data(database.name.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(database.hash.utf8))
            hasher.update(data: Data([0]))
        }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
