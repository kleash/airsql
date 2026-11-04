import Foundation

/// The status bar's figures for the selected cells (grid-spec §3): how many values, their sum, average, smallest,
/// largest, median and distinct count. Numbers add up exactly (as decimals, the way the server sends DECIMAL);
/// sum, average and median need every value to be a number. NULLs are left out and counted apart.
public struct GridAggregate: Equatable {
    public enum Kind: String, CaseIterable, Codable {
        case count, sum, average, minimum, maximum, median, distinct

        public var title: String {
            switch self {
            case .count: return "Count"
            case .sum: return "Sum"
            case .average: return "Avg"
            case .minimum: return "Min"
            case .maximum: return "Max"
            case .median: return "Median"
            case .distinct: return "Distinct"
            }
        }
    }

    /// Values that aren't NULL.
    public private(set) var count = 0
    public private(set) var nulls = 0
    public private(set) var distinct = 0
    /// Nil unless every value is a number.
    public private(set) var sum: Decimal?
    public private(set) var average: Decimal?
    public private(set) var median: Decimal?
    /// As numbers when they all are, else as text.
    public private(set) var minimum: String?
    public private(set) var maximum: String?
    /// The most decimals a value has: sums show as many.
    private var scale = 0

    /// `numbers` false: the values only look like numbers (BIT's digits), so they don't add up.
    public init<Values: Sequence>(_ values: Values, numbers canAddUp: Bool = true) where Values.Element == String? {
        var texts: [String] = []
        for value in values {
            if let value { texts.append(value) } else { nulls += 1 }
        }
        count = texts.count
        distinct = Set(texts).count
        guard !texts.isEmpty else { return }
        let numbers = texts.map(Self.number)
        if canAddUp, numbers.allSatisfy({ $0 != nil }) {
            let sorted = numbers.compactMap { $0 }.sorted()
            let total = sorted.reduce(Decimal(0), +)
            sum = total
            average = total / Decimal(sorted.count)
            let middle = sorted.count / 2
            median = sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
            scale = texts.map { text in text.firstIndex(of: ".").map { text.distance(from: $0, to: text.endIndex) - 1 } ?? 0 }.max() ?? 0
            minimum = texts[numbers.firstIndex(of: sorted.first)!]
            maximum = texts[numbers.firstIndex(of: sorted.last)!]
        } else {
            minimum = texts.min()
            maximum = texts.max()
        }
    }

    /// A value as a number, the way MySQL writes them ("-12.50", "1e3"); nil when it isn't one. The whole text must
    /// be one: `Decimal(string:)` alone reads "2026-11-03" as 2026.
    static func number(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The figure as the status bar shows it ("6,563.95"), nil when it doesn't apply (a sum of words, no values).
    public func text(_ kind: Kind, locale: Locale = .current) -> String? {
        switch kind {
        case .count: return count.formatted(.number.locale(locale))
        case .distinct: return distinct.formatted(.number.locale(locale))
        case .sum: return sum.map { format($0, digits: scale, locale) }
        case .average: return average.map { format($0, digits: scale + 2, locale) }
        case .median: return median.map { format($0, digits: scale + 1, locale) }
        case .minimum: return minimum.map { sum == nil ? $0 : format(Self.number($0)!, digits: scale, locale) }
        case .maximum: return maximum.map { sum == nil ? $0 : format(Self.number($0)!, digits: scale, locale) }
        }
    }

    /// The figure as plain text for the clipboard: no grouping, a point for decimals.
    public func copyText(_ kind: Kind) -> String? {
        switch kind {
        case .count: return String(count)
        case .distinct: return String(distinct)
        default: return text(kind, locale: Locale(identifier: "en_US_POSIX"))
        }
    }

    private func format(_ number: Decimal, digits: Int, _ locale: Locale) -> String {
        // As many decimals as the values have (a sum of prices keeps its cents), more for an average or median.
        var exact = number, rounded = Decimal()
        NSDecimalRound(&rounded, &exact, min(max(digits, scale), 20), .bankers)
        return GridAggregate.laidOut("\(rounded)", fraction: min(scale, 20), grouping: locale.identifier != "en_US_POSIX", locale)
    }

    /// Plain digits ("-1234.5") in `locale`'s separators, at least `fraction` decimals. NumberFormatter goes through
    /// Double, which keeps about 15 digits. shortcut: groups of three, as most locales; lakh grouping needs a formatter.
    static func laidOut(_ plain: String, fraction: Int, grouping: Bool, _ locale: Locale) -> String {
        let negative = plain.hasPrefix("-"), parts = plain.drop { $0 == "-" }.split(separator: ".", omittingEmptySubsequences: false)
        var whole = "", digits = Array(parts.first ?? "0")
        if grouping, let separator = locale.groupingSeparator {
            while digits.count > 3 {
                whole = separator + String(digits.suffix(3)) + whole
                digits.removeLast(3)
            }
        }
        whole = String(digits) + whole
        let decimals = parts.count > 1 ? String(parts[1]) : ""
        let padded = decimals + String(repeating: "0", count: max(0, fraction - decimals.count))
        return (negative ? "-" : "") + whole + (padded.isEmpty ? "" : (locale.decimalSeparator ?? ".") + padded)
    }
}

extension GridSelection {
    /// An area's rows and columns in a grid of `rows` × `columns` (display columns), cut to the grid.
    private func bounds(_ area: Area, rows: Int, columns: Int) -> (Range<Int>, Range<Int>) {
        func cut(_ range: ClosedRange<Int>, _ count: Int) -> Range<Int> {
            min(range.lowerBound, count)..<min(range.upperBound + 1, count)
        }
        switch area {
        case .cells(let r, let c): return (cut(r, rows), cut(c, columns))
        case .rows(let r): return (cut(r, rows), 0..<columns)
        case .columns(let c): return (0..<rows, cut(c, columns))
        case .all: return (0..<rows, 0..<columns)
        }
    }

    /// How many cells the selection covers (areas added with ⌘ that overlap count their shared cells twice).
    public func cellCount(rows: Int, columns: Int) -> Int {
        areas.reduce(0) { total, area in
            let (r, c) = bounds(area, rows: rows, columns: columns)
            return total + r.count * c.count
        }
    }

    /// The selected cells, each once, row by row; nil when there are more than `limit`.
    public func cells(rows: Int, columns: Int, limit: Int) -> [GridPosition]? {
        guard cellCount(rows: rows, columns: columns) <= limit else { return nil }
        var seen = Set<GridPosition>(), cells: [GridPosition] = []
        for area in areas {
            let (r, c) = bounds(area, rows: rows, columns: columns)
            for row in r {
                for column in c where areas.count == 1 || seen.insert(GridPosition(row: row, column: column)).inserted {
                    cells.append(GridPosition(row: row, column: column))
                }
            }
        }
        return areas.count == 1 ? cells : cells.sorted { ($0.row, $0.column) < ($1.row, $1.column) }
    }
}

/// What Column Summary shows (grid-spec §3, HeidiSQL's "more values" with counts): distinct values, NULLs, smallest
/// and largest, and the most frequent values with their counts.
public struct ColumnSummary: Equatable {
    public static let topLimit = 50

    public var distinct: Int
    public var nulls: Int
    public var rows: Int
    public var minimum: String?
    public var maximum: String?
    /// Most frequent first; nil is NULL.
    public var top: [(value: String?, count: Int)]

    public static func == (a: ColumnSummary, b: ColumnSummary) -> Bool {
        a.distinct == b.distinct && a.nulls == b.nulls && a.rows == b.rows && a.minimum == b.minimum && a.maximum == b.maximum
            && a.top.map(\.value) == b.top.map(\.value) && a.top.map(\.count) == b.top.map(\.count)
    }

    public init(distinct: Int, nulls: Int, rows: Int, minimum: String?, maximum: String?, top: [(value: String?, count: Int)]) {
        self.distinct = distinct
        self.nulls = nulls
        self.rows = rows
        self.minimum = minimum
        self.maximum = maximum
        self.top = top
    }

    /// A value as a list shows it: quoted when it would pass for NULL or nothing.
    public static func label(_ value: String?, nullText: String) -> String {
        guard let value else { return nullText }
        return value.isEmpty || value == nullText ? "'\(value)'" : value
    }

    /// Worked out from values in memory (a console result's rows); numbers compare as numbers.
    public init(values: [String?], limit: Int = topLimit) {
        var counts: [String?: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        let present = counts.keys.compactMap { $0 }
        let numeric = !present.isEmpty && present.allSatisfy { Double($0) != nil }
        func less(_ a: String, _ b: String) -> Bool { numeric ? GridSorting.compare(a, b, number: true) == .orderedAscending : a < b }
        self.init(distinct: present.count, nulls: counts[nil] ?? 0, rows: values.count, minimum: present.min(by: less),
                  maximum: present.max(by: less),
                  top: counts.sorted { $0.value != $1.value ? $0.value > $1.value : ($0.key ?? "") < ($1.key ?? "") }
                    .prefix(limit).map { ($0.key, $0.value) })
    }
}
