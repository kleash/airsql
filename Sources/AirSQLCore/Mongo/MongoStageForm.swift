import Foundation

/// The stage builder's cards (mongo-plan, Phase 5 B): one card per pipeline stage, never folded, so card n is stage n.
/// A stage a card can't show exactly is a Shell card holding its document.
public enum MongoStageForm: Equatable, Sendable {
    case filter(MongoBuilder.Group)
    case join(Join)
    case group(Grouping)
    case sort([MongoBuilder.SortKey])
    case show(MongoBuilder.Projection)
    case limit(Int64)
    case unwind(Unwind)
    case shell(BSONDocument)

    /// `$lookup` with localField and foreignField: their documents whose `foreignField` equals this `localField`, as
    /// an array in `as`.
    public struct Join: Equatable, Sendable {
        public var from: String
        public var localField: String
        public var foreignField: String
        public var `as`: String

        public init(from: String, localField: String, foreignField: String, as name: String) {
            self.from = from
            self.localField = localField
            self.foreignField = foreignField
            self.as = name
        }
    }

    public enum Accumulator: String, CaseIterable, Sendable {
        case count, sum, average, smallest, largest, first, last, list, distinctList

        public var title: String {
            switch self {
            case .count: return "Count"
            case .sum: return "Sum"
            case .average: return "Average"
            case .smallest: return "Smallest"
            case .largest: return "Largest"
            case .first: return "First"
            case .last: return "Last"
            case .list: return "List"
            case .distinctList: return "Distinct list"
            }
        }

        /// SQL's name for it, where it has one.
        public var sqlHint: String {
            switch self {
            case .count: return "COUNT(*)"
            case .sum: return "SUM"
            case .average: return "AVG"
            case .smallest: return "MIN"
            case .largest: return "MAX"
            case .first, .last: return ""
            case .list: return "GROUP_CONCAT"
            case .distinctList: return "GROUP_CONCAT(DISTINCT)"
            }
        }

        var mongo: String {
            switch self {
            case .count, .sum: return "$sum"
            case .average: return "$avg"
            case .smallest: return "$min"
            case .largest: return "$max"
            case .first: return "$first"
            case .last: return "$last"
            case .list: return "$push"
            case .distinctList: return "$addToSet"
            }
        }

        var prefix: String {
            switch self {
            case .average: return "avg"
            case .smallest: return "min"
            case .largest: return "max"
            case .distinctList: return "distinct"
            default: return rawValue
            }
        }
    }

    /// One result of a group: Count, or an accumulator of a field.
    public struct Output: Equatable, Sendable {
        public var op: Accumulator
        /// Unused for Count.
        public var field: String

        /// The name it is written under.
        public var name: String

        public init(_ op: Accumulator, _ field: String = "", name: String? = nil) {
            self.op = op
            self.field = field
            self.name = name ?? Self.defaultName(op, field)
        }

        /// `count`, `sum_price`, `avg_items_qty`.
        public static func defaultName(_ op: Accumulator, _ field: String) -> String {
            op == .count ? "count" : op.prefix + "_" + MongoStageForm.key(field)
        }
    }

    /// `$group` — GROUP BY `by` (none: one group of every document).
    public struct Grouping: Equatable, Sendable {
        public var by: [String]
        /// One field's `_id` as `{ a: "$a" }` rather than `"$a"` (several fields always are a document).
        public var byDocument: Bool
        public var outputs: [Output]

        public init(by: [String] = [], byDocument: Bool = false, outputs: [Output] = []) {
            self.by = by
            self.byDocument = byDocument
            self.outputs = outputs
        }

        var idIsDocument: Bool { by.count > 1 || (byDocument && by.count == 1) }
    }

    public struct Unwind: Equatable, Sendable {
        public var path: String
        /// Keep documents whose array is missing or empty (a join's "keep documents without a match").
        public var preserve: Bool

        public init(path: String, preserve: Bool = false) {
            self.path = path
            self.preserve = preserve
        }
    }

    /// The card's name with SQL's beside it.
    public var title: String {
        switch self {
        case .filter: return "Filter — WHERE"
        case .join: return "Join — JOIN"
        case .group: return "Group — GROUP BY"
        case .sort: return "Sort — ORDER BY"
        case .show: return "Show fields — SELECT"
        case .limit: return "Limit — LIMIT"
        case .unwind: return "Unwind"
        case .shell: return "Shell"
        }
    }

    /// A key for a path inside a document the stage writes: dots become underscores.
    static func key(_ path: String) -> String { path.replacingOccurrences(of: ".", with: "_") }

    public static func forms(from stages: [BSONDocument]) -> [MongoStageForm] { stages.map(MongoStageForm.init(stage:)) }

    /// The card for a stage: a Shell card when no other shows it exactly.
    public init(stage: BSONDocument) {
        self = Self.read(stage) ?? .shell(stage)
    }

    private static func read(_ stage: BSONDocument) -> MongoStageForm? {
        guard stage.fields.count == 1 else { return nil }
        let value = stage.fields[0].value
        switch (stage.fields[0].key, value) {
        case ("$match", .document(let d)): return MongoBuilder.Group(filter: d).map(MongoStageForm.filter)
        case ("$lookup", .document(let d)):
            guard d.keys.count == 4, Set(d.keys) == ["from", "localField", "foreignField", "as"] else { return nil }
            func text(_ key: String) -> String? { if case .string(let s)? = d[key], !s.isEmpty { return s } else { return nil } }
            guard let from = text("from"), let local = text("localField"), let foreign = text("foreignField"), let name = text("as")
            else { return nil }
            return .join(Join(from: from, localField: local, foreignField: foreign, as: name))
        case ("$group", .document(let d)): return readGroup(d).map(MongoStageForm.group)
        case ("$sort", .document(let d)) where !d.fields.isEmpty: return MongoBuilder.sortKeys(d).map(MongoStageForm.sort)
        case ("$project", .document(let d)): return MongoBuilder.Projection(document: d).map(MongoStageForm.show)
        case ("$limit", _):
            switch value {
            case .int32(let n) where n > 0: return .limit(Int64(n))
            case .int64(let n) where n > 0: return .limit(n)
            case .double(let d) where d >= 1 && d < 9.2e18 && d.rounded() == d: return .limit(Int64(d))
            default: return nil
            }
        case ("$unwind", .string(let s)): return fieldPath(s).map { .unwind(Unwind(path: $0)) }
        case ("$unwind", .document(let d)):
            guard d.keys.first == "path", Set(d.keys).count == d.keys.count,
                  Set(d.keys).isSubset(of: ["path", "preserveNullAndEmptyArrays"]),
                  case .string(let s)? = d["path"], let path = fieldPath(s) else { return nil }
            var preserve = false
            if let flag = d["preserveNullAndEmptyArrays"] {
                guard case .bool(let b) = flag else { return nil }
                preserve = b
            }
            return .unwind(Unwind(path: path, preserve: preserve))
        default: return nil
        }
    }

    /// `"$a.b"` → `a.b`; nil for anything else (`"$$ROOT"`, a literal).
    static func fieldPath(_ s: String) -> String? {
        guard s.hasPrefix("$"), !s.hasPrefix("$$"), s.count > 1 else { return nil }
        return String(s.dropFirst())
    }

    private static func readGroup(_ d: BSONDocument) -> Grouping? {
        guard d.keys.first == "_id", Set(d.keys).count == d.keys.count else { return nil }
        var group = Grouping()
        switch d["_id"]! {
        case .null: break
        case .string(let s):
            guard let path = fieldPath(s) else { return nil }
            group.by = [path]
        case .document(let id) where !id.fields.isEmpty:
            for (k, v) in id.fields {
                guard case .string(let s) = v, let path = fieldPath(s), key(path) == k else { return nil }
                group.by.append(path)
            }
            group.byDocument = id.fields.count == 1
        default: return nil
        }
        for (name, value) in d.fields.dropFirst() {
            guard case .document(let acc) = value, acc.fields.count == 1, !name.hasPrefix("$"), !name.contains(".") else { return nil }
            let (op, arg) = acc.fields[0]
            let output: Output
            switch arg {
            case .int32(1) where op == "$sum", .int64(1) where op == "$sum", .double(1) where op == "$sum":
                output = Output(.count, name: name)
            case .string(let s):
                guard let path = fieldPath(s), let a = Accumulator.allCases.first(where: { $0 != .count && $0.mongo == op }) else { return nil }
                output = Output(a, path, name: name)
            default: return nil
            }
            group.outputs.append(output)
        }
        return group
    }

    /// The stage this card writes, or a plain error saying what to fill in.
    public func stage() throws -> BSONDocument {
        func one(_ key: String, _ value: BSONValue) -> BSONDocument { BSONDocument([(key, value)]) }
        func path(_ p: String, _ what: String) throws -> String {
            guard !p.isEmpty else { throw BSONError("Choose \(what)") }
            guard !p.hasPrefix("$") else { throw BSONError("‘\(p)’: a field's name can't start with $") }
            return p
        }
        switch self {
        case .filter(let group): return one("$match", .document(try group.filter()))
        case .join(let j):
            guard !j.from.isEmpty else { throw BSONError("Choose the collection to join") }
            return one("$lookup", .document(BSONDocument([
                ("from", .string(j.from)), ("localField", .string(try path(j.localField, "this collection's field"))),
                ("foreignField", .string(try path(j.foreignField, "their field"))), ("as", .string(try path(j.as, "a name for the joined documents")))])))
        case .group(let g):
            let by = try g.by.map { try path($0, "a field to group by") }
            let id: BSONValue = g.idIsDocument ? .document(BSONDocument(by.map { (Self.key($0), .string("$" + $0)) }))
                : by.first.map { .string("$" + $0) } ?? .null
            var fields: [(key: String, value: BSONValue)] = [("_id", id)]
            for output in g.outputs {
                let arg: BSONValue = output.op == .count ? .int32(1) : .string("$" + (try path(output.field, "a field for \(output.op.title)")))
                guard !output.name.isEmpty else { throw BSONError("Name the result of \(output.op.title)") }
                guard !output.name.hasPrefix("$"), !output.name.contains(".") else {
                    throw BSONError("‘\(output.name)’: a result's name can't start with $ or hold a dot")
                }
                guard !fields.contains(where: { $0.key == output.name }) else { throw BSONError("Two results are both named \(output.name)") }
                fields.append((output.name, .document(one(output.op.mongo, arg))))
            }
            return one("$group", .document(BSONDocument(fields)))
        case .sort(let keys):
            _ = try keys.map { try path($0.path, "a field to sort by") }
            guard let sort = MongoBuilder.sortDocument(keys) else { throw BSONError("Add a field to sort by") }
            return one("$sort", .document(sort))
        case .show(let projection):
            _ = try projection.paths.map { try path($0, "a field to show") }
            guard let document = projection.document else { throw BSONError("Tick the fields to show") }
            return one("$project", .document(document))
        case .limit(let n):
            guard n > 0 else { throw BSONError("Type a limit of 1 or more") }
            return one("$limit", Int32(exactly: n).map(BSONValue.int32) ?? .int64(n))
        case .unwind(let u):
            let p = "$" + (try path(u.path, "the array field to unwind"))
            return one("$unwind", u.preserve ? .document(BSONDocument([("path", .string(p)), ("preserveNullAndEmptyArrays", .bool(true))]))
                       : .string(p))
        case .shell(let document): return document
        }
    }

    // MARK: Fields downstream

    /// The paths after each stage (`result[n]`: what stage n+1 sees), from the collection's sample paths (`items.[].sku`)
    /// and a joined collection's (`foreign(from)`): Join adds `<as>` and `<as>.<their paths>`, Group gives `_id` and its
    /// names, Show narrows, Unwind turns `path.[]…` into `path…`; the others keep them.
    public static func fields(after forms: [MongoStageForm], base: [String], foreign: (String) -> [String]) -> [[String]] {
        var paths = base
        return forms.map { form in
            switch form {
            case .join(let j):
                let kept = paths.filter { p in let q = MongoBuilder.queryPath(p); return q != j.as && !q.hasPrefix(j.as + ".") }
                paths = kept + [j.as] + foreign(j.from).map { j.as + "." + $0 }
            case .group(let g):
                paths = ["_id"] + (g.idIsDocument ? g.by.map { "_id." + key($0) } : []) + g.outputs.map(\.name)
            case .show(let projection):
                let ticked = projection.paths
                paths = (projection.includeId ? ["_id"] : []) + paths.filter { p in
                    let q = MongoBuilder.queryPath(p)
                    return q != "_id" && ticked.contains { q == $0 || q.hasPrefix($0 + ".") || $0.hasPrefix(q + ".") }
                }
            case .unwind(let u):
                let array = paths.first { MongoBuilder.queryPath($0) == u.path && !$0.hasSuffix(".[]") } ?? u.path
                paths = paths.compactMap { p in
                    if p == array + ".[]" { return nil }
                    return p.hasPrefix(array + ".[].") ? array + "." + p.dropFirst(array.count + 4) : p
                }
            case .filter, .sort, .limit, .shell: break
            }
            var seen = Set<String>()
            paths = paths.filter { seen.insert($0).inserted }
            return paths
        }
    }
}

// MARK: Splicing a card's stage into the pipeline's text

extension MongoPipeline {
    /// `text` with stage `n` (from 0) written as `stage`, laid out as the old one was (one line, or indented as it
    /// was); everything else byte for byte.
    public static func replacingStage(_ n: Int, with stage: BSONDocument, in text: String) throws -> String {
        let stages = try stages(in: text), units = Array(text.utf16)
        guard stages.indices.contains(n) else { throw BSONError("There is no stage \(n + 1)") }
        let old = stages[n].range
        return splice(units, old, render(stage, like: old, in: units))
    }

    /// `text` with `stage` put in as stage `n` (`n` = the count adds it at the end), laid out as its neighbour.
    public static func insertingStage(_ stage: BSONDocument, at n: Int, in text: String) throws -> String {
        let stages = try stages(in: text), units = Array(text.utf16)
        guard (0...stages.count).contains(n) else { throw BSONError("There is no stage \(n + 1)") }
        guard !stages.isEmpty else { return self.text([stage]) }
        let neighbour = stages[min(n, stages.count - 1)].range
        let separator = indent(of: neighbour.lowerBound, in: units).map { ",\n" + $0 } ?? ", "
        let new = render(stage, like: neighbour, in: units)
        if n < stages.count { return splice(units, neighbour.lowerBound..<neighbour.lowerBound, new + separator) }
        return splice(units, neighbour.upperBound..<neighbour.upperBound, separator + new)
    }

    /// `text` without stage `n` and the separator before it (after it, for the first).
    public static func removingStage(_ n: Int, in text: String) throws -> String {
        let stages = try stages(in: text), units = Array(text.utf16)
        guard stages.indices.contains(n) else { throw BSONError("There is no stage \(n + 1)") }
        if stages.count == 1 { return self.text([]) }
        if n == 0 { return splice(units, stages[0].range.lowerBound..<stages[1].range.lowerBound, "") }
        return splice(units, stages[n - 1].range.upperBound..<stages[n].range.upperBound, "")
    }

    private static func splice(_ units: [UInt16], _ range: Range<Int>, _ new: String) -> String {
        String(decoding: units[..<range.lowerBound] + Array(new.utf16) + units[range.upperBound...], as: UTF16.self)
    }

    /// The spaces before a stage that starts its own line; nil when something else is before it on its line.
    private static func indent(of offset: Int, in units: [UInt16]) -> String? {
        let start = units[..<offset].lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        let before = units[start..<offset]
        return start > 0 && before.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) ? String(decoding: before, as: UTF16.self) : nil
    }

    private static func render(_ stage: BSONDocument, like old: Range<Int>, in units: [UInt16]) -> String {
        guard units[old].contains(0x0A) else { return stage.shellForm() }
        return stage.shellForm(pretty: true).replacingOccurrences(of: "\n", with: "\n" + (indent(of: old.lowerBound, in: units) ?? ""))
    }
}

// MARK: Join warnings

/// What may be wrong with a join, in plain words, from the cached samples of both collections (the stage builder's
/// Join card and Query with SQL).
public enum MongoJoinCheck {
    /// Warnings for joining `from` on `localField` = `foreignField` into `as`; a missing sample says nothing.
    public static func warnings(from: String, localField: String, foreignField: String, as name: String,
                                here: MongoSample?, there: MongoSample?) -> [String] {
        var out: [String] = []
        if let here, let there, let a = MongoBuilder.mainType(of: localField, in: here.schema),
           let b = MongoBuilder.mainType(of: foreignField, in: there.schema), kind(a) != kind(b) {
            out.append("‘\(localField)’ is \(word(a)) here but ‘\(foreignField)’ is \(word(b)) in \(from): values of different types never match, so nothing joins")
        }
        // No indexes listed means they couldn't be read (every collection has _id's).
        if let there, !there.indexes.isEmpty, !there.indexes.contains(where: { $0.keys.first == foreignField }) {
            out.append("\(from) has no index starting with ‘\(foreignField)’: each document's join reads all of \(from)")
        }
        if let here, here.schema.fields.contains(where: { MongoBuilder.queryPath($0.path) == name }) {
            out.append("‘\(name)’ is already a field here: the join replaces it")
        }
        return out
    }

    private static func kind(_ type: String) -> String { ["int", "long", "double", "decimal"].contains(type) ? "number" : type }

    private static func word(_ type: String) -> String {
        switch kind(type) {
        case "objectId": return "an ObjectId"
        case "string": return "text"
        case "number": return "a number"
        case "date": return "a date"
        case "bool": return "true/false"
        case "object": return "a sub-document"
        default: return type
        }
    }
}
