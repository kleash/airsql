import Foundation

/// Update Many and Delete Many (mongo-plan, Phase 2 bulk): a filter and, for an update, its operators or a pipeline,
/// typed in shell form. Before it runs the person sees the exact command and how many documents the filter matches now,
/// and types that number (an empty filter's delete: the collection's name) to confirm it; after, AirSQL says how many
/// the server matched and whether that differs from the count shown. An update must be operators or a pipeline: a
/// replacement document would replace every matching document whole. Upsert stays off.
public struct MongoBulk: Equatable, Sendable {
    public let database: String
    public let collection: String
    public let filter: BSONDocument
    /// An update's operators (a document) or pipeline (an array); nil for a delete.
    public let update: BSONValue?
    /// The tab's collation, so the count and the write match the same documents.
    public let collation: BSONDocument?

    public var isDelete: Bool { update == nil }

    /// An Update Many from the sheet's text; why not, if it can't be one.
    public init(database: String, collection: String, filter: String, update: String, collation: BSONDocument?) throws {
        let value: BSONValue
        do { value = try BSONValue(shellForm: update) } catch { throw AirSQLError(.syntax, "Update: \(error)") }
        try Self.check(value)
        self.init(database, collection, try Self.filter(filter), value, collation)
    }

    /// A Delete Many from the sheet's text.
    public init(database: String, collection: String, filter: String, collation: BSONDocument?) throws {
        self.init(database, collection, try Self.filter(filter), nil, collation)
    }

    private init(_ database: String, _ collection: String, _ filter: BSONDocument, _ update: BSONValue?, _ collation: BSONDocument?) {
        (self.database, self.collection, self.filter, self.update, self.collation) = (database, collection, filter, update, collation)
    }

    private static func filter(_ text: String) throws -> BSONDocument {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return BSONDocument() }
        do { return try BSONDocument(shellForm: text) } catch { throw AirSQLError(.syntax, "Filter: \(error)") }
    }

    /// Operators ({ $set: … }) or a pipeline ([ { $set: … } ]); a replacement document is refused, with why.
    static func check(_ update: BSONValue) throws {
        func refuse(_ words: String) -> AirSQLError { AirSQLError(.other, words) }
        switch update {
        case .document(let document):
            guard !document.fields.isEmpty else { throw refuse("The update is empty: write operators, such as { $set: { field: value } }.") }
            let operators = document.fields.filter { $0.key.hasPrefix("$") }.count
            if operators == 0 {
                throw refuse("This is a replacement document: it would replace every matching document whole, and their other "
                             + "fields would be lost. Write operators instead, such as { $set: { field: value } }.")
            }
            if operators < document.fields.count {
                throw refuse("Every top-level field of an update must be an operator ($set, $unset, $inc…): "
                             + document.fields.filter { !$0.key.hasPrefix("$") }.map(\.key).joined(separator: ", ") + " isn't.")
            }
        case .array(let stages):
            guard !stages.isEmpty else { throw refuse("The pipeline is empty: write its stages, such as [ { $set: { field: value } } ].") }
            for stage in stages {
                guard case .document(let d) = stage, d.fields.count == 1, d.fields[0].key.hasPrefix("$") else {
                    throw refuse("Each stage of a pipeline update is one stage, such as { $set: { field: value } }.")
                }
            }
        default:
            throw refuse("Write the update as operators, { $set: { field: value } }, or a pipeline, [ { $set: { field: value } } ].")
        }
    }

    /// The command as mongosh would take it.
    public var shellForm: String {
        let target = "db.getSiblingDB(\(BSONValue.string(database).shellForm())).getCollection(\(BSONValue.string(collection).shellForm()))"
        var options: [(key: String, value: BSONValue)] = update == nil ? [] : [("upsert", .bool(false))]
        if let collation { options.append(("collation", .document(collation))) }
        let tail = options.isEmpty ? "" : ", " + BSONDocument(options).shellForm()
        if let update { return "\(target).updateMany(\(filter.shellForm()), \(update.shellForm())\(tail))" }
        return "\(target).deleteMany(\(filter.shellForm())\(tail))"
    }

    /// What the person types to confirm: the count shown, or for a delete of every document, the collection's name.
    public func confirmation(count: Int64) -> String {
        isDelete && filter.fields.isEmpty ? collection : String(count)
    }

    /// The preview's heading.
    public func heading(count: Int64) -> String {
        let documents = "\(count.formatted()) document\(count == 1 ? "" : "s")"
        if isDelete && filter.fields.isEmpty { return "Delete every document of \(database).\(collection) (\(documents))?" }
        return "\(isDelete ? "Delete" : "Update") the \(documents) of \(database).\(collection) that the filter matches?"
    }

    /// What the server did, and a warning when it matched another number than the count shown (documents changed
    /// meanwhile). `modified` is nil for a delete.
    public func report(counted: Int64, matched: Int64, modified: Int64?) -> (message: String, differs: Bool) {
        func n(_ count: Int64) -> String { "\(count.formatted()) document\(count == 1 ? "" : "s")" }
        var message = modified.map { "Updated \(collection): \(matched.formatted()) matched, \($0.formatted()) modified." }
            ?? "Deleted \(n(matched)) from \(collection)."
        let differs = matched != counted
        if differs {
            message += " The count shown was \(counted.formatted()): documents changed between the count and the "
                + "\(isDelete ? "delete" : "update"). Refresh (⌘R) to see them."
        }
        return (message, differs)
    }

    /// Why it stopped, in words that say what the server kept: a cancel or an error keeps what it did before it; a lost
    /// connection leaves it unknown (AirSQL never runs it again).
    public func failure(_ error: Error) -> String {
        let verb = isDelete ? "deleted" : "updated"
        let error = error as? AirSQLError ?? AirSQLError(.other, error.localizedDescription)
        switch error.kind {
        case .outcomeUnknown:
            return "Unknown whether documents were \(verb): the connection failed before the server answered. Reload to see "
                + "what happened; AirSQL doesn't run it again."
        case .cancelled:
            return "Cancelled. The server keeps the documents it had \(verb) before it stopped: Refresh (⌘R) to see them."
        default:
            return error.message + " The server keeps any documents it had \(verb) before the error: Refresh (⌘R) to see them."
        }
    }
}
