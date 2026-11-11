import Foundation

/// Autofill for MongoDB's shell-form text (mongo-plan, Phase 3): what fits at the caret (`MongoCaret`) from the word
/// table (`MongoWords`) and the collection's sample (`MongoSampleCache`), best first. Nothing is read from the server:
/// the caller hands over what is cached. Ranking: a prefix match, then the fuzzy matcher's (`SQLCompletion.match`), then
/// the place's own order (paths before operators in a filter), indexed leading fields, then share in the sample.
public enum MongoCompletion {
    /// The range the suggestions replace and the suggestions, best first. `indexes` are listIndexes' documents (empty:
    /// the sample's key patterns, named as the server names them); `path` is the edited field's path for a `.document`
    /// root (Edit Value); `foreign` gives another collection's cached sample (`$lookup`'s `foreignField`).
    public static func items(root: MongoCaret.Root, text: String, caret: Int, sample: MongoSample?, indexes: [BSONDocument] = [],
                             collections: [String] = [], serverVersion: String? = nil, path: String? = nil,
                             foreign: @escaping (String) -> MongoSample? = { _ in nil }) -> (range: Range<Int>, items: [CompletionItem]) {
        let at = MongoCaret(text: text, caret: caret, root: root)
        var known = Known(sample, indexes: indexes)
        if root == .pipeline, !at.stagesBefore.isEmpty {
            known.paths = outputs(of: at.stagesBefore, in: text, from: known.paths)
        }
        let answer = Answer(at: at, known: known, collections: collections, version: serverVersion, foreign: foreign)
        var place: Place
        switch root {
        case .filter: place = .filter
        case .projection: place = .fields(.projection)
        case .sort: place = .fields(.sort)
        case .hint: place = .hint
        case .collation: place = .collation
        case .update: place = .update
        case .pipeline: place = .pipeline
        case .document: place = .document(path ?? "")
        }
        for key in at.chain { place = key == "[]" ? place.element : answer.enter(place, key) }
        return (at.range, rank(answer.offer(place), at))
    }

    // MARK: Places

    enum Fields { case sort, projection, computed }

    /// What a document's keys, or a value, are at a place.
    indirect enum Place {
        case filter
        /// A field of a filter (collapsed path, `items.sku`): its operators as keys, its values.
        case field(String)
        case update
        /// The document of an update operator (`$set`): paths, those of a type it suits first.
        case updateFields(String)
        case fields(Fields)
        /// A projected field: 1, 0 or an expression.
        case projected
        case hint
        case collation
        /// Under a path of an inserted or edited document (the sample's, `items.[]`); "" is the top.
        case document(String)
        case pipeline
        case stage(MongoWord)
        case expression
        /// `$group`'s (or an `output`'s) new fields; `accumulator`: one of them, an accumulator.
        case accumulators(String)
        case accumulator(String)
        case collection
        /// A field's name in a string, of another collection when named.
        case path(String?)
        case literal([String])
        /// An array of these.
        case list(Place)
        case none

        var element: Place {
            switch self {
            case .list(let inner): return inner
            case .document(let path): return .document(path + ".[]")
            default: return self
            }
        }
    }

    /// The sample's fields as completion offers them.
    struct PathInfo {
        /// As a query writes it: `items.sku` for `items.[].sku`.
        var path: String
        var type: String?
        var share: Double
        var field: MongoSchema.Field?
        var indexed = false
    }

    struct Known {
        var paths: [PathInfo] = [] {
            didSet { index() }
        }
        private var byPath: [String: PathInfo] = [:]
        /// The sample's own paths, `.[]` kept (a document's children).
        var raw: [String: MongoSchema.Field] = [:]
        var rawOrder: [String] = []
        var indexes: [(name: String, key: BSONDocument)] = []

        init(_ sample: MongoSample?, indexes documents: [BSONDocument]) {
            indexes = documents.compactMap { index in
                guard case .document(let key)? = index["key"] else { return nil }
                if case .string(let name)? = index["name"] { return (name, key) }
                return (Self.name(key), key)
            }
            if indexes.isEmpty { indexes = (sample?.indexes ?? []).map { (Self.name($0), $0) } }
            guard let sample else { return }
            let leading = Set(indexes.compactMap(\.key.keys.first))
            for field in sample.schema.fields where raw[field.path] == nil { raw[field.path] = field }
            var seen = Set<String>()
            for rawPath in sample.paths {
                rawOrder.append(rawPath)
                let path = rawPath.contains(".[]") ? rawPath.replacingOccurrences(of: ".[]", with: "") : rawPath
                guard seen.insert(path).inserted else { continue }
                let field = raw[rawPath]
                let share = field.map { Double($0.present) / Double(max(1, $0.present + $0.missing)) } ?? 0
                paths.append(PathInfo(path: path, type: field?.types.first { $0.name != "null" }?.name, share: share, field: field,
                                      indexed: leading.contains(path)))
            }
            index()
        }

        private mutating func index() { byPath = Dictionary(paths.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }) }

        /// The server's name for an index of `key`: `status_1_createdAt_-1`.
        static func name(_ key: BSONDocument) -> String {
            key.fields.map { field in
                if case .string(let kind) = field.value { return field.key + "_" + kind }
                return field.key + "_" + field.value.shellForm()
            }.joined(separator: "_")
        }

        func info(_ path: String) -> PathInfo? { byPath[path] }
    }

    // MARK: What fits

    struct Candidate {
        var item: CompletionItem
        /// The place's order of kinds: paths before operators.
        var group = 0
        var indexed = false
        var share = 0.0
    }

    struct Answer {
        let at: MongoCaret
        let known: Known
        let collections: [String]
        let version: String?
        let foreign: (String) -> MongoSample?

        func available(_ word: MongoWord) -> Bool { version.map(word.isAvailable) ?? true }

        /// The value of `key` in a document at `place`.
        func enter(_ place: Place, _ key: String) -> Place {
            switch place {
            case .filter:
                if ["$and", "$or", "$nor"].contains(key) { return .list(.filter) }
                if key == "$expr" { return .expression }
                return key.hasPrefix("$") ? .none : .field(key)
            case .field(let path):
                switch key {
                case "$exists": return .literal(["true", "false"])
                case "$elemMatch", "$regex", "$options", "$size", "$mod", "$type": return .none
                default: return key.hasPrefix("$") ? .field(path) : .field(path + "." + key)
                }
            case .update: return key.hasPrefix("$") ? .updateFields(key) : .field(key)
            case .updateFields(let op): return ["$unset", "$rename"].contains(op) ? .none : .field(key)
            case .fields(let kind):
                switch kind {
                case .sort: return .literal(["1", "-1"])
                case .projection: return .projected
                case .computed: return .expression
                }
            case .hint: return .literal(["1", "-1"])
            case .document(let path): return .document(path.isEmpty ? key : path + "." + key)
            case .pipeline: return MongoWords.stage(key).map(Place.stage) ?? .none
            case .stage(let word):
                if let slot = word.slot(key) {
                    switch slot {
                    case .collection: return .collection
                    case .field:
                        // Names of new fields aren't the input's.
                        if ["as", "includeArrayIndex", "depthField", "distanceField", "includeLocs"].contains(key) { return .none }
                        return .path(["foreignField", "connectToField"].contains(key) ? at.values["from"] : nil)
                    case .fields: return .fields(.sort)
                    case .pipeline: return .list(.pipeline)
                    case .expression: return .expression
                    case .query: return .filter
                    case .accumulators: return .accumulators(word.name)
                    case .value: return .none
                    }
                }
                switch word.argument {
                case .query?: return enter(.filter, key)
                case .fields?: return enter(.fields(Self.fields(word.name)), key)
                case .accumulators?: return enter(.accumulators(word.name), key)
                case .pipeline?: return .list(.pipeline)
                case .expression?: return enter(.expression, key)
                default: return .none
                }
            case .expression, .projected: return .expression
            case .accumulators(let stage): return key == "_id" ? .expression : .accumulator(stage)
            case .accumulator: return .expression
            default: return .none
            }
        }

        static func fields(_ stage: String) -> Fields { stage == "$sort" ? .sort : stage == "$project" ? .projection : .computed }

        func offer(_ place: Place) -> [Candidate] {
            switch at.slot {
            case .key: return keys(place)
            case .value, .string: return values(place)
            case .reference: return references()
            case .variable: return MongoWords.variables.filter(available).map { word(.variable, $0, text: $0.name) }
            case .none: return []
            }
        }

        // MARK: Keys

        func keys(_ place: Place) -> [Candidate] {
            switch place {
            case .filter:
                return paths() + MongoWords.query.filter(\.topLevel).map { word(.keyword, $0, group: 1) }
            case .field(let path):
                let type = known.info(path)?.type
                let words = type == nil ? MongoWords.query.filter { !$0.topLevel } : MongoWords.query(for: type)
                // Those for the field's type first: $gt for a number, $regex for a string.
                return words.map { word(.keyword, $0, group: $0.types.isEmpty ? 1 : 0) }
            case .update:
                return MongoWords.update.map { word(.keyword, $0) } + paths(group: 1)
            case .updateFields(let op):
                let suits = MongoWords.named(op, kind: .update).first?.types ?? []
                return paths().map { candidate in
                    var candidate = candidate
                    if !suits.isEmpty, !suits.contains(known.info(candidate.item.label)?.type ?? "") { candidate.group = 1 }
                    return candidate
                }
            case .fields: return paths()
            case .hint:
                var seen = Set<String>()
                return known.indexes.flatMap(\.key.keys).filter { seen.insert($0).inserted }.map {
                    Candidate(item: CompletionItem(kind: .column, text: key($0), label: $0, detail: "indexed"), indexed: true)
                }
            case .collation:
                return ["locale", "strength", "caseLevel", "caseFirst", "numericOrdering", "alternate", "maxVariable", "backwards"].map {
                    Candidate(item: CompletionItem(kind: .keyword, text: $0, label: $0, detail: "collation"))
                }
            case .document(let path):
                let under = path.isEmpty ? "" : path + "."
                return known.rawOrder.compactMap { raw -> Candidate? in
                    guard raw.hasPrefix(under) else { return nil }
                    let name = String(raw.dropFirst(under.count))
                    guard !name.isEmpty, !name.contains("."), name != "[]" else { return nil }
                    return pathCandidate(name, info: known.info(raw.replacingOccurrences(of: ".[]", with: "")))
                }
            case .pipeline:
                guard at.siblings.isEmpty else { return [] }
                return MongoWords.stages.filter(available).map { stage($0, braces: false) }
            case .stage(let word):
                if !word.keys.isEmpty {
                    return word.keys.map { Candidate(item: CompletionItem(kind: .keyword, text: $0.name, label: $0.name,
                                                                          detail: $0.required ? "required" : word.name)) }
                }
                switch word.argument {
                case .query?: return keys(.filter)
                case .fields?: return keys(.fields(Self.fields(word.name)))
                case .expression?: return keys(.expression)
                default: return []
                }
            case .expression, .projected:
                return MongoWords.expressions.filter(available).map { word(.function, $0) }
            case .accumulators(let stage):
                return stage == "$group" ? [Candidate(item: CompletionItem(kind: .keyword, text: "_id", label: "_id",
                                                                           detail: "required: what to group by"))] : []
            case .accumulator(let stage):
                return MongoWords.accumulators(in: stage).filter(available).map { word(.function, $0) }
            default: return []
            }
        }

        // MARK: Values

        func values(_ place: Place) -> [Candidate] {
            var atStage = false
            if case .pipeline = place { atStage = true }
            if at.slot == .value, at.prefix.hasPrefix("$"), !atStage {
                // `_id: $st` before its quote: a reference, quoted.
                return at.prefix.hasPrefix("$$") ? MongoWords.variables.filter(available).map { word(.variable, $0, text: quoted($0.name)) }
                    : known.paths.map { pathCandidate("$" + $0.path, info: $0, text: quoted("$" + $0.path)) }
            }
            switch place {
            case .field(let path):
                return constructors(known.info(path)?.field)
            case .projected: return values(.literal(["1", "0"]))
            case .literal(let words):
                return words.map { Candidate(item: CompletionItem(kind: .value, text: $0, label: $0, detail: "")) }
            case .collection:
                return collections.map { Candidate(item: CompletionItem(kind: .table, text: string($0), label: $0, detail: "collection")) }
            case .path(let collection):
                let source = collection.map { Known(foreign($0), indexes: []) } ?? known
                return source.paths.map { pathCandidate($0.path, info: $0, text: string($0.path)) }
            case .hint:
                return known.indexes.map {
                    Candidate(item: CompletionItem(kind: .word, text: string($0.name), label: $0.name, detail: $0.key.shellForm()))
                }
            case .document(let path):
                return constructors(known.raw[path])
            case .pipeline:
                return at.slot == .value && at.chain.isEmpty ? MongoWords.stages.filter(available).map { stage($0, braces: true) } : []
            case .stage(let word):
                switch word.argument {
                case .collection?: return values(.collection)
                case .field?: return word.name == "$unset" ? values(.path(nil)) : []
                default: return []
                }
            case .list(let inner): return values(inner)
            default: return []
            }
        }

        /// A field's likely values by its sampled type: `ObjectId("")`, `ISODate("")`, true and false, null, and a
        /// string's values when it has few.
        func constructors(_ field: MongoSchema.Field?) -> [Candidate] {
            guard let field else { return [] }
            var found: [Candidate] = []
            func add(_ text: String, _ detail: String) {
                found.append(Candidate(item: CompletionItem(kind: .value, text: text, label: text, detail: detail)))
            }
            for (type, count) in field.types {
                let share = Self.percent(Double(count) / Double(max(1, field.present)))
                switch type {
                case "objectId": add("ObjectId(\"\")", "objectId " + share)
                case "date": add("ISODate(\"\")", "date " + share)
                case "bool": add("true", "bool " + share); add("false", "bool " + share)
                case "null": add("null", "null " + share)
                case "string" where field.distinctIsExact && field.distinct <= 20:
                    for (value, times) in field.top {
                        guard case .string(let plain)? = try? BSONValue(shellForm: value) else { continue }
                        found.append(Candidate(item: CompletionItem(kind: .value, text: at.slot == .string ? plain : value, label: plain,
                                                                    detail: "\(times) of \(field.present)")))
                    }
                default: break
                }
            }
            return found
        }

        func references() -> [Candidate] {
            known.paths.map { pathCandidate("$" + $0.path, info: $0) }
        }

        // MARK: Items

        func paths(group: Int = 0) -> [Candidate] {
            known.paths.map { info in
                var candidate = pathCandidate(info.path, info: info)
                candidate.group = group
                return candidate
            }
        }

        func pathCandidate(_ label: String, info: PathInfo?, text: String? = nil) -> Candidate {
            var detail = info?.type.map { "\($0) · \(Self.percent(info!.share))" } ?? ""
            if info?.indexed == true { detail = detail.isEmpty ? "indexed" : "indexed · " + detail }
            return Candidate(item: CompletionItem(kind: .column, text: text ?? (at.slot == .key ? key(label) : label), label: label,
                                                  detail: detail),
                             indexed: info?.indexed ?? false, share: info?.share ?? 0)
        }

        func word(_ kind: CompletionItem.Kind, _ word: MongoWord, group: Int = 0, text: String? = nil) -> Candidate {
            Candidate(item: CompletionItem(kind: kind, text: text ?? word.name, label: word.name, detail: word.summary), group: group)
        }

        /// A stage as a template (`SQLTemplate`): its required keys to fill in, Tab from one to the next.
        func stage(_ word: MongoWord, braces: Bool) -> Candidate {
            func field(_ name: String, _ slot: MongoWord.Slot?) -> String {
                switch slot {
                case .collection?, .field?: return "\"$\(name)$\""
                case .query?, .fields?, .accumulators?: return "{ $\(name)$ }"
                case .pipeline?: return word.name == "$facet" ? "{ $name$: [] }" : "[]"
                default: return "$\(name)$"
                }
            }
            let keys = word.name == "$lookup" ? ["from", "localField", "foreignField", "as"] : word.keys.filter(\.required).map(\.name)
            var body = keys.isEmpty ? field(word.argument == .field ? "path" : "value", word.argument)
                : "{ " + keys.map { "\($0): " + field($0, word.slot($0)) }.joined(separator: ", ") + " }"
            if word.name == "$unwind" { body = "\"$$$path$\"" }
            body = "$" + word.name + ": " + body
            if braces { body = "{ " + body + " }" }
            return Candidate(item: CompletionItem(kind: .template, text: body + "$END$", label: word.name, detail: word.summary))
        }

        /// A key as shell form takes it: bare when it is a plain name, else in quotes (`"items.sku"`).
        func key(_ name: String) -> String {
            let plain = name.first.map { !$0.isNumber } == true && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$") }
            return at.quoted || plain ? name : quoted(name)
        }

        /// A string value: in quotes unless the caret is already in them.
        func string(_ text: String) -> String { at.slot == .string ? text : quoted(text) }

        func quoted(_ text: String) -> String { BSONValue.string(text).shellForm() }

        static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }
    }

    // MARK: Ranking

    /// Those that match what is typed: the closest match first, then the place's order, indexed leading fields, share in
    /// the sample; keys already in the document left out; at most 200, without repeats.
    static func rank(_ candidates: [Candidate], _ at: MongoCaret) -> [CompletionItem] {
        let typed = at.prefix.lowercased()
        let siblings = at.slot == .key ? Set(at.siblings) : []
        // Sorted by small keys, not the candidates themselves: 2,000 paths sort within a keystroke.
        var keys: [(match: Int, group: Int, indexed: Bool, share: Double, offset: Int)] = []
        let letters = Array(typed.utf16)
        // Every letter typed is in the name, in order (case aside): else the fuzzy matcher, the slow part, isn't asked.
        func mayMatch(_ name: String) -> Bool {
            var next = 0
            for unit in name.utf16 where next < letters.count {
                if (0x41...0x5A).contains(unit) ? unit + 0x20 == letters[next] : unit == letters[next] { next += 1 }
            }
            return next == letters.count
        }
        let ascii = letters.allSatisfy { $0 < 0x80 }
        for (offset, candidate) in candidates.enumerated() where !siblings.contains(candidate.item.label) {
            guard !ascii || mayMatch(candidate.item.label), let match = SQLCompletion.match(candidate.item.label, typed) else { continue }
            keys.append((match, candidate.group, candidate.indexed, candidate.share, offset))
        }
        keys.sort { a, b in
            if a.match != b.match { return a.match < b.match }
            if a.group != b.group { return a.group < b.group }
            if a.indexed != b.indexed { return a.indexed }
            if a.share != b.share { return a.share > b.share }
            return a.offset < b.offset
        }
        var seen = Set<String>(), found: [CompletionItem] = []
        for key in keys where found.count < 200 {
            let item = candidates[key.offset].item
            if seen.insert(item.kind.rawValue + item.text).inserted { found.append(item) }
        }
        return found
    }

    // MARK: A pipeline's fields

    /// The fields after `stages`: `$group` and `$project` give their own, `$addFields`/`$set` add, `$unset` takes away,
    /// `$replaceRoot` gives newRoot's, `$lookup` adds `as`; stages that don't parse yet, and the others, keep them.
    static func outputs(of stages: [Range<Int>], in text: String, from input: [PathInfo]) -> [PathInfo] {
        let units = Array(text.utf16)
        var paths = input
        func info(_ path: String) -> PathInfo { input.first { $0.path == path } ?? PathInfo(path: path, share: 0) }
        func keys(_ value: BSONValue?) -> [String] {
            if case .document(let document)? = value { return document.keys }
            return []
        }
        func isZero(_ value: BSONValue) -> Bool {
            switch value {
            case .int32(0), .int64(0), .bool(false): return true
            case .double(let d): return d == 0
            default: return false
            }
        }
        func under(_ path: String, _ names: [String]) -> Bool { names.contains { path == $0 || path.hasPrefix($0 + ".") } }
        for range in stages where range.upperBound <= units.count {
            guard let stage = try? BSONDocument(shellForm: String(decoding: units[range], as: UTF16.self)),
                  let (name, value) = stage.fields.first else { continue }
            switch name {
            case "$group": paths = (["_id"] + keys(value).filter { $0 != "_id" }).map { PathInfo(path: $0, share: 1) }
            case "$project":
                guard case .document(let projection) = value else { continue }
                let kept = projection.fields.filter { !isZero($0.value) }.map(\.key)
                let excluded = projection.fields.filter { isZero($0.value) }.map(\.key)
                if kept.allSatisfy({ $0 == "_id" }) {
                    paths.removeAll { under($0.path, excluded) }
                } else {
                    let keep = (excluded.contains("_id") ? [] : ["_id"]) + kept
                    paths = paths.filter { under($0.path, keep) } + kept.filter { name in !paths.contains { $0.path == name } }.map(info)
                }
            case "$addFields", "$set":
                paths += keys(value).filter { name in !paths.contains { $0.path == name } }.map(info)
            case "$unset":
                let gone: [String]
                switch value {
                case .string(let one): gone = [one]
                case .array(let many): gone = many.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
                default: gone = []
                }
                paths.removeAll { under($0.path, gone) }
            case "$replaceRoot":
                guard case .document(let options) = value else { continue }
                paths = keys(options["newRoot"]).map { PathInfo(path: $0, share: 1) }
            case "$lookup":
                if case .document(let options) = value, case .string(let name)? = options["as"] { paths.append(PathInfo(path: name, share: 1)) }
            default: break
            }
        }
        return paths
    }
}
