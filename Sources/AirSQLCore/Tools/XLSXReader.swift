import Compression
import Foundation

/// The first sheet of an .xlsx workbook as rows of text (Import): its zip read through the central directory, the
/// sheet's XML through Foundation's parser. Numbers keep the digits the file holds; a cell with a date format reads
/// YYYY-MM-DD[ HH:MM:SS]; empty cells are empty. Formulas read as their saved values.
enum XLSXReader {
    /// A file inside a workbook is never larger in a real one: the bound keeps a hostile zip from filling memory.
    private static let largestPart = 1 << 31

    static func rows(_ data: Data) throws -> [[String]] {
        let zip = try ZipIndex(data)
        let shared = try zip.part("xl/sharedStrings.xml").map(SharedStrings.read) ?? []
        let dates = try zip.part("xl/styles.xml").map(DateStyles.read) ?? []
        var path = "xl/worksheets/sheet1.xml"
        var date1904 = false
        if let workbook = try zip.part("xl/workbook.xml") {
            let found = FirstSheet.read(workbook)
            date1904 = found.date1904
            if let id = found.relation, let relations = try zip.part("xl/_rels/workbook.xml.rels"),
               let target = Relations.read(relations)[id] {
                path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            }
        }
        guard let sheet = try zip.part(path) else { throw AirSQLError(.other, "The workbook has no sheet AirSQL can read.") }
        let reader = SheetReader(shared: shared, dates: dates, date1904: date1904)
        try reader.parse(sheet)
        return reader.rows
    }

    /// A zip's table of contents.
    private struct ZipIndex {
        struct Entry {
            var method: UInt16
            var compressed: Int
            var size: Int
            var offset: Int
        }

        let data: Data
        var entries: [String: Entry] = [:]

        init(_ data: Data) throws {
            self.data = data
            let notWorkbook = AirSQLError(.other, "This isn't an Excel workbook (.xlsx).")
            guard data.count >= 22 else { throw notWorkbook }
            // The end record is 22 bytes, then a comment of up to 64 KB.
            var end = data.count - 22
            let lowest = max(0, end - 65535)
            while end >= lowest, Self.le32(data, end) != 0x0605_4B50 { end -= 1 }
            guard end >= lowest else { throw notWorkbook }
            let count = Self.le16(data, end + 10)
            var at = Int(Self.le32(data, end + 16))
            for _ in 0..<count {
                guard at + 46 <= data.count, Self.le32(data, at) == 0x0201_4B50 else { throw notWorkbook }
                let nameLength = Self.le16(data, at + 28), extra = Self.le16(data, at + 30), comment = Self.le16(data, at + 32)
                guard at + 46 + nameLength <= data.count else { throw notWorkbook }
                let start = data.startIndex + at + 46
                let name = String(decoding: data[start..<start + nameLength], as: UTF8.self)
                entries[name] = Entry(method: UInt16(Self.le16(data, at + 10)), compressed: Int(Self.le32(data, at + 20)),
                                      size: Int(Self.le32(data, at + 24)), offset: Int(Self.le32(data, at + 42)))
                at += 46 + nameLength + extra + comment
            }
        }

        private static func le16(_ data: Data, _ at: Int) -> Int {
            Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8
        }

        private static func le32(_ data: Data, _ at: Int) -> UInt32 {
            UInt32(le16(data, at)) | UInt32(le16(data, at + 2)) << 16
        }

        /// The bytes of `name`, nil when there's no such part.
        func part(_ name: String) throws -> Data? {
            guard let entry = entries[name] else { return nil }
            let damaged = AirSQLError(.other, "The workbook is damaged: \(name) can't be read.")
            guard entry.offset + 30 <= data.count, entry.size <= XLSXReader.largestPart else { throw damaged }
            let start = entry.offset + 30 + Self.le16(data, entry.offset + 26) + Self.le16(data, entry.offset + 28)
            guard start + entry.compressed <= data.count else { throw damaged }
            let bytes = data[(data.startIndex + start)..<(data.startIndex + start + entry.compressed)]
            switch entry.method {
            case 0: return Data(bytes)
            case 8:
                guard entry.size > 0 else { return Data() }
                var out = Data(count: entry.size)
                let written = out.withUnsafeMutableBytes { target in
                    bytes.withUnsafeBytes { source in
                        // COMPRESSION_ZLIB is raw DEFLATE, as a zip holds it.
                        compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                                                  source.bindMemory(to: UInt8.self).baseAddress!, entry.compressed, nil, COMPRESSION_ZLIB)
                    }
                }
                guard written == entry.size else { throw damaged }
                return out
            default: throw damaged
            }
        }
    }

    /// Runs Foundation's parser over `data`, an error if it isn't XML.
    private class Handler: NSObject, XMLParserDelegate {
        func parse(_ data: Data) throws {
            let parser = XMLParser(data: data)
            parser.delegate = self
            guard parser.parse() else {
                throw AirSQLError(.other, "The workbook is damaged: \(parser.parserError?.localizedDescription ?? "its XML can't be read").")
            }
        }
    }

    /// `<si>` items: the text of their `<t>`s, without phonetic guides (`<rPh>`).
    private final class SharedStrings: Handler {
        private var items: [String] = []
        private var text = "", inText = false, phonetic = false

        static func read(_ data: Data) throws -> [String] {
            let reader = SharedStrings()
            try reader.parse(data)
            return reader.items
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            switch name {
            case "si": text = ""
            case "t": inText = !phonetic
            case "rPh": phonetic = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { text += string } }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "si": items.append(text)
            case "t": inText = false
            case "rPh": phonetic = false
            default: break
            }
        }
    }

    /// For each cell style, whether its number format is a date's.
    private final class DateStyles: Handler {
        private var custom: [Int: Bool] = [:]
        private var isDate: [Bool] = []
        private var inCellFormats = false

        static func read(_ data: Data) throws -> [Bool] {
            let reader = DateStyles()
            try reader.parse(data)
            return reader.isDate
        }

        /// y, m, d, h or s outside quotes, brackets and escapes.
        static func looksLikeDate(_ code: String) -> Bool {
            var quoted = false, bracket = false, escaped = false
            for character in code.lowercased() {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    quoted.toggle()
                } else if character == "[" {
                    bracket = true
                } else if character == "]" {
                    bracket = false
                } else if !quoted, !bracket, "ymdhs".contains(character) {
                    return true
                }
            }
            return false
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            if name == "numFmt", let id = attributes["numFmtId"].flatMap(Int.init) {
                custom[id] = Self.looksLikeDate(attributes["formatCode"] ?? "")
            } else if name == "cellXfs" {
                inCellFormats = true
            } else if name == "xf", inCellFormats {
                let id = attributes["numFmtId"].flatMap(Int.init) ?? 0
                isDate.append(custom[id] ?? ((14...22).contains(id) || (45...47).contains(id)))
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "cellXfs" { inCellFormats = false }
        }
    }

    /// The first `<sheet>`'s relation, and whether dates count from 1904.
    private final class FirstSheet: Handler {
        var relation: String?
        var date1904 = false

        static func read(_ data: Data) -> FirstSheet {
            let reader = FirstSheet()
            try? reader.parse(data)
            return reader
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            if name == "sheet", relation == nil { relation = attributes["r:id"] }
            if name == "workbookPr", let value = attributes["date1904"] { date1904 = value == "1" || value == "true" }
        }
    }

    private final class Relations: Handler {
        private var targets: [String: String] = [:]

        static func read(_ data: Data) -> [String: String] {
            let reader = Relations()
            try? reader.parse(data)
            return reader.targets
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] { targets[id] = target }
        }
    }

    private final class SheetReader: Handler {
        private let shared: [String]
        private let dates: [Bool]
        private let date1904: Bool
        private(set) var rows: [[String]] = []
        private var row: [String] = []
        private var rowNumber = 0
        private var column = 0, kind = "", style = 0
        private var text = "", collecting = false

        init(shared: [String], dates: [Bool], date1904: Bool) {
            self.shared = shared
            self.dates = dates
            self.date1904 = date1904
        }

        /// "BC12": 54 (from 0).
        static func column(of reference: String) -> Int? {
            var value = 0, seen = false
            for byte in reference.utf8 {
                guard (65...90).contains(byte) else { break }
                value = value * 26 + Int(byte) - 64
                seen = true
            }
            return seen ? value - 1 : nil
        }

        /// A serial day as the date Excel shows: days since 1899-12-30 (1904-01-01), the time as the fraction of a day.
        static func dateText(_ serial: Double, date1904: Bool) -> String? {
            guard serial >= 0, serial < 3_000_000 else { return nil }
            var seconds = Int64((serial * 86400).rounded())
            if date1904 { seconds += 1462 * 86400 }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = seconds % 86400 == 0 ? "yyyy-MM-dd" : serial < 1 ? "HH:mm:ss" : "yyyy-MM-dd HH:mm:ss"
            return formatter.string(from: Date(timeIntervalSince1970: Double(seconds) - 2_209_161_600))
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            switch name {
            case "row":
                // Rows left out of the file are empty ones: blank lines drop out later, as in a CSV.
                let number = attributes["r"].flatMap(Int.init) ?? rowNumber + 1
                while rowNumber + 1 < number {
                    rows.append([""])
                    rowNumber += 1
                }
                rowNumber = number
                row = []
            case "c":
                column = attributes["r"].flatMap(Self.column) ?? row.count
                kind = attributes["t"] ?? "n"
                style = attributes["s"].flatMap(Int.init) ?? 0
                text = ""
            case "v", "t":
                collecting = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if collecting { text += string } }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v", "t":
                collecting = false
            case "c":
                while row.count < column { row.append("") }
                row.append(value)
            case "row":
                while row.last == "" && row.count > 1 { row.removeLast() }
                rows.append(row.isEmpty ? [""] : row)
            default: break
            }
        }

        private var value: String {
            switch kind {
            case "s": return Int(text).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
            case "e": return ""
            case "b", "str", "inlineStr": return text
            default:
                if style < dates.count, dates[style], let serial = Double(text),
                   let date = Self.dateText(serial, date1904: date1904) { return date }
                return text
            }
        }
    }
}
