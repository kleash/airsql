import Foundation

/// A command that creates, drops or renames a collection, view or database, or changes a collection's validation rules
/// (mongo-plan, Phase 2 admin). Only `MongoAdmin`'s builders make one, after checking its names, so the preview shows
/// exactly what `MongoSession.run(_:)` sends and nothing reaches MongoDB's own databases or system collections.
public struct MongoAdminCommand: Sendable, Equatable {
    public let command: BSONDocument
    /// Where it runs: the collection's database, or admin for renameCollection.
    public let database: String

    /// As mongosh runs it: what the preview shows and Copy Commands copies.
    /// A user's new password (`MongoUsers`) shows as the command log has it.
    public var shellForm: String { MongoIndex.shellForm(command["pwd"] == nil ? command : MongoLog.redacted(command), database: database) }
}

/// The admin commands and the checks on their names. Fields come in as the sheets hold them (shell form, or plain text
/// for names and numbers); a wrong one throws `MongoQueryText.Problem` naming it.
public enum MongoAdmin {
    public typealias Problem = MongoQueryText.Problem

    /// Why `database`, or its `collection`, can't be changed here; nil: it can.
    public static func refusal(database: String, collection: String? = nil) -> String? {
        if MongoAgentGuard.internalDatabases.contains(database.lowercased()) {
            return "\(database) is MongoDB's own database: AirSQL doesn't change it"
        }
        if let collection, collection.hasPrefix("system.") {
            return "\(collection) is a system collection, which MongoDB keeps itself"
        }
        return nil
    }

    /// The trimmed names, or which is wrong and why: MongoDB's rules for names on any platform, and the refusals.
    static func names(_ database: String, _ collection: String?) throws -> (String, String?) {
        let db = database.trimmingCharacters(in: .whitespaces), name = collection?.trimmingCharacters(in: .whitespaces)
        if db.isEmpty || db.utf8.count >= 64 || db.contains(where: { "/\\. \"$*<>:|?\0".contains($0) }) {
            throw Problem(field: "Database", message: "Type a name under 64 bytes without spaces or any of / \\ . \" $ * < > : | ?")
        }
        if let name, name.isEmpty || name.contains("$") || name.contains("\0") || db.utf8.count + 1 + name.utf8.count > 255 {
            throw Problem(field: "Name", message: "Type a name without $, under 255 bytes with its database's")
        }
        if let refusal = refusal(database: db) { throw Problem(field: "Database", message: refusal) }
        if let refusal = refusal(database: db, collection: name) { throw Problem(field: "Name", message: refusal) }
        return (db, name)
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func document(_ text: String, _ field: String) throws -> BSONDocument? {
        guard !trimmed(text).isEmpty else { return nil }
        do { return try BSONDocument(shellForm: text) } catch { throw Problem(field: field, message: "\(error)") }
    }

    private static func count(_ text: String, _ field: String) throws -> Int64? {
        guard !trimmed(text).isEmpty else { return nil }
        guard let value = Int64(trimmed(text)), value > 0 else { throw Problem(field: field, message: "Type a whole number above 0") }
        return value
    }

    // MARK: Create

    public static let validationLevels = ["strict", "moderate", "off"]
    public static let validationActions = ["error", "warn"]
    public static let granularities = ["seconds", "minutes", "hours"]

    /// create for a collection: capped when `size` is given, time-series when `timeField` is, clustered on _id when
    /// `clustered`; with a default collation and validation rules when given. Empty fields leave the server's defaults.
    public static func createCollection(database: String, name: String, size: String = "", max: String = "",
                                        timeField: String = "", metaField: String = "", granularity: String = "",
                                        clustered: Bool = false, collation: String = "", validator: String = "",
                                        level: String = "", action: String = "") throws -> MongoAdminCommand {
        let (db, name) = try names(database, name)
        var fields: [(key: String, value: BSONValue)] = [("create", .string(name!))]
        if let size = try count(size, "Size") {
            fields += [("capped", .bool(true)), ("size", .int64(size))]
            if let max = try count(max, "Max Documents") { fields.append(("max", .int64(max))) }
        } else if !trimmed(max).isEmpty {
            throw Problem(field: "Size", message: "A capped collection needs its size in bytes")
        }
        if !trimmed(timeField).isEmpty {
            var series: [(key: String, value: BSONValue)] = [("timeField", .string(trimmed(timeField)))]
            if !trimmed(metaField).isEmpty { series.append(("metaField", .string(trimmed(metaField)))) }
            if !granularity.isEmpty { series.append(("granularity", .string(granularity))) }
            fields.append(("timeseries", .document(BSONDocument(series))))
        } else if !trimmed(metaField).isEmpty {
            throw Problem(field: "Time Field", message: "A time-series collection needs the field that holds each document's date")
        }
        if clustered {
            fields.append(("clusteredIndex", .document(BSONDocument([("key", .document(BSONDocument([("_id", .int32(1))]))),
                                                                     ("unique", .bool(true))]))))
        }
        if let collation = try document(collation, "Collation") { fields.append(("collation", .document(collation))) }
        if let validator = try document(validator, "Validator") { fields.append(("validator", .document(validator))) }
        if !level.isEmpty { fields.append(("validationLevel", .string(level))) }
        if !action.isEmpty { fields.append(("validationAction", .string(action))) }
        return MongoAdminCommand(command: BSONDocument(fields), database: db)
    }

    /// create for a view of `source` through `pipeline`: read-only, computed each time it is read. Also what an
    /// aggregation tab's Save as View sends.
    public static func createView(database: String, name: String, on source: String, pipeline: [BSONDocument],
                                  collation: BSONDocument? = nil) throws -> MongoAdminCommand {
        let (db, name) = try names(database, name)
        guard let source = try? names(db, source).1 else { throw Problem(field: "Source", message: "Choose the collection or view it reads") }
        return MongoAdminCommand(command: BSONDocument([("create", .string(name!)), ("viewOn", .string(source)),
                                                        ("pipeline", .array(pipeline.map { .document($0) }))]
                                                       + (collation.map { [("collation", .document($0))] } ?? [])), database: db)
    }

    /// The same, with the pipeline in shell form (`[{ $match: … }, …]`, as the aggregation tab takes it).
    public static func createView(database: String, name: String, on source: String, pipeline text: String) throws -> MongoAdminCommand {
        let stages: [BSONDocument]
        do { stages = try MongoPipeline.stages(in: text).map(\.document) } catch { throw Problem(field: "Pipeline", message: "\(error)") }
        return try createView(database: database, name: name, on: source, pipeline: stages)
    }

    // MARK: Drop and rename

    /// drop: a collection with its documents and indexes, or a view.
    public static func drop(database: String, collection: String) throws -> MongoAdminCommand {
        let (db, name) = try names(database, collection)
        return MongoAdminCommand(command: BSONDocument([("drop", .string(name!))]), database: db)
    }

    /// dropDatabase: every collection and view of the database.
    public static func dropDatabase(_ database: String) throws -> MongoAdminCommand {
        let (db, _) = try names(database, nil)
        return MongoAdminCommand(command: BSONDocument([("dropDatabase", .int32(1))]), database: db)
    }

    /// renameCollection within its database, run on admin; `dropTarget` drops a collection that has the new name first.
    public static func rename(database: String, collection: String, to name: String, dropTarget: Bool = false) throws -> MongoAdminCommand {
        let (db, from) = try names(database, collection), (_, to) = try names(database, name)
        guard from != to else { throw Problem(field: "Name", message: "Type a name other than its own") }
        return MongoAdminCommand(command: BSONDocument([("renameCollection", .string(db + "." + from!)), ("to", .string(db + "." + to!)),
                                                        ("dropTarget", .bool(dropTarget))]), database: "admin")
    }

    // MARK: Validation

    /// The collection's rules as listCollections describes them: the validator in shell form (empty: none), its level
    /// and action (the server's defaults, strict and error, when not set).
    public static func validation(_ info: MongoCollectionInfo) -> (validator: String, level: String, action: String) {
        var text = ""
        if case .document(let validator)? = info.options["validator"], !validator.fields.isEmpty { text = validator.shellForm(pretty: true) }
        var level = "strict", action = "error"
        if case .string(let given)? = info.options["validationLevel"] { level = given }
        if case .string(let given)? = info.options["validationAction"] { action = given }
        return (text, level, action)
    }

    /// The validator the editor's text gives: empty text is none, {} as the server takes it.
    public static func validator(_ text: String) throws -> BSONDocument { try document(text, "Validator") ?? BSONDocument() }

    /// collMod setting the collection's validator, level and action (an empty validator removes the rules).
    public static func setValidation(database: String, collection: String, validator: BSONDocument, level: String,
                                     action: String) throws -> MongoAdminCommand {
        let (db, name) = try names(database, collection)
        return MongoAdminCommand(command: BSONDocument([("collMod", .string(name!)), ("validator", .document(validator)),
                                                        ("validationLevel", .string(level)), ("validationAction", .string(action))]),
                                 database: db)
    }

    /// A filter for the documents `validator` would refuse: those matching none of it.
    public static func failing(_ validator: BSONDocument) -> BSONDocument {
        BSONDocument([("$nor", .array([.document(validator)]))])
    }
}
