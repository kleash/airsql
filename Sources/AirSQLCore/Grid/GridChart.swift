import Foundation

/// What Chart draws (grid-spec §3): the rows' points for each kind of chart. Bars and pie slices add up a number per
/// label (a label's rows summed), lines, areas and points pair two numbers, and a histogram counts the values in equal
/// ranges.
public enum GridChart {
    public enum Kind: Int, CaseIterable {
        case bar, line, area, pie, scatter, histogram

        public var title: String { ["Bar", "Line", "Area", "Pie", "Scatter", "Histogram"][rawValue] }
    }

    public struct Point: Equatable, Identifiable {
        public let id: Int
        /// The bar's or slice's label, the histogram range, or the x value as text.
        public var label: String
        public var x: Double
        public var y: Double
        /// A histogram bin's width (it runs from x to x + width).
        public var width: Double

        public init(id: Int, label: String, x: Double, y: Double, width: Double = 0) {
            self.id = id
            self.label = label
            self.x = x
            self.y = y
            self.width = width
        }
    }

    /// The pie's most slices before the rest fold into "Other" (the palette's eight hues).
    public static let sliceLimit = 8
    /// The most bars a bar chart shows (the first labels); more would be too thin to read.
    public static let barLimit = 30

    /// A number per label, summed over its rows, in the order labels first appear; past `limit` labels, the rest add up
    /// to one "Other" (a pie), or are left out (`other` false: bars). Rows without a number are left out; NULL labels
    /// show as "NULL".
    public static func totals(labels: [String?], values: [Double?], limit: Int, other: Bool = true) -> [Point] {
        var order: [String] = [], sums: [String: Double] = [:]
        for (label, value) in zip(labels, values) {
            guard let value else { continue }
            let key = label ?? "NULL"
            if sums[key] == nil { order.append(key) }
            sums[key, default: 0] += value
        }
        var points = order.prefix(limit).enumerated().map { Point(id: $0, label: $1, x: Double($0), y: sums[$1]!) }
        if other, order.count > limit {
            let rest = order.dropFirst(limit).reduce(0) { $0 + sums[$1]! }
            points.append(Point(id: limit, label: "Other", x: Double(limit), y: rest))
        }
        return points
    }

    /// Pairs of numbers, rows where both are numbers; without `xs`, x is the row's number from 1.
    public static func series(xs: [Double?]?, ys: [Double?]) -> [Point] {
        ys.enumerated().compactMap { row, y in
            guard let y, let x = xs.map({ $0[row] }) ?? Double(row + 1) else { return nil }
            return Point(id: row, label: x.formatted(), x: x, y: y)
        }
    }

    private static let dateFormats: [Int: DateFormatter] = Dictionary(uniqueKeysWithValues: [
        "yyyy", "HH:mm:ss", "yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return (format.count, formatter)
    })

    /// A date column's value as a place on the axis, in seconds; nil for NULL, a zero date, and a TIME past a day's
    /// hours. Fractions of a second don't move it. YEAR, TIME, DATE, DATETIME and TIMESTAMP, as the server writes them.
    public static func seconds(_ text: String) -> Double? {
        let whole = text.prefix { $0 != "." }
        return dateFormats[whole.count]?.date(from: String(whole))?.timeIntervalSince1970
    }

    /// Dates against numbers, in date order, rows where both are there; each point keeps its date as its label.
    public static func series(dates: [String?], ys: [Double?]) -> [Point] {
        ys.enumerated().compactMap { row, y -> Point? in
            guard let y, let text = dates[row], let x = seconds(text) else { return nil }
            return Point(id: row, label: text, x: x, y: y)
        }.sorted { $0.x < $1.x }
    }

    /// A place on a date axis as text: the time when `span` (the axis' length in seconds) is under two days, else the day.
    public static func dateLabel(_ seconds: Double, span: Double) -> String {
        (dateFormats[span < 2 * 86_400 ? 8 : 10]!).string(from: Date(timeIntervalSince1970: seconds))
    }

    /// The values counted in `bins` equal ranges from the smallest to the largest.
    public static func histogram(_ values: [Double?], bins: Int) -> [Point] {
        let numbers = values.compactMap { $0 }.filter(\.isFinite)
        guard let low = numbers.min(), let high = numbers.max(), bins > 0 else { return [] }
        let width = high > low ? (high - low) / Double(bins) : 1
        var counts = Array(repeating: 0, count: high > low ? bins : 1)
        for number in numbers { counts[min(counts.count - 1, Int((number - low) / width))] += 1 }
        return counts.enumerated().map { index, count in
            let start = low + Double(index) * width
            return Point(id: index, label: "\(start.formatted()) – \((start + width).formatted())", x: start, y: Double(count), width: width)
        }
    }
}
