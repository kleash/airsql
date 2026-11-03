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

        public init(id: Int, label: String, x: Double, y: Double) {
            self.id = id
            self.label = label
            self.x = x
            self.y = y
        }
    }

    /// The pie's most slices before the rest fold into "Other" (the palette's eight hues).
    public static let sliceLimit = 8

    /// A number per label, summed over its rows, in the order labels first appear; past `limit` labels, the rest add up
    /// to one "Other". Rows without a number are left out; NULL labels show as "NULL".
    public static func totals(labels: [String?], values: [Double?], limit: Int) -> [Point] {
        var order: [String] = [], sums: [String: Double] = [:]
        for (label, value) in zip(labels, values) {
            guard let value else { continue }
            let key = label ?? "NULL"
            if sums[key] == nil { order.append(key) }
            sums[key, default: 0] += value
        }
        var points = order.prefix(limit).enumerated().map { Point(id: $0, label: $1, x: Double($0), y: sums[$1]!) }
        if order.count > limit {
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

    /// The values counted in `bins` equal ranges from the smallest to the largest.
    public static func histogram(_ values: [Double?], bins: Int) -> [Point] {
        let numbers = values.compactMap { $0 }.filter(\.isFinite)
        guard let low = numbers.min(), let high = numbers.max(), bins > 0 else { return [] }
        let width = high > low ? (high - low) / Double(bins) : 1
        var counts = Array(repeating: 0, count: high > low ? bins : 1)
        for number in numbers { counts[min(counts.count - 1, Int((number - low) / width))] += 1 }
        return counts.enumerated().map { index, count in
            let start = low + Double(index) * width
            return Point(id: index, label: "\(start.formatted()) – \((start + width).formatted())", x: start, y: Double(count))
        }
    }
}
