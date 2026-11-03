import Foundation

/// How a column's values are shown (Display As, grid-spec §3), kept per table by name (`TableViewSettings.displayTypes`):
/// a Unix time as a local date and time, binary(16) as a UUID, bytes as hex or as text, numbers with grouping. Only
/// the look: copying and editing use the value itself.
public enum GridDisplay: String, CaseIterable, Codable {
    case standard, unixTime, unixMillis, grouped, uuid, hex, text

    public var title: String {
        switch self {
        case .standard: return "As Stored"
        case .unixTime: return "Date from Unix Time (seconds)"
        case .unixMillis: return "Date from Unix Time (milliseconds)"
        case .grouped: return "Number with Grouping"
        case .uuid: return "UUID"
        case .hex: return "Hex"
        case .text: return "Text (UTF-8)"
        }
    }

    /// The ways a column of this kind can be shown.
    public static func choices(for column: GridColumn) -> [GridDisplay] {
        switch column.kind {
        case .number: return [.standard, .grouped, .unixTime, .unixMillis]
        case .binary: return [.standard, .uuid, .hex, .text]
        default: return [.standard]
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// A value shown this way; nil keeps the cell as it is (NULL, or a value this way can't show).
    public func format(_ value: String?, bytes: [UInt8]?, timeZone: TimeZone = .current) -> String? {
        switch self {
        case .standard: return nil
        case .unixTime, .unixMillis:
            guard let value, let number = Double(value), number.isFinite else { return nil }
            let formatter = Self.dateFormatter
            formatter.timeZone = timeZone
            return formatter.string(from: Date(timeIntervalSince1970: self == .unixMillis ? number / 1000 : number))
        case .grouped:
            guard let value, let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = value.firstIndex(of: ".").map { value.distance(from: $0, to: value.endIndex) - 1 } ?? 0
            formatter.minimumFractionDigits = formatter.maximumFractionDigits
            return formatter.string(from: decimal as NSDecimalNumber)
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
        }
    }
}

/// A source shown with display types on some columns (`GridDisplay`); `value` stays the stored value.
public final class DisplaySource: GridSource {
    public let base: GridSource
    /// By the base's column.
    public let displays: [Int: GridDisplay]
    public let columns: [GridColumn]
    private let bytes: (Int, Int) -> [UInt8]?

    /// `bytes`: the base's bytes for a cell (hex, UUID and text need them).
    public init(_ base: GridSource, displays: [Int: GridDisplay], bytes: @escaping (Int, Int) -> [UInt8]?) {
        self.base = base
        self.displays = displays
        self.bytes = bytes
        var columns = base.columns
        let words: [GridDisplay: String] = [.unixTime: "date", .unixMillis: "date", .grouped: "grouped", .uuid: "UUID", .hex: "hex",
                                            .text: "text"]
        for (column, display) in displays where columns.indices.contains(column) && display != .standard {
            columns[column].type += (columns[column].type.isEmpty ? "as " : " as ") + (words[display] ?? display.rawValue)
            if display == .unixTime || display == .unixMillis { columns[column].kind = .date }
            if display == .text { columns[column].kind = .text }
        }
        self.columns = columns
    }

    public var rowCount: Int { base.rowCount }

    public func cell(_ row: Int, _ column: Int) -> GridCell {
        let cell = base.cell(row, column)
        guard let display = displays[column], display != .standard, case .text = cell else { return cell }
        let raw = [.uuid, .hex, .text].contains(display) ? bytes(row, column) : nil
        return display.format(base.value(row, column), bytes: raw).map { .text($0) } ?? cell
    }

    public func value(_ row: Int, _ column: Int) -> String? { base.value(row, column) }
    public func mark(_ row: Int, _ column: Int) -> GridMark { base.mark(row, column) }
    public func prefetch(_ rows: Range<Int>) { base.prefetch(rows) }
}
