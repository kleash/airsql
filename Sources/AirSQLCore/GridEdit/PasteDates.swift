import Foundation

/// Dates and times as spreadsheets copy them (3/11/2026, 03.11.26, 2:05 PM) turned into what `literal` reads
/// (2026-11-03 14:05:00), in the column's date order. Anything else is passed on as it is, for `literal` to check.
enum PasteDates {
    static func normalised(_ text: String, _ type: ColumnType, order: PasteFormat.DateOrder) throws -> String {
        var date: String?, time: String?, afternoon: Bool?
        for token in text.split(separator: " ") {
            switch token.lowercased() {
            case "am", "a.m.": afternoon = false
            case "pm", "p.m.": afternoon = true
            case _ where token.contains(":") && time == nil: time = String(token)
            case _ where date == nil: date = String(token)
            default: return text
            }
        }
        if let given = date {
            guard let converted = day(given, order: order) else { return text }
            date = converted
        }
        if var clock = time {
            if let afternoon {
                // 12 AM is midnight and 12 PM noon.
                let parts = clock.split(separator: ":", maxSplits: 1)
                guard let hour = Int(parts[0]), (1...12).contains(hour), parts.count == 2 else { return text }
                clock = String(format: "%02d", hour % 12 + (afternoon ? 12 : 0)) + ":" + parts[1]
            }
            time = clock
        } else if afternoon != nil {
            return text
        }
        switch type.kind {
        case .date:
            if let time, time.contains(where: { "123456789".contains($0) }) {
                throw EditError("DATE keeps no time of day: \(time) would be lost")
            }
            return date ?? text
        case .time:
            guard date == nil else { throw EditError("TIME keeps no date: type the time alone") }
            return time ?? text
        default:
            guard let date else { return text }
            return time.map { date + " " + $0 } ?? date
        }
    }

    /// d/m/y, m/d/y or y/m/d with /, . or - between the parts; a four-digit first part is always the year. Two-digit
    /// years are 2000–2029 and 1930–1999, as in Excel.
    private static func day(_ text: String, order: PasteFormat.DateOrder) -> String? {
        guard let mark = text.first(where: { "/.-".contains($0) }) else { return nil }
        let parts = text.split(separator: mark, omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isASCII) }),
              let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]) else { return nil }
        var (year, month, day): (Int, Int, Int)
        if parts[0].count == 4 {
            (year, month, day) = (a, b, c)
        } else {
            switch order {
            case .dayMonthYear: (year, month, day) = (c, b, a)
            case .monthDayYear: (year, month, day) = (c, a, b)
            case .yearMonthDay: (year, month, day) = (a, b, c)
            }
            let yearDigits = order == .yearMonthDay ? parts[0].count : parts[2].count
            if yearDigits <= 2 { year += year < 30 ? 2000 : 1900 }
        }
        guard (0...9999).contains(year) else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
