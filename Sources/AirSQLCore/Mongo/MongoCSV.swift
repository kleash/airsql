import Foundation

/// Documents as CSV: one column per dotted path, written by `CopyWriter` so quoting, separator, line endings and the
/// null text are the grid's CSV export's own. A missing field is an empty cell, null is the null text ("null" unless
/// the caller sets another), and a string that reads as the null text is quoted.
public struct MongoCSVWriter {
    public enum CellForm: Sendable {
        /// Values as the grid shows them: ObjectId("…"), ISODate("…"), NumberLong(…), { a: 1 }.
        case shell
        /// Values in relaxed Extended JSON: {"$oid": "…"}, {"$date": "…"}, {"a":1}.
        case relaxedJSON
    }

    public let paths: [String]
    public let form: CellForm
    private var writer: CopyWriter

    public init(paths: [String], form: CellForm = .shell, options: CopyOptions = CopyOptions(headers: true, nullText: "null")) {
        self.paths = paths
        self.form = form
        writer = CopyWriter(.csv, columns: paths.map { GridColumn(name: $0) }, options: options)
    }

    public func header() -> String { writer.header() }

    public mutating func row(_ document: BSONDocument) -> String {
        writer.row(paths.map { path -> String? in
            switch Self.value(at: path, in: document) {
            case nil: return ""
            case .null?: return nil
            case .string(let s)?: return s
            case let value?: return form == .shell ? value.shellForm() : value.extendedJSON(.relaxed)
            }
        })
    }

    /// The paths of these documents in order of first appearance: a sub-document's fields become their own columns
    /// (an empty one stays one column); arrays stay whole.
    public static func paths(of documents: [BSONDocument]) -> [String] {
        var paths: [String] = []
        var seen: Set<String> = []
        func visit(_ document: BSONDocument, _ prefix: String) {
            for (key, value) in document.fields {
                let path = prefix + key
                if case .document(let sub) = value, !sub.fields.isEmpty {
                    visit(sub, path + ".")
                } else if seen.insert(path).inserted {
                    paths.append(path)
                }
            }
        }
        for document in documents { visit(document, "") }
        return paths
    }

    /// The value at a dotted path, through sub-documents and array indexes ("items.0.price"); nil when missing.
    static func value(at path: String, in document: BSONDocument) -> BSONValue? {
        var current = BSONValue.document(document)
        for part in path.split(separator: ".", omittingEmptySubsequences: false) {
            switch current {
            case .document(let d):
                guard let next = d[String(part)] else { return nil }
                current = next
            case .array(let values):
                guard let index = Int(part), values.indices.contains(index) else { return nil }
                current = values[index]
            default: return nil
            }
        }
        return current
    }
}

/// How Import Documents… reads a CSV column: auto takes a cell as int32, int64, double, bool, null, a date or an
/// ObjectId only when it is exactly that shape (or the shell form the CSV export writes, such as NumberLong(5)), else as
/// a string; any other reads every cell as that type, or says why it can't.
public enum MongoCSVType: String, CaseIterable, Sendable {
    case auto, string, int, long, double, decimal, bool, date, objectId

    /// "an int (…)", for what a cell isn't.
    var article: String {
        switch self {
        case .int: return "an int (a whole number from -2147483648 to 2147483647)"
        case .long: return "a long (a whole number from -9223372036854775808 to 9223372036854775807)"
        case .double: return "a double (a number)"
        case .decimal: return "a decimal (a number of at most 34 digits)"
        case .bool: return "a bool (true or false)"
        case .date: return "a date, such as 2024-05-01T12:00:00Z"
        case .objectId: return "an ObjectId (24 hex digits)"
        default: return "a \(rawValue)"
        }
    }
}

/// A CSV file's rows as documents (Import Documents…): the header row names the fields, a dotted name ("address.city")
/// building a sub-document, and each column is read as its `MongoCSVType`. An empty cell leaves its field out, as the
/// export writes a missing field. The file streams through `ImportRecords`, MySQL's CSV import's reader, with its
/// separator guessed from the first line. File work.
public final class MongoCSVReader {
    public let names: [String]
    /// Each column's type, by name; auto when not given.
    public var types: [String: MongoCSVType] = [:]
    private let paths: [[String]]
    private let records: ImportRecords
    private var waiting: [[String]] = []
    private var ended = false
    /// The rows handed over so far, the header among them: the last one's number in the file.
    public private(set) var row = 1

    /// A data row that can't be a document, with its number and why. The reader goes on after it.
    public struct RowError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Opens `url` and reads its header; a header that can't name a document's fields throws.
    public init(_ url: URL) throws {
        var options = CSVImport.Options()
        options.emptyIsNull = false
        options.separator = CSVReader.guessSeparator(try ImportSource.file(url).sample())
        records = try ImportRecords(.file(url), options: options)
        var header: [String]?
        while header == nil, let piece = try records.next() {
            header = piece.first
            waiting = Array(piece.dropFirst())
        }
        guard let header, header != [""] else {
            records.close()
            throw AirSQLError(.other, "The file has no header row to name the fields.")
        }
        names = header
        paths = header.map { $0.components(separatedBy: ".") }
        do { try Self.check(names, paths) } catch {
            records.close()
            throw error
        }
    }

    deinit { records.close() }

    /// How much of the file has been read, and its size.
    public var bytes: Int64 { records.bytes }
    public var size: Int64 { records.size }

    /// About how many rows the file holds: those read so far, scaled up by what is left to read.
    public var estimate: Int {
        let read = row - 1 + waiting.count
        return ended || bytes == 0 || bytes >= size ? read : Int(Double(read) * Double(size) / Double(bytes))
    }

    /// The names must make one document: none empty, no two the same, none both a value and a sub-document.
    private static func check(_ names: [String], _ paths: [[String]]) throws {
        for (n, path) in paths.enumerated() where path.contains("") {
            throw AirSQLError(.other, names[n].isEmpty ? "Column \(n + 1) of the header has no name."
                              : "The column “\(names[n])” has an empty part in its name.")
        }
        var seen: Set<String> = []
        for name in names where !seen.insert(name).inserted { throw AirSQLError(.other, "Two columns are named “\(name)”.") }
        for name in names {
            if let parent = names.first(where: { name.hasPrefix($0 + ".") }) {
                throw AirSQLError(.other, "“\(parent)” is a column, and “\(name)” would make it a sub-document.")
            }
        }
    }

    /// The next row's document and its number; nil at the end. Blank lines are passed over. A row that can't be read
    /// throws a `RowError`, and the next call goes on after it.
    public func next() throws -> (BSONDocument, Int)? {
        while true {
            if waiting.isEmpty {
                guard !ended, let piece = try records.next() else {
                    ended = true
                    return nil
                }
                waiting = piece
                continue
            }
            let record = waiting.removeFirst()
            row += 1
            if record == [""] { continue }
            guard record.count == names.count else {
                throw RowError(message: "Row \(row): it has \(record.count) field\(record.count == 1 ? "" : "s"), and the header "
                               + "names \(names.count)")
            }
            var document = BSONDocument()
            for (n, cell) in record.enumerated() where !cell.isEmpty {
                do {
                    Self.insert(try Self.value(cell, as: types[names[n]] ?? .auto), at: paths[n][...], into: &document)
                } catch {
                    throw RowError(message: "Row \(row), \(names[n]): \(error)")
                }
            }
            return (document, row)
        }
    }

    private static func insert(_ value: BSONValue, at path: ArraySlice<String>, into document: inout BSONDocument) {
        let key = path.first!
        guard path.count > 1 else { return document.fields.append((key, value)) }
        let at = document.fields.firstIndex { $0.key == key }
        var sub = BSONDocument()
        if let at, case .document(let existing) = document.fields[at].value { sub = existing }
        insert(value, at: path.dropFirst(), into: &sub)
        if let at { document.fields[at].value = .document(sub) } else { document.fields.append((key, .document(sub))) }
    }

    /// A cell read as `type`.
    public static func value(_ cell: String, as type: MongoCSVType) throws -> BSONValue {
        // The shell form the export writes (NumberLong(5), ISODate("…"), ObjectId("…")) keeps its type.
        let shell = cell.hasSuffix(")") ? try? BSONValue(shellForm: cell) : nil
        switch type {
        case .auto:
            if let shell { return shell }
            if cell == "null" { return .null }
            if cell == "true" || cell == "false" { return .bool(cell == "true") }
            if isInteger(Substring(cell)) {
                if let n = Int32(cell) { return .int32(n) }
                if let n = Int64(cell) { return .int64(n) }
            }
            if isDecimal(cell), let d = Double(cell), d.isFinite { return .double(d) }
            if cell.utf8.count == 24, let id = BSONObjectId(hex: cell) { return .objectId(id) }
            if cell.first?.isASCII == true, cell.first?.isNumber == true, let ms = ShellDate.parse(cell) { return .datetime(ms) }
            return .string(cell)
        case .string:
            return .string(cell)
        default:
            if let shell, shell.typeAlias == type.rawValue { return shell }
            let value: BSONValue?
            switch type {
            case .int: value = Int32(cell).map { .int32($0) }
            case .long: value = Int64(cell).map { .int64($0) }
            case .double: value = Double(cell).map { .double($0) }
            case .decimal: value = BSONDecimal128(cell).map { .decimal128($0) }
            case .bool: value = ["true": true, "false": false][cell.lowercased()].map { .bool($0) }
            case .date: value = ShellDate.parse(cell).map { .datetime($0) }
            default: value = BSONObjectId(hex: cell).map { .objectId($0) }
            }
            guard let value else { throw RowError(message: "“\(cell.prefix(60))” isn't \(type.article)") }
            return value
        }
    }

    /// -12, 0, 7: digits with an optional minus and no leading zero (so 0123, a code, stays text).
    private static func isInteger(_ text: Substring) -> Bool {
        let digits = text.hasPrefix("-") ? text.dropFirst() : text
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber } && (digits == "0" || !digits.hasPrefix("0"))
    }

    /// -1.5, 2e10, 0.25E-3: an integer, then a fraction, an exponent or both.
    private static func isDecimal(_ text: String) -> Bool {
        let (number, exponent) = text.firstIndex { $0 == "e" || $0 == "E" }.map { (text[..<$0], text[text.index(after: $0)...]) }
            ?? (text[...], nil)
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, isInteger(parts[0]), parts.count == 2 || exponent != nil else { return false }
        if parts.count == 2, parts[1].isEmpty || !parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) { return false }
        guard let exponent else { return true }
        let digits = exponent.hasPrefix("-") || exponent.hasPrefix("+") ? exponent.dropFirst() : exponent
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
