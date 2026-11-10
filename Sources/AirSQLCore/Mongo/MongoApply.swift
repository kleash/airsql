import Foundation

/// A collection's changes waiting for Apply (mongo-plan, Safe editing): edited fields of loaded documents, new
/// documents and documents to delete. Not `PendingChanges`: that one finds a row by its key columns' text and holds SQL
/// text, while a document is found by its `_id`, a BSON value of any type, and every value must keep its exact type.
/// The rules are checked as each change is added, with the reason in plain words; nothing here touches the server:
/// `steps` are the commands, `MongoApply.run` sends them.
public struct MongoChanges: Sendable {
    /// One field's change: `old` as loaded (nil: missing), `new` (nil: remove the field).
    public struct Edit: Sendable, Equatable {
        public var path: [String]
        public var old: BSONValue?
        public var new: BSONValue?
    }

    public let database: String
    public let collection: String
    public let kind: MongoCollectionInfo.Kind
    /// Edited documents by `_id`, in the order first edited.
    public private(set) var edits: [(id: BSONValue, edits: [Edit])] = []
    public private(set) var inserts: [BSONDocument] = []
    /// Documents to delete, as loaded: Apply deletes each only while it is still exactly so.
    public private(set) var deletes: [BSONDocument] = []

    public init(database: String, collection: String, kind: MongoCollectionInfo.Kind) {
        self.database = database
        self.collection = collection
        self.kind = kind
    }

    public var isEmpty: Bool { edits.isEmpty && inserts.isEmpty && deletes.isEmpty }

    /// Sets the field at `path` of a loaded document to `new` (nil removes the field). A value of another type than the
    /// old one is refused unless `changingType`; null and missing have no type to keep. Setting the loaded value
    /// again drops the edit.
    public mutating func edit(_ document: BSONDocument, path: [String], to new: BSONValue?, changingType: Bool = false) throws {
        try checkWritable()
        guard let id = document["_id"] else { throw refused("This document has no _id to find it by, so it can't be changed.") }
        guard let first = path.first else { throw refused("Choose a field to change.") }
        if first == "_id" { throw refused("_id is read-only: it is how the document is found.") }
        if let key = path.first(where: { $0.isEmpty || BSONDocument.keyNeedsCare($0) }) {
            throw refused("The field name \"\(key)\" can't be named in a path (it is empty, or holds . or $), so it is read-only.")
        }
        let old: BSONValue?
        switch Self.lookup(path, in: document) {
        case .value(let value): old = value
        case .missing: old = nil
        case .blocked(let reason): throw refused(reason)
        }
        let dotted = path.joined(separator: ".")
        if let old, old.isReadOnly { throw refused("\(dotted) holds a deprecated \(old.typeAlias), which is read-only.") }
        for value in [old, new].compactMap({ $0 }) where Self.hasKeyNeedingCare(value) {
            throw refused("\(dotted) holds a field name with . or $, which can't be written as an update, so it is read-only.")
        }
        if let old, let new, old != .null, new != .null, old.typeByte != new.typeByte, !changingType {
            throw refused("This changes \(dotted) from \(old.typeAlias) to \(new.typeAlias). Choose the new type to change it.")
        }
        let index = edits.firstIndex { $0.id == id }
        var fields = index.map { edits[$0].edits } ?? []
        if let clash = fields.first(where: { $0.path != path && (Self.isPrefix($0.path, of: path) || Self.isPrefix(path, of: $0.path)) }) {
            throw refused("\(clash.path.joined(separator: ".")) is already changed in this document; change \(dotted) after "
                + "applying it, or edit the outer one as one value.")
        }
        fields.removeAll { $0.path == path }
        if old != new { fields.append(Edit(path: path, old: old, new: new)) }
        switch (index, fields.isEmpty) {
        case (let i?, true): edits.remove(at: i)
        case (let i?, false): edits[i].edits = fields
        case (nil, false): edits.append((id, fields))
        case (nil, true): break
        }
    }

    /// A new document; without `_id`, the driver gives it an ObjectId.
    public mutating func insert(_ document: BSONDocument) throws {
        try checkWritable()
        if Self.hasKeyNeedingCare(.document(document)) {
            throw refused("A field name holds . or $, which AirSQL doesn't write. Rename the field.")
        }
        inserts.append(document)
    }

    /// Deletes a loaded document (and forgets its edits).
    public mutating func delete(_ document: BSONDocument) throws {
        try checkWritable()
        guard let id = document["_id"] else { throw refused("This document has no _id to find it by, so it can't be deleted.") }
        edits.removeAll { $0.id == id }
        if !deletes.contains(where: { $0["_id"] == id }) { deletes.append(document) }
    }

    /// The commands Apply runs, in order: deletes, then edits, then inserts.
    public var steps: [MongoApplyStep] {
        deletes.map { .delete($0) } + edits.map { .update(id: $0.id, edits: $0.edits) } + inserts.map { .insert($0) }
    }

    /// What the Apply sheet lists: exactly the commands Apply sends, in shell form.
    public var preview: [String] { steps.flatMap { $0.shellForm(database: database, collection: collection) } }

    private func checkWritable() throws {
        switch kind {
        case .collection: return
        case .view: throw refused("\(collection) is a view, which is read-only: change the collection it reads.")
        case .timeseries: throw refused("\(collection) is a time-series collection, which AirSQL keeps read-only.")
        }
    }

    private func refused(_ reason: String) -> AirSQLError { AirSQLError(.readOnly, reason) }

    // MARK: Taking changes back, and showing them

    /// Takes back a loaded document's edits and its delete.
    public mutating func revert(_ id: BSONValue) {
        edits.removeAll { $0.id == id }
        deletes.removeAll { $0["_id"] == id }
    }

    /// Takes back the new documents at these places in `inserts`.
    public mutating func removeInserts(_ offsets: [Int]) {
        for offset in Set(offsets).sorted(by: >) where inserts.indices.contains(offset) { inserts.remove(at: offset) }
    }

    /// Puts `document` in place of the new document at `offset` (edited again before Apply).
    public mutating func replaceInsert(_ offset: Int, with document: BSONDocument) throws {
        if Self.hasKeyNeedingCare(.document(document)) {
            throw refused("A field name holds . or $, which AirSQL doesn't write. Rename the field.")
        }
        inserts[offset] = document
    }

    /// Forgets the first `count` steps: those a stopped Apply left applied on a standalone, so that the rest can be
    /// applied later without running them twice.
    public mutating func dropApplied(_ count: Int) {
        let deleting = min(count, deletes.count), editing = min(count - deleting, edits.count)
        deletes.removeFirst(deleting)
        edits.removeFirst(editing)
        inserts.removeFirst(min(count - deleting - editing, inserts.count))
    }

    /// `document` as Apply would leave it, its edits made (sub-documents made on the way, as `$set` does): the grid's.
    public func applied(to document: BSONDocument) -> BSONDocument {
        guard let id = document["_id"], let fields = edits.first(where: { $0.id == id })?.edits else { return document }
        var result = document
        for edit in fields { Self.set(edit.path[...], edit.new, in: &result) }
        return result
    }

    private static func set(_ path: ArraySlice<String>, _ value: BSONValue?, in document: inout BSONDocument) {
        guard let key = path.first else { return }
        let index = document.fields.firstIndex { $0.key == key }
        guard path.count > 1 else {
            switch (index, value) {
            case let (i?, new?): document.fields[i].value = new
            case let (nil, new?): document.fields.append((key, new))
            case let (i?, nil): document.fields.remove(at: i)
            case (nil, nil): break
            }
            return
        }
        var inner = BSONDocument()
        if let index, case .document(let found) = document.fields[index].value { inner = found } else if value == nil { return }
        set(path.dropFirst(), value, in: &inner)
        if let index { document.fields[index].value = .document(inner) } else { document.fields.append((key, .document(inner))) }
    }

    /// What `text` (shell form) means typed over `old`: a value of `old`'s type wherever the text reads as one — 5 over
    /// NumberLong(1) is NumberLong(5), words over a string are that string, an ISO date over a date is that date, 24 hex
    /// digits over an ObjectId are that ObjectId — else the value as typed, which `edit` refuses as another type unless
    /// the type is being changed. Null typed is null; over null or a missing field the value is as typed.
    public static func value(_ text: String, keeping old: BSONValue?) throws -> BSONValue {
        let typed = Result { try BSONValue(shellForm: text) }
        let parsed = try? typed.get()
        if let parsed, parsed.typeByte == old?.typeByte || parsed == .null { return parsed }
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var number: String?, words = plain
        switch parsed {
        case .int32(let n)?: number = String(n)
        case .int64(let n)?: number = String(n)
        case .double(let d)?: number = BSONValue.doubleText(d)
        case .decimal128(let d)?: number = d.description
        case .string(let typedWords)?: words = typedWords
        default: break
        }
        switch old {
        case .string?: return .string(text)
        case .int32?: if let n = Int32(plain) ?? number.flatMap({ Int32($0) }) { return .int32(n) }
        case .int64?: if let n = Int64(plain) ?? number.flatMap({ Int64($0) }) { return .int64(n) }
        case .double?: if let d = Double(plain) ?? number.flatMap({ Double($0) }) { return .double(d) }
        case .decimal128?: if let d = BSONDecimal128(plain) ?? number.flatMap({ BSONDecimal128($0) }) { return .decimal128(d) }
        case .datetime?: if let date = try? BSONValue(shellForm: "ISODate(\(BSONValue.string(words).shellForm()))") { return date }
        case .objectId?: if let id = BSONObjectId(hex: words) { return .objectId(id) }
        default: break
        }
        return try typed.get()
    }

    // MARK: Paths

    enum Lookup: Equatable {
        case value(BSONValue)
        case missing
        case blocked(String)
    }

    /// The value at `path`, following sub-documents only: a path through an array or a plain value is blocked.
    static func lookup(_ path: [String], in document: BSONDocument) -> Lookup {
        var current = document
        for (depth, key) in path.enumerated() {
            guard let value = current[key] else { return .missing }
            if depth == path.count - 1 { return .value(value) }
            let parent = path[...depth].joined(separator: ".")
            switch value {
            case .document(let inner): current = inner
            case .array: return .blocked("\(parent) is an array, which is edited as one whole value.")
            default: return .blocked("\(parent) holds a \(value.typeAlias), not a sub-document, so it has no fields to change.")
            }
        }
        return .missing
    }

    /// The value at `path` of `document`; nil when it is missing or lies past an array or a plain value.
    public static func value(at path: [String], in document: BSONDocument) -> BSONValue? {
        if case .value(let value) = lookup(path, in: document) { return value }
        return nil
    }

    static func hasKeyNeedingCare(_ value: BSONValue) -> Bool {
        var found = false
        BSONDocument([("", value)]).walk { path, _ in
            if case .key(let key)? = path.last, path.count > 1, BSONDocument.keyNeedsCare(key) { found = true }
        }
        return found
    }

    static func isPrefix(_ a: [String], of b: [String]) -> Bool { a.count < b.count && Array(b.prefix(a.count)) == a }
}

/// One command of Apply, with what it checks.
public enum MongoApplyStep: Sendable {
    /// Read the document back and check each old value is still exactly so (type included, inside sub-documents and
    /// arrays too, which the filter alone can't), then `updateOne` with the old values in its filter, matching 1.
    case update(id: BSONValue, edits: [MongoChanges.Edit])
    /// `insertOne`, inserting 1.
    case insert(BSONDocument)
    /// Read the document back and check it is exactly as loaded, then `deleteOne({_id})`, deleting 1.
    case delete(BSONDocument)

    /// Matching ignores the collection's collation: "a" never matches "A".
    static let simple = BSONDocument([("locale", .string("simple"))])

    /// `{_id: id, path: {$eq: old}, path: {$type: alias}, …}`; a missing old value: `{path: {$exists: false}}`. `$eq`
    /// so that an old regex or a document with `$` keys is compared, not run as a query.
    static func filter(id: BSONValue, edits: [MongoChanges.Edit]) -> BSONDocument {
        var fields: [(key: String, value: BSONValue)] = [("_id", id)]
        for edit in edits {
            let path = edit.path.joined(separator: ".")
            if let old = edit.old {
                fields.append((path, .document(BSONDocument([("$eq", old)]))))
                fields.append((path, .document(BSONDocument([("$type", .string(old.typeAlias))]))))
            } else {
                fields.append((path, .document(BSONDocument([("$exists", .bool(false))]))))
            }
        }
        return BSONDocument(fields)
    }

    /// `{$set: {path: new, …}, $unset: {path: "", …}}`, either left out when empty.
    static func update(_ edits: [MongoChanges.Edit]) -> BSONDocument {
        let set = edits.compactMap { edit in edit.new.map { (key: edit.path.joined(separator: "."), value: $0) } }
        let unset = edits.filter { $0.new == nil }.map { (key: $0.path.joined(separator: "."), value: BSONValue.string("")) }
        return BSONDocument((set.isEmpty ? [] : [("$set", .document(BSONDocument(set)))])
            + (unset.isEmpty ? [] : [("$unset", .document(BSONDocument(unset)))]))
    }

    var id: BSONValue? {
        switch self {
        case .update(let id, _): return id
        case .insert(let document), .delete(let document): return document["_id"]
        }
    }

    /// The step's commands as mongosh would take them.
    public func shellForm(database: String, collection: String) -> [String] {
        let target = "db.getSiblingDB(\(BSONValue.string(database).shellForm())).getCollection(\(BSONValue.string(collection).shellForm()))"
        let options = "{ collation: \(Self.simple.shellForm()) }"
        func read(_ id: BSONValue) -> String {
            "\(target).findOne(\(BSONDocument([("_id", id)]).shellForm()), {}, \(options))"
        }
        switch self {
        case let .update(id, edits):
            return [read(id) + "  // its old values must be exactly as loaded",
                    "\(target).updateOne(\(Self.filter(id: id, edits: edits).shellForm()), \(Self.update(edits).shellForm()), \(options))"]
        case .insert(let document):
            return ["\(target).insertOne(\(document.shellForm()))"]
        case .delete(let document):
            let id = document["_id"] ?? .null
            return [read(id) + "  // must be exactly as loaded",
                    "\(target).deleteOne(\(BSONDocument([("_id", id)]).shellForm()), \(options))"]
        }
    }
}

/// What Apply did.
public struct MongoApplyReport: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// Every step.
        case applied
        /// A step failed or found a change; `applied` steps stand (0 in a transaction, which was aborted).
        case stopped
        /// The connection failed before the server answered a write or the commit: whether it was made is unknown.
        case unknown
    }

    public var outcome: Outcome
    /// Steps whose changes stand: all, the ones before `failedStep` without a transaction, or none.
    public var applied: Int
    public var total: Int
    /// The step that stopped Apply (an index into `MongoChanges.steps`).
    public var failedStep: Int?
    /// In plain words, naming the document and why.
    public var message: String
}

public enum MongoApply {
    /// A replica set or a sharded cluster: Apply runs in one transaction, all or nothing. On a standalone it can't, so
    /// the sheet says before running that a failure leaves earlier changes applied.
    public static func isAtomic(_ server: MongoServerInfo) -> Bool { server.setName != nil || server.isMongos }

    /// Runs `changes.steps` on `session` (the data session): in one transaction when `atomic` (a mismatch or error
    /// aborts it), else one by one, stopping at the first mismatch or error. A lost connection on a write or the
    /// commit stops it with an unknown outcome; nothing is sent again.
    public static func run(_ changes: MongoChanges, on session: MongoSession, atomic: Bool) async -> MongoApplyReport {
        let steps = changes.steps
        var done = 0
        // The step running; nil while starting or committing the transaction.
        var failed: Int?
        do {
            if atomic { try await session.startTransaction() }
            for step in steps {
                failed = done
                try await run(step, changes, session)
                done += 1
            }
            failed = nil
            if atomic { try await session.commitTransaction() }
            return MongoApplyReport(outcome: .applied, applied: steps.count, total: steps.count, failedStep: nil,
                                    message: steps.count == 1 ? "Applied 1 change." : "Applied \(steps.count) changes.")
        } catch {
            if atomic { try? await session.abortTransaction() }
            let reason = (error as? AirSQLError)?.message ?? error.localizedDescription
            let what = failed.map { describe(steps[$0]) } ?? (done == 0 ? "Starting the transaction" : "Committing the changes")
            if (error as? AirSQLError)?.kind == .outcomeUnknown {
                let before = atomic || done == 0 ? "" : "The \(done) change\(done == 1 ? " before it was" : "s before it were") applied. "
                return MongoApplyReport(outcome: .unknown, applied: atomic ? 0 : done, total: steps.count, failedStep: failed,
                                        message: "\(what): unknown whether it was applied; the connection failed before "
                                            + "the server answered. \(before)Reload to see what happened. AirSQL doesn't run it again.")
            }
            let kept = atomic ? "Nothing was applied."
                : done == 0 ? "Nothing was applied." : "The \(done) change\(done == 1 ? " before it was" : "s before it were") "
                    + "applied; the \(steps.count - done) from it on weren't."
            return MongoApplyReport(outcome: .stopped, applied: atomic ? 0 : done, total: steps.count, failedStep: failed,
                                    message: "\(what): \(reason) \(kept)")
        }
    }

    private static func describe(_ step: MongoApplyStep) -> String {
        let id = step.id.map { "{ _id: \($0.shellForm(maxLength: 200)) }" } ?? "the new document"
        switch step {
        case .update: return "Changing the document \(id)"
        case .insert: return "Inserting \(step.id == nil ? id : "the document " + id)"
        case .delete: return "Deleting the document \(id)"
        }
    }

    private static let changed = "It was changed by someone else since you loaded it. Reload to see it."

    private static func run(_ step: MongoApplyStep, _ changes: MongoChanges, _ session: MongoSession) async throws {
        let (database, collection) = (changes.database, changes.collection)
        func current(_ id: BSONValue) async throws -> BSONDocument {
            let cursor = try await session.find(database: database, collection: collection,
                                                MongoFind(filter: BSONDocument([("_id", id)]), limit: 1, collation: MongoApplyStep.simple))
            let found = try await cursor.next(maxCount: 1)
            await cursor.close()
            guard let bytes = found.first else { throw AirSQLError(.notFound, "It was deleted by someone else since you loaded it.") }
            return try BSONDocument(bytes: bytes)
        }
        func expect(_ count: Int64, _ verb: String) throws {
            guard count == 1 else {
                throw AirSQLError(.other, count == 0 ? changed : "The server \(verb) \(count) documents where AirSQL expected 1.")
            }
        }
        switch step {
        case let .update(id, edits):
            let now = try await current(id)
            if let edit = edits.first(where: { MongoChanges.lookup($0.path, in: now) != ($0.old.map { .value($0) } ?? .missing) }) {
                throw AirSQLError(.other, "Its \(edit.path.joined(separator: ".")) was changed by someone else since you loaded it. "
                    + "Reload to see it.")
            }
            let result = try await session.updateOne(database: database, collection: collection,
                                                     filter: MongoApplyStep.filter(id: id, edits: edits),
                                                     update: MongoApplyStep.update(edits), collation: MongoApplyStep.simple)
            try expect(result.matched, "matched")
        case .insert(let document):
            try expect(try await session.insertMany(database: database, collection: collection, [document]), "inserted")
        case .delete(let loaded):
            let id = loaded["_id"] ?? .null
            guard try await current(id).typeExactEqual(loaded) else { throw AirSQLError(.other, changed) }
            try expect(try await session.deleteOne(database: database, collection: collection,
                                                   filter: BSONDocument([("_id", id)]), collation: MongoApplyStep.simple), "deleted")
        }
    }
}
