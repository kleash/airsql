import Darwin
import Foundation

/// Reads CSV as spreadsheets write it (RFC 4180): fields split by the separator, double quotes around fields that hold
/// separators, quotes or line breaks, a quote inside written twice, records ended by LF or CRLF, a BOM ignored.
/// Text is UTF-8, or UTF-16 after a BOM; a field that isn't UTF-8 reads as Windows-1252, which spreadsheets on Windows
/// save, unless `encoding` names the file's own. It takes the file in pieces and keeps an unfinished record for the next one.
public struct CSVReader {
    public var separator: UInt8
    /// What encloses a field; nil: nothing does.
    public var quote: UInt8? = 0x22
    /// Inside quotes, the byte before a character taken as it is (MySQL's backslash), besides the quote written twice.
    public var escape: UInt8?
    /// The file's encoding; nil: UTF-8 with Windows-1252 for what isn't.
    public var encoding: String.Encoding?
    /// Spaces around a field without quotes drop out.
    public var trim = false
    /// A NULL without quotes, as AirSQL's CSV writes the real one, reads as an empty field.
    public var bareNullIsEmpty = false
    /// Whether a field wasn't UTF-8, or wasn't what `encoding` says.
    public private(set) var readWindows1252 = false
    /// UTF-16 bytes kept for the next piece: half a character, or the first half of a surrogate pair.
    private var wide: [UInt8] = []
    /// After an escape byte, in quotes.
    private var escaped = false
    private var field: [UInt8] = []
    private var fieldQuoted = false
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
            bytes = first
            if first.starts(with: [0xEF, 0xBB, 0xBF]) {
                bytes = Array(first.dropFirst(3))
            } else if first.starts(with: [0xFF, 0xFE]) {
                encoding = .utf16LittleEndian
                bytes = Array(first.dropFirst(2))
            } else if first.starts(with: [0xFE, 0xFF]) {
                encoding = .utf16BigEndian
                bytes = Array(first.dropFirst(2))
            }
        }
        if isWide { bytes = utf8(fromWide: bytes) }
        var done: [[String]] = []
        for byte in bytes {
            if pendingCR {
                pendingCR = false
                if byte == 0x0A { continue }  // CRLF
            }
            if quoted {
                if escaped {
                    escaped = false
                    field.append(byte)
                    continue
                } else if quoteSeen {
                    quoteSeen = false
                    if byte == quote {
                        field.append(byte)
                        continue
                    }
                    quoted = false  // the closing quote: this byte follows the field
                } else if byte == quote {
                    quoteSeen = true
                    continue
                } else if byte == escape {
                    escaped = true
                    continue
                } else {
                    field.append(byte)
                    continue
                }
            }
            switch byte {
            case quote where field.isEmpty:
                quoted = true
                fieldQuoted = true
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

    private var isWide: Bool { encoding == .utf16LittleEndian || encoding == .utf16BigEndian }

    /// UTF-16 as UTF-8, which the rest reads: separators and quotes are then single bytes.
    private mutating func utf8(fromWide bytes: [UInt8]) -> [UInt8] {
        let all = wide + bytes
        var usable = all.count & ~1
        if usable >= 2, (0xD8...0xDB).contains(all[encoding == .utf16LittleEndian ? usable - 1 : usable - 2]) { usable -= 2 }
        wide = Array(all[usable...])
        return Array((String(bytes: all[..<usable], encoding: encoding ?? .utf16) ?? "").utf8)
    }

    private mutating func endField() {
        var text = String(decoding: field, as: UTF8.self)
        if let encoding, !isWide {
            if let exact = String(bytes: field, encoding: encoding) { text = exact } else { readWindows1252 = true }
        } else if text.contains("\u{FFFD}"), String(bytes: field, encoding: .utf8) == nil {
            text = String(bytes: field, encoding: .windowsCP1252) ?? text
            readWindows1252 = true
        }
        if trim && !fieldQuoted { text = text.trimmingCharacters(in: .whitespaces) }
        record.append(bareNullIsEmpty && !fieldQuoted && text == "NULL" ? "" : text)
        field = []
        fieldQuoted = false
    }

    /// The separator a sample most likely uses: of comma, semicolon, tab and bar, the one found most often on its first
    /// line outside quotes.
    public static func guessSeparator(_ sample: Data) -> UInt8 {  // UTF-16's zero bytes don't change the count
        var counts: [UInt8: Int] = [:], quoted = false
        for byte in sample {
            if byte == 0x22 { quoted.toggle() }
            if byte == 0x0A && !quoted { break }
            if !quoted, [0x2C, 0x3B, 0x09, 0x7C].contains(byte) { counts[byte, default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 0x2C
    }
}

/// Import (scope: CSV import with column mapping): a file's or the clipboard's records as INSERTs of about 1 MB into a
/// table, each mapped field into its column, in one transaction, so a record that fails leaves the table as it was,
/// unless bad rows are to be skipped (`rejects`). LOCAL INFILE stays off (plan §1), so the rows go as INSERTs.
public enum CSVImport {
    /// What to do with a row whose key is already there.
    public enum Duplicates: Int, CaseIterable, Sendable {
        case stop, skip, replace

        public var verb: String {
            switch self {
            case .stop: return "INSERT INTO"
            case .skip: return "INSERT IGNORE INTO"
            case .replace: return "REPLACE INTO"
            }
        }
    }

    public struct Options: Sendable {
        public var separator = UInt8(ascii: ",")
        public var quote: UInt8? = 0x22
        public var escape: UInt8?
        /// The file's encoding; nil: UTF-8, Windows-1252 for what isn't, UTF-16 after a BOM.
        public var encoding: String.Encoding?
        /// Spaces around fields without quotes drop out.
        public var trim = false
        /// Records skipped before anything else: a title above the table.
        public var skipRecords = 0
        /// The first record names the columns: it isn't imported.
        public var header = true
        /// Empty fields and a NULL without quotes become NULL (otherwise strings).
        public var emptyIsNull = true
        /// Columns that take a whole "0x…" field as its bytes, as AirSQL's CSV writes them.
        public var binaryColumns: Set<String> = []
        /// A whole "0x…" field is bytes: the rows are AirSQL's own (a result), so a new table gets a binary column for them.
        public var hexIsBinary = false
        /// Numbers are written 1.234,56: in `numberColumns` they go to the server as 1234.56.
        public var decimalComma = false
        public var numberColumns: Set<String> = []
        public var duplicates = Duplicates.stop
        /// The table's rows go first, in the same transaction: a failed import brings them back.
        public var emptyFirst = false
        /// Keep going past rows the server refuses, written to this file with its reason; the rest are kept. Nil: all or none.
        public var rejects: URL?

        public init() {}

        func reader() -> CSVReader {
            var reader = CSVReader(separator: separator)
            reader.quote = quote
            reader.escape = escape
            reader.encoding = encoding
            reader.trim = trim
            reader.bareNullIsEmpty = emptyIsNull
            return reader
        }
    }

    /// Rows imported so far, the bytes of the file read of its size, the server's warnings (it stored something other
    /// than the file said), whether a field wasn't UTF-8 and the rows the server refused, when those are skipped.
    public struct Progress: Equatable, Sendable {
        public var rows: Int64
        public var bytes: Int64
        public var size: Int64
        public var warnings = 0
        public var notUTF8 = false
        public var rejected: Int64 = 0

        /// What the finished import should add, "" when nothing happened.
        public var note: String {
            (rejected > 0 ? " \(rejected) row\(rejected == 1 ? " was" : "s were") refused and skipped." : "")
                + (notUTF8 ? " Some fields weren't in the file's encoding and were read as Windows-1252: check them." : "")
                + (warnings > 0 ? " The server gave \(warnings) warning\(warnings == 1 ? "" : "s"): it changed some values as it stored them." : "")
        }
    }

    /// The first records, for the sheet: up to `limit` of them, from about the first 256 KB, and the separator, guessed
    /// when `guess` is set. File work.
    public static func preview(_ source: ImportSource, options: Options, guess: Bool = false,
                               limit: Int = 20) throws -> (separator: UInt8, records: [[String]]) {
        var options = options
        if guess { options.separator = CSVReader.guessSeparator(try source.sample()) }
        let reader = try ImportRecords(source, options: options)
        defer { reader.close() }
        var records: [[String]] = []
        while records.count < limit, reader.bytes < 256 << 10, let piece = try reader.next() { records += piece }
        return (options.separator, Array(records.prefix(limit)))
    }

    /// Imports `source` into `database`.`table` through `session`: `mapping` gives, for each of `columns`, the field it
    /// takes (nil: left out, so the server's default applies).
    public static func run(_ source: ImportSource, options: Options, into session: DBConnection, database: String, table: String,
                           columns: [String], mapping: [Int?], cancellation: Cancellation,
                           progress: @escaping (Progress) -> Void) async throws -> Progress {
        let used = zip(columns, mapping).compactMap { column, field in field.map { (column, $0) } }
        guard !used.isEmpty else { throw AirSQLError(.other, "No column takes a field of the file: map at least one.") }
        let reader = try ImportRecords(source, options: options)
        defer { reader.close() }
        let target = SQLQuote.identifier(database, table)
        let insert = "\(options.duplicates.verb) \(target) (" + used.map { SQLQuote.identifier($0.0) }
            .joined(separator: ", ") + ") VALUES "
        let noBackslashEscapes = session.noBackslashEscapes
        var state = Progress(rows: 0, bytes: 0, size: reader.size)
        var pending = "", pendingRows: Int64 = 0, skipHeader = options.header, record = 0
        // Each row of the statement at hand, to go one by one when the statement fails.
        var batch: [(fields: [String], values: String)] = []
        var rejects: FileHandle?
        var oneByOne = false
        if options.rejects != nil {
            // A table without transactions keeps the first rows of a statement that fails: each row goes alone.
            let quoted = { SQLQuote.string($0, noBackslashEscapes: noBackslashEscapes) }
            oneByOne = try await session.rows("SELECT e.TRANSACTIONS FROM information_schema.TABLES t JOIN information_schema.ENGINES e "
                + "ON e.ENGINE = t.ENGINE WHERE t.TABLE_SCHEMA = \(quoted(database)) AND t.TABLE_NAME = \(quoted(table))")
                .first?[0] != "YES"
        }
        func reject(_ fields: [String], _ error: AirSQLError) throws {
            state.rejected += 1
            guard let url = options.rejects else { return }
            if rejects == nil {
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw AirSQLError(.other, "Can't write the skipped rows to \(url.lastPathComponent).")
                }
                rejects = try FileHandle(forWritingTo: url)
            }
            let line = (fields + [error.localizedDescription]).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            try rejects?.write(contentsOf: Data((line.joined(separator: ",") + "\n").utf8))
        }
        func add(_ records: [[String]]) async throws {
            for fields in records {
                record += 1
                if skipHeader {
                    skipHeader = false
                    continue
                }
                if fields.count == 1 && fields[0].isEmpty { continue }  // a blank line
                let values = used.map { column, index -> String in
                    var value = index < fields.count ? fields[index] : ""
                    if value == ImportSource.null { return "NULL" }
                    if options.binaryColumns.contains(column), let digits = CopyWriter.hexDigits(value) { return "X'\(digits)'" }
                    if options.decimalComma, options.numberColumns.contains(column) { value = ImportDetect.pointNumber(value) }
                    return value.isEmpty && options.emptyIsNull ? "NULL" : SQLQuote.string(value, noBackslashEscapes: noBackslashEscapes)
                }
                let row = "(" + values.joined(separator: ",") + ")"
                pending += (pending.isEmpty ? insert : ",") + row
                pendingRows += 1
                if options.rejects != nil { batch.append((fields, row)) }
                if oneByOne || pending.utf8.count >= SQLExport.statementSize { try await flush() }
            }
        }
        func flush() async throws {
            guard !pending.isEmpty else { return }
            defer {
                pending = ""
                pendingRows = 0
                batch = []
            }
            do {
                state.warnings += try await session.query(pending).last?.warnings ?? 0
                state.rows += pendingRows
            } catch let error as AirSQLError {
                guard options.rejects != nil, isTheRow(error) else {
                    throw AirSQLError(error.kind, "Records up to \(record) couldn't be imported: \(error.message)", details: error.details,
                                      code: error.code)
                }
                for row in batch {
                    if cancellation.isCancelled { throw AirSQLError.cancelled }
                    do {
                        state.warnings += try await session.query(insert + row.values).last?.warnings ?? 0
                        state.rows += 1
                    } catch let error as AirSQLError where isTheRow(error) {
                        try reject(row.fields, error)
                    }
                }
            }
        }
        _ = try await session.query("START TRANSACTION")
        do {
            if options.emptyFirst { _ = try await session.query("DELETE FROM " + target) }
            while let piece = try reader.next() {
                if cancellation.isCancelled { throw AirSQLError.cancelled }
                state.bytes = reader.bytes
                try await add(piece)
                progress(state)
            }
            state.bytes = reader.bytes
            try await flush()
            _ = try await session.query("COMMIT")
            try rejects?.close()
        } catch {
            _ = try? await session.query("ROLLBACK")
            if rejects != nil, let url = options.rejects { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        state.notUTF8 = reader.notUTF8
        progress(state)
        return state
    }

    /// Whether the server refused the row itself. Anything else (a lost connection, a deadlock, which ends the
    /// transaction, no privilege) stops the import: going on would commit half of it, or skip every row.
    static func isTheRow(_ error: AirSQLError) -> Bool {
        guard (1000..<2000).contains(error.code) || error.code >= 3000 else { return false }
        return error.kind == .duplicate || error.kind == .foreignKey || error.kind == .other
    }
}
