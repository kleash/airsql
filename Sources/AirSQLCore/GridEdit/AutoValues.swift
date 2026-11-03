/// How a new row's untouched cell gets its value: what the grid shows there until Apply, and whether the INSERT leaves
/// the column out so the server decides (grid-spec §5, auto-generated values).
public enum NewRowValue: Equatable, Sendable {
    /// AUTO_INCREMENT: the server numbers the row; the number shows after Apply (read back with the insert ID).
    case auto
    /// A DEFAULT as the server shows it: a constant's text ("new", "0.00") or an expression ("current_timestamp()").
    case `default`(String)
    /// Nullable with no other default.
    case null
    /// A generated column: always left out, never edited.
    case generated
    /// NOT NULL with no default: the row needs a value before Apply.
    case required

    /// What the untouched cell shows: "auto", "default", "NULL", "generated", or nothing.
    public var placeholder: String {
        switch self {
        case .auto: return "auto"
        case .default: return "default"
        case .null: return "NULL"
        case .generated: return "generated"
        case .required: return ""
        }
    }

    /// The INSERT leaves the column out when the cell is untouched, so the server fills it in.
    public var leftOutOfInsert: Bool { self != .required }
}

extension SchemaColumn {
    public var newRowValue: NewRowValue {
        if generated != nil { return .generated }
        if autoIncrement { return .auto }
        switch defaultValue {
        case .value(let text), .expression(let text): return .default(text)
        case .null: return .null
        case .none: return nullable ? .null : .required
        }
    }

    /// Why the cell can't be edited, nil when it can: only generated columns, which the server works out.
    public var readOnlyReason: String? {
        guard let generated else { return nil }
        return "Generated (\(generated.stored ? "stored" : "virtual")) from \(generated.expression): the server works it out"
    }

    /// How the server fills the column in, for the header's tooltip and the new row's cell; nil when it doesn't.
    public var valueNote: String? {
        var notes: [String] = []
        switch newRowValue {
        case .auto: notes.append("AUTO_INCREMENT: the server numbers new rows, and the number shows after Apply")
        case .default(let text): notes.append("New rows get the default (\(text)) unless you type a value")
        case .generated: notes.append(readOnlyReason ?? "")
        case .required: notes.append("Needs a value in new rows: NOT NULL with no default")
        case .null: break
        }
        if let onUpdate { notes.append("The server sets it to \(onUpdate) whenever the row changes") }
        return notes.isEmpty ? nil : notes.joined(separator: ". ")
    }

    /// The Insert Value items that fit this column, in menu order.
    public var insertValues: [InsertValue] {
        guard generated == nil else { return [] }
        let type = ColumnType(self), spatial = ["geometry", "point", "linestring", "polygon", "multipoint",
                                                "multilinestring", "multipolygon", "geometrycollection", "geomcollection", "vector"]
        var items: [InsertValue] = []
        if nullable { items.append(.null) }
        switch newRowValue {
        case .default, .null: items.append(.default)
        default: break
        }
        switch type.kind {
        case .datetime, .timestamp: items += [.now, .utcNow]
        case .date: items += [.currentDate, .utcDate]
        case .time: items += [.currentTime, .utcTime]
        case .integer(let bytes):
            if bytes >= 4 && !type.isBoolean { items.append(.unixTimestamp) }
            if bytes == 8 { items.append(.uuidShort) }
        case .text(let characters, _):
            if (characters ?? 36) >= 36 { items.append(.uuid) }
            if (characters ?? 32) >= 32 { items.append(.uuidWithoutDashes) }
        case .binary(let bytes, _) where bytes >= 16 && !spatial.contains(dataType.lowercased()): items.append(.uuidBinary)
        case .other where dataType.lowercased() == "uuid": items.append(.uuid)
        default: break
        }
        switch type.kind {
        case .json, .other: break
        case .binary where spatial.contains(dataType.lowercased()): break
        default: items.append(.random)
        }
        return items
    }
}

/// The Insert Value menu: values the server works out when Apply runs, sent as SQL expressions (the grid shows them as
/// ƒ NOW() until then), never guessed on this Mac.
public enum InsertValue: String, CaseIterable, Sendable {
    case null, `default`, now, utcNow, currentDate, utcDate, currentTime, utcTime, unixTimestamp
    case uuid, uuidWithoutDashes, uuidBinary, uuidShort, random

    /// The menu item's title: the SQL it sends, except for the random value.
    public func title(for type: ColumnType, _ context: EditContext) -> String {
        self == .random ? "Random Value" : sql(for: type, context)
    }

    /// The item's tooltip.
    public var help: String {
        switch self {
        case .null: return "Set the cell to NULL"
        case .default: return "Give the cell the column's default when Apply runs"
        case .now: return "Set the server's date and time when Apply runs, in the session's time zone"
        case .utcNow: return "Set the server's UTC date and time when Apply runs"
        case .currentDate: return "Set the server's date when Apply runs"
        case .utcDate: return "Set the server's UTC date when Apply runs"
        case .currentTime: return "Set the server's time of day when Apply runs"
        case .utcTime: return "Set the server's UTC time of day when Apply runs"
        case .unixTimestamp: return "Set the seconds since 1970 (UTC) when Apply runs"
        case .uuid: return "Set a new UUID made by the server"
        case .uuidWithoutDashes: return "Set a new UUID made by the server, without its dashes"
        case .uuidBinary: return "Set a new UUID made by the server, as 16 bytes"
        case .uuidShort: return "Set a new unique number made by the server (UUID_SHORT)"
        case .random: return "Set a random value the server picks, within the column's type"
        }
    }

    /// The SQL expression, for the column's type (fractional seconds as the column keeps them).
    public func sql(for type: ColumnType, _ context: EditContext) -> String {
        var fraction = 0
        switch type.kind {
        case .time(let digits), .datetime(let digits), .timestamp(let digits): fraction = digits
        default: break
        }
        let digits = fraction > 0 ? String(fraction) : ""
        switch self {
        case .null: return "NULL"
        case .default: return "DEFAULT"
        case .now: return "NOW(\(digits))"
        case .utcNow: return "UTC_TIMESTAMP(\(digits))"
        case .currentDate: return "CURDATE()"
        case .utcDate: return "UTC_DATE()"
        case .currentTime: return "CURTIME(\(digits))"
        case .utcTime: return "UTC_TIME(\(digits))"
        case .unixTimestamp: return "UNIX_TIMESTAMP()"
        case .uuid: return "UUID()"
        case .uuidWithoutDashes: return "REPLACE(UUID(), '-', '')"
        case .uuidBinary: return "UNHEX(REPLACE(UUID(), '-', ''))"
        case .uuidShort: return "UUID_SHORT()"
        case .random: return Self.random(type, context)
        }
    }

    private static func random(_ type: ColumnType, _ context: EditContext) -> String {
        switch type.kind {
        case .integer(let bytes):
            if type.isBoolean { return "FLOOR(RAND() * 2)" }
            // RAND() has 53 bits, so BIGINT stays below 2^53 and nothing rounds past the type's top.
            let bits = min(53, bytes * 8 - (type.unsigned ? 0 : 1))
            return "FLOOR(RAND() * \(UInt64(1) << bits))"
        case .decimal(let precision, let scale):
            return "TRUNCATE(RAND() * 1\(String(repeating: "0", count: precision - scale)), \(scale))"
        case .float: return "RAND()"
        case .bit(let width): return "FLOOR(RAND() * \(UInt64(1) << min(53, width)))"
        case .date: return "CURDATE() - INTERVAL FLOOR(RAND() * 3650) DAY"
        case .datetime, .timestamp: return "NOW() - INTERVAL FLOOR(RAND() * 315360000) SECOND"
        case .time: return "SEC_TO_TIME(FLOOR(RAND() * 86400))"
        case .year: return "YEAR(CURDATE()) - FLOOR(RAND() * 50)"
        case .text(let characters, _): return "LEFT(MD5(RAND()), \(min(32, characters ?? 32)))"
        case .binary(let bytes, _): return "LEFT(UNHEX(SHA2(RAND(), 256)), \(min(32, bytes)))"
        case .enumeration(let members), .set(let members):
            let quoted = members.map { SQLQuote.string($0, noBackslashEscapes: context.noBackslashEscapes) }
            return "ELT(1 + FLOOR(RAND() * \(members.count)), \(quoted.joined(separator: ", ")))"
        case .json, .other: return "NULL"
        }
    }
}

extension SchemaTable {
    /// The columns that address one row for editing: the primary key, else the first UNIQUE key whose columns are all
    /// NOT NULL. Never a match on every column (HeidiSQL t=358): nil when there is no such key.
    public var editingKey: [String]? {
        if let primaryKey { return primaryKey.parts.compactMap(\.column) }
        return indexes.first { index in
            index.unique && index.parts.allSatisfy { part in part.column.flatMap(self.column).map { !$0.nullable } ?? false }
        }?.parts.compactMap(\.column)
    }

    /// Why rows of this table can't be edited, nil when they can.
    public var editingRefusal: String? {
        switch kind {
        case .view: return "A view has no key to address its rows: edit the table it shows"
        case .sequence: return "A sequence is changed with ALTER SEQUENCE or SETVAL, not edited as rows"
        case .table: break
        }
        if columns.isEmpty { return "AirSQL hasn't read this table's columns yet" }
        if editingKey == nil {
            return "It has no primary key or NOT NULL unique key, so a row can't be addressed exactly: add one to edit here"
        }
        return nil
    }

    /// The SELECT that reads an inserted row back after Apply, so the grid shows what the server filled in: by the
    /// editing key, `values` holding the literals the INSERT gave (column → SQL), and the insert ID standing in for an
    /// AUTO_INCREMENT key column it left out. Throws when a key column's value came from the server some other way
    /// (a DEFAULT such as UUID(), or an expression), since the row can't be found again: reload instead.
    public func readBackQuery(database: String, values: [String: String], insertID: UInt64) throws -> String {
        guard let key = editingKey, !columns.isEmpty else { throw EditError(editingRefusal ?? "No key") }
        let conditions = try key.map { name -> String in
            if let literal = values[name] { return SQLQuote.identifier(name) + " = " + literal }
            guard column(name)?.autoIncrement == true, insertID != 0 else {
                throw EditError("The new row's \(name) came from the server, so it can't be found again: reload to see it")
            }
            return SQLQuote.identifier(name) + " = \(insertID)"
        }
        return "SELECT " + columns.map { SQLQuote.identifier($0.name) }.joined(separator: ", ")
            + " FROM " + SQLQuote.identifier(database, self.name) + " WHERE " + conditions.joined(separator: " AND ")
    }
}
