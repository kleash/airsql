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

    public init<Values: Sequence>(_ values: Values) where Values.Element == String? {
        var texts: [String] = []
        for value in values {
            if let value { texts.append(value) } else { nulls += 1 }
        }
        count = texts.count
        distinct = Set(texts).count
        guard !texts.isEmpty else { return }
        let numbers = texts.map(Self.number)
        if numbers.allSatisfy({ $0 != nil }) {
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

    /// A value as a number, the way MySQL writes them ("-12.50", "1e3"); nil when it isn't one.
    static func number(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.unicodeScalars.first, CharacterSet(charactersIn: "+-.0123456789").contains(first),
              trimmed.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "+-.0123456789eE").contains($0) }) else { return nil }
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
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = locale.identifier != "en_US_POSIX"
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = min(digits, 20)
        return formatter.string(from: number as NSDecimalNumber) ?? "\(number)"
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
