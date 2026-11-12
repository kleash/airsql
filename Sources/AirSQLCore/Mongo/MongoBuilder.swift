import Foundation

/// The query builder's model (mongo-plan, Phase 5 A): conditions in plain words, each with its SQL name beside it, to a
/// filter document and back; projection ticks, sort rows and "ignore case" likewise. The shell text stays the source of
/// truth: `Group(filter:)` reads back only the shapes `filter()` writes (and a few plain ones), and refuses the rest,
/// which then stays text.
public enum MongoBuilder {
    // MARK: Operators and value types

    public enum Operator: String, CaseIterable, Sendable {
        case `is`, isNot, contains, notContains, startsWith, endsWith, matches
        case greater, atLeast, less, atMost, between, oneOf, noneOf, hasValue, hasNoValue

        public var title: String {
            switch self {
            case .is: return "is"
            case .isNot: return "is not"
            case .contains: return "contains"
            case .notContains: return "doesn't contain"
            case .startsWith: return "starts with"
            case .endsWith: return "ends with"
            case .matches: return "matches pattern"
            case .greater: return "greater than"
            case .atLeast: return "at least"
            case .less: return "less than"
            case .atMost: return "at most"
            case .between: return "between"
            case .oneOf: return "is one of"
            case .noneOf: return "is none of"
            case .hasValue: return "has a value"
            case .hasNoValue: return "has no value"
            }
        }

        /// What SQL writes for it.
        public var sqlHint: String {
            switch self {
            case .is: return "= x"
            case .isNot: return "<> x"
            case .contains: return "LIKE '%x%'"
            case .notContains: return "NOT LIKE '%x%'"
            case .startsWith: return "LIKE 'x%'"
            case .endsWith: return "LIKE '%x'"
            case .matches: return "REGEXP 'x'"
            case .greater: return "> x"
            case .atLeast: return ">= x"
            case .less: return "< x"
            case .atMost: return "<= x"
            case .between: return "BETWEEN x AND y"
            case .oneOf: return "IN (x, y)"
            case .noneOf: return "NOT IN (x, y)"
            case .hasValue: return "IS NOT NULL"
            case .hasNoValue: return "IS NULL"
            }
        }

        /// "contains — LIKE '%x%'", for the operator menu.
        public var label: String { title + " — " + sqlHint }

        public enum Arity: Sendable { case none, one, two, list }

        /// How many values it takes: `.list` is one or more (`listItems` splits the box's text).
        public var arity: Arity {
            switch self {
            case .hasValue, .hasNoValue: return .none
            case .between: return .two
            case .oneOf, .noneOf: return .list
            default: return .one
            }
        }

        /// The text operators: written as a regular expression, the only ones Ignore case applies to.
        public var isPattern: Bool { [.contains, .notContains, .startsWith, .endsWith, .matches].contains(self) }

        /// The operators the menu offers for a value type (an array field: its element's type, `valueType(of:in:)`).
        public static func fitting(_ type: ValueType) -> [Operator] {
            switch type {
            case .text: return allCases
            case .bool: return [.is, .isNot, .hasValue, .hasNoValue]
            case .number, .date, .objectId, .shell: return allCases.filter { !$0.isPattern }
            }
        }
    }

    public enum ValueType: String, CaseIterable, Sendable {
        case text, number, date, objectId, bool
        /// A value in shell form, taken as written: `ObjectId("…")`, `UUID("…")`, `NumberDecimal("…")`, and anything
        /// read back that the other types can't hold.
        case shell

        public var title: String {
            switch self {
            case .text: return "text"
            case .number: return "number"
            case .date: return "date (UTC)"
            case .objectId: return "ObjectId"
            case .bool: return "true/false"
            case .shell: return "shell value"
            }
        }

        /// The type for a sample's `$type` name ("string", "int", …); nil (no sample) is text.
        public init(typeAlias: String?) {
            switch typeAlias {
            case nil, "string"?: self = .text
            case "int"?, "long"?, "double"?, "decimal"?: self = .number
            case "date"?: self = .date
            case "objectId"?: self = .objectId
            case "bool"?: self = .bool
            default: self = .shell
            }
        }

        /// The value `text` stands for. Every type but text also takes a shell constructor as written, so
        /// `NumberDecimal("1.5")` works in a number field and `ISODate("…")` in a date one.
        public func value(_ text: String) throws -> BSONValue { try MongoBuilder.value(text, self).value }
    }

    /// The type a field's values have in a sample, by its main type (null aside); an array's from its elements.
    public static func valueType(of path: String, in schema: MongoSchema) -> ValueType {
        ValueType(typeAlias: mainType(of: path, in: schema))
    }

    /// The most common `$type` name of `path` (as a query names it: `items.sku`) in a sample, null aside; for an array,
    /// its elements' type. Nil when the sample hasn't the path.
    public static func mainType(of path: String, in schema: MongoSchema) -> String? {
        func main(_ field: MongoSchema.Field?) -> String? { field?.types.first { $0.name != "null" }?.name }
        guard let field = schema.fields.first(where: { queryPath($0.path) == path && !$0.path.hasSuffix(".[]") }) else { return nil }
        let type = main(field)
        return type == "array" ? main(schema[field.path + ".[]"]) ?? type : type
    }

    /// A sample's path as a query names it: `items.[].sku` → `items.sku`.
    public static func queryPath(_ samplePath: String) -> String {
        samplePath.split(separator: ".", omittingEmptySubsequences: false).filter { $0 != "[]" }.joined(separator: ".")
    }

    // MARK: Conditions

    /// One row: a field, an operator and its values as typed.
    public struct Rule: Equatable, Sendable {
        public var path: String
        public var op: Operator
        /// As typed: one for most operators, two for between, the items for is one of / is none of, none for has a value.
        public var values: [String]
        public var type: ValueType
        /// Only on the pattern operators (`i`); Ignore case for the whole query is the collation.
        public var ignoreCase: Bool

        public init(_ path: String, _ op: Operator, _ values: [String] = [], type: ValueType = .text, ignoreCase: Bool = false) {
            self.path = path
            self.op = op
            self.values = values
            self.type = type
            self.ignoreCase = ignoreCase
        }

        /// `{ path: … }`, or a plain error naming the field and the value that is wrong.
        public func clause() throws -> BSONDocument {
            BSONDocument([(path, try condition())])
        }
    }

    public indirect enum Condition: Equatable, Sendable {
        case rule(Rule)
        case group(Group)
    }

    /// Find documents where all (`$and`) or any (`$or`) of the conditions hold. The builders make one level of groups
    /// inside the top one; parse-back reads no deeper.
    public struct Group: Equatable, Sendable {
        public var any: Bool
        public var children: [Condition]

        public init(any: Bool = false, _ children: [Condition] = []) {
            self.any = any
            self.children = children
        }

        /// The filter: `{}` when there are no conditions; `$and` when a key would repeat; empty groups left out.
        public func filter() throws -> BSONDocument {
            if any {
                let parts = try children.flatMap { try $0.orParts() }
                return parts.isEmpty ? BSONDocument() : BSONDocument([("$or", .array(parts.map(BSONValue.document)))])
            }
            return MongoBuilder.and(try children.flatMap { try $0.andParts() })
        }

        /// The conditions of a filter `filter()` could have written, or nil (it stays text).
        public init?(filter: BSONDocument) {
            if filter.fields.count == 1, filter.fields[0].key == "$or" {
                guard let children = MongoBuilder.orChildren(filter.fields[0].value, level: 0) else { return nil }
                self.init(any: true, children)
            } else {
                guard let children = MongoBuilder.conditions(filter, level: 0) else { return nil }
                self.init(any: false, children)
            }
        }
    }

    static func and(_ parts: [BSONDocument]) -> BSONDocument {
        let keys = parts.flatMap(\.keys)
        if Set(keys).count == keys.count { return BSONDocument(parts.flatMap(\.fields)) }
        return BSONDocument([("$and", .array(parts.map(BSONValue.document)))])
    }

    // MARK: Values

    /// Split a list box's text at commas outside double quotes; an item in quotes loses them.
    public static func listItems(_ text: String) -> [String] {
        var items: [String] = [], item = "", quoted = false, escaped = false
        for c in text {
            if c == "," && !quoted { items.append(item); item = ""; continue }
            item.append(c)
            if escaped { escaped = false } else if c == "\\" && quoted { escaped = true } else if c == "\"" { quoted.toggle() }
        }
        items.append(item)
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { item in
            if item.count >= 2, item.hasPrefix("\""), item.hasSuffix("\""), case .string(let s)? = try? BSONValue(shellForm: item) { return s }
            return item
        }
    }

    /// The items as one box's text, which `listItems` reads back the same.
    public static func listText(_ items: [String]) -> String {
        items.map { item in
            item.contains(",") || item.hasPrefix("\"") || item != item.trimmingCharacters(in: .whitespaces)
                ? BSONValue.string(item).shellForm() : item
        }.joined(separator: ", ")
    }

    static let msPerDay = ShellDate.msPerDay

    /// The value, and for a date typed without a time, that it is a whole day.
    static func value(_ raw: String, _ type: ValueType) throws -> (value: BSONValue, isDay: Bool) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BSONError("Type a value") }
        func shell() throws -> BSONValue {
            do { return try BSONValue(shellForm: text) } catch let error as BSONError {
                throw BSONError("‘\(text)’ isn't a value in shell form: \(error.message)")
            }
        }
        let isConstructor = text.range(of: #"^[A-Za-z][A-Za-z0-9]*\(.*\)$"#, options: .regularExpression) != nil
        if type != .text && type != .shell && isConstructor { return (try shell(), false) }
        switch type {
        case .text: return (.string(raw), false)
        case .shell: return (try shell(), false)
        case .number:
            if let n = Int64(text) { return (.int64(n), false) }
            if let d = Double(text), d.isFinite, text.first.map({ $0.isNumber || "+-.".contains($0) }) == true { return (.double(d), false) }
            throw BSONError("‘\(text)’ isn't a number")
        case .date:
            if text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil, let ms = ShellDate.parse(text) {
                return (.datetime(ms), true)
            }
            if let ms = ShellDate.parse(text) { return (.datetime(ms), false) }
            throw BSONError("‘\(text)’ isn't a date: type 2026-11-12, 2026-11-12 10:30 or 2026-11-12T10:30:00Z (UTC)")
        case .objectId:
            if let id = BSONObjectId(hex: text) { return (.objectId(id), false) }
            throw BSONError("‘\(text)’ isn't an ObjectId: type its 24 hex digits")
        case .bool:
            switch text.lowercased() {
            case "true": return (.bool(true), false)
            case "false": return (.bool(false), false)
            default: throw BSONError("‘\(text)’ isn't true or false")
            }
        }
    }

    /// A value read back as the type and text a rule shows; nil for documents and arrays, which no rule holds.
    static func typed(_ value: BSONValue) -> (type: ValueType, text: String)? {
        switch value {
        case .document, .array: return nil
        case .string(let s) where !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: return (.text, s)
        case .int32(let n): return (.number, String(n))
        case .int64(let n): return (.number, String(n))
        case .double(let d) where d.isFinite: return (.number, BSONValue.doubleText(d))
        case .datetime(let ms) where (ShellDate.days(0, 1, 1)...ShellDate.days(9999, 12, 31)).contains(split(ms).day):
            return (.date, dateText(ms))
        case .objectId(let id): return (.objectId, id.hex)
        case .bool(let b): return (.bool, b ? "true" : "false")
        default: return (.shell, value.shellForm())
        }
    }

    static func isMidnight(_ ms: Int64) -> Bool { ms % msPerDay == 0 }

    /// Days since 1970 and milliseconds into the day.
    static func split(_ ms: Int64) -> (day: Int64, time: Int64) {
        let (q, r) = ms.quotientAndRemainder(dividingBy: msPerDay)
        return r < 0 ? (q - 1, r + msPerDay) : (q, r)
    }

    /// `2026-11-12`.
    static func dayText(_ ms: Int64) -> String {
        let (y, m, d) = ShellDate.civil(split(ms).day)
        return String(format: "%04lld-%02lld-%02lld", y, m, d)
    }

    /// `2026-11-12 10:30` when it has no seconds, else `2026-11-12T10:30:05.250Z`: an instant, never a whole day.
    static func dateText(_ ms: Int64) -> String {
        let time = split(ms).time
        if time % 60_000 == 0 { return dayText(ms) + String(format: " %02lld:%02lld", time / 3_600_000, time / 60_000 % 60) }
        return String(ShellDate.text(ms).dropFirst("ISODate(\"".count).dropLast(2))
    }

    /// Ranges of whole days, as between's two values: today, the last 7 days (today and the 6 before), this month.
    public enum DatePreset: String, CaseIterable, Sendable {
        case today, last7Days, thisMonth

        public var title: String {
            switch self {
            case .today: return "today"
            case .last7Days: return "last 7 days"
            case .thisMonth: return "this month"
            }
        }

        /// The first and last day (`2026-11-12`), counted in `calendar`'s days.
        public func values(now: Date, calendar: Calendar) -> [String] {
            func text(_ date: Date) -> String {
                let c = calendar.dateComponents([.year, .month, .day], from: date)
                return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
            }
            switch self {
            case .today: return [text(now), text(now)]
            case .last7Days: return [text(calendar.date(byAdding: .day, value: -6, to: now)!), text(now)]
            case .thisMonth:
                let month = calendar.dateInterval(of: .month, for: now)!
                return [text(month.start), text(calendar.date(byAdding: .day, value: -1, to: month.end)!)]
            }
        }
    }

    // MARK: Patterns

    static let metacharacters = Set("\\^$.|?*+()[]{}")

    /// `text` as a pattern that matches it literally: every metacharacter escaped.
    public static func escapedPattern(_ text: String) -> String {
        String(text.flatMap { metacharacters.contains($0) ? ["\\", $0] : [$0] })
    }

    /// The literal text a pattern `escapedPattern` wrote stands for; nil for an empty one or a real pattern.
    static func literal(_ pattern: Substring) -> String? {
        var out = "", escaped = false
        for c in pattern {
            if escaped {
                guard metacharacters.contains(c) else { return nil }
                out.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                guard !metacharacters.contains(c) else { return nil }
                out.append(c)
            }
        }
        return escaped || out.isEmpty ? nil : out
    }

    // MARK: Projection, sort, collation

    /// Show fields — SELECT: the ticked paths, `_id` shown unless unticked. No paths and `_id` shown is no projection.
    public struct Projection: Equatable, Sendable {
        public var paths: [String]
        public var includeId: Bool

        public init(paths: [String] = [], includeId: Bool = true) {
            self.paths = paths
            self.includeId = includeId
        }

        /// `{ a: 1, b: 1 }` (`_id: 0` when unticked); nil when everything is shown.
        public var document: BSONDocument? {
            let fields = paths.filter { $0 != "_id" }.map { ($0, BSONValue.int32(1)) } + (includeId ? [] : [("_id", .int32(0))])
            return fields.isEmpty ? nil : BSONDocument(fields)
        }

        /// The ticks of an inclusion projection; nil for an exclusion of other fields, expressions, `$` names, a key
        /// twice, or `{ _id: 1 }` alone.
        public init?(document: BSONDocument?) {
            guard let document else { self.init(); return }
            guard Set(document.keys).count == document.keys.count else { return nil }
            var paths: [String] = [], includeId = true
            for (key, value) in document.fields {
                guard let on = MongoBuilder.flag(value), !key.isEmpty, !key.hasPrefix("$") else { return nil }
                if key == "_id" { includeId = on } else if on { paths.append(key) } else { return nil }
            }
            guard !paths.isEmpty || !includeId else { return nil }
            self.init(paths: paths, includeId: includeId)
        }
    }

    /// 1/true or 0/false.
    static func flag(_ value: BSONValue) -> Bool? {
        switch value {
        case .bool(let b): return b
        case .int32(let n) where n == 0 || n == 1: return n == 1
        case .int64(let n) where n == 0 || n == 1: return n == 1
        case .double(let d) where d == 0 || d == 1: return d == 1
        default: return nil
        }
    }

    /// Sort — ORDER BY: one row.
    public struct SortKey: Equatable, Sendable {
        public var path: String
        public var ascending: Bool

        public init(_ path: String, ascending: Bool = true) {
            self.path = path
            self.ascending = ascending
        }
    }

    /// `{ a: 1, b: -1 }`; nil for no rows.
    public static func sortDocument(_ keys: [SortKey]) -> BSONDocument? {
        keys.isEmpty ? nil : BSONDocument(keys.map { ($0.path, .int32($0.ascending ? 1 : -1)) })
    }

    /// The rows of a sort of 1s and -1s; nil for `$meta`, a key twice or anything else.
    public static func sortKeys(_ document: BSONDocument?) -> [SortKey]? {
        guard let document else { return [] }
        guard Set(document.keys).count == document.keys.count else { return nil }
        var keys: [SortKey] = []
        for (key, value) in document.fields {
            let n: Double
            switch value {
            case .int32(let v): n = Double(v)
            case .int64(let v): n = Double(v)
            case .double(let v): n = v
            default: return nil
            }
            guard n == 1 || n == -1, !key.isEmpty, !key.hasPrefix("$") else { return nil }
            keys.append(SortKey(key, ascending: n == 1))
        }
        return keys
    }

    /// "Ignore case in comparisons and sorting": English, strength 2 (letters' case aside, accents count).
    public static let ignoreCaseCollation = BSONDocument([("locale", .string("en")), ("strength", .int32(2))])

    /// Whether a collation is the ignore-case one (nil, no collation: false); nil for any other collation.
    public static func ignoresCase(_ collation: BSONDocument?) -> Bool? {
        guard let collation else { return false }
        guard collation.keys == ["locale", "strength"], collation["locale"] == .string("en") else { return nil }
        switch collation["strength"] {
        case .int32(2)?, .int64(2)?, .double(2)?: return true
        default: return nil
        }
    }

    // MARK: Arrays

    /// For each path, the array (`items`) it shares with another path of `paths`, else nil: rules on `items.sku` and
    /// `items.qty` may each match a different item. `arrayPaths` are the sample's (`items.[]`).
    public static func sharedArrays(paths: [String], arrayPaths: [String]) -> [String?] {
        let arrays = Set(arrayPaths.filter { $0.hasSuffix(".[]") }.map { queryPath(String($0.dropLast(3))) })
            .sorted { $0.count > $1.count }
        func under(_ path: String) -> [String] { arrays.filter { path == $0 || path.hasPrefix($0 + ".") } }
        let each = paths.map(under)
        return each.indices.map { i in
            each[i].first { array in each.indices.contains { $0 != i && each[$0].contains(array) } }
        }
    }
}

// MARK: Writing a rule

extension MongoBuilder.Rule {
    typealias B = MongoBuilder

    /// The value under the field's key.
    func condition() throws -> BSONValue {
        guard !path.isEmpty else { throw BSONError("Choose a field") }
        guard !path.hasPrefix("$") else { throw BSONError("‘\(path)’: a field's name can't start with $") }
        func values(_ count: Int) throws -> [(value: BSONValue, isDay: Bool)] {
            guard self.values.count >= count else { throw BSONError("Type a value for \(path)") }
            return try self.values.prefix(count).map { text in
                do {
                    let typed = try B.value(text, type)
                    switch typed.value {
                    case .document, .array: throw BSONError("‘\(text)’ is a sub-document or array: write that in Shell")
                    case .regex: throw BSONError("‘\(text)’ is a regular expression: use matches pattern")
                    default: return (typed.value, type == .date && typed.isDay)
                    }
                } catch let error as BSONError { throw BSONError("\(path): \(error.message)") }
            }
        }
        func op(_ fields: [(String, BSONValue)]) -> BSONValue { .document(BSONDocument(fields)) }
        func next(_ v: BSONValue) -> BSONValue {
            guard case .datetime(let ms) = v else { return v }
            return .datetime(ms + B.msPerDay)
        }
        func pattern() throws -> BSONValue {
            guard let text = self.values.first, !text.isEmpty else { throw BSONError("Type a value for \(path)") }
            let p: String
            switch self.op {
            case .startsWith: p = "^" + B.escapedPattern(text)
            case .endsWith: p = B.escapedPattern(text) + "$"
            case .matches: p = text
            default: p = B.escapedPattern(text)
            }
            return .regex(pattern: p, options: ignoreCase ? "i" : "")
        }
        switch self.op {
        case .is:
            let v = try values(1)[0]
            return v.isDay ? op([("$gte", v.value), ("$lt", next(v.value))]) : v.value
        case .isNot:
            let v = try values(1)[0]
            return v.isDay ? op([("$not", op([("$gte", v.value), ("$lt", next(v.value))]))]) : op([("$ne", v.value)])
        case .contains, .startsWith, .endsWith, .matches: return try pattern()
        case .notContains: return op([("$not", try pattern())])
        case .greater:
            let v = try values(1)[0]
            return v.isDay ? op([("$gte", next(v.value))]) : op([("$gt", v.value)])
        case .atLeast: return op([("$gte", try values(1)[0].value)])
        case .less: return op([("$lt", try values(1)[0].value)])
        case .atMost:
            let v = try values(1)[0]
            return v.isDay ? op([("$lt", next(v.value))]) : op([("$lte", v.value)])
        case .between:
            let v = try values(2)
            return op([("$gte", v[0].value), v[1].isDay ? ("$lt", next(v[1].value)) : ("$lte", v[1].value)])
        case .oneOf, .noneOf:
            guard !self.values.isEmpty else { throw BSONError("Type a value for \(path)") }
            return op([(self.op == .oneOf ? "$in" : "$nin", .array(try values(self.values.count).map(\.value)))])
        case .hasValue: return op([("$ne", .null)])
        case .hasNoValue: return .null
        }
    }
}

extension MongoBuilder.Condition {
    /// The documents this condition puts in an all-group's `$and` (an all-group inside one is the same as its rules).
    func andParts() throws -> [BSONDocument] {
        switch self {
        case .rule(let rule): return [try rule.clause()]
        case .group(let group) where group.any:
            let filter = try group.filter()
            return filter.fields.isEmpty ? [] : [filter]
        case .group(let group): return try group.children.flatMap { try $0.andParts() }
        }
    }

    /// The documents this condition puts in an any-group's `$or` (an any-group inside one is the same as its rules).
    func orParts() throws -> [BSONDocument] {
        switch self {
        case .rule(let rule): return [try rule.clause()]
        case .group(let group) where group.any: return try group.children.flatMap { try $0.orParts() }
        case .group(let group):
            let filter = try group.filter()
            return filter.fields.isEmpty ? [] : [filter]
        }
    }
}

// MARK: Reading a filter back

extension MongoBuilder {
    /// The conditions of a document whose fields all hold (`{a: 1, $or: […]}`, `{$and: […]}`), in a group at `level`
    /// (the top is 0); nil for anything a builder doesn't write.
    static func conditions(_ document: BSONDocument, level: Int) -> [Condition]? {
        guard Set(document.keys).count == document.keys.count else { return nil }
        var out: [Condition] = []
        for (key, value) in document.fields {
            switch key {
            case "$and":
                guard case .array(let parts) = value, !parts.isEmpty else { return nil }
                for part in parts {
                    guard case .document(let d) = part, !d.fields.isEmpty, let more = conditions(d, level: level) else { return nil }
                    out += more
                }
            case "$or":
                guard level == 0, let children = orChildren(value, level: 1) else { return nil }
                out.append(.group(Group(any: true, children)))
            default:
                guard !key.hasPrefix("$"), !key.isEmpty, let rules = rules(key, value) else { return nil }
                out += rules.map(Condition.rule)
            }
        }
        return out
    }

    /// The children of an any-group at `level` from its `$or` array: a rule each, or an all-group of several.
    static func orChildren(_ value: BSONValue, level: Int) -> [Condition]? {
        guard case .array(let parts) = value, !parts.isEmpty else { return nil }
        var out: [Condition] = []
        for part in parts {
            guard case .document(let d) = part, !d.fields.isEmpty, let found = conditions(d, level: level + 1) else { return nil }
            if found.count == 1, case .rule = found[0] {
                out.append(found[0])
            } else {
                guard level == 0, found.allSatisfy({ if case .rule = $0 { return true } else { return false } }) else { return nil }
                out.append(.group(Group(any: false, found)))
            }
        }
        return out
    }

    /// The rules `{path: value}` stands for.
    static func rules(_ path: String, _ value: BSONValue) -> [Rule]? {
        switch value {
        case .null: return [Rule(path, .hasNoValue)]
        case let .regex(pattern, options): return patternRule(path, pattern, options, negated: false).map { [$0] }
        case .document(let d) where d.fields.first?.key.hasPrefix("$") == true: return operatorRules(path, d)
        default:
            guard let (type, text) = typed(value) else { return nil }
            return [Rule(path, .is, [text], type: type)]
        }
    }

    static func patternRule(_ path: String, _ pattern: String, _ options: String, negated: Bool) -> Rule? {
        guard options == "" || options == "i" else { return nil }
        let i = options == "i"
        if negated { return literal(pattern[...]).map { Rule(path, .notContains, [$0], ignoreCase: i) } }
        if let text = literal(pattern[...]) { return Rule(path, .contains, [text], ignoreCase: i) }
        if pattern.hasPrefix("^"), let text = literal(pattern.dropFirst()) { return Rule(path, .startsWith, [text], ignoreCase: i) }
        if pattern.hasSuffix("$"), let text = literal(pattern.dropLast()) { return Rule(path, .endsWith, [text], ignoreCase: i) }
        return Rule(path, .matches, [pattern], ignoreCase: i)
    }

    /// A whole day `{$gte: day, $lt: next day}`'s first day.
    static func day(_ d: BSONDocument) -> Int64? {
        guard d.keys == ["$gte", "$lt"], case .datetime(let a)? = d["$gte"], case .datetime(let b)? = d["$lt"],
              isMidnight(a), b == a + msPerDay else { return nil }
        return a
    }

    /// `{path: {$op: …, …}}`: a rule per operator, or one for between's two.
    static func operatorRules(_ path: String, _ d: BSONDocument) -> [Rule]? {
        guard Set(d.keys).count == d.keys.count else { return nil }
        if let a = day(d) { return [Rule(path, .is, [dayText(a)], type: .date)] }
        if d.keys == ["$not"] {
            switch d["$not"]! {
            case let .regex(pattern, options): return patternRule(path, pattern, options, negated: true).map { [$0] }
            case .document(let inner): return day(inner).map { [Rule(path, .isNot, [dayText($0)], type: .date)] }
            default: return nil
            }
        }
        if d.keys == ["$gte", "$lt"], case .datetime(let a)? = d["$gte"], case .datetime(let b)? = d["$lt"], isMidnight(b) {
            return [Rule(path, .between, [isMidnight(a) ? dayText(a) : dateText(a), dayText(b - msPerDay)], type: .date)]
        }
        if d.keys == ["$gte", "$lte"], let a = typed(d["$gte"]!), let b = typed(d["$lte"]!), a.type == b.type,
           scalar(d["$gte"]!), scalar(d["$lte"]!) {
            return [Rule(path, .between, [a.text, b.text], type: a.type)]
        }
        var rules: [Rule] = []
        for (key, value) in d.fields {
            switch key {
            case "$eq":
                if value == .null { rules.append(Rule(path, .hasNoValue)); continue }
                guard scalar(value), let (type, text) = typed(value) else { return nil }
                rules.append(Rule(path, .is, [text], type: type))
            case "$ne":
                if value == .null { rules.append(Rule(path, .hasValue)); continue }
                guard scalar(value), let (type, text) = typed(value) else { return nil }
                rules.append(Rule(path, .isNot, [text], type: type))
            case "$gt", "$gte", "$lt", "$lte":
                guard scalar(value), let (type, text) = typed(value) else { return nil }
                let op: Operator = ["$gt": .greater, "$gte": .atLeast, "$lt": .less, "$lte": .atMost][key]!
                rules.append(Rule(path, op, [text], type: type))
            case "$in", "$nin":
                guard case .array(let items) = value, !items.isEmpty else { return nil }
                let read = items.compactMap(typed)
                guard read.count == items.count else { return nil }
                let op: Operator = key == "$in" ? .oneOf : .noneOf
                if let type = read.first?.type, read.allSatisfy({ $0.type == type }) {
                    rules.append(Rule(path, op, read.map(\.text), type: type))
                } else {
                    rules.append(Rule(path, op, items.map { $0.shellForm() }, type: .shell))
                }
            case "$exists":
                guard case .bool(let b) = value else { return nil }
                rules.append(Rule(path, b ? .hasValue : .hasNoValue))
            default: return nil
            }
        }
        return rules
    }

    /// A value a comparison takes: not a document, an array or a regular expression.
    static func scalar(_ value: BSONValue) -> Bool {
        switch value {
        case .document, .array, .regex: return false
        default: return true
        }
    }
}
