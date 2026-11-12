import Foundation

/// SQL for people who know SQL, not MongoDB (mongo-plan, Phase 5 C): one SELECT, read with `SQLParser`, written as an
/// aggregation pipeline, always; or refused with the part it can't translate and where that part is. It never guesses
/// and runs nothing: `sample` only reads samples already cached, for the notes.
///
/// Paths: `a.b.c` is a path of the FROM collection unless its first part is a FROM alias (or collection name), so
/// `o.items.sku` and `items.sku` are the same path under `FROM orders o`; `` `a.b` `` is the path a.b too.
public enum MongoSQL {
    public struct Translation: Sendable {
        public var pipeline: [BSONDocument]
        /// The FROM collection, which the pipeline runs on.
        public var collection: String
        /// The JOINs' collections, in order.
        public var joined: [String]
        /// Plain-word lines to show with the pipeline, only those that apply to this query.
        public var notes: [String]
    }

    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public var message: String
        /// The part refused, in UTF-16 offsets of the SQL (as `SQLParser` and NSTextView count).
        public var range: Range<Int>
        public var offset: Int { range.lowerBound }
        public var description: String { message }
    }

    public static let equalityNote = "= and IN compare exactly: they are case-sensitive and never convert types ('42' doesn't find 42)"
    public static let negationNote = "<>, NOT IN, NOT LIKE, NOT BETWEEN and NOT also return documents that don't have the field (SQL leaves out NULLs)"
    public static let groupNote = "GROUP BY and DISTINCT put documents whose field is null or missing in one group"
    public static let joinNote = "A JOIN also pairs documents whose fields are both missing or null (SQL never matches NULL)"
    public static let emptyNote = "With no GROUP BY, no matching documents give no row (SQL gives one, with a COUNT of 0)"

    /// `sample` gives a collection's cached sample (`MongoSampleCache.cached`), or nil.
    public static func translate(_ sql: String, sample: ((String) -> MongoSample?)? = nil) throws -> Translation {
        try Translator(sql, sample: sample).translate()
    }
}

private typealias Refusal = MongoSQL.Refusal

private final class Translator {
    let sql: String
    let text: NSString
    let sample: ((String) -> MongoSample?)?
    var notes: [String] = []
    var baseName = "", baseCollection = ""
    /// The joins read so far: what a name may refer to at this point.
    var joins: [(name: String, collection: String)] = []
    /// Every FROM name (aliases and collections), visible yet or not.
    var fromNames: Set<String> = []
    /// Whether a literal's type is checked against the sample of the field it's compared with.
    var checkTypes = true

    init(_ sql: String, sample: ((String) -> MongoSample?)?) {
        self.sql = sql
        text = sql as NSString
        self.sample = sample
    }

    func refuse(_ message: String, _ range: Range<Int>) -> Refusal { Refusal(message: message, range: range) }
    func source(_ range: Range<Int>) -> String { text.substring(with: NSRange(location: range.lowerBound, length: range.count)) }
    func note(_ line: String) { if !notes.contains(line) { notes.append(line) } }

    // MARK: The statement

    func translate() throws -> MongoSQL.Translation {
        let statements = SQLParser.parse(sql).filter { !$0.verb.isEmpty }
        guard let statement = statements.first else { throw refuse("Write a SELECT to translate", 0..<0) }
        if statements.count > 1 { throw refuse("Only one statement is translated at a time", statements[1].range) }
        if let error = statement.errors.first { throw refuse(error.message, error.range) }
        if statement.shallow { throw refuse("This SQL can't be read in full (an executable comment or an unclosed quote)", statement.range) }
        guard statement.kind == .select, let query = statement.query else {
            throw refuse("Only SELECT is translated: \(statement.verb) isn't", statement.range)
        }
        if let cte = query.ctes.first { throw refuse("WITH isn't translated: use Stages", cte.range) }
        if query.blocks.count > 1 {
            throw refuse("\(query.setOperators.first ?? "UNION") isn't translated: use Stages", query.blocks[1].range)
        }
        guard let select = query.blocks.first else { throw refuse("Write a SELECT to translate", statement.range) }
        if select.nested != nil || !query.orderBy.isEmpty || !query.limit.isEmpty {
            throw refuse("A SELECT in brackets isn't translated: write it without them", select.range)
        }
        if select.table != nil || !select.rows.isEmpty { throw refuse("Only SELECT … FROM is translated", select.range) }
        for (clause, start) in select.clauses {
            switch clause {
            case .into: throw refuse("SELECT … INTO isn't translated: nothing here writes", start..<start)
            case .other: throw refuse("FOR UPDATE, LOCK and PROCEDURE aren't translated", start..<start)
            case .window: throw refuse("Window functions aren't translated: use Stages", start..<start)
            case .limit where select.limit.isEmpty: throw refuse("FETCH isn't translated: use LIMIT", start..<start)
            default: break
            }
        }
        try refuseUnsupported(select)
        return try translate(select)
    }

    /// Subqueries, CASE and window functions anywhere, before any clause is read.
    func refuseUnsupported(_ select: SQLSelect) throws {
        var expressions = select.items.map(\.expr) + select.from.compactMap { $0.join?.on }
        expressions += [select.whereClause, select.having].compactMap { $0 } + select.groupBy + select.orderBy.map(\.expr)
        expressions += select.limit
        var found: Refusal?
        for expression in expressions where found == nil {
            expression.walk { e in
                guard found == nil else { return }
                switch e.kind {
                case .subquery, .exists: found = refuse("Subqueries aren't translated: use Stages", e.range)
                case .inList where e.query != nil: found = refuse("Subqueries aren't translated: use Stages", e.range)
                case .caseWhen: found = refuse("CASE isn't translated: use Stages", e.range)
                case .call where e.isWindow: found = refuse("Window functions aren't translated: use Stages", e.range)
                default: break
                }
            }
        }
        if let found { throw found }
    }

    func translate(_ select: SQLSelect) throws -> MongoSQL.Translation {
        var pipeline: [BSONDocument] = []
        let lookups = try from(select)
        // WHERE: conditions on the FROM collection alone go before the $lookups, so they can use its indexes.
        if let condition = select.whereClause {
            let conjuncts = condition.kind == .binary && condition.op == "AND" ? condition.children : [condition]
            var before: [BSONDocument] = [], after: [BSONDocument] = []
            for conjunct in conjuncts {
                let filter = try self.filter(conjunct, field: whereField)
                if try lookups.isEmpty || onlyBase(conjunct) { before.append(filter) } else { after.append(filter) }
            }
            if !before.isEmpty { pipeline.append(stage("$match", .document(and(before)))) }
            pipeline += lookups
            if !after.isEmpty { pipeline.append(stage("$match", .document(and(after)))) }
        } else {
            pipeline += lookups
        }

        let items = try selectItems(select)
        let grouped = select.distinct || !select.groupBy.isEmpty || items.contains { $0.aggregate != nil }
        if select.having != nil && !grouped { throw refuse("HAVING without GROUP BY isn't translated: use WHERE", select.having!.range) }
        if grouped {
            pipeline += try group(select, items)
        } else {
            if let sort = try sort(select.orderBy, items) { pipeline.append(stage("$sort", .document(sort))) }
            pipeline += try limit(select)
            if !items.isEmpty { pipeline.append(stage("$project", .document(project(items.map { ($0.name, "$" + $0.path) })))) }
        }
        return MongoSQL.Translation(pipeline: pipeline, collection: baseCollection, joined: joins.map(\.collection), notes: notes)
    }

    func stage(_ name: String, _ value: BSONValue) -> BSONDocument { BSONDocument([(name, value)]) }

    /// `{_id: 0, name: "$path", …}`: the SQL columns in order, nothing else.
    func project(_ columns: [(name: String, value: String)]) -> BSONDocument {
        var fields: [(key: String, value: BSONValue)] = columns.contains { $0.name == "_id" } ? [] : [("_id", .int32(0))]
        fields += columns.map { ($0.name, .string($0.value)) }
        return BSONDocument(fields)
    }

    // MARK: FROM and JOIN

    /// One name of FROM: a collection of this database, and what the query calls it.
    func collection(_ table: SQLTableRef) throws -> (collection: String, name: String) {
        guard table.kind == .table, let name = table.name else {
            if table.kind == .derived { throw refuse("Subqueries aren't translated: use Stages", table.range) }
            throw refuse("Only collections are translated in FROM", table.range)
        }
        if name.parts.count > 1 { throw refuse("A database name isn't translated: the query runs in this database", name.range) }
        let called = table.alias?.value ?? name.last.value
        if called.contains(".") || called.hasPrefix("$") || called.isEmpty {
            throw refuse("\(called) can't name a field: give it an alias without a dot or $", table.alias?.range ?? name.range)
        }
        return (name.last.value, called)
    }

    /// The FROM collection, and a $lookup (with its $unwind) per JOIN.
    func from(_ select: SQLSelect) throws -> [BSONDocument] {
        guard let first = select.from.first else { throw refuse("FROM is needed: it names the collection", select.range) }
        for table in select.from {
            if let name = table.name { fromNames.insert(name.last.value) }
            if let alias = table.alias { fromNames.insert(alias.value) }
        }
        (baseCollection, baseName) = try collection(first)
        var stages: [BSONDocument] = []
        for (index, table) in select.from.enumerated().dropFirst() {
            if let alias = select.from[index - 1].alias, !alias.quoted, alias.value.uppercased() == "FULL" {
                throw refuse("FULL JOIN isn't translated: MongoDB has no full join", alias.range)
            }
            guard let join = table.join else { throw refuse("A comma between collections isn't translated: use JOIN … ON", table.range) }
            switch join.kind {
            case "JOIN", "LEFT JOIN": break
            case "RIGHT JOIN": throw refuse("RIGHT JOIN isn't translated: swap the collections and use LEFT JOIN", join.range)
            default: throw refuse("\(join.kind) isn't translated: use JOIN or LEFT JOIN with ON", join.range)
            }
            if !join.using.isEmpty { throw refuse("USING isn't translated: write ON a.x = b.y", join.range) }
            let (collection, name) = try self.collection(table)
            if name == baseName || joins.contains(where: { $0.name == name }) {
                throw refuse("\(name) is named twice in FROM: give one an alias", table.range)
            }
            guard let on = join.on else { throw refuse("A JOIN needs ON a.x = b.y", join.range) }
            guard on.kind == .binary, on.op == "=", on.children.count == 2,
                  on.children.allSatisfy({ $0.kind == .column }) else {
                throw refuse("ON is translated only as one equality of two fields: a.x = b.y", on.range)
            }
            joins.append((name, collection))
            let sides = try on.children.map { try field($0) }
            let theirs = sides.firstIndex { $0.join == name }
            guard let theirs, sides[1 - theirs].join != name else {
                throw refuse("ON must compare a field of \(name) with one of an earlier collection", on.range)
            }
            let local = sides[1 - theirs].path, foreign = sides[theirs].local
            stages.append(stage("$lookup", .document(BSONDocument([("from", .string(collection)), ("localField", .string(local)),
                                                                   ("foreignField", .string(foreign)), ("as", .string(name))]))))
            var unwind: [(key: String, value: BSONValue)] = [("path", .string("$" + name))]
            if join.kind == "LEFT JOIN" { unwind.append(("preserveNullAndEmptyArrays", .bool(true))) }
            stages.append(stage("$unwind", .document(BSONDocument(unwind))))
            note(MongoSQL.joinNote)
        }
        return stages
    }

    // MARK: Names

    /// A field: its path in the pipeline's documents, the joined collection it comes from (nil: FROM's) and its path there.
    struct Field {
        var path: String
        var join: String?
        var local: String
        var collection: String
    }

    func field(_ e: SQLExpr) throws -> Field {
        guard e.kind == .column, let name = e.name else { throw refuse("A field name is needed here", e.range) }
        var parts = name.parts.map(\.value)
        for part in name.parts where part.value.isEmpty || part.value.hasPrefix("$") {
            throw refuse("A field name can't be empty or start with $", part.range)
        }
        if parts.count > 1 {
            if parts[0] == baseName {
                parts.removeFirst()
            } else if let join = joins.first(where: { $0.name == parts[0] }) {
                let local = parts.dropFirst().joined(separator: ".")
                return Field(path: join.name + "." + local, join: join.name, local: local, collection: join.collection)
            } else if fromNames.contains(parts[0]) {
                throw refuse("\(parts[0]) can't be named here: use its alias, of a collection joined before this", name.parts[0].range)
            }
        }
        let path = parts.joined(separator: ".")
        return Field(path: path, join: nil, local: path, collection: baseCollection)
    }

    func whereField(_ e: SQLExpr) throws -> String? {
        if e.kind == .call, aggregateName(e) != nil { throw refuse("Aggregates go in HAVING, not WHERE", e.range) }
        return e.kind == .column ? try field(e).path : nil
    }

    func onlyBase(_ e: SQLExpr) throws -> Bool {
        var columns: [SQLExpr] = []
        e.walk { if $0.kind == .column { columns.append($0) } }
        return try columns.allSatisfy { try field($0).join == nil }
    }

    // MARK: WHERE and HAVING

    /// A condition as a query document; `field` gives a field's path, nil for what isn't a field.
    func filter(_ e: SQLExpr, field: (SQLExpr) throws -> String?) throws -> BSONDocument {
        func pathAndValue(_ a: SQLExpr, _ b: SQLExpr) throws -> (String, BSONValue, flipped: Bool) {
            if let path = try field(a) {
                if try field(b) != nil { throw refuse("Comparing two fields isn't translated: use Stages", e.range) }
                return (path, try value(b, comparedWith: a), false)
            }
            if let path = try field(b) { return (path, try value(a, comparedWith: b), true) }
            throw refuse("A comparison needs a field on one side", e.range)
        }
        func one(_ path: String, _ value: BSONValue) -> BSONDocument { BSONDocument([(path, value)]) }
        func op(_ name: String, _ value: BSONValue) -> BSONValue { .document(BSONDocument([(name, value)])) }

        switch e.kind {
        case .binary where e.op == "AND":
            return and(try e.children.map { try filter($0, field: field) })
        case .binary where e.op == "OR":
            return one("$or", .array(try e.children.map { .document(try filter($0, field: field)) }))
        case .unary where e.op == "NOT":
            note(MongoSQL.negationNote)
            return one("$nor", .array([.document(try filter(e.children[0], field: field))]))
        case .row where e.children.count == 1:
            return try filter(e.children[0], field: field)
        case .binary where ["=", "<>", "!=", "<", "<=", ">", ">="].contains(e.op):
            let (path, value, flipped) = try pathAndValue(e.children[0], e.children[1])
            if case .null = value { throw refuse("A comparison with NULL is never true in SQL: use IS NULL or IS NOT NULL", e.range) }
            let flip = ["<": ">", "<=": ">=", ">": "<", ">=": "<="]
            let mongo = ["=": "", "<>": "$ne", "!=": "$ne", "<": "$lt", "<=": "$lte", ">": "$gt", ">=": "$gte"][flipped ? flip[e.op] ?? e.op : e.op]!
            if e.op == "=" { note(MongoSQL.equalityNote); return one(path, value) }
            if mongo == "$ne" { note(MongoSQL.equalityNote); note(MongoSQL.negationNote) }
            return one(path, op(mongo, value))
        case .isTest where e.op == "NULL":
            guard let path = try field(e.children[0]) else { throw refuse("IS NULL needs a field", e.range) }
            return one(path, e.negated ? op("$ne", .null) : .null)
        case .isTest:
            throw refuse("IS \(e.negated ? "NOT " : "")\(e.op) isn't translated: use = TRUE or = FALSE", e.range)
        case .inList:
            guard let path = try field(e.children[0]) else { throw refuse("IN needs a field before it", e.range) }
            let values = try e.children.dropFirst().map { try value($0, comparedWith: e.children[0]) }
            if let null = e.children.dropFirst().first(where: { $0.kind == .literal && $0.op == "NULL" }) {
                throw refuse("NULL in IN (…) matches nothing in SQL: use IS NULL", null.range)
            }
            note(MongoSQL.equalityNote)
            if e.negated { note(MongoSQL.negationNote) }
            return one(path, op(e.negated ? "$nin" : "$in", .array(values)))
        case .between:
            guard let path = try field(e.children[0]) else { throw refuse("BETWEEN needs a field before it", e.range) }
            let low = try value(e.children[1], comparedWith: e.children[0]), high = try value(e.children[2], comparedWith: e.children[0])
            if case .null = low { throw refuse("BETWEEN NULL is never true in SQL", e.children[1].range) }
            if case .null = high { throw refuse("BETWEEN … AND NULL is never true in SQL", e.children[2].range) }
            let range = BSONValue.document(BSONDocument([("$gte", low), ("$lte", high)]))
            if e.negated { note(MongoSQL.negationNote) }
            return one(path, e.negated ? op("$not", range) : range)
        case .like:
            guard e.op == "LIKE" else { throw refuse("\(e.op) isn't translated: use LIKE, or Stages", e.opRange ?? e.range) }
            if e.children.count > 2 { throw refuse("ESCAPE isn't translated: LIKE takes \\ before % or _", e.children[2].range) }
            guard let path = try field(e.children[0]) else { throw refuse("LIKE needs a field before it", e.range) }
            guard case .string(let pattern) = try value(e.children[1], comparedWith: nil) else {
                throw refuse("LIKE needs a text pattern: '%text%'", e.children[1].range)
            }
            let regex = BSONValue.regex(pattern: Self.regex(like: pattern), options: "is")
            if e.negated { note(MongoSQL.negationNote) }
            return one(path, e.negated ? op("$not", regex) : regex)
        case .column, .literal:
            throw refuse("A condition is needed here, such as name = 'value'", e.range)
        case .call:
            if aggregateName(e) != nil, try field(e) == nil { throw refuse("Aggregates go in HAVING, not WHERE", e.range) }
            throw refuse("Functions aren't translated in conditions: use Stages", e.range)
        default:
            throw refuse("\(source(e.range)) isn't translated: use Stages", e.range)
        }
    }

    /// Conditions together: one document when no key repeats, else $and.
    func and(_ documents: [BSONDocument]) -> BSONDocument {
        let keys = documents.flatMap(\.keys)
        if documents.count == 1 || Set(keys).count == keys.count { return BSONDocument(documents.flatMap(\.fields)) }
        return BSONDocument([("$and", .array(documents.map { .document($0) }))])
    }

    /// LIKE's pattern as an anchored regular expression: % is .*, _ is ., \ takes the next character as it is, the
    /// rest is escaped. A leading or trailing % drops its anchor instead.
    static func regex(like pattern: String) -> String {
        var pieces: [String] = [], characters = Array(pattern), i = 0
        while i < characters.count {
            let c = characters[i]
            if c == "\\", i + 1 < characters.count {
                pieces.append(escaped(characters[i + 1]))
                i += 2
                continue
            }
            pieces.append(c == "%" ? ".*" : c == "_" ? "." : escaped(c))
            i += 1
        }
        let open = pieces.last == ".*", start = pieces.first == ".*" ? "" : "^", end = open ? "" : "\\z"
        if start.isEmpty { pieces.removeFirst() }
        if open, !pieces.isEmpty { pieces.removeLast() }
        return start + pieces.joined() + end
    }

    static func escaped(_ c: Character) -> String { "\\^$.|?*+()[]{}/".contains(c) ? "\\" + String(c) : String(c) }

    // MARK: Values

    /// A literal: text, a number, TRUE, FALSE, NULL, DATE '…', TIMESTAMP '…' (UTC), ObjectId('…'). With the field it
    /// is compared with, a note when the sample mostly holds another type there.
    func value(_ e: SQLExpr, comparedWith column: SQLExpr?) throws -> BSONValue {
        let found = try literal(e)
        if checkTypes, let column, column.kind == .column { typeNote(try field(column), found) }
        return found
    }

    func literal(_ e: SQLExpr) throws -> BSONValue {
        let written = source(e.range)
        switch e.kind {
        case .literal:
            switch e.op {
            case "string": return .string(try string(written, e.range))
            case "number":
                guard written.allSatisfy({ "0123456789.eE+-".contains($0) }) else { break }
                if let whole = Int64(written) { return .int64(whole) }
                if let number = Double(written), number.isFinite { return .double(number) }
            case "TRUE": return .bool(true)
            case "FALSE": return .bool(false)
            case "NULL": return .null
            case "date": return try date(written, e.range)
            default: break
            }
        case .unary where ["-", "+"].contains(e.op) && e.children[0].kind == .literal && e.children[0].op == "number":
            switch try literal(e.children[0]) {
            case .int64(let n): return .int64(e.op == "-" ? -n : n)
            case .double(let n): return .double(e.op == "-" ? -n : n)
            default: break
            }
        case .call where e.name?.parts.count == 1 && e.name?.last.value.uppercased() == "OBJECTID":
            if e.children.count == 1, e.children[0].kind == .literal, e.children[0].op == "string",
               let id = BSONObjectId(hex: try string(source(e.children[0].range), e.children[0].range)) {
                return .objectId(id)
            }
            throw refuse("ObjectId('…') takes 24 hexadecimal digits", e.range)
        default: break
        }
        throw refuse("\(written) isn't a value translated here: use text, a number, TRUE, FALSE, DATE '…', TIMESTAMP '…' or ObjectId('…')", e.range)
    }

    /// A string literal's text: 'a' 'b' is one string; quotes doubled and backslash escapes as MySQL reads them.
    func string(_ written: String, _ range: Range<Int>) throws -> String {
        var result = ""
        for token in SQLLexer.tokens(written) where token.kind == .string {
            let quoted = (written as NSString).substring(with: NSRange(location: token.range.lowerBound, length: token.range.count))
            guard let quote = quoted.first, quote == "'" || quote == "\"" else { throw refuse("\(quoted) isn't translated: write plain 'text'", range) }
            result += InsertRows.unescaped(quoted, quote: quote, noBackslashEscapes: false)
        }
        return result
    }

    /// DATE 'YYYY-MM-DD' or TIMESTAMP 'YYYY-MM-DD HH:MM:SS[.fff]', in UTC.
    func date(_ written: String, _ range: Range<Int>) throws -> BSONValue {
        let word = written.prefix { $0.isLetter }.uppercased()
        let value = try string(String(written.dropFirst(word.count)), range)
        let pattern = word == "DATE" ? #"^(\d{4})-(\d{2})-(\d{2})$"# : #"^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?)?$"#
        guard word != "TIME" else { throw refuse("TIME '…' isn't translated: MongoDB keeps dates with times", range) }
        let expression = try! NSRegularExpression(pattern: pattern)
        guard let match = expression.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) else {
            throw refuse(word == "DATE" ? "DATE takes 'YYYY-MM-DD'" : "TIMESTAMP takes 'YYYY-MM-DD HH:MM:SS'", range)
        }
        func part(_ n: Int) -> String? {
            n >= match.numberOfRanges || match.range(at: n).location == NSNotFound ? nil : (value as NSString).substring(with: match.range(at: n))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: Int(part(1)!), month: Int(part(2)!), day: Int(part(3)!),
                                        hour: Int(part(4) ?? "0"), minute: Int(part(5) ?? "0"), second: Int(part(6) ?? "0"))
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == components else {
            throw refuse("\(value) isn't a date", range)
        }
        let milliseconds = Int64((part(7) ?? "0").padding(toLength: 3, withPad: "0", startingAt: 0))!
        return .datetime(Int64(date.timeIntervalSince1970.rounded()) * 1000 + milliseconds)
    }

    /// The sample's main type at the field, when the literal's is another.
    func typeNote(_ field: Field, _ value: BSONValue) {
        guard let sample = sample?(field.collection) else { return }
        let fields = sample.schema.fields
        guard let found = fields.first(where: { $0.path == field.local })
                ?? fields.first(where: { $0.path.replacingOccurrences(of: ".[]", with: "") == field.local }),
              let main = found.types.first(where: { $0.name != "null" })?.name else { return }
        func kind(_ name: String) -> String {
            switch name {
            case "int", "long", "double", "decimal": return "number"
            case "string": return "text"
            case "bool": return "true/false"
            case "objectId": return "ObjectId"
            default: return name
            }
        }
        let theirs = kind(main), ours: String
        switch value {
        case .string: ours = "text"
        case .int64, .double: ours = "number"
        case .bool: ours = "true/false"
        case .datetime: ours = "date"
        case .objectId: ours = "ObjectId"
        default: return
        }
        guard !["array", "object"].contains(theirs), theirs != ours else { return }
        note("\(field.path) is mostly \(theirs) in \(field.collection)'s sample but is compared with \(ours) here: "
             + "MongoDB never converts types, so this may find nothing")
    }

    // MARK: SELECT

    struct Item {
        var name: String
        var range: Range<Int>
        /// A column's path (nil for an aggregate).
        var path: String
        var aggregate: Aggregate?
    }

    struct Aggregate: Equatable {
        /// COUNT, SUM, AVG, MIN, MAX.
        var function: String
        /// nil for COUNT(*).
        var path: String?
        var key: String { "\(function)(\(path ?? "*"))" }
        var accumulator: BSONDocument {
            let op = ["COUNT": "$sum", "SUM": "$sum", "AVG": "$avg", "MIN": "$min", "MAX": "$max"][function]!
            return BSONDocument([(op, path.map { .string("$" + $0) } ?? .int32(1))])
        }
    }

    func aggregateName(_ e: SQLExpr) -> String? {
        guard e.kind == .call, let name = e.name, name.parts.count == 1 else { return nil }
        let upper = name.last.value.uppercased()
        return ["COUNT", "SUM", "AVG", "MIN", "MAX"].contains(upper) ? upper : nil
    }

    func aggregate(_ e: SQLExpr) throws -> Aggregate? {
        guard let function = aggregateName(e) else { return nil }
        if e.distinct { throw refuse("\(function)(DISTINCT …) isn't translated: use Stages", e.range) }
        if e.opaque || e.children.count != 1 { throw refuse("\(function) takes one field", e.range) }
        let argument = e.children[0]
        if function == "COUNT" {
            guard argument.kind == .star, argument.name == nil else {
                throw refuse("COUNT(field) isn't translated: use COUNT(*) with WHERE field IS NOT NULL", e.range)
            }
            return Aggregate(function: function, path: nil)
        }
        guard argument.kind == .column else { throw refuse("\(function) takes one field, not an expression", e.range) }
        return Aggregate(function: function, path: try field(argument).path)
    }

    /// The SELECT list; empty for `*`.
    func selectItems(_ select: SQLSelect) throws -> [Item] {
        if select.items.count == 1, select.items[0].expr.kind == .star, select.items[0].expr.name == nil, select.items[0].alias == nil {
            if select.distinct { throw refuse("DISTINCT * isn't translated: name the fields", select.items[0].range) }
            return []
        }
        var items: [Item] = []
        for item in select.items {
            let e = item.expr
            var found: Item
            switch e.kind {
            case .column:
                found = Item(name: item.alias?.value ?? e.name!.last.value, range: item.range, path: try field(e).path)
            case .star:
                throw refuse(e.name == nil ? "* with other columns isn't translated: name the fields"
                             : "\(source(e.range)) isn't translated: name the fields, or use *", e.range)
            case .call where aggregateName(e) != nil:
                found = Item(name: item.alias?.value ?? source(e.range), range: item.range, path: "", aggregate: try aggregate(e))
                if found.name == "_id" { throw refuse("An aggregate can't be named _id: choose another name", item.range) }
            default:
                throw refuse("Expressions in SELECT aren't translated: name fields, or use Stages", e.range)
            }
            if found.name.contains(".") || found.name.hasPrefix("$") || found.name.isEmpty {
                throw refuse("\(found.name) can't be a field name in MongoDB: give it a name with AS", item.range)
            }
            if items.contains(where: { $0.name == found.name }) {
                throw refuse("Two columns are named \(found.name): give one another name with AS", item.range)
            }
            items.append(found)
        }
        return items
    }

    /// A name of ORDER BY or GROUP BY: a position, a SELECT alias, or a field.
    func item(_ e: SQLExpr, _ items: [Item]) throws -> Item? {
        if e.kind == .literal, e.op == "number" {
            guard let n = Int(source(e.range)), n >= 1, n <= items.count else {
                throw refuse("\(source(e.range)) isn't a column of the SELECT list", e.range)
            }
            return items[n - 1]
        }
        if e.kind == .column, let name = e.name, name.parts.count == 1, let found = items.first(where: { $0.name == name.last.value }) {
            return found
        }
        return nil
    }

    // MARK: GROUP BY, HAVING, ORDER BY, LIMIT

    /// $group (with HAVING's $match, the $sort and the limits after it) and the $project giving the SQL columns.
    func group(_ select: SQLSelect, _ items: [Item]) throws -> [BSONDocument] {
        if select.rollup { throw refuse("WITH ROLLUP isn't translated: use Stages", select.range) }
        var keys: [(path: String, name: String)] = []
        func addKey(_ path: String, _ e: SQLExpr) throws {
            guard !keys.contains(where: { $0.path == path }) else { return }
            let name = items.first { $0.aggregate == nil && $0.path == path }?.name ?? path.replacingOccurrences(of: ".", with: "_")
            if keys.contains(where: { $0.name == name }) { throw refuse("Two GROUP BY fields are both named \(name)", e.range) }
            keys.append((path, name))
        }
        if select.distinct {
            if !select.groupBy.isEmpty { throw refuse("DISTINCT with GROUP BY isn't translated: leave out DISTINCT", select.range) }
            for (item, written) in zip(items, select.items) {
                if item.aggregate != nil { throw refuse("DISTINCT with aggregates isn't translated", written.range) }
                try addKey(item.path, written.expr)
            }
        }
        for e in select.groupBy {
            if let found = try item(e, items) {
                if found.aggregate != nil { throw refuse("GROUP BY can't name an aggregate", e.range) }
                try addKey(found.path, e)
            } else if e.kind == .column {
                try addKey(try field(e).path, e)
            } else {
                throw refuse("GROUP BY takes field names, not expressions", e.range)
            }
        }
        note(keys.isEmpty ? MongoSQL.emptyNote : MongoSQL.groupNote)
        for (item, written) in zip(items, select.items) where item.aggregate == nil && !keys.contains(where: { $0.path == item.path }) {
            throw refuse("\(item.name) isn't in GROUP BY: group by it, or use an aggregate such as MAX(\(item.name))", written.range)
        }
        func keyPath(_ path: String) -> String? {
            guard let key = keys.first(where: { $0.path == path }) else { return nil }
            return keys.count == 1 ? "_id" : "_id." + key.name
        }

        // Accumulators: the SELECT list's, then those HAVING and ORDER BY name.
        var accumulators: [(name: String, aggregate: Aggregate)] = items.compactMap { item in item.aggregate.map { (item.name, $0) } }
        func accumulator(_ aggregate: Aggregate) -> String {
            if let found = accumulators.first(where: { $0.aggregate == aggregate }) { return found.name }
            var n = 1
            while accumulators.contains(where: { $0.name == "_agg\(n)" }) || items.contains(where: { $0.name == "_agg\(n)" }) { n += 1 }
            accumulators.append(("_agg\(n)", aggregate))
            return "_agg\(n)"
        }
        /// A name in the grouped documents.
        func grouped(_ e: SQLExpr, positions: Bool) throws -> String? {
            if let aggregate = try aggregate(e) { return accumulator(aggregate) }
            if positions || e.kind == .column, let found = try item(e, items) {
                return found.aggregate == nil ? keyPath(found.path)! : accumulators.first { $0.aggregate == found.aggregate }!.name
            }
            guard e.kind == .column else { return nil }
            guard let path = keyPath(try field(e).path) else {
                throw refuse("\(source(e.range)) isn't in GROUP BY: after grouping only its fields and aggregates are left", e.range)
            }
            return path
        }

        var having: BSONDocument?
        if let condition = select.having {
            checkTypes = false  // HAVING's names are the grouped documents', not a sampled collection's
            having = try filter(condition) { try grouped($0, positions: false) }
        }
        var sortFields: [(key: String, value: BSONValue)] = []
        for order in select.orderBy {
            guard let path = try grouped(order.expr, positions: true) else { throw refuse("ORDER BY takes names, aliases and positions, not expressions", order.expr.range) }
            if !sortFields.contains(where: { $0.key == path }) { sortFields.append((path, .int32(order.direction?.value.uppercased() == "DESC" ? -1 : 1))) }
        }

        let id: BSONValue = keys.isEmpty ? .null : keys.count == 1 ? .string("$" + keys[0].path)
            : .document(BSONDocument(keys.map { ($0.name, .string("$" + $0.path)) }))
        var stages = [stage("$group", .document(BSONDocument([("_id", id)] + accumulators.map { ($0.name, .document($0.aggregate.accumulator)) })))]
        if let having { stages.append(stage("$match", .document(having))) }
        if !sortFields.isEmpty { stages.append(stage("$sort", .document(BSONDocument(sortFields)))) }
        stages += try limit(select)
        stages.append(stage("$project", .document(project(items.map { item in
            (item.name, "$" + (item.aggregate == nil ? keyPath(item.path)! : item.name))
        }))))
        return stages
    }

    /// ORDER BY without grouping: on the documents' paths, before the $project.
    func sort(_ orderBy: [SQLOrderItem], _ items: [Item]) throws -> BSONDocument? {
        guard !orderBy.isEmpty else { return nil }
        var fields: [(key: String, value: BSONValue)] = []
        for order in orderBy {
            let e = order.expr
            let path: String
            if e.kind == .literal, e.op == "number", items.isEmpty {
                throw refuse("ORDER BY a position needs a SELECT list, not *", e.range)
            } else if let found = try item(e, items) {
                path = found.path
            } else if e.kind == .column {
                path = try field(e).path
            } else {
                throw refuse("ORDER BY takes names, aliases and positions, not expressions", e.range)
            }
            if !fields.contains(where: { $0.key == path }) { fields.append((path, .int32(order.direction?.value.uppercased() == "DESC" ? -1 : 1))) }
        }
        return BSONDocument(fields)
    }

    /// LIMIT n, LIMIT m, n, LIMIT n OFFSET m: $skip, then $limit.
    func limit(_ select: SQLSelect) throws -> [BSONDocument] {
        if select.limit.count > 2 { throw refuse("ROWS EXAMINED isn't translated", select.limit[2].range) }
        var count: Int64?, offset: Int64?
        for e in select.limit {
            guard e.kind == .literal, e.op == "number", let n = Int64(source(e.range)) else {
                throw refuse("LIMIT and OFFSET take whole numbers", e.range)
            }
            let before = text.substring(to: e.range.lowerBound).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if before.hasSuffix("OFFSET") {
                offset = n
            } else if before.hasSuffix(",") {
                offset = count
                count = n
            } else {
                count = n
            }
        }
        if count == 0 { throw refuse("LIMIT 0 returns nothing", select.limit[0].range) }
        var stages: [BSONDocument] = []
        if let offset, offset > 0 { stages.append(stage("$skip", .int64(offset))) }
        if let count { stages.append(stage("$limit", .int64(count))) }
        return stages
    }
}
