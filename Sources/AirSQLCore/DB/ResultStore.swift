import CMariaDB
import Foundation

/// A result set as the server sent it: per column its cells' bytes one after another, each cell's end offset (4 bytes)
/// and a NULL bit, so a million rows of short values take tens of megabytes rather than a String (and its object) per
/// cell. Cells
/// keep the server's bytes and the column keeps its field type; turning bytes into text for people is `display`'s job,
/// done only for the cells on screen. Filled by `DBConnection` as rows arrive, read-only once `query` returns it.
public final class ResultStore {
    /// A column as the server describes it (MYSQL_FIELD).
    public struct Column: Equatable, Sendable {
        public var name: String
        /// The column's own name, without an alias ("" for an expression).
        public var originalName: String
        public var table: String
        public var originalTable: String
        public var database: String
        /// Connector/C's enum_field_types (MYSQL_TYPE_LONG, MYSQL_TYPE_VAR_STRING, …).
        public var type: enum_field_types
        /// NOT_NULL_FLAG, PRI_KEY_FLAG, UNSIGNED_FLAG, BINARY_FLAG, …
        public var flags: UInt32
        /// The character set (collation) number; 63 is binary.
        public var charset: UInt32
        /// The column's width in bytes (for BIT: in bits).
        public var length: UInt64
        public var decimals: UInt32

        public init(name: String, originalName: String = "", table: String = "", originalTable: String = "",
                    database: String = "", type: enum_field_types, flags: UInt32 = 0, charset: UInt32 = 45,
                    length: UInt64 = 0, decimals: UInt32 = 0) {
            self.name = name
            self.originalName = originalName
            self.table = table
            self.originalTable = originalTable
            self.database = database
            self.type = type
            self.flags = flags
            self.charset = charset
            self.length = length
            self.decimals = decimals
        }

        /// Bytes rather than text: BINARY, VARBINARY, BLOB, GEOMETRY.
        public var isBinary: Bool {
            charset == 63 && ![MYSQL_TYPE_BIT, MYSQL_TYPE_DECIMAL, MYSQL_TYPE_NEWDECIMAL, MYSQL_TYPE_TINY, MYSQL_TYPE_SHORT,
                               MYSQL_TYPE_INT24, MYSQL_TYPE_LONG, MYSQL_TYPE_LONGLONG, MYSQL_TYPE_FLOAT, MYSQL_TYPE_DOUBLE,
                               MYSQL_TYPE_YEAR, MYSQL_TYPE_DATE, MYSQL_TYPE_NEWDATE, MYSQL_TYPE_TIME, MYSQL_TYPE_DATETIME,
                               MYSQL_TYPE_TIMESTAMP, MYSQL_TYPE_NULL].contains(type)
        }
    }

    public let columns: [Column]
    public private(set) var rowCount = 0
    /// The statement had more rows than the row cap (or than AirSQL holds in memory): these are its first `rowCount`.
    public internal(set) var capped = false

    /// A column's cells for `segmentRows` rows: their bytes one after another, where each ends, and a NULL bit each.
    /// Segments keep every array small enough for the allocator's fine size classes (one buffer per column grew by
    /// copying, and macOS hands big requests blocks of up to 1.5 times their size), and are trimmed once full.
    private final class Segment {
        var bytes: [UInt8] = []
        var ends: [UInt32] = []
        var nulls: [UInt64] = []

        func trim() {
            bytes = Self.trimmed(bytes)
            ends = Self.trimmed(ends)
            nulls = Self.trimmed(nulls)
        }

        static func trimmed<T>(_ array: [T]) -> [T] {
            guard array.capacity > array.count + array.count / 16 + 16 else { return array }
            return Array(unsafeUninitializedCapacity: array.count) { buffer, count in
                _ = buffer.initialize(from: array)
                count = array.count
            }
        }
    }

    /// A full segment's ends (4 bytes each) and an array's 32-byte header fill one 64 KB block.
    static let segmentRows = 16_376

    /// Per column, its segments.
    private var segments: [[Segment]]
    /// The cells' bytes so far, all columns.
    private(set) var storedBytes = 0
    /// What the store may hold: a segment's offsets are 32-bit, and 1 GB keeps the Mac responsive.
    let byteLimit: Int

    public convenience init(columns: [Column]) {
        self.init(columns: columns, byteLimit: 1 << 30)
    }

    init(columns: [Column], byteLimit: Int) {
        self.columns = columns
        self.byteLimit = byteLimit
        segments = Array(repeating: [], count: columns.count)
    }

    /// Appends a row, nil for NULL. False (nothing appended) when it would take the store past `byteLimit`.
    @discardableResult
    public func append(_ cells: [[UInt8]?]) -> Bool {
        precondition(cells.count == columns.count, "a row has one cell per column")
        let size = cells.reduce(0) { $0 + ($1?.count ?? 0) }
        guard storedBytes + size <= byteLimit else { return false }
        for (column, cell) in cells.enumerated() {
            if let cell {
                cell.withUnsafeBufferPointer { add(column, $0) }
            } else {
                add(column, nil)
            }
        }
        rowCount += 1
        storedBytes += size
        return true
    }

    /// Appends the row Connector/C just fetched (mysql_fetch_row and mysql_fetch_lengths). False when it would take the
    /// store past `byteLimit`.
    func append(_ row: MYSQL_ROW, lengths: UnsafeMutablePointer<UInt>) -> Bool {
        var size = 0
        for column in 0..<columns.count { size += Int(lengths[column]) }
        guard storedBytes + size <= byteLimit else { return false }
        for column in 0..<columns.count {
            if let cell = row[column] {
                cell.withMemoryRebound(to: UInt8.self, capacity: Int(lengths[column])) {
                    add(column, UnsafeBufferPointer(start: $0, count: Int(lengths[column])))
                }
            } else {
                add(column, nil)
            }
        }
        rowCount += 1
        storedBytes += size
        return true
    }

    private func add(_ column: Int, _ cell: UnsafeBufferPointer<UInt8>?) {
        let local = rowCount % Self.segmentRows
        if local == 0 {
            segments[column].last?.trim()
            segments[column].append(Segment())
        }
        let segment = segments[column][segments[column].count - 1]
        if local % 64 == 0 { segment.nulls.append(0) }
        if let cell {
            segment.bytes.append(contentsOf: cell)
        } else {
            segment.nulls[local / 64] |= 1 << UInt64(local % 64)
        }
        segment.ends.append(UInt32(segment.bytes.count))
    }

    /// Trims the last segments once the rows are all in.
    func finish() {
        for column in segments { column.last?.trim() }
    }

    // MARK: Reading

    public func isNull(_ row: Int, _ column: Int) -> Bool {
        let local = row % Self.segmentRows
        return segments[column][row / Self.segmentRows].nulls[local / 64] & (1 << UInt64(local % 64)) != 0
    }

    /// The cell's bytes as the server sent them, nil for NULL.
    public func bytes(_ row: Int, _ column: Int) -> [UInt8]? {
        withBytes(row, column) { Array($0) }
    }

    /// Calls `body` with the cell's bytes (nil for NULL) without copying them.
    public func withBytes<R>(_ row: Int, _ column: Int, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R? {
        guard !isNull(row, column) else { return nil }
        let segment = segments[column][row / Self.segmentRows], local = row % Self.segmentRows
        let start = local == 0 ? 0 : Int(segment.ends[local - 1]), end = Int(segment.ends[local])
        return segment.bytes.withUnsafeBufferPointer { body(UnsafeBufferPointer(rebasing: $0[start..<end])) }
    }

    /// The cell as text (UTF-8; the text protocol sends numbers and dates as text too), nil for NULL.
    public func string(_ row: Int, _ column: Int) -> String? {
        withBytes(row, column) { String(decoding: $0, as: UTF8.self) }
    }

    /// The cell as people read it: text as text, BINARY/BLOB bytes as 0x… hex (the first 256 bytes), BIT as its bits
    /// ("101" for BIT(3)); nil for NULL.
    public func display(_ row: Int, _ column: Int) -> String? {
        let info = columns[column]
        return withBytes(row, column) { bytes in
            if info.type == MYSQL_TYPE_BIT {
                let bits = bytes.map { byte -> String in
                    let digits = String(byte, radix: 2)
                    return String(repeating: "0", count: 8 - digits.count) + digits
                }.joined()
                return String(bits.suffix(max(1, min(Int(info.length), bits.count))))
            }
            if info.isBinary {
                let digits = Array("0123456789ABCDEF".utf8)
                var text = Array("0x".utf8)
                for byte in bytes.prefix(256) {
                    text.append(digits[Int(byte >> 4)])
                    text.append(digits[Int(byte & 0x0F)])
                }
                return String(decoding: text, as: UTF8.self) + (bytes.count > 256 ? "…" : "")
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// The memory the store holds: buffers as reserved, not only as filled.
    public var byteCount: Int {
        segments.joined().reduce(0) { $0 + $1.bytes.capacity + $1.ends.capacity * 4 + $1.nulls.capacity * 8 }
    }
}
