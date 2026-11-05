import Foundation

/// The text formats the grid copies and exports rows in (grid-spec §6). ⌘C copies in the last format chosen in Copy As
/// (TSV at first); Export adds Excel (`XLSXWriter`). A `CopyWriter` writes a format a part at a time (header, rows,
/// footer), so exporting every row of a table streams instead of holding them.
public enum CopyFormat: String, CaseIterable, Codable, Sendable {
    case tsv, csv, pipe, json, jsonLines, markdown, html, xml, prettyTable, oneRow, insert, insertRows, insertIgnore, replace, update, delete, whereClause, inList

    public var title: String {
        switch self {
        case .tsv: "TSV"
        case .csv: "CSV"
        case .pipe: "Pipe-Separated"
        case .prettyTable: "Pretty Table"
        case .oneRow: "One Row"
        case .insertRows: "SQL INSERT, Many Rows"
        case .json: "JSON"
        case .jsonLines: "JSON Lines"
        case .markdown: "Markdown"
        case .html: "HTML Table"
        case .xml: "XML"
        case .insert: "SQL INSERT"
        case .insertIgnore: "SQL INSERT IGNORE"
        case .replace: "SQL REPLACE"
        case .update: "SQL UPDATE"
        case .delete: "SQL DELETE"
        case .whereClause: "WHERE Clause"
        case .inList: "IN List"
        }
    }

    public var fileExtension: String {
        switch self {
        case .tsv: "tsv"
        case .csv: "csv"
        case .pipe, .prettyTable, .oneRow: "txt"
        case .json: "json"
        case .jsonLines: "jsonl"
        case .markdown: "md"
        case .html: "html"
        case .xml: "xml"
        case .insert, .insertRows, .insertIgnore, .replace, .update, .delete, .whereClause, .inList: "sql"
        }
    }

    /// Formats whose first line can be the column names (the others name them anyway).
    public var hasOptionalHeaders: Bool { self == .tsv || self == .csv || self == .pipe }
}

/// How rows are written: column names first (TSV and CSV), what NULL looks like, CSV's separator, line endings, and the
/// session's NO_BACKSLASH_ESCAPES for the SQL formats' strings.
public struct CopyOptions: Codable, Equatable, Sendable {
    public var headers = false
    public var nullText = "NULL"
    public var separator = ","
    public var lineEnding = "\n"
    public var noBackslashEscapes = false

    public init(headers: Bool = false, nullText: String = "NULL") {
        self.headers = headers
        self.nullText = nullText
    }
}

/// Writes rows in one format. Values are text as the grid shows it in full (never shortened), nil for NULL; binary
/// values are "0x…" hex. The SQL formats name `table` (in `database` when given) and address rows by the key columns
/// among those copied (`GridCopy` adds the rest of the key), or by every column when there are none.
public struct CopyWriter {
    public let format: CopyFormat
    public let columns: [GridColumn]
    public var database: String?
    public var table: String
    public var options: CopyOptions
    public private(set) var rowsWritten = 0
    /// WHERE Clause on one column and IN List: the values listed so far, and whether a NULL was left out of the clause.
    private var listed = 0
    private var sawNull = false
    /// Pretty Table's rows: its columns' widths need them all.
    private var pretty: [[String]] = []

    public init(_ format: CopyFormat, columns: [GridColumn], database: String? = nil, table: String = "table",
                options: CopyOptions = CopyOptions()) {
        self.format = format
        self.columns = columns
        self.database = database
        self.table = table
        self.options = options
    }

    /// Everything at once: header, rows and footer.
    public static func text(_ format: CopyFormat, columns: [GridColumn], rows: [[String?]], database: String? = nil,
                            table: String = "table", options: CopyOptions = CopyOptions()) -> String {
        var writer = CopyWriter(format, columns: columns, database: database, table: table, options: options)
        var text = writer.header()
        for row in rows { text += writer.row(row) }
        return text + writer.footer()
    }

    private var eol: String { options.lineEnding }

    public func header() -> String {
        let names = columns.map(\.name)
        switch format {
        case .tsv: return options.headers ? names.map(tsvField).joined(separator: "\t") + eol : ""
        case .csv, .pipe: return options.headers ? names.map(csvField).joined(separator: separator) + eol : ""
        case .json: return "["
        case .markdown:
            return "| " + names.map(markdownCell).joined(separator: " | ") + " |" + eol
                + "|" + columns.map { $0.kind == .number ? " ---: |" : " --- |" }.joined() + eol
        case .html:
            return "<table>" + eol + "<thead><tr>" + names.map { "<th>\(html($0))</th>" }.joined() + "</tr></thead>" + eol
                + "<tbody>" + eol
        case .xml: return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + eol + "<table name=\"\(xml(table))\">" + eol
        case .whereClause where columns.count == 1: return SQLQuote.identifier(columns[0].name) + " IN ("
        case .jsonLines, .prettyTable, .oneRow, .insert, .insertRows, .insertIgnore, .replace, .update, .delete, .whereClause, .inList: return ""
        }
    }

    public mutating func row(_ values: [String?]) -> String {
        defer { rowsWritten += 1 }
        switch format {
        case .tsv: return values.map { tsvField($0 ?? options.nullText) }.joined(separator: "\t") + eol
        case .csv, .pipe:
            // Text that reads as NULL is quoted: a bare NULL is the real one, which CSV import reads back.
            return values.map { value in value.map { $0 == options.nullText ? quoted($0) : csvField($0) } ?? csvField(options.nullText) }
                .joined(separator: separator) + eol
        case .prettyTable:
            pretty.append(values.map { ($0 ?? options.nullText).split(whereSeparator: \.isNewline).joined(separator: " ") })
            return ""
        case .oneRow: return (rowsWritten == 0 ? "" : ", ") + values.map { $0 ?? options.nullText }.joined(separator: ", ")
        case .insertRows:
            let written = columns.indices.filter { !columns[$0].marks.contains(.generated) }
            let start = rowsWritten > 0 ? "," + eol : "INSERT INTO " + qualifiedTable + " (" + written.map { SQLQuote.identifier(columns[$0].name) }.joined(separator: ", ")
                + ") VALUES" + eol
            return start + "  (" + written.map { literal(values[$0], columns[$0]) }.joined(separator: ", ") + ")"
        case .json: return (rowsWritten == 0 ? eol : "," + eol) + "  " + jsonObject(values)
        case .jsonLines: return jsonObject(values) + eol
        case .markdown: return "| " + values.map { markdownCell($0 ?? options.nullText) }.joined(separator: " | ") + " |" + eol
        case .html: return "<tr>" + values.map { "<td>\(html($0 ?? options.nullText))</td>" }.joined() + "</tr>" + eol
        case .xml:
            let fields = zip(columns, values).map { column, value in
                value.map { "    <field name=\"\(xml(column.name))\">\(xml($0))</field>" }
                    ?? "    <field name=\"\(xml(column.name))\" null=\"true\"/>"
            }
            return "  <row>" + eol + fields.joined(separator: eol) + eol + "  </row>" + eol
        case .insert, .insertIgnore, .replace:
            let verb = format == .insert ? "INSERT INTO" : format == .insertIgnore ? "INSERT IGNORE INTO" : "REPLACE INTO"
            // Generated columns take no value: the server refuses one.
            let written = columns.indices.filter { !columns[$0].marks.contains(.generated) }
            return verb + " " + qualifiedTable + " (" + written.map { SQLQuote.identifier(columns[$0].name) }.joined(separator: ", ")
                + ") VALUES (" + written.map { literal(values[$0], columns[$0]) }.joined(separator: ", ") + ");" + eol
        case .update:
            let keys = keyIndexes
            let set = columns.indices.filter { (!keys.contains($0) || keys.count == columns.count) && !columns[$0].marks.contains(.generated) }
                .map { SQLQuote.identifier(columns[$0].name) + " = " + literal(values[$0], columns[$0]) }
            return "UPDATE " + qualifiedTable + " SET " + set.joined(separator: ", ") + " WHERE " + condition(values, keys) + ";" + eol
        case .delete: return "DELETE FROM " + qualifiedTable + " WHERE " + condition(values, keyIndexes) + ";" + eol
        case .whereClause:
            if columns.count == 1 {
                guard let value = values[0] else {
                    sawNull = true
                    return ""
                }
                listed += 1
                return (listed == 1 ? "" : ", ") + literal(value, columns[0])
            }
            return (rowsWritten == 0 ? "" : eol + "OR ") + "(" + condition(values, Array(columns.indices)) + ")"
        case .inList:
            // Every cell, for the brackets of an IN, which a NULL can never match.
            var text = ""
            for (value, column) in zip(values, columns) where value != nil {
                text += (listed == 0 ? "" : ", ") + literal(value, column)
                listed += 1
            }
            return text
        }
    }

    public func footer() -> String {
        switch format {
        case .json: return (rowsWritten == 0 ? "" : eol) + "]" + eol
        case .insertRows: return rowsWritten == 0 ? "" : ";" + eol
        case .oneRow: return rowsWritten == 0 ? "" : eol
        case .prettyTable: return prettyTable
        case .html: return "</tbody>" + eol + "</table>" + eol
        case .xml: return "</table>" + eol
        case .whereClause where columns.count == 1:
            // IN (NULL) matches nothing, as a list of no values should.
            return (listed == 0 ? "NULL)" : ")") + (sawNull ? " OR " + SQLQuote.identifier(columns[0].name) + " IS NULL" : "")
        default: return ""
        }
    }

    private var separator: String { format == .pipe ? "|" : options.separator }

    /// The rows in lines and columns of plain text, numbers to the right.
    private var prettyTable: String {
        let names = columns.map(\.name)
        let widths = names.indices.map { index in pretty.reduce(names[index].count) { max($0, $1[index].count) } }
        func line(_ cells: [String], right: Bool) -> String {
            "| " + cells.indices.map { index in
                let room = String(repeating: " ", count: widths[index] - cells[index].count)
                return right && columns[index].kind == .number ? room + cells[index] : cells[index] + room
            }.joined(separator: " | ") + " |" + eol
        }
        let rule = "+" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "+") + "+" + eol
        return rule + line(names, right: false) + rule + pretty.map { line($0, right: true) }.joined() + rule
    }

    private var qualifiedTable: String {
        database.map { SQLQuote.identifier($0, table) } ?? SQLQuote.identifier(table)
    }

    /// The key columns among those written, or every column when none is a key.
    private var keyIndexes: [Int] {
        let keys = columns.indices.filter { columns[$0].isKey }
        return keys.isEmpty ? Array(columns.indices) : keys
    }

    private func condition(_ values: [String?], _ indexes: [Int]) -> String {
        indexes.map { index in
            let name = SQLQuote.identifier(columns[index].name)
            return values[index] == nil ? name + " IS NULL" : name + " = " + literal(values[index], columns[index])
        }.joined(separator: " AND ")
    }

    // MARK: Values

    func literal(_ value: String?, _ column: GridColumn) -> String {
        column.literal(value, noBackslashEscapes: options.noBackslashEscapes)
    }

    /// A number as JSON writes one (and SQL reads it): -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?
    static func isNumber(_ text: String) -> Bool {
        var bytes = Array(text.utf8)[...]
        func digits() -> Int {
            let count = bytes.prefix { $0 >= 48 && $0 <= 57 }.count
            bytes = bytes.dropFirst(count)
            return count
        }
        if bytes.first == UInt8(ascii: "-") { bytes = bytes.dropFirst() }
        let first = bytes.first
        let whole = digits()
        guard whole == 1 || (whole > 1 && first != UInt8(ascii: "0")) else { return false }
        if bytes.first == UInt8(ascii: ".") {
            bytes = bytes.dropFirst()
            guard digits() > 0 else { return false }
        }
        if bytes.first == UInt8(ascii: "e") || bytes.first == UInt8(ascii: "E") {
            bytes = bytes.dropFirst()
            if bytes.first == UInt8(ascii: "+") || bytes.first == UInt8(ascii: "-") { bytes = bytes.dropFirst() }
            guard digits() > 0 else { return false }
        }
        return bytes.isEmpty
    }

    /// The hex digits of a whole "0x…" value (as the grid shows binary values), nil for anything else.
    static func hexDigits(_ text: String) -> String? {
        guard text.hasPrefix("0x") || text.hasPrefix("0X") else { return nil }
        let digits = text.dropFirst(2)
        guard digits.count % 2 == 0, digits.allSatisfy(\.isHexDigit), digits.allSatisfy(\.isASCII) else { return nil }
        return String(digits).uppercased()
    }

    private func jsonObject(_ values: [String?]) -> String {
        "{" + zip(columns, values).map { column, value in
            CopyWriter.jsonString(column.name) + ": " + jsonValue(value, column)
        }.joined(separator: ", ") + "}"
    }

    private func jsonValue(_ value: String?, _ column: GridColumn) -> String {
        guard let value else { return "null" }
        if column.kind == .number, CopyWriter.isNumber(value) { return value }
        if column.kind == .json, let data = value.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil {
            return value
        }
        return CopyWriter.jsonString(value)
    }

    static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar == "\u{2028}" || scalar == "\u{2029}":
                out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// TSV as spreadsheets paste it: a value with a tab or a line break, or starting with a quote, in double quotes.
    private func tsvField(_ text: String) -> String {
        text.contains(where: { $0 == "\t" || $0.isNewline }) || text.hasPrefix("\"") ? quoted(text) : text
    }

    /// CSV as RFC 4180 writes it: a value with the separator, a quote or a line break in double quotes.
    private func csvField(_ text: String) -> String {
        text.contains(where: { $0 == "\"" || $0.isNewline }) || text.contains(separator) ? quoted(text) : text
    }

    private func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    private func markdownCell(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }

    private func html(_ text: String) -> String {
        xml(text).replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\n", with: "<br>")
    }

    /// Text for XML and HTML: the five entities, and � for the control characters XML 1.0 can't hold.
    func xml(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF: out += "\u{FFFD}"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
