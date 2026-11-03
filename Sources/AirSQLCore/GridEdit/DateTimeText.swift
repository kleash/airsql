import Foundation

/// DATE, TIME, DATETIME, TIMESTAMP and YEAR values as people type them, checked the way the session's sql_mode would
/// check them, so Apply never meets a value the server would refuse or quietly change. Zero dates are kept as typed
/// where sql_mode allows them; more fractional digits than the column keeps are refused (the server would round).
enum DateTimeText {
    static func literal(_ text: String, _ type: ColumnType, _ context: EditContext) throws -> String {
        let canonical: String
        switch type.kind {
        case .date: canonical = try date(text, type, context)
        case .time(let fraction): canonical = try time(text, fraction: fraction, type)
        case .datetime(let fraction), .timestamp(let fraction): canonical = try dateTime(text, fraction: fraction, type, context)
        default: return try year(text)
        }
        return SQLQuote.string(canonical, noBackslashEscapes: context.noBackslashEscapes)
    }

    /// YEAR: four digits, 1901 to 2155, or 0000. A bare number: 0 is the zero year, where '0' would be 2000.
    private static func year(_ text: String) throws -> String {
        guard text.count == 4 || text == "0", let value = Int(text), text.allSatisfy(\.isNumber),
              value == 0 || (1901...2155).contains(value) else {
            throw EditError("YEAR holds four digits from 1901 to 2155, or 0000")
        }
        return String(value)
    }

    /// YYYY-MM-DD (the month and day may have one digit).
    private static func date(_ text: String, _ type: ColumnType, _ context: EditContext) throws -> String {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, (1...2).contains(parts[1].count), (1...2).contains(parts[2].count),
              let year = number(parts[0]), let month = number(parts[1]), let day = number(parts[2]) else {
            throw EditError(type.kind == .date ? "Type the date as YYYY-MM-DD, such as 2026-11-03"
                : "Type the date and time as YYYY-MM-DD hh:mm:ss, such as 2026-11-03 14:05:00")
        }
        try check(year: year, month: month, day: day, type, context)
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// A date, then a space or T and the time of day; the date alone is midnight.
    private static func dateTime(_ text: String, fraction: Int, _ type: ColumnType, _ context: EditContext) throws -> String {
        let halves = text.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "T" })
        let day = try date(String(halves.first ?? ""), type, context)
        guard halves.count == 2 else { return day + " 00:00:00" }
        let (negative, hours, minutes, seconds, digits) = try clock(String(halves[1]), type, days: false)
        guard !negative, hours < 24 else { throw EditError("The time of day runs from 00:00:00 to 23:59:59") }
        let time = String(format: "%02d:%02d:%02d", hours, minutes, seconds) + (try fractionText(digits, keeps: fraction))
        if case .timestamp = type.kind, day != "0000-00-00" || time.contains(where: { $0 != "0" && $0 != ":" && $0 != "." }) {
            // TIMESTAMP counts seconds from 1970 (UTC) to 2038, or 2106 on MariaDB 11.5 and later; the edges depend on
            // the time zone, so only the year is checked here and the server checks the rest.
            let last = context.flavour == .mariadb && context.atLeast(11, 5) ? 2106 : 2038
            guard let year = Int(day.prefix(4)), (1970...last).contains(year) else {
                throw EditError("TIMESTAMP holds dates from 1970 to \(last); use DATETIME for others")
            }
        }
        return day + " " + time
    }

    /// TIME: [-][D ]h:mm[:ss[.ffffff]], up to ±838:59:59; written back as [-]hh:mm:ss[.f…].
    private static func time(_ text: String, fraction: Int, _ type: ColumnType) throws -> String {
        let (negative, hours, minutes, seconds, digits) = try clock(text, type, days: true)
        let fractionPart = try fractionText(digits, keeps: fraction)
        let fractionZero = !fractionPart.contains { "123456789".contains($0) }
        guard hours < 838 || hours == 838 && fractionZero else { throw EditError("TIME holds -838:59:59 to 838:59:59") }
        let zero = hours == 0 && minutes == 0 && seconds == 0 && fractionZero
        return (negative && !zero ? "-" : "") + String(format: "%02d:%02d:%02d", hours, minutes, seconds) + fractionPart
    }

    /// Hours (with days folded in), minutes, seconds and the fraction's digits of h:mm[:ss[.f]].
    private static func clock(_ text: String, _ type: ColumnType, days allowDays: Bool)
        throws -> (Bool, Int, Int, Int, Substring) {
        var rest = Substring(text)
        let negative = allowDays && rest.first == "-"
        if negative { rest = rest.dropFirst() }
        var days = 0
        if allowDays, let space = rest.firstIndex(of: " ") {
            guard let value = number(rest[..<space]), value <= 34 else { throw EditError("Type the time as hh:mm:ss, such as 14:05:00") }
            days = value
            rest = rest[rest.index(after: space)...]
        }
        let dot = rest.firstIndex(of: ".")
        let digits = dot.map { rest[rest.index(after: $0)...] } ?? ""
        let parts = rest[..<(dot ?? rest.endIndex)].split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), (1...3).contains(parts[0].count), parts.dropFirst().allSatisfy({ $0.count == 2 }),
              let hours = number(parts[0]), let minutes = number(parts[1]), let seconds = parts.count == 3 ? number(parts[2]) : 0,
              dot == nil || (parts.count == 3 && !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }) else {
            throw EditError(allowDays ? "Type the time as hh:mm:ss, such as 14:05:00"
                : "Type the date and time as YYYY-MM-DD hh:mm:ss, such as 2026-11-03 14:05:00")
        }
        guard minutes < 60, seconds < 60 else { throw EditError("Minutes and seconds run from 00 to 59") }
        return (negative, days * 24 + hours, minutes, seconds, digits)
    }

    /// ".123" for the digits the column keeps; digits past that are fine only when they are zeros.
    private static func fractionText(_ digits: Substring, keeps: Int) throws -> String {
        var kept = digits
        while kept.count > keeps, kept.last == "0" { kept = kept.dropLast() }
        guard kept.count <= keeps else {
            throw EditError(keeps == 0 ? "This column keeps whole seconds; leave out the fraction"
                : "This column keeps \(keeps) digit\(keeps == 1 ? "" : "s") after the seconds; round .\(digits) first")
        }
        return kept.isEmpty ? "" : "." + kept
    }

    /// Month 1–12 and a day the month has; zero dates and zero parts only where sql_mode allows them.
    private static func check(year: Int, month: Int, day: Int, _ type: ColumnType, _ context: EditContext) throws {
        var timestamp = false
        if case .timestamp = type.kind { timestamp = true }
        if year == 0 && month == 0 && day == 0 {
            guard !(context.sqlMode.contains("NO_ZERO_DATE") && context.strict) else {
                throw EditError("This server's sql_mode (NO_ZERO_DATE) refuses the zero date; type a real date or use Set NULL")
            }
            return
        }
        if month == 0 || day == 0 {
            // Without strict mode the server would save 0000-00-00 instead, with only a warning.
            guard !context.sqlMode.contains("NO_ZERO_IN_DATE") else {
                throw EditError("This server's sql_mode (NO_ZERO_IN_DATE) refuses a 0 month or day")
            }
            guard !timestamp else { throw EditError("TIMESTAMP has no 0 month or day") }
            guard month <= 12, day <= 31 else { throw EditError("Months run from 1 to 12 and days from 1 to 31") }
            return
        }
        guard month <= 12 else { throw EditError("Months run from 1 to 12") }
        let invalidAllowed = context.sqlMode.contains("ALLOW_INVALID_DATES") && !timestamp
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let length = invalidAllowed ? 31 : [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        guard day <= length else {
            let names = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                         "October", "November", "December"]
            throw EditError("\(names[month - 1]) \(year) has \(length) days")
        }
    }

    private static func number(_ text: Substring) -> Int? {
        text.isEmpty || !text.allSatisfy({ $0.isASCII && $0.isNumber }) ? nil : Int(text)
    }
}
