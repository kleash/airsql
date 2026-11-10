import Foundation

/// What a sample of a collection's documents holds, per dotted path (mongo-plan, Schema): the Schema tab, field
/// completion and the agents' schema tool read it. Sub-documents are followed into their fields; an array's elements
/// are gathered under `path.[]` (and their fields under `path.[].field`). Getting the sample (`$sample`) is the caller's.
public struct MongoSchema: Sendable {
    public struct Field: Sendable {
        /// `address.city`, `tags.[]`, `items.[].price`.
        public var path: String
        /// Values found here, null included.
        public var present = 0
        /// Times the document holding this field (the top-level one, a sub-document or an array's element) lacked it:
        /// a field of a sub-document that is itself absent isn't counted. Always 0 for `path.[]`.
        public var missing = 0
        public var nulls = 0
        /// How many values have each type, by `$type`'s name ("int", "string", "object", …); most common first.
        public var types: [(name: String, count: Int)] = []
        /// The most common values in shell form (not documents or arrays), most common first.
        public var top: [(value: String, count: Int)] = []
        /// Distinct values (not documents or arrays): exact when `distinctIsExact`, else a lower bound.
        public var distinct = 0
        public var distinctIsExact = true
        /// The smallest and largest number (int, long, double, decimal; NaN left out), and date.
        public var minNumber: BSONValue?
        public var maxNumber: BSONValue?
        public var minDate: BSONValue?
        public var maxDate: BSONValue?

        /// A type's share of the values here, 0…1.
        public func share(_ type: String) -> Double {
            present == 0 ? 0 : Double(types.first { $0.name == type }?.count ?? 0) / Double(present)
        }
    }

    public var documents: Int
    /// In the order paths first appear.
    public var fields: [Field]

    public subscript(path: String) -> Field? { fields.first { $0.path == path } }

    /// `topLimit` values kept per path; distinct values counted exactly up to `distinctLimit`.
    public init(sample: [BSONDocument], topLimit: Int = 10, distinctLimit: Int = 1_000) {
        var order: [String] = []
        var tally: [String: Tally] = [:]

        func visit(_ path: String, parent: String?, _ value: BSONValue) {
            if tally[path] == nil { order.append(path); tally[path] = Tally(parent: parent) }
            tally[path]!.add(value, distinctLimit: distinctLimit)
            switch value {
            case .document(let document): visit(document, under: path)
            case .array(let elements): for element in elements { visit(path + ".[]", parent: nil, element) }
            default: break
            }
        }
        func visit(_ document: BSONDocument, under parent: String?) {
            var seen = Set<String>()  // a repeated key counts once, as the server reads the first
            for (key, value) in document.fields where seen.insert(key).inserted {
                visit(parent.map { $0 + "." + key } ?? key, parent: parent, value)
            }
            if let parent { tally[parent]!.holders += 1 }
        }
        for document in sample { visit(document, under: nil) }

        documents = sample.count
        fields = order.map { path in
            let t = tally[path]!
            // The documents that could hold it: the sample at the top, else how often its parent was a document.
            let holding = path.hasSuffix(".[]") ? t.present : t.parent.map { tally[$0]!.holders } ?? sample.count
            var field = Field(path: path)
            field.present = t.present
            field.missing = max(0, holding - t.present)
            field.nulls = t.types["null"] ?? 0
            field.types = t.types.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }
            field.top = t.values.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(topLimit)
                .map { ($0.key, $0.value) }
            field.distinct = t.values.count
            field.distinctIsExact = !t.overflowed
            (field.minNumber, field.maxNumber, field.minDate, field.maxDate) = (t.minNumber, t.maxNumber, t.minDate, t.maxDate)
            return field
        }
    }

    private struct Tally {
        /// The document's path for a field in a sub-document; nil at the top and for an array's elements.
        let parent: String?
        var present = 0
        /// How often this path was a document (its fields' `missing` counts against it).
        var holders = 0
        var types: [String: Int] = [:]
        var values: [String: Int] = [:]
        var overflowed = false
        var minNumber: BSONValue?, maxNumber: BSONValue?, minDate: BSONValue?, maxDate: BSONValue?

        mutating func add(_ value: BSONValue, distinctLimit: Int) {
            present += 1
            types[value.typeAlias, default: 0] += 1
            switch value {
            case .document, .array: return
            case .datetime(let ms):
                if case .datetime(let low)? = minDate, low <= ms {} else { minDate = value }
                if case .datetime(let high)? = maxDate, high >= ms {} else { maxDate = value }
            default:
                if let n = Self.number(value), !n.isNaN {
                    if minNumber.flatMap(Self.number).map({ $0 <= n }) != true { minNumber = value }
                    if maxNumber.flatMap(Self.number).map({ $0 >= n }) != true { maxNumber = value }
                }
            }
            // shortcut: values are told apart by their first 200 characters, a hash of the whole value if that misleads.
            let text = value.shellForm(maxLength: 200)
            if values[text] != nil {
                values[text]! += 1
            } else if values.count < distinctLimit {
                values[text] = 1
            } else {
                overflowed = true
            }
        }

        /// For ordering only: a long beyond 2^53 or a decimal may round, which can only swap near-equal neighbours.
        static func number(_ value: BSONValue) -> Double? {
            switch value {
            case .int32(let n): return Double(n)
            case .int64(let n): return Double(n)
            case .double(let d): return d
            case .decimal128(let d): return Double(d.description)
            default: return nil
            }
        }
    }
}
