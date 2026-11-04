import Foundation

/// How a column's values are shown (Display As, grid-spec §3), kept per table by name (`TableViewSettings.displayTypes`):
/// a Unix time as a local date and time, binary(16) as a UUID, bytes as hex or as text, numbers with grouping or rounded
/// to some decimal places, dates in the Mac's short, medium or long style. Only the look: copying and editing use the
/// value itself.
public enum GridDisplay: String, CaseIterable, Codable {
    case standard, unixTime, unixMillis, grouped, uuid, hex, text
    case decimals0, decimals1, decimals2, decimals3, decimals4
    case dateShort, dateMedium, dateLong

    public var title: String {
        switch self {
        case .standard: return "As Stored"
        case .unixTime: return "Date from Unix Time (seconds)"
        case .unixMillis: return "Date from Unix Time (milliseconds)"
        case .grouped: return "Number with Grouping"
        case .uuid: return "UUID"
        case .hex: return "Hex"
        case .text: return "Text (UTF-8)"
        case .decimals0: return "No Decimals"
        case .decimals1: return "1 Decimal Place"
        case .decimals2, .decimals3, .decimals4: return "\(decimals ?? 0) Decimal Places"
        case .dateShort: return "Short Date and Time"
        case .dateMedium: return "Medium Date and Time"
        case .dateLong: return "Long Date and Time"
        }
    }

    /// The decimal places a rounded number shows.
    public var decimals: Int? {
        [.decimals0: 0, .decimals1: 1, .decimals2: 2, .decimals3: 3, .decimals4: 4][self]
    }

    /// The Mac's style a date is shown in (the person's region settings decide what it looks like).
    var dateStyle: DateFormatter.Style? {
        [.dateShort: .short, .dateMedium: .medium, .dateLong: .long][self]
    }

    /// The ways a column of this kind can be shown.
    public static func choices(for column: GridColumn) -> [GridDisplay] {
        switch column.kind {
        case .number: return [.standard, .grouped, .decimals0, .decimals1, .decimals2, .decimals3, .decimals4, .unixTime, .unixMillis]
        case .binary: return [.standard, .uuid, .hex, .text]
        case .date where column.hasDate: return [.standard, .dateShort, .dateMedium, .dateLong]
        default: return [.standard]
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// A value shown this way, its date and time moved by `zone`; nil keeps the cell as it is (NULL, or a value this way
    /// can't show).
    public func format(_ value: String?, bytes: [UInt8]?, timeZone: TimeZone = .current, zone: GridZone = .stored) -> String? {
        switch self {
        case .standard: return zone == .stored ? nil : value.flatMap { Self.date($0, style: nil, zone: zone) }
        case .unixTime, .unixMillis:
            guard let value, let number = Double(value), number.isFinite else { return nil }
            let formatter = Self.dateFormatter
            formatter.timeZone = timeZone
            return formatter.string(from: Date(timeIntervalSince1970: self == .unixMillis ? number / 1000 : number))
        case .grouped, .decimals0, .decimals1, .decimals2, .decimals3, .decimals4:
            guard let value, var decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
            guard let decimals else {
                // Every digit as it is: a DECIMAL(65,30) has more than any number type here keeps.
                let plain = !value.contains { $0 == "e" || $0 == "E" } && CopyWriter.isNumber(value)
                return GridAggregate.laidOut(plain ? value : "\(decimal)", fraction: 0, grouping: true, .current)
            }
            var rounded = Decimal()
            NSDecimalRound(&rounded, &decimal, decimals, .plain)
            return GridAggregate.laidOut("\(rounded)", fraction: decimals, grouping: true, .current)
        case .uuid:
            guard let bytes, bytes.count == 16 else { return nil }
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
                String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
            }
            return parts.joined(separator: "-")
        case .hex:
            guard let bytes else { return nil }
            return "0x" + bytes.prefix(512).map { String(format: "%02X", $0) }.joined() + (bytes.count > 512 ? "…" : "")
        case .text:
            guard let bytes else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        case .dateShort, .dateMedium, .dateLong:
            return value.flatMap { Self.date($0, style: dateStyle, zone: zone) }
        }
    }

    /// A DATETIME or TIMESTAMP value ("2026-11-03 14:05:09.250") or a DATE in `style` (nil: as stored, fractions kept),
    /// moved by `zone`; nil for what isn't one (a zero date, a TIME, an hour a clock change skips).
    static func date(_ value: String, style: DateFormatter.Style?, zone: GridZone) -> String? {
        let main = String(value.prefix(19)), fraction = value.dropFirst(19), hasTime = main.count == 19
        guard hasTime || main.count == 10, fraction.isEmpty || fraction.first == "." else { return nil }
        let (from, to) = zone.zones
        guard let date = formatter(nil, hasTime: hasTime, in: from).date(from: main) else { return nil }
        guard let style else { return formatter(nil, hasTime: hasTime, in: to).string(from: date) + fraction }
        return formatter(style, hasTime: hasTime, in: to).string(from: date)
    }

    /// Formatters by style, time and zone: making one takes longer than drawing a cell.
    private static var formatters: [String: DateFormatter] = [:]

    private static func formatter(_ style: DateFormatter.Style?, hasTime: Bool, in zone: TimeZone) -> DateFormatter {
        let key = "\(style.map { String($0.rawValue) } ?? "stored") \(hasTime) \(zone.identifier)"
        if let formatter = formatters[key] { return formatter }
        let formatter = DateFormatter()
        formatter.timeZone = zone
        if let style {
            formatter.dateStyle = style
            formatter.timeStyle = !hasTime ? .none : style == .short ? .short : .medium
        } else {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = hasTime ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
        }
        formatters[key] = formatter
        return formatter
    }
}

/// The time zone a DATETIME or TIMESTAMP column's values are shown in (Display As ▸ Time Zone), kept per table by name
/// (`TableViewSettings.displayZones`): as the server sends them, or taken as UTC and shown in this Mac's time zone, or
/// the other way round. Only the look, as with `GridDisplay`.
public enum GridZone: String, CaseIterable {
    case stored, utcToLocal, localToUTC

    public var title: String {
        let mac = TimeZone.current.identifier
        switch self {
        case .stored: return "As Stored"
        case .utcToLocal: return "From UTC to This Mac's (\(mac))"
        case .localToUTC: return "From This Mac's (\(mac)) to UTC"
        }
    }

    /// The zone a value is read in, and the one it is shown in.
    var zones: (from: TimeZone, to: TimeZone) {
        let utc = TimeZone(identifier: "UTC")!
        switch self {
        case .stored: return (utc, utc)
        case .utcToLocal: return (utc, .current)
        case .localToUTC: return (.current, utc)
        }
    }

    /// Whether `column` has a time of day to move: DATETIME and TIMESTAMP.
    public static func applies(to column: GridColumn) -> Bool {
        column.kind == .date && ["datetime", "timestamp"].contains { column.type.lowercased().hasPrefix($0) }
    }
}

extension GridColumn {
    /// A DATE, DATETIME or TIMESTAMP column: its values have a calendar date (TIME and YEAR don't).
    var hasDate: Bool { kind == .date && type.lowercased().hasPrefix("date") || GridZone.applies(to: self) }
}

/// A source shown with display types on some columns (`GridDisplay`); `value` stays the stored value.
public final class DisplaySource: GridSource {
    public let base: GridSource
    /// By the base's column.
    public let displays: [Int: GridDisplay]
    public let zones: [Int: GridZone]
    public let columns: [GridColumn]
    private let bytes: (Int, Int) -> [UInt8]?

    /// `bytes`: the base's bytes for a cell (hex, UUID and text need them). `zones`: the time zones of date columns.
    public init(_ base: GridSource, displays: [Int: GridDisplay], zones: [Int: GridZone] = [:],
                bytes: @escaping (Int, Int) -> [UInt8]?) {
        self.base = base
        self.displays = displays
        self.zones = zones
        self.bytes = bytes
        var columns = base.columns
        let words: [GridDisplay: String] = [.unixTime: "date", .unixMillis: "date", .grouped: "grouped", .uuid: "UUID", .hex: "hex",
                                            .text: "text", .dateShort: "short date", .dateMedium: "medium date", .dateLong: "long date"]
        for (column, display) in displays where columns.indices.contains(column) && display != .standard {
            let word = display.decimals.map { "\($0) decimals" } ?? words[display] ?? display.rawValue
            columns[column].type += (columns[column].type.isEmpty ? "as " : " as ") + word
            if display == .unixTime || display == .unixMillis { columns[column].kind = .date }
            if display == .text { columns[column].kind = .text }
        }
        for (column, zone) in zones where columns.indices.contains(column) && zone != .stored {
            columns[column].type += zone == .utcToLocal ? ", UTC → this Mac's" : ", this Mac's → UTC"
        }
        self.columns = columns
    }

    public var rowCount: Int { base.rowCount }

    public func cell(_ row: Int, _ column: Int) -> GridCell {
        let cell = base.cell(row, column)
        let display = displays[column] ?? .standard, zone = zones[column] ?? .stored
        guard display != .standard || zone != .stored, case .text = cell else { return cell }
        let raw = [.uuid, .hex, .text].contains(display) ? bytes(row, column) : nil
        return display.format(base.value(row, column), bytes: raw, zone: zone).map { .text($0) } ?? cell
    }

    public func value(_ row: Int, _ column: Int) -> String? { base.value(row, column) }
    public func mark(_ row: Int, _ column: Int) -> GridMark { base.mark(row, column) }
    public func note(_ row: Int, _ column: Int) -> String? { base.note(row, column) }
    public func prefetch(_ rows: Range<Int>) { base.prefetch(rows) }
}
