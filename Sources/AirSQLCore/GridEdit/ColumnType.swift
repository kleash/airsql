import Foundation

// The AppKit-free half of grid editing (grid-spec §5): what a typed or pasted value becomes in SQL, per column type and
// flavour. Values travel as text end to end (numbers and DECIMAL are never turned into Double); every literal is built
// with SQLQuote or from characters checked one by one, so nothing typed can end a literal early.

/// Why a value can't be saved as it is, in plain words for the cell's tooltip or the paste report.
public struct EditError: LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// What the data session decides about values: the server, its sql_mode (zero dates, invalid dates, backslashes) and
/// the time zone TIMESTAMP values are shown and typed in. Read once on the data session, after its startup SQL:
/// `SELECT @@SESSION.sql_mode, @@SESSION.time_zone`.
public struct EditContext: Equatable {
    public var flavour: SchemaServer.Flavour
    /// Major, minor and patch, such as [11, 4, 13].
    public var version: [Int]
    /// The session's sql_mode words, upper case.
    public var sqlMode: Set<String>
    /// `@@time_zone`: "SYSTEM", "+02:00" or a named zone.
    public var timeZone: String

    public init(flavour: SchemaServer.Flavour, version: [Int], sqlMode: String, timeZone: String = "SYSTEM") {
        self.flavour = flavour
        self.version = version
        self.sqlMode = Set(sqlMode.uppercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        self.timeZone = timeZone
    }

    public init(server: SchemaServer, sqlMode: String, timeZone: String = "SYSTEM") {
        self.init(flavour: server.flavour, version: server.version, sqlMode: sqlMode, timeZone: timeZone)
    }

    /// A backslash in a string literal is an ordinary character (as `SQLQuote.string` needs to know).
    public var noBackslashEscapes: Bool { sqlMode.contains("NO_BACKSLASH_ESCAPES") }
    /// STRICT_TRANS_TABLES or STRICT_ALL_TABLES: a value the column can't hold is an error, not a warning.
    var strict: Bool { sqlMode.contains("STRICT_TRANS_TABLES") || sqlMode.contains("STRICT_ALL_TABLES") }

    func atLeast(_ major: Int, _ minor: Int = 0) -> Bool {
        let own = version + Array(repeating: 0, count: max(0, 2 - version.count))
        return !own.lexicographicallyPrecedes([major, minor])
    }

    /// What the editor of a TIMESTAMP column says about the time zone.
    public var timeZoneNote: String {
        let zone = timeZone.uppercased() == "SYSTEM" ? "the server's own time zone" : timeZone
        return "Shown and saved in the session's time zone (\(zone)); the server keeps TIMESTAMP values in UTC"
    }
}

/// A column's type as editing sees it, read from information_schema's DATA_TYPE and COLUMN_TYPE.
public struct ColumnType: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// TINYINT … BIGINT: the size in bytes (1, 2, 3, 4 or 8).
        case integer(bytes: Int)
        case decimal(precision: Int, scale: Int)
        /// FLOAT (4 bytes) or DOUBLE (8).
        case float(bytes: Int)
        /// BIT(n), 1 to 64 bits.
        case bit(width: Int)
        case date
        /// TIME, DATETIME and TIMESTAMP: the digits kept after the seconds (0 to 6).
        case time(fraction: Int)
        case datetime(fraction: Int)
        case timestamp(fraction: Int)
        case year
        /// CHAR(n) and VARCHAR(n) hold n characters; TINYTEXT … LONGTEXT a number of bytes.
        case text(characters: Int?, bytes: Int?)
        /// BINARY(n) (padded with zero bytes), VARBINARY(n), TINYBLOB … LONGBLOB, spatial and VECTOR values: bytes,
        /// edited as hex.
        case binary(bytes: Int, fixed: Bool)
        /// MySQL's JSON, or MariaDB's LONGTEXT with a JSON_VALID check.
        case json
        case enumeration([String])
        case set([String])
        /// Anything else (INET6, UUID, …): sent as text for the server to check.
        case other
    }

    public var kind: Kind
    /// COLUMN_TYPE as the server shows it ("int(10) unsigned", "decimal(10,2)"), for messages.
    public var definition: String
    public var unsigned: Bool
    /// The column's character set ("utf8mb4", "latin1"); nil for numbers, dates and bytes.
    public var charset: String?

    public init(kind: Kind, definition: String, unsigned: Bool = false, charset: String? = nil) {
        self.kind = kind
        self.definition = definition
        self.unsigned = unsigned
        self.charset = charset
    }

    public init(_ column: SchemaColumn) {
        self.init(dataType: column.dataType, columnType: column.columnType, isJSON: column.isJSON,
                  charset: column.charset)
    }

    public init(dataType: String, columnType: String, isJSON: Bool = false, charset: String? = nil) {
        let type = columnType.lowercased(), base = dataType.lowercased()
        let numbers = Self.arguments(type).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let first = numbers.first, words = type.split(separator: " ")
        definition = columnType
        unsigned = words.contains("unsigned")
        self.charset = charset
        let sizes = ["tinytext": 255, "text": 65_535, "mediumtext": 16_777_215, "longtext": 4_294_967_295,
                     "tinyblob": 255, "blob": 65_535, "mediumblob": 16_777_215, "longblob": 4_294_967_295]
        switch base {
        case _ where isJSON || base == "json": kind = .json
        case "tinyint", "bool", "boolean": kind = .integer(bytes: 1)
        case "smallint": kind = .integer(bytes: 2)
        case "mediumint": kind = .integer(bytes: 3)
        case "int", "integer": kind = .integer(bytes: 4)
        case "bigint": kind = .integer(bytes: 8)
        case "decimal", "numeric", "dec", "fixed": kind = .decimal(precision: first ?? 10, scale: numbers.count > 1 ? numbers[1] : 0)
        case "float": kind = .float(bytes: 4)
        case "double", "real", "double precision": kind = .float(bytes: 8)
        case "bit": kind = .bit(width: min(64, max(1, first ?? 1)))
        case "date": kind = .date
        case "time": kind = .time(fraction: first ?? 0)
        case "datetime": kind = .datetime(fraction: first ?? 0)
        case "timestamp": kind = .timestamp(fraction: first ?? 0)
        case "year": kind = .year
        case "char", "varchar": kind = .text(characters: first ?? 1, bytes: nil)
        case "tinytext", "text", "mediumtext", "longtext": kind = .text(characters: nil, bytes: sizes[base])
        case "binary": kind = .binary(bytes: first ?? 1, fixed: true)
        case "varbinary": kind = .binary(bytes: first ?? 65_535, fixed: false)
        case "tinyblob", "blob", "mediumblob", "longblob": kind = .binary(bytes: sizes[base] ?? 65_535, fixed: false)
        case "geometry", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon",
             "geometrycollection", "geomcollection": kind = .binary(bytes: 4_294_967_295, fixed: false)
        case "vector": kind = .binary(bytes: 4 * (first ?? 2048), fixed: true)
        case "enum": kind = .enumeration(Self.members(columnType))
        case "set": kind = .set(Self.members(columnType))
        default: kind = .other
        }
    }

    /// TINYINT(1) and BIT(1): edited with a checkbox.
    public var isBoolean: Bool {
        switch kind {
        case .integer(bytes: 1): return definition.lowercased().hasPrefix("tinyint(1)")
        case .bit(width: 1): return true
        default: return false
        }
    }

    /// The text inside the first parentheses, split at commas: "decimal(10,2)" → ["10", "2"].
    private static func arguments(_ type: String) -> [String] {
        guard let open = type.firstIndex(of: "("), let close = type[open...].firstIndex(of: ")") else { return [] }
        return type[type.index(after: open)..<close].split(separator: ",").map(String.init)
    }

    /// ENUM and SET members from COLUMN_TYPE: enum('a','it''s') → ["a", "it's"]. information_schema writes a quote in a
    /// member twice and a backslash once, whatever the sql_mode.
    static func members(_ columnType: String) -> [String] {
        var members: [String] = [], current = "", inside = false
        var characters = columnType.drop { $0 != "(" }.dropFirst()[...]
        while let character = characters.popFirst() {
            if !inside {
                if character == "'" { inside = true; current = "" } else if character == ")" { break }
            } else if character == "'" {
                if characters.first == "'" {
                    current.append("'")
                    characters.removeFirst()
                } else {
                    inside = false
                    members.append(current)
                }
            } else {
                current.append(character)
            }
        }
        return members
    }
}
