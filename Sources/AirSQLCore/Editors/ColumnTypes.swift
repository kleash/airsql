import Foundation

/// A column type as the table editor offers it, and what its "Length / values" field holds there.
public struct EditorColumnType: Hashable {
    public enum Length: Hashable {
        /// DATE, TEXT, JSON: nothing goes in the field.
        case none
        /// INT(11), CHAR(1), BIT(1), DATETIME(3): the server has a default.
        case optional
        /// VARCHAR(255), VARBINARY(16), VECTOR(3).
        case required
        /// ENUM and SET: 'a','b'.
        case values
    }

    /// As information_schema writes it (DATA_TYPE): "int", "varchar".
    public let name: String
    public let length: Length
    /// What the field holds, for its placeholder and tooltip: "Digits, decimals".
    public let hint: String
    /// UNSIGNED and ZEROFILL apply.
    public let numeric: Bool
    /// A character set and collation apply.
    public let text: Bool
    /// AUTO_INCREMENT applies.
    public let integer: Bool
}

/// The column types of each flavour and version, in the order the type menu lists them.
public enum ColumnTypes {
    public static func all(for server: SchemaServer) -> [EditorColumnType] {
        var names = ["tinyint", "smallint", "mediumint", "int", "bigint", "decimal", "float", "double", "bit",
                     "date", "time", "datetime", "timestamp", "year",
                     "char", "varchar", "binary", "varbinary", "tinytext", "text", "mediumtext", "longtext",
                     "tinyblob", "blob", "mediumblob", "longblob", "enum", "set", "json"]
        switch server.flavour {
        case .mysql:
            if server.atLeast(9) { names.append("vector") }
        case .mariadb:
            names.append("inet6")
            if server.atLeast(10, 7) { names.append("uuid") }
            if server.atLeast(10, 10) { names.append("inet4") }
            if server.atLeast(11, 7) { names.append("vector") }
        }
        // MySQL 8 reads GEOMETRYCOLLECTION back as geomcollection.
        let collection = server.flavour == .mysql && server.atLeast(8) ? "geomcollection" : "geometrycollection"
        names += ["geometry", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon", collection]
        return names.compactMap(type)
    }

    /// The type of that name on any server (nil for one AirSQL doesn't know, such as a plugin's).
    public static func type(_ name: String) -> EditorColumnType? {
        let name = name.lowercased()
        switch name {
        case "tinyint", "smallint", "mediumint", "int", "bigint":
            return EditorColumnType(name: name, length: .optional, hint: "Display width", numeric: true, text: false, integer: true)
        case "decimal", "float", "double":
            return EditorColumnType(name: name, length: .optional, hint: "Digits, decimals (12,2)", numeric: true, text: false,
                              integer: false)
        case "bit":
            return EditorColumnType(name: name, length: .optional, hint: "Bits (1 to 64)", numeric: false, text: false, integer: false)
        case "time", "datetime", "timestamp":
            return EditorColumnType(name: name, length: .optional, hint: "Fraction digits (0 to 6)", numeric: false, text: false,
                              integer: false)
        case "char", "binary":
            return EditorColumnType(name: name, length: .optional, hint: "Length", numeric: false, text: name == "char", integer: false)
        case "varchar", "varbinary":
            return EditorColumnType(name: name, length: .required, hint: "Length", numeric: false, text: name == "varchar",
                              integer: false)
        case "vector":
            return EditorColumnType(name: name, length: .required, hint: "Dimensions", numeric: false, text: false, integer: false)
        case "enum", "set":
            return EditorColumnType(name: name, length: .values, hint: "Values: 'a','b'", numeric: false, text: true, integer: false)
        case "tinytext", "text", "mediumtext", "longtext":
            return EditorColumnType(name: name, length: .none, hint: "", numeric: false, text: true, integer: false)
        case "date", "year", "tinyblob", "blob", "mediumblob", "longblob", "json", "inet6", "uuid", "inet4", "geometry",
             "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon", "geometrycollection",
             "geomcollection":
            return EditorColumnType(name: name, length: .none, hint: "", numeric: false, text: false, integer: false)
        default:
            return nil
        }
    }
}

/// A column's type split as the editor shows it: "decimal(12,2) unsigned" is decimal, "12,2", unsigned.
public struct TypeSpec: Hashable {
    /// Lowercase, as information_schema writes it.
    public var name: String
    /// "255", "12,2", "3", or ENUM's and SET's values as SQL ("'paid','shipped'"); empty for none.
    public var length: String
    public var unsigned: Bool
    public var zerofill: Bool

    public init(name: String, length: String = "", unsigned: Bool = false, zerofill: Bool = false) {
        self.name = name.lowercased()
        self.length = length
        self.unsigned = unsigned
        self.zerofill = zerofill
    }

    /// Splits information_schema's COLUMN_TYPE: "int(10) unsigned zerofill", "enum('a','b''c')", "varchar(255)".
    public init(columnType: String) {
        let scalars = Array(columnType.unicodeScalars)
        var index = 0
        while index < scalars.count, scalars[index] != "(", scalars[index] != " " { index += 1 }
        let name = String(String.UnicodeScalarView(scalars[0..<index]))
        var length = ""
        if index < scalars.count, scalars[index] == "(" {
            // To the closing parenthesis outside quotes (ENUM values may hold parentheses and commas).
            var end = index + 1, quoted = false
            while end < scalars.count, quoted || scalars[end] != ")" {
                if scalars[end] == "'" { quoted.toggle() }
                if quoted, scalars[end] == "\\" { end += 1 }
                end += 1
            }
            length = String(String.UnicodeScalarView(scalars[(index + 1)..<min(end, scalars.count)]))
            index = end + 1
        }
        let words = index < scalars.count ? String(String.UnicodeScalarView(scalars[index...])).lowercased().split(separator: " ") : []
        self.init(name: name, length: length, unsigned: words.contains("unsigned"), zerofill: words.contains("zerofill"))
    }

    /// The type as SQL, checked: the name a plain word, the length digits ("12,2"), ENUM's and SET's values quoted again
    /// with `SQLQuote`, UNSIGNED and ZEROFILL only on numbers.
    public func sql(noBackslashEscapes: Bool) throws -> String {
        guard name.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil else {
            throw DesignError("“\(name)” isn't a column type")
        }
        let known = ColumnTypes.type(name)
        var text = name
        let trimmed = length.trimmingCharacters(in: .whitespaces)
        if known?.length == .values {
            let values = try TypeSpec.values(trimmed, noBackslashEscapes: noBackslashEscapes)
            guard !values.isEmpty else { throw DesignError("Give \(name.uppercased()) its values, as 'a','b'") }
            text += "(" + values.map { SQLQuote.string($0, noBackslashEscapes: noBackslashEscapes) }.joined(separator: ",") + ")"
        } else if !trimmed.isEmpty {
            let digits = trimmed.replacingOccurrences(of: " ", with: "")
            guard known?.length != EditorColumnType.Length.none, digits.range(of: "^[0-9]+(,[0-9]+)?$", options: .regularExpression) != nil
            else {
                throw DesignError(known?.length == EditorColumnType.Length.none ? "\(name.uppercased()) takes no length"
                                  : "Write the length of \(name.uppercased()) as digits, such as 255 or 12,2")
            }
            text += "(" + digits + ")"
        } else if known?.length == .required {
            throw DesignError("Give \(name.uppercased()) a length")
        }
        if known?.numeric ?? false {
            if unsigned { text += " unsigned" }
            if zerofill { text += " zerofill" }
        }
        return text
    }

    /// ENUM's and SET's values from their SQL ("'a','b''c'"): each a single-quoted string, separated by commas.
    public static func values(_ text: String, noBackslashEscapes: Bool) throws -> [String] {
        var values: [String] = []
        var scalars = text.unicodeScalars.makeIterator()
        var next = scalars.next()
        func skipSpaces() { while let scalar = next, scalar == " " || scalar == "\n" || scalar == "\t" { next = scalars.next() } }
        let format = DesignError("Write the values as quoted text separated by commas, such as 'paid','shipped'")
        skipSpaces()
        while next != nil {
            guard next == "'" else { throw format }
            var value = String.UnicodeScalarView()
            next = scalars.next()
            while true {
                guard let scalar = next else { throw format }
                next = scalars.next()
                if scalar == "'" {
                    guard next == "'" else { break }
                    value.append("'")
                    next = scalars.next()
                } else if scalar == "\\", !noBackslashEscapes, let escaped = next {
                    value.append(SchemaIntrospection.unescaped(escaped))
                    next = scalars.next()
                } else {
                    value.append(scalar)
                }
            }
            values.append(String(value))
            skipSpaces()
            if next == "," {
                next = scalars.next()
                skipSpaces()
                guard next != nil else { throw format }
            } else if next != nil {
                throw format
            }
        }
        return values
    }
}

/// Something in a design the server couldn't take, said plainly ("Give VARCHAR a length").
public struct DesignError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
