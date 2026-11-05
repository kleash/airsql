import Darwin
import Foundation

/// Where an import's rows come from: a file (CSV and the like; .xlsx and .json by their extension), text at hand (the
/// clipboard), or rows at hand (a result: the first one its column names, nil for NULL).
public enum ImportSource: Equatable, Sendable {
    case file(URL)
    case text(String)
    case rows([[String?]])

    /// A field that is a real NULL, whatever "Empty fields become NULL" says: no file's text is this.
    public static let null = "\u{0}NULL\u{0}"

    /// The kinds of file with a format of their own.
    public enum Kind: Sendable {
        case delimited, excel, json
    }

    public var kind: Kind {
        guard case .file(let url) = self else { return .delimited }
        switch url.pathExtension.lowercased() {
        case "xlsx": return .excel
        case "json", "jsonl", "ndjson": return .json
        default: return .delimited
        }
    }

    /// The start of the text, for guessing its separator. File work.
    func sample() throws -> Data {
        switch self {
        case .text(let text): return Data(text.utf8.prefix(256 << 10))
        case .rows: return Data()
        case .file(let url):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return handle.readData(ofLength: 256 << 10)
        }
    }
}

/// A source's records in pieces, past the ones to skip: delimited files stream; Excel and JSON, whose reading needs the
/// whole, come as one piece. File work.
public final class ImportRecords {
    /// How much of the source has been read, of `size`.
    public private(set) var bytes: Int64 = 0
    public let size: Int64
    public var notUTF8: Bool { reader.readWindows1252 }
    private var reader: CSVReader
    private let source: ImportSource
    private var fd: Int32 = -1
    private var ended = false
    private var toSkip: Int

    public init(_ source: ImportSource, options: CSVImport.Options) throws {
        self.source = source
        reader = options.reader()
        toSkip = options.skipRecords
        guard case .file(let url) = source else {
            switch source {
            case .text(let text): size = Int64(text.utf8.count)
            case .rows(let rows): size = Int64(rows.count)
            case .file: size = 0
            }
            return
        }
        fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw AirSQLError(.other, "Can't open \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        var info = stat()
        fstat(fd, &info)
        size = Int64(info.st_size)
    }

    public func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    /// The next records (perhaps none yet); nil at the end.
    public func next() throws -> [[String]]? {
        guard !ended else { return nil }
        var records = try read()
        let skipped = min(toSkip, records.count)
        toSkip -= skipped
        records.removeFirst(skipped)
        return records
    }

    private func read() throws -> [[String]] {
        if case .text(let text) = source {
            ended = true
            bytes = size
            return try reader.read(Data(text.utf8)) + reader.finish()
        }
        if case .rows(let rows) = source {
            ended = true
            bytes = size
            return rows.map { $0.map { $0 ?? ImportSource.null } }
        }
        if case .file(let url) = source, source.kind != .delimited {
            ended = true
            bytes = size
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return source.kind == .excel ? try XLSXReader.rows(data) : try JSONRecords.rows(data)
        }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw AirSQLError(.other, "Can't read the file: \(String(cString: strerror(errno)))") }
            guard count > 0 else {
                ended = true
                return try reader.finish()
            }
            bytes += Int64(count)
            return reader.read(Data(buffer[0..<count]))
        }
    }
}

/// JSON as rows: an array of objects, or objects one after another (JSON Lines). The first record is the keys, in the
/// order first seen; a key a record lacks is empty, and null is NULL. Numbers keep their digits and nested values their
/// text, so it reads the text itself rather than through JSONSerialization, which keeps neither nor the keys' order.
enum JSONRecords {
    static func rows(_ data: Data) throws -> [[String]] {
        var scanner = Scanner(bytes: Array(data))
        var objects: [[(key: String, value: String)]] = []
        scanner.skipSpace()
        let inArray = scanner.peek == UInt8(ascii: "[")
        if inArray { scanner.at += 1 }
        while true {
            scanner.skipSpace()
            if scanner.peek == UInt8(ascii: ",") {
                scanner.at += 1
                continue
            }
            if scanner.peek == nil || (inArray && scanner.peek == UInt8(ascii: "]")) { break }
            objects.append(try scanner.object())
        }
        var keys: [String] = [], seen: [String: Int] = [:]
        for object in objects {
            for pair in object where seen[pair.key] == nil {
                seen[pair.key] = keys.count
                keys.append(pair.key)
            }
        }
        guard !keys.isEmpty else { throw AirSQLError(.other, "The JSON has no objects to read rows from.") }
        return [keys] + objects.map { object in
            var row = [String](repeating: "", count: keys.count)
            for pair in object { row[seen[pair.key] ?? 0] = pair.value }
            return row
        }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var at = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { at = 3 }
        }

        var peek: UInt8? { at < bytes.count ? bytes[at] : nil }

        mutating func skipSpace() {
            while let byte = peek, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { at += 1 }
        }

        private func failure() -> AirSQLError {
            let line = bytes[..<min(at, bytes.count)].reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
            return AirSQLError(.other, "The JSON can't be read: expected an object at line \(line).")
        }

        /// `{…}` as its keys and values, in order.
        mutating func object() throws -> [(key: String, value: String)] {
            guard peek == UInt8(ascii: "{") else { throw failure() }
            at += 1
            var pairs: [(key: String, value: String)] = []
            while true {
                skipSpace()
                if peek == UInt8(ascii: "}") {
                    at += 1
                    return pairs
                }
                if peek == UInt8(ascii: ",") {
                    at += 1
                    continue
                }
                let start = at
                try skipValue()
                let key = try text(start..<at)
                skipSpace()
                guard peek == UInt8(ascii: ":") else { throw failure() }
                at += 1
                skipSpace()
                let valueStart = at, first = peek
                try skipValue()
                switch first {
                case UInt8(ascii: "\""): pairs.append((key, try text(valueStart..<at)))
                case UInt8(ascii: "n"): pairs.append((key, ImportSource.null))
                case UInt8(ascii: "t"): pairs.append((key, "1"))
                case UInt8(ascii: "f"): pairs.append((key, "0"))
                default: pairs.append((key, String(decoding: bytes[valueStart..<at], as: UTF8.self)))
                }
            }
        }

        private func text(_ range: Range<Int>) throws -> String {
            let string = try? JSONSerialization.jsonObject(with: Data(bytes[range]), options: .fragmentsAllowed) as? String
            guard let string else { throw failure() }
            return string
        }

        /// Moves past one value of any kind.
        private mutating func skipValue() throws {
            guard let first = peek else { throw failure() }
            switch first {
            case UInt8(ascii: "\""):
                at += 1
                while let byte = peek, byte != UInt8(ascii: "\"") { at += byte == UInt8(ascii: "\\") ? 2 : 1 }
                guard peek != nil else { throw failure() }
                at += 1
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                repeat {
                    guard let byte = peek else { throw failure() }
                    if byte == UInt8(ascii: "\"") {
                        try skipValue()
                        continue
                    }
                    if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") { depth += 1 }
                    if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") { depth -= 1 }
                    at += 1
                } while depth > 0
            default:
                let start = at
                while let byte = peek, !" \n\r\t,}]".utf8.contains(byte) { at += 1 }
                if at == start { throw failure() }
            }
        }
    }
}

/// What a new table's columns should be, from every value of the file (a sample could miss the one long or odd value),
/// and the CREATE TABLE to propose. Only what the server takes as it is becomes a number or a date: a leading zero, a
/// date in another order or a plus sign stay text, so nothing is changed on the way in. Every column allows NULL, and
/// no key is guessed.
public enum ImportDetect {
    public struct Column: Equatable, Sendable {
        public var name: String
        public var type: String
    }

    /// The columns of `source`. File work: it reads the whole of it.
    public static func columns(_ source: ImportSource, options: CSVImport.Options, cancellation: Cancellation) throws -> [Column] {
        let reader = try ImportRecords(source, options: options)
        defer { reader.close() }
        var names: [String] = [], guesses: [Guess] = [], first = true
        while let records = try reader.next() {
            if cancellation.isCancelled { throw AirSQLError.cancelled }
            for fields in records {
                if first {
                    first = false
                    if options.header {
                        names = fields
                        continue
                    }
                }
                if fields.count == 1 && fields[0].isEmpty { continue }
                while guesses.count < fields.count {
                    guesses.append(Guess(emptyIsNull: options.emptyIsNull, hexIsBinary: options.hexIsBinary))
                }
                for (index, value) in fields.enumerated() { guesses[index].add(options.decimalComma ? pointNumber(value) : value) }
            }
        }
        while guesses.count < names.count { guesses.append(Guess(emptyIsNull: options.emptyIsNull, hexIsBinary: options.hexIsBinary)) }
        return zip(columnNames(names, count: guesses.count), guesses).map { Column(name: $0, type: $1.type) }
    }

    /// `count` names the server takes, from the file's first row: "column_3" for an empty one, "name_2" for a repeat.
    static func columnNames(_ names: [String], count: Int) -> [String] {
        var seen = Set<String>()
        return (0..<count).map { index in
            let given = index < names.count ? names[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let base = String((given.isEmpty ? "column_\(index + 1)" : given).prefix(60)).trimmingCharacters(in: .whitespaces)
            var name = base, repeated = 1
            while !seen.insert(name.lowercased()).inserted {
                repeated += 1
                name = base + "_\(repeated)"
            }
            return name
        }
    }

    /// The statement that makes the table, in utf8mb4 so any text of the file fits.
    public static func createTable(database: String, table: String, columns: [Column]) -> String {
        "CREATE TABLE " + SQLQuote.identifier(database, table) + " (\n"
            + columns.map { "  " + SQLQuote.identifier($0.name) + " " + $0.type }.joined(separator: ",\n")
            + "\n) DEFAULT CHARSET=utf8mb4"
    }

    /// The table a CREATE TABLE typed in the sheet makes, nil for anything else: one statement, of columns, without a
    /// query that would write rows of its own.
    public static func createdTable(_ sql: String) -> (database: String?, table: String)? {
        let statements = SQLParser.parse(sql)
        guard statements.count == 1, let statement = statements.first, statement.kind == .create, !statement.shallow,
              statement.errors.isEmpty, statement.query == nil, !statement.columns.isEmpty,
              let name = statement.objects.first, name.kind == "TABLE" else { return nil }
        return (name.name.qualifier?.value, name.name.last.value)
    }

    /// 1.234,56 as 1234.56; anything else as it is.
    static func pointNumber(_ text: String) -> String {
        let point = text.filter { $0 != "." && $0 != " " && $0 != "\u{A0}" && $0 != "'" }.replacingOccurrences(of: ",", with: ".")
        return CopyWriter.isNumber(point) ? point : text
    }

    /// One column's values so far: what they could all be.
    struct Guess {
        let emptyIsNull: Bool
        let hexIsBinary: Bool
        private var seen = false
        private var int32 = true, int64 = true, decimal = true, real = true, date = true, dateTime = true, time = true, binary = true
        private var whole = 0, scale = 0, fraction = 0, longest = 0, bytes = 0

        init(emptyIsNull: Bool, hexIsBinary: Bool) {
            self.emptyIsNull = emptyIsNull
            self.hexIsBinary = hexIsBinary
        }

        mutating func add(_ value: String) {
            guard value != ImportSource.null, !value.isEmpty || !emptyIsNull else { return }
            seen = true
            longest = max(longest, value.unicodeScalars.count)
            bytes = max(bytes, value.utf8.count)
            if binary, CopyWriter.hexDigits(value) == nil { binary = false }
            if real || decimal { addNumber(value) }
            guard date || dateTime || time else { return }
            let shape = ImportDetect.dateShape(value)
            if shape?.kind != .date { date = false }
            if shape?.kind != .date && shape?.kind != .dateTime { dateTime = false }
            if shape?.kind != .time { time = false }
            fraction = max(fraction, shape?.fraction ?? 0)
        }

        private mutating func addNumber(_ value: String) {
            guard CopyWriter.isNumber(value) else {
                int32 = false
                int64 = false
                decimal = false
                real = false
                return
            }
            if value.contains(where: { $0 == "e" || $0 == "E" }) {
                int32 = false
                int64 = false
                decimal = false
                return
            }
            let parts = value.drop { $0 == "-" }.split(separator: ".", omittingEmptySubsequences: false)
            whole = max(whole, parts[0].count)
            scale = max(scale, parts.count > 1 ? parts[1].count : 0)
            if parts.count > 1 {
                int32 = false
                int64 = false
            } else if let number = Int64(value) {
                if Int32(exactly: number) == nil { int32 = false }
            } else {
                int32 = false
                int64 = false
            }
        }

        var type: String {
            guard seen else { return "VARCHAR(255)" }
            if int32 { return "INT" }
            if int64 { return "BIGINT" }
            if decimal, whole + scale <= 65, scale <= 30 { return "DECIMAL(\(whole + scale),\(scale))" }
            // DOUBLE only for what is written as one: more digits than DECIMAL holds stay text, whole.
            if real && !decimal { return "DOUBLE" }
            if date { return "DATE" }
            if dateTime { return fraction > 0 ? "DATETIME(\(fraction))" : "DATETIME" }
            if time { return fraction > 0 ? "TIME(\(fraction))" : "TIME" }
            if hexIsBinary && binary { return "LONGBLOB" }
            if longest <= 255 { return "VARCHAR(\(max(32, min(255, (longest + 31) / 32 * 32))))" }
            return bytes <= 65535 ? "TEXT" : bytes < 1 << 24 ? "MEDIUMTEXT" : "LONGTEXT"
        }
    }

    enum DateKind {
        case date, dateTime, time
    }

    /// `text` as a date, date and time or time the server reads as it is: YYYY-MM-DD, then HH:MM[:SS[.ffffff]] after a
    /// space or T, or HH:MM:SS[.ffffff] alone; real calendar days only.
    static func dateShape(_ text: String) -> (kind: DateKind, fraction: Int)? {
        let bytes = Array(text.utf8)
        func number(_ at: Int, _ count: Int) -> Int? {
            guard at + count <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[at..<at + count] {
                guard (48...57).contains(byte) else { return nil }
                value = value * 10 + Int(byte) - 48
            }
            return value
        }
        /// The fraction's digits of a time at `at`, nil when it isn't one.
        func clock(_ at: Int, hours: ClosedRange<Int>, secondsOptional: Bool) -> Int? {
            let hourDigits = bytes[at...].prefix { (48...57).contains($0) }.count
            guard hourDigits == 2 || (hourDigits == 3 && at == 0), let hour = number(at, hourDigits), hours.contains(hour) else { return nil }
            let colon = at + hourDigits
            guard colon < bytes.count, bytes[colon] == 0x3A, let minute = number(colon + 1, 2), minute < 60 else { return nil }
            let end = colon + 3
            if end == bytes.count { return secondsOptional ? 0 : nil }
            guard bytes[end] == 0x3A, let second = number(end + 1, 2), second < 60 else { return nil }
            let after = end + 3
            if after == bytes.count { return 0 }
            let digits = bytes.count - after - 1
            guard bytes[after] == 0x2E, (1...6).contains(digits), number(after + 1, digits) != nil else { return nil }
            return digits
        }
        if bytes.count >= 10, bytes[4] == 0x2D, bytes[7] == 0x2D, let year = number(0, 4), let month = number(5, 2), let day = number(8, 2) {
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard year > 0, (1...12).contains(month), (1...days[month - 1]).contains(day) else { return nil }
            if bytes.count == 10 { return (.date, 0) }
            guard bytes.count > 11, bytes[10] == 0x20 || bytes[10] == 0x54,
                  let fraction = clock(11, hours: 0...23, secondsOptional: true) else { return nil }
            return (.dateTime, fraction)
        }
        return clock(0, hours: 0...838, secondsOptional: false).map { (.time, $0) }
    }
}
