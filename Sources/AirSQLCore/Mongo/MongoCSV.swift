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
