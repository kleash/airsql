import Darwin
import Foundation

/// Reads CSV as spreadsheets write it (RFC 4180): fields split by the separator, double quotes around fields that hold
/// separators, quotes or line breaks, a quote inside written twice, records ended by LF or CRLF, a UTF-8 BOM ignored.
/// It takes the file in pieces and keeps an unfinished record for the next one.
public struct CSVReader {
    public var separator: UInt8
    private var field: [UInt8] = []
    private var record: [String] = []
    private var quoted = false
    /// In a quoted field, a quote was just read: the end of the quotes, or the first of two.
    private var quoteSeen = false
    /// The file's first bytes, until there are three to tell whether they are a BOM.
    private var head: [UInt8]? = []
    private var pendingCR = false
    /// Records handed over so far (the line numbers of errors count from these).
    public private(set) var records = 0

    public init(separator: UInt8 = UInt8(ascii: ",")) { self.separator = separator }

    /// The records completed by `data`.
    public mutating func read(_ data: Data) -> [[String]] {
        var bytes = Array(data)
        if let start = head {
            let first = start + bytes
            guard first.count >= 3 else {
                head = first
                return []
            }
            head = nil
            bytes = first.starts(with: [0xEF, 0xBB, 0xBF]) ? Array(first.dropFirst(3)) : first
        }
        var done: [[String]] = []
        for byte in bytes {
            if pendingCR {
                pendingCR = false
                if byte == 0x0A { continue }  // CRLF
            }
            if quoted {
                if quoteSeen {
                    quoteSeen = false
                    if byte == 0x22 {
                        field.append(byte)
                        continue
                    }
                    quoted = false  // the closing quote: this byte follows the field
                } else if byte == 0x22 {
                    quoteSeen = true
                    continue
                } else {
                    field.append(byte)
                    continue
                }
            }
            switch byte {
            case 0x22 where field.isEmpty:
                quoted = true
            case separator:
                endField()
            case 0x0A, 0x0D:
                pendingCR = byte == 0x0D
                endField()
                done.append(record)
                record = []
            default:
                field.append(byte)
            }
        }
        records += done.count
        return done
    }

    /// The last record, when the file doesn't end with a line break; an error when it ends inside quotes.
    public mutating func finish() throws -> [[String]] {
        var done: [[String]] = []
        if let start = head {  // a file of fewer than three bytes
            head = nil
            done = read(Data(start))
        }
        if quoted && !quoteSeen { throw AirSQLError(.other, "The file ends inside a quoted field (record \(records + 1)).") }
        guard !field.isEmpty || !record.isEmpty || quoteSeen else { return done }
        quoted = false
        quoteSeen = false
        endField()
        defer { record = [] }
        records += 1
        return done + [record]
    }

    private mutating func endField() {
        record.append(String(decoding: field, as: UTF8.self))
        field = []
    }

    /// The separator a sample most likely uses: of comma, semicolon, tab and bar, the one found most often on its first
    /// line outside quotes.
    public static func guessSeparator(_ sample: Data) -> UInt8 {
        var counts: [UInt8: Int] = [:], quoted = false
        for byte in sample {
            if byte == 0x22 { quoted.toggle() }
            if byte == 0x0A && !quoted { break }
            if !quoted, [0x2C, 0x3B, 0x09, 0x7C].contains(byte) { counts[byte, default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 0x2C
    }
}

/// Import CSV (scope: CSV import with column mapping): the file's records as INSERTs of about 1 MB into a table, each
/// mapped field into its column, in one transaction, so a record that fails leaves the table as it was. LOCAL INFILE
/// stays off (plan §1), so the rows go as INSERTs.
public enum CSVImport {
    public struct Options: Sendable {
        public var separator = UInt8(ascii: ",")
        /// The first record names the columns: it isn't imported.
        public var header = true
        /// Empty fields become NULL (otherwise empty strings).
        public var emptyIsNull = true

        public init() {}
    }

    /// Rows imported so far, and the bytes of the file read of its size.
    public struct Progress: Equatable, Sendable {
        public var rows: Int64
        public var bytes: Int64
        public var size: Int64
    }

    /// The first records of the file, for the mapping sheet: up to `limit` of them, from its first 256 KB. File work.
    public static func preview(_ url: URL, separator: UInt8?, limit: Int = 20) throws -> (separator: UInt8, records: [[String]]) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let sample = handle.readData(ofLength: 256 << 10)
        let chosen = separator ?? CSVReader.guessSeparator(sample)
        var reader = CSVReader(separator: chosen)
        var records = reader.read(sample)
        if sample.count < 256 << 10 { records += try reader.finish() }
        return (chosen, Array(records.prefix(limit)))
    }

    /// Imports `url` into `database`.`table` through `session`: `mapping` gives, for each of `columns`, the field it takes
    /// (nil: left out, so the server's default applies).
    public static func run(_ url: URL, options: Options, into session: DBConnection, database: String, table: String,
                           columns: [String], mapping: [Int?], cancellation: Cancellation,
                           progress: @escaping (Progress) -> Void) async throws -> Int64 {
        let used = zip(columns, mapping).compactMap { column, field in field.map { (column, $0) } }
        guard !used.isEmpty else { throw AirSQLError(.other, "No column takes a field of the file: map at least one.") }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw AirSQLError(.other, "Can't open \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var info = stat()
        fstat(fd, &info)
        let insert = "INSERT INTO \(SQLQuote.identifier(database, table)) (" + used.map { SQLQuote.identifier($0.0) }
            .joined(separator: ", ") + ") VALUES "
        let noBackslashEscapes = session.noBackslashEscapes
        var reader = CSVReader(separator: options.separator)
        var state = Progress(rows: 0, bytes: 0, size: Int64(info.st_size))
        var pending = "", skipHeader = options.header, record = 0
        func add(_ records: [[String]]) async throws {
            for fields in records {
                record += 1
                if skipHeader {
                    skipHeader = false
                    continue
                }
                if fields.count == 1 && fields[0].isEmpty { continue }  // a blank line
                let values = used.map { _, index -> String in
                    let value = index < fields.count ? fields[index] : ""
                    return value.isEmpty && options.emptyIsNull ? "NULL" : SQLQuote.string(value, noBackslashEscapes: noBackslashEscapes)
                }
                pending += (pending.isEmpty ? insert : ",") + "(" + values.joined(separator: ",") + ")"
                state.rows += 1
                if pending.utf8.count >= SQLExport.statementSize { try await flush() }
            }
        }
        func flush() async throws {
            guard !pending.isEmpty else { return }
            do {
                _ = try await session.query(pending)
            } catch let error as AirSQLError {
                throw AirSQLError(error.kind, "Records up to \(record) couldn't be imported: \(error.message)", details: error.details)
            }
            pending = ""
        }
        _ = try await session.query("START TRANSACTION")
        do {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                if cancellation.isCancelled { throw AirSQLError.cancelled }
                let count = read(fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                state.bytes += Int64(count)
                try await add(reader.read(Data(buffer[0..<count])))
                progress(state)
            }
            try await add(reader.finish())
            try await flush()
            _ = try await session.query("COMMIT")
        } catch {
            _ = try? await session.query("ROLLBACK")
            throw error
        }
        progress(state)
        return state.rows
    }
}
