import Foundation

/// Writes rows as an Excel workbook (.xlsx, grid-spec §6): one sheet, the column names in the first row, numbers
/// as numbers and everything else as text, NULL as an empty cell. The sheet goes to a temporary file row by row, so an
/// export of a whole table streams; `finish` packs it with the workbook's other parts into a zip (stored, not deflated:
/// every spreadsheet app reads that).
public final class XLSXWriter {
    /// Excel's limits: rows in a sheet, characters in a cell.
    public static let maxRows = 1_048_576
    static let maxCellCharacters = 32_767

    public struct TooManyRows: LocalizedError {
        public var errorDescription: String? {
            "Excel holds at most \(XLSXWriter.maxRows.formatted()) rows in a sheet: export these rows as CSV instead."
        }
    }

    private let url: URL
    private let columns: [GridColumn]
    private let sheetURL: URL
    private let sheet: FileHandle
    private var crc = CRC32()
    private var size = 0
    private var rows = 0
    private var buffer = Data()

    /// Starts a workbook at `url` (written by `finish`); with `headers` the column names are its first row.
    public init(url: URL, columns: [GridColumn], headers: Bool = true) throws {
        self.url = url
        self.columns = columns
        sheetURL = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-sheet-\(UUID().uuidString).xml")
        guard FileManager.default.createFile(atPath: sheetURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        sheet = try FileHandle(forWritingTo: sheetURL)
        write("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<worksheet xmlns=\"\(Self.main)\"><sheetData>")
        if headers { try add(columns.map(\.name), names: true) }
    }

    deinit {
        try? sheet.close()
        try? FileManager.default.removeItem(at: sheetURL)
    }

    public func add(_ values: [String?]) throws { try add(values, names: false) }

    private func add(_ values: [String?], names: Bool) throws {
        guard rows < Self.maxRows else { throw TooManyRows() }
        rows += 1
        var row = "<row>"
        for (column, value) in zip(columns, values) {
            guard let value else {
                row += "<c/>"
                continue
            }
            if !names, column.kind == .number, CopyWriter.isNumber(value) {
                row += "<c><v>\(value)</v></c>"
            } else {
                let text = value.count > Self.maxCellCharacters ? String(value.prefix(Self.maxCellCharacters)) : value
                row += "<c t=\"inlineStr\"><is><t xml:space=\"preserve\">\(Self.escaped(text))</t></is></c>"
            }
        }
        write(row + "</row>")
        if buffer.count > 1 << 20 { try flush() }
    }

    /// Writes the workbook to `url`.
    public func finish() throws {
        write("</sheetData></worksheet>")
        try flush()
        try sheet.close()
        guard size < Int(UInt32.max) else { throw CocoaError(.fileWriteVolumeReadOnly) }
        var zip = ZipStore()
        zip.add("[Content_Types].xml", Data(Self.contentTypes.utf8))
        zip.add("_rels/.rels", Data(Self.packageRelations.utf8))
        zip.add("xl/workbook.xml", Data(Self.workbook.utf8))
        zip.add("xl/_rels/workbook.xml.rels", Data(Self.workbookRelations.utf8))
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        try out.truncate(atOffset: 0)
        try out.write(contentsOf: zip.data)
        // The sheet: its header, then the temporary file's bytes as they are.
        try out.write(contentsOf: zip.header("xl/worksheets/sheet1.xml", crc: crc.value, size: size))
        let input = try FileHandle(forReadingFrom: sheetURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
        try out.write(contentsOf: zip.directory())
    }

    private func write(_ text: String) {
        buffer.append(contentsOf: text.utf8)
    }

    private func flush() throws {
        crc.update(buffer)
        size += buffer.count
        try sheet.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    static func escaped(_ text: String) -> String {
        CopyWriter(.xml, columns: []).xml(text)
    }

    private static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relations = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let packageRelationsNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
        """
    private static let packageRelations = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="\(packageRelationsNamespace)"><Relationship Id="rId1" \
        Type="\(relations)/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """
    private static let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="\(main)" xmlns:r="\(relations)"><sheets><sheet name="Rows" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
    private static let workbookRelations = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="\(packageRelationsNamespace)"><Relationship Id="rId1" \
        Type="\(relations)/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
        """
}

/// A zip archive of stored (uncompressed) files, written in order: each file's local header and bytes, then the
/// central directory (APPNOTE.TXT §4.3). No zip64: every file and the whole archive stay under 4 GB.
struct ZipStore {
    private(set) var data = Data()
    private var entries: [(name: String, crc: UInt32, size: Int, offset: Int)] = []
    private var written = 0

    /// Adds a file whose bytes are at hand.
    mutating func add(_ name: String, _ bytes: Data) {
        var crc = CRC32()
        crc.update(bytes)
        data.append(header(name, crc: crc.value, size: bytes.count))
        data.append(bytes)
    }

    /// A file's local header; its `size` bytes must follow it.
    mutating func header(_ name: String, crc: UInt32, size: Int) -> Data {
        entries.append((name, crc, size, written))
        var out = Data()
        out.le32(0x0403_4B50)
        out.le16(20); out.le16(0x0800); out.le16(0); out.le16(0); out.le16(0x21)  // version, UTF-8 names, stored, 1980-01-01
        out.le32(crc); out.le32(UInt32(size)); out.le32(UInt32(size))
        out.le16(UInt16(name.utf8.count)); out.le16(0)
        out.append(contentsOf: name.utf8)
        written += out.count + size
        return out
    }

    /// The central directory and its end record, after every file.
    func directory() -> Data {
        var out = Data()
        for entry in entries {
            out.le32(0x0201_4B50)
            out.le16(20); out.le16(20); out.le16(0x0800); out.le16(0); out.le16(0); out.le16(0x21)
            out.le32(entry.crc); out.le32(UInt32(entry.size)); out.le32(UInt32(entry.size))
            out.le16(UInt16(entry.name.utf8.count)); out.le16(0); out.le16(0); out.le16(0); out.le16(0); out.le32(0)
            out.le32(UInt32(entry.offset))
            out.append(contentsOf: entry.name.utf8)
        }
        let size = out.count
        out.le32(0x0605_4B50)
        out.le16(0); out.le16(0); out.le16(UInt16(entries.count)); out.le16(UInt16(entries.count))
        out.le32(UInt32(size)); out.le32(UInt32(written)); out.le16(0)
        return out
    }
}

/// CRC-32 (IEEE 802.3), as zip checks each file.
struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private var state: UInt32 = 0xFFFF_FFFF

    mutating func update(_ bytes: Data) {
        var crc = state
        for byte in bytes { crc = Self.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        state = crc
    }

    var value: UInt32 { state ^ 0xFFFF_FFFF }
}

private extension Data {
    mutating func le16(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}
