import Foundation

// Compare and reconcile (plan §2.9, R6): what a compare looks at, and what it found. Plain values, so the compare
// window, the report export and the Liquibase writer (L8b) all read the same result.

/// What a compare looks at, and the noise it leaves out (the compare window's choices).
public struct ReconOptions: Equatable {
    public enum Mode: String, CaseIterable, Codable {
        case structure, data, both
    }

    public var mode: Mode = .both
    public var ignore = ReconIgnoreRules()
    /// By source table name: tables left out, compared with a renamed target table, columns left out, a WHERE.
    public var tables: [String: ReconTableChoice] = [:]
    /// Compare just this pair instead of the whole database.
    public var only: ReconPair?

    public init() {}

    public func choice(_ table: String) -> ReconTableChoice { tables[table] ?? ReconTableChoice() }
}

/// Two objects of one kind chosen by name: any names, in any two databases or in the same one.
public struct ReconPair: Equatable {
    public var kind: ReconObject.Kind
    public var source: String
    public var target: String

    public init(kind: ReconObject.Kind, source: String, target: String) {
        self.kind = kind
        self.source = source
        self.target = target
    }
}

/// Differences a compare doesn't count (scope: AUTO_INCREMENT values, DEFINER, default collation, whitespace).
public struct ReconIgnoreRules: Equatable, Codable {
    /// Tables' next AUTO_INCREMENT values.
    public var autoIncrement = true
    /// Who views, routines, triggers and events run as (DEFINER=…); the sync script then leaves DEFINER out.
    public var definer = true
    /// Character sets and collations of tables and columns (MySQL 8 and MariaDB name their defaults differently).
    public var collation = true
    /// Spaces, tabs and line breaks in view, routine, trigger and event bodies (outside quoted text).
    public var whitespace = true
    /// The order of a table's columns: only the columns themselves count.
    public var columnOrder = false
    /// Upper and lower case in view, routine, trigger and event definitions (outside quoted text).
    public var letterCase = false
    /// What views, routines, triggers and events say: only whether each exists counts.
    public var definitions = false

    public init() {}

    /// What is ignored, in plain words, for the window and the report.
    public var names: [String] {
        [autoIncrement ? "AUTO_INCREMENT" : nil, definer ? "DEFINER" : nil, collation ? "collations" : nil,
         whitespace ? "whitespace" : nil, columnOrder ? "column order" : nil, letterCase ? "letter case" : nil,
         definitions ? "definitions" : nil].compactMap { $0 }
    }
}

/// How one source table is compared.
public struct ReconTableChoice: Equatable, Codable {
    public var included = true
    /// The target table it is compared with, when it was renamed there; nil for the same name.
    public var target: String?
    /// Columns whose values aren't compared, such as updated_at.
    public var excludedColumns: [String] = []
    /// A WHERE condition (without the word WHERE) for both sides' rows; empty for every row.
    public var filter = ""

    public init(included: Bool = true, target: String? = nil, excludedColumns: [String] = [], filter: String = "") {
        self.included = included
        self.target = target
        self.excludedColumns = excludedColumns
        self.filter = filter
    }
}

/// One side of a finished compare: which connection and database it was.
public struct ReconEnd: Equatable {
    /// The connection's name, such as "Production".
    public var name: String
    public var database: String
    /// `VERSION()`, such as "8.4.13" or "11.8.9-MariaDB".
    public var version: String
    /// The session's sql_mode has NO_BACKSLASH_ESCAPES: the script's strings double quotes instead.
    public var noBackslashEscapes: Bool

    public init(name: String, database: String, version: String, noBackslashEscapes: Bool = false) {
        self.name = name
        self.database = database
        self.version = version
        self.noBackslashEscapes = noBackslashEscapes
    }

    public var isMariaDB: Bool { version.range(of: "MariaDB", options: .caseInsensitive) != nil }
}

/// What a compare found.
public struct ReconResult {
    public var source: ReconEnd
    public var target: ReconEnd
    public var options: ReconOptions
    /// Every object compared, in the order the compare window lists them.
    public var objects: [ReconObject]
    public var duration: TimeInterval = 0
    /// Rows the servers checksummed, and rows (or keys with their hashes) that came over the network.
    public var rowsChecked = 0
    public var rowsFetched = 0
    /// A server compare: each pair's own result by source database name; `objects` lists the pairs as `.database`.
    public var databases: [String: ReconResult] = [:]

    public init(source: ReconEnd, target: ReconEnd, options: ReconOptions, objects: [ReconObject] = []) {
        self.source = source
        self.target = target
        self.options = options
        self.objects = objects
    }

    public func object(_ kind: ReconObject.Kind, _ name: String) -> ReconObject? {
        objects.first { $0.kind == kind && $0.name == name }
    }

    /// Two whole servers: `objects` are database pairs, opened one at a time, and a script belongs to a pair.
    public var isServer: Bool { source.database.isEmpty }
}

/// A table, view, routine, trigger, event or sequence, and how it compares; in a server compare, a pair of databases.
public struct ReconObject: Equatable {
    public enum Kind: String, CaseIterable {
        case table, view, sequence, procedure, function, trigger, event, database
    }

    public enum Status: String {
        case same, different, onlyInSource, onlyInTarget
    }

    public var kind: Kind
    /// The name in the source (in the target when only there).
    public var name: String
    /// The name in the target: `name` unless the table was mapped to a renamed one.
    public var targetName: String
    /// How the structure compares.
    public var status: Status
    /// What differs in the structure, part by part (tables), or the whole definition (other objects).
    public var parts: [ReconPart] = []
    /// SHOW CREATE … on each side as the compare read it (ignored noise taken out), for the side-by-side view; nil where
    /// the object doesn't exist or wasn't read (tables whose structure matches).
    public var sourceDDL: String?
    public var targetDDL: String?
    /// The data compare of a table on both sides, when data was compared.
    public var data: ReconTableData?
    /// Tables of the same database this table's foreign keys point at (where it exists), for the script's order.
    public var references: [String] = []
    /// The target table's engine: MyISAM, Aria and MEMORY can't roll back a failed sync.
    public var targetEngine: String?
    /// The person unticked it: the sync script skips it.
    public var leftOut = false

    public init(kind: Kind, name: String, targetName: String? = nil, status: Status) {
        self.kind = kind
        self.name = name
        self.targetName = targetName ?? name
        self.status = status
    }

    /// Different in structure or in data.
    public var differs: Bool { status != .same || data?.differs == true }
}

/// One structural difference of a table, with the source's definition the sync script uses.
public struct ReconPart: Equatable {
    public enum Kind: String {
        case column, index, foreignKey, check, options
    }

    public enum Change: String {
        case added, changed, dropped
    }

    public var kind: Kind
    public var name: String
    public var change: Change
    /// The source's definition as SHOW CREATE TABLE writes it ("`currency` char(3) NOT NULL DEFAULT 'EUR'", "KEY `ix`
    /// (`a`)"), or table options ("ENGINE=InnoDB"); empty for drops.
    public var definition: String
    /// For an added or moved column: the source column it follows, nil for the first.
    public var after: String?
    /// In plain words: "type int → bigint", "added", "only in the target".
    public var detail: String
    /// A changed column whose new type may not hold every value it has now (a narrowing ALTER): destructive.
    public var narrowing = false
    /// A changed column that also has to move, after `after`.
    public var moved = false

    public init(kind: Kind, name: String, change: Change, definition: String = "", after: String? = nil,
                detail: String = "", narrowing: Bool = false) {
        self.kind = kind
        self.name = name
        self.change = change
        self.definition = definition
        self.after = after
        self.detail = detail
        self.narrowing = narrowing
    }
}

/// A table's data on both sides, matched row by row on a key.
public struct ReconTableData: Equatable {
    public enum Outcome: Equatable {
        case same, different
        /// Rows couldn't be matched (no primary or NOT NULL unique key on both sides) but the whole-table checksums
        /// differ.
        case differentWithoutKey
        /// More rows differ than a compare lists (`ReconData.maxDifferences`): no sync statements for this table.
        case tooManyDifferences
        /// Not compared, and why ("no columns in common").
        case notCompared(String)
    }

    public var outcome: Outcome
    /// The key the rows were matched on, and every compared column (key first) with how its values are read.
    public var key: [String] = []
    public var columns: [ReconColumn] = []
    public var sourceRows = 0
    public var targetRows = 0
    /// Rows only in the source (INSERT), only in the target (DELETE), and in both with different values (UPDATE).
    public var missing: [ReconRow] = []
    public var extra: [ReconRow] = []
    public var changed: [ReconRowChange] = []

    public init(outcome: Outcome) { self.outcome = outcome }

    /// More differing rows than this and a table is reported as having too many to list.
    public static var maxDifferences: Int { ReconDataCompare.maxDifferences }

    public var differs: Bool {
        switch outcome {
        case .same, .notCompared: return false
        case .different, .differentWithoutKey, .tooManyDifferences: return true
        }
    }

    public var differenceCount: Int { missing.count + extra.count + changed.count }
}

/// A compared column: its name and how its values are hashed, compared and written.
public struct ReconColumn: Equatable {
    public enum Kind: String {
        case integer, decimal, float, bit, binary, blob, text, longText, json, temporal
    }

    public var name: String
    public var kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    /// The kind of a column from information_schema's DATA_TYPE.
    public init(_ column: SchemaColumn) {
        name = column.name
        kind = Self.kind(dataType: column.dataType, isJSON: column.isJSON)
    }

    static func kind(dataType: String, isJSON: Bool) -> Kind {
        if isJSON { return .json }
        switch dataType.lowercased() {
        case "tinyint", "smallint", "mediumint", "int", "integer", "bigint": return .integer
        case "decimal", "numeric": return .decimal
        case "float", "double", "real", "double precision": return .float
        case "bit": return .bit
        case "binary", "varbinary": return .binary
        case "tinyblob", "blob", "mediumblob", "longblob", "geometry", "point", "linestring", "polygon", "multipoint",
             "multilinestring", "multipolygon", "geometrycollection", "geomcollection", "vector":
            return .blob
        case "tinytext", "text", "mediumtext", "longtext", "json": return .longText
        case "date", "datetime", "timestamp", "time", "year": return .temporal
        default: return .text // char, varchar, enum, set, and MariaDB's uuid, inet4 and inet6
        }
    }
}

/// A row's values in the compared columns' order, as the server sent them; nil for NULL.
public struct ReconRow: Equatable {
    public var values: [[UInt8]?]

    public init(_ values: [[UInt8]?]) { self.values = values }

    /// A value as text (binary values as 0x… hex), nil for NULL.
    public func text(_ column: Int, kind: ReconColumn.Kind) -> String? {
        guard let bytes = values[column] else { return nil }
        switch kind {
        case .binary, .blob, .bit: return "0x" + bytes.map { String(format: "%02X", $0) }.joined()
        default: return String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// A row in both, with the columns (indexes into the compared columns) whose values differ.
public struct ReconRowChange: Equatable {
    public var source: ReconRow
    public var target: ReconRow
    public var columns: [Int]

    public init(source: ReconRow, target: ReconRow, columns: [Int]) {
        self.source = source
        self.target = target
        self.columns = columns
    }
}
