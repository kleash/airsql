import Foundation

/// How pasted text is read (the Paste Format sheet overrides the guesses).
public struct PasteFormat: Equatable {
    public enum Separator: Equatable, Sendable {
        /// Tabs, as Excel and Numbers copy cells; text without a tab is one column (a lone "1,5" is never split).
        case auto
        case tab, comma, semicolon
    }

    public enum DateOrder: Equatable, Sendable { case dayMonthYear, monthDayYear, yearMonthDay }

    public var separator: Separator
    /// "." or ","; nil works it out from the column's values, then from `locale` for one like 1,234.
    public var decimalSeparator: Character?
    /// nil works it out from the column's values (a part over 12 is the day), then from `locale` for one like 03/04/2026.
    public var dateOrder: DateOrder?
    /// A cell that means NULL, such as "NULL" or "\N"; nil for none (an empty cell is NULL in a nullable non-text column).
    public var nullText: String?
    public var locale: Locale

    public init(separator: Separator = .auto, decimalSeparator: Character? = nil, dateOrder: DateOrder? = nil,
                nullText: String? = nil, locale: Locale = .current) {
        self.separator = separator
        self.decimalSeparator = decimalSeparator
        self.dateOrder = dateOrder
        self.nullText = nullText
        self.locale = locale
    }
}

/// A pasted cell that can't be saved, and why.
public struct PasteFailure: Equatable, Sendable {
    public var row: Int
    public var column: Int
    public var text: String
    public var reason: String
}

/// Paste from Excel, Numbers or CSV (grid-spec §5): the text becomes a rectangle of cells, and each cell the SQL for
/// the column it lands in, converted from the way people write numbers and dates where they live.
public enum Paste {
    /// The rows of pasted text, each padded to the widest: cells in double quotes may hold separators, quotes (written
    /// twice) and line breaks; a line break at the very end adds no row. A single line with no separator is one cell,
    /// as it is.
    public static func cells(_ text: String, separator: PasteFormat.Separator = .auto) -> [[String]] {
        let mark: Unicode.Scalar?
        switch separator {
        case .auto, .tab: mark = text.unicodeScalars.contains("\t") || separator == .tab ? "\t" : nil
        case .comma: mark = ","
        case .semicolon: mark = ";"
        }
        // One line without a separator is one value, quotes and all.
        var line = Substring(text)
        if line.last?.isNewline == true { line = line.dropLast() }
        if mark == nil, !line.isEmpty, !line.contains(where: \.isNewline) { return [[String(line)]] }
        var rows: [[String]] = [], row: [String] = [], cell = String.UnicodeScalarView()
        var quoted = false, cellStart = true
        var scalars = text.unicodeScalars[...]
        func endCell() { row.append(String(cell)); cell = String.UnicodeScalarView(); cellStart = true }
        while let scalar = scalars.popFirst() {
            if quoted {
                if scalar == "\"" {
                    if scalars.first == "\"" { cell.append("\""); scalars.removeFirst() } else { quoted = false }
                } else {
                    cell.append(scalar)
                }
            } else if scalar == "\"" && cellStart {
                quoted = true
                cellStart = false
            } else if scalar == mark {
                endCell()
            } else if scalar == "\r" || scalar == "\n" {
                if scalar == "\r", scalars.first == "\n" { scalars.removeFirst() }
                endCell()
                rows.append(row)
                row = []
            } else {
                cell.append(scalar)
                cellStart = false
            }
        }
        if !cellStart || !row.isEmpty || !cell.isEmpty { endCell(); rows.append(row) }
        let width = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
    }

    /// Each cell as SQL for its column (`columns[i]` takes the i-th pasted column): a literal, or NULL. nil leaves the
    /// cell as it is: a failure (listed with its reason), an empty cell in a NOT NULL non-text column (a new row then
    /// gets the column's default), or a cell past the last column (listed).
    public static func convert(_ cells: [[String]], columns: [SchemaColumn], format: PasteFormat = PasteFormat(),
                               context: EditContext) -> (values: [[String?]], failures: [PasteFailure]) {
        let (values, failures) = values(cells, columns: columns, format: format, context: context)
        let types = columns.map(ColumnType.init)
        return (values.map { line in
            line.enumerated().map { index, value -> String? in
                switch value {
                case .text(let text)?: return try? types[index].literal(text, context)
                case .null?: return "NULL"
                default: return nil
                }
            }
        }, failures)
    }

    /// The cells as pending values, as `convert` decides them: `.text` written the way `ColumnType.literal` reads it
    /// (numbers with a point and no grouping, dates as YYYY-MM-DD; checked already), `.null`, or nil to leave the cell.
    public static func values(_ cells: [[String]], columns: [SchemaColumn], format: PasteFormat = PasteFormat(),
                              context: EditContext) -> (values: [[PendingChanges.Value?]], failures: [PasteFailure]) {
        let width = cells.map(\.count).max() ?? 0
        let types = columns.map(ColumnType.init)
        let decimals = (0..<min(width, columns.count)).map { index in
            format.decimalSeparator ?? decimalSeparator(cells.map { $0[index] }, locale: format.locale)
        }
        let orders = (0..<min(width, columns.count)).map { index in
            format.dateOrder ?? dateOrder(cells.map { $0[index] }, locale: format.locale)
        }
        var failures: [PasteFailure] = []
        let values = cells.enumerated().map { row, line in
            line.enumerated().map { index, text -> PendingChanges.Value? in
                guard index < columns.count else {
                    failures.append(PasteFailure(row: row, column: index, text: text, reason: "No column here to paste into"))
                    return nil
                }
                let column = columns[index], type = types[index]
                do {
                    if let reason = column.readOnlyReason { throw EditError(reason) }
                    if text == format.nullText || text.isEmpty && !isText(type) {
                        if column.nullable { return .null }
                        if text.isEmpty { return nil }
                        throw EditError("The column is NOT NULL")
                    }
                    let normalised = try normalised(text, type, decimal: decimals[index], order: orders[index])
                    _ = try type.literal(normalised, context)
                    return .text(normalised)
                } catch {
                    failures.append(PasteFailure(row: row, column: index, text: text,
                                                 reason: (error as? EditError)?.message ?? "\(error)"))
                    return nil
                }
            }
        }
        return (values, failures)
    }

    private static func isText(_ type: ColumnType) -> Bool {
        switch type.kind {
        case .text, .set: return true
        default: return false
        }
    }

    /// The cell written the way `literal` reads it: numbers without grouping and with a point, dates as YYYY-MM-DD.
    static func normalised(_ text: String, _ type: ColumnType, decimal: Character, order: PasteFormat.DateOrder) throws -> String {
        switch type.kind {
        case .integer, .decimal, .float:
            if type.isBoolean { return text }
            let cleaned = cleanNumber(text)
            let grouping: Character = decimal == "," ? "." : ","
            return String(cleaned.filter { $0 != grouping }.map { $0 == decimal ? "." : $0 })
        case .date, .datetime, .timestamp, .time:
            return try PasteDates.normalised(text.trimmingCharacters(in: .whitespaces), type, order: order)
        default:
            return text
        }
    }

    /// Spaces, no-break spaces and apostrophes between digit groups gone; − as a minus sign.
    static func cleanNumber(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespaces).filter { !" \u{A0}\u{202F}'’".contains($0) }
            .map { $0 == "−" ? "-" : $0 })
    }

    /// The decimal separator a column's numbers use: both "." and "," in one value make the last one decimal; one of
    /// them twice makes it grouping; one followed by other than three digits is decimal. Otherwise the locale's.
    static func decimalSeparator(_ texts: [String], locale: Locale) -> Character {
        for text in texts.lazy.map(cleanNumber) {
            let marks = text.filter { $0 == "." || $0 == "," }
            guard let last = marks.last else { continue }
            if Set(marks).count == 2 { return last }
            if marks.count > 1 { return last == "." ? "," : "." }
            let after = text.drop { $0 != last }.dropFirst().prefix { $0.isNumber }
            if after.count != 3 { return last }
        }
        return locale.decimalSeparator == "," ? "," : "."
    }

    /// The order of day, month and year in a column's dates: a first part over 12 is the day, a second one over 12
    /// the day too (month first). Otherwise the locale's order.
    static func dateOrder(_ texts: [String], locale: Locale) -> PasteFormat.DateOrder {
        for text in texts {
            let parts = text.trimmingCharacters(in: .whitespaces).prefix { $0 != " " && $0 != "T" }
                .split(whereSeparator: { "/.-".contains($0) }).compactMap { Int($0) }
            guard parts.count == 3, parts[0] < 100 else { continue }
            if parts[0] > 12 { return .dayMonthYear }
            if parts[1] > 12 { return .monthDayYear }
        }
        let pattern = DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: locale) ?? "y-M-d"
        let positions = ["d", "M", "y"].map { pattern.firstIndex(of: Character($0)) ?? pattern.endIndex }
        if positions[2] < positions[1] { return .yearMonthDay }
        return positions[0] < positions[1] ? .dayMonthYear : .monthDayYear
    }
}
