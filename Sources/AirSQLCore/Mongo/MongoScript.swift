import Foundation

/// A tab's query as a script mongosh runs as it is (Copy and Export Query as JavaScript): the find with its cursor's
/// methods, or the pipeline with aggregate's options, each value in shell form with its type kept. It names the database
/// and the collection only, never the connection's address, user or password.
public enum MongoScript {
    /// `db.getSiblingDB("shop").getCollection("orders").find({ … }, { … }).sort({ … })…`, the parts set only; a field
    /// that doesn't parse is refused as Run refuses it (`MongoQueryText.Problem`).
    public static func find(_ query: MongoQueryText, database: String, collection: String) throws -> String {
        let find = try query.find()
        try check(find.filter, "Filter")
        try check(find.projection, "Project")
        try check(find.sort, "Sort")
        try check(find.collation, "Collation")
        if case .document(let keys)? = find.hint { try check(keys, "Hint") }
        var script = header(database, collection) + ".find(" + BSONValue.document(find.filter).mongoshForm()
            + (find.projection.map { ", " + BSONValue.document($0).mongoshForm() } ?? "") + ")"
        if let sort = find.sort { script += ".sort(\(BSONValue.document(sort).mongoshForm()))" }
        if let skip = find.skip { script += ".skip(\(skip))" }
        if let limit = find.limit { script += ".limit(\(limit))" }
        if let collation = find.collation { script += ".collation(\(BSONValue.document(collation).mongoshForm()))" }
        if let hint = find.hint { script += ".hint(\(hint.mongoshForm()))" }
        if let maxTimeMS = find.maxTimeMS { script += ".maxTimeMS(\(maxTimeMS))" }
        return script + "\n"
    }

    /// `db.getSiblingDB("shop").getCollection("orders").aggregate([ …a stage a line… ], { allowDiskUse: true, … })`,
    /// with the options the tab runs it with: allowDiskUse always, the collation and Max Time when set.
    public static func aggregate(_ stages: [BSONDocument], options: MongoFind, database: String, collection: String) throws -> String {
        for (index, stage) in stages.enumerated() { try check(stage, "Stage \(index + 1)") }
        try check(options.collation, "Collation")
        let pipeline = stages.isEmpty ? "[]" : "[\n" + stages.map { "  " + BSONValue.document($0).mongoshForm() }.joined(separator: ",\n") + "\n]"
        var settings = "{ allowDiskUse: true"
        if let collation = options.collation { settings += ", collation: " + BSONValue.document(collation).mongoshForm() }
        if let maxTimeMS = options.maxTimeMS { settings += ", maxTimeMS: \(maxTimeMS)" }
        return header(database, collection) + ".aggregate(" + pipeline + ", " + settings + " })\n"
    }

    /// A comment naming the database and collection (as string literals, so no name breaks the line), then the collection.
    static func header(_ database: String, _ collection: String) -> String {
        let (database, collection) = (BSONValue.string(database).mongoshForm(), BSONValue.string(collection).mongoshForm())
        return "// The query on collection \(collection) of database \(database), for mongosh\n"
            + "db.getSiblingDB(\(database)).getCollection(\(collection))"
    }

    /// Refuses the deprecated types mongosh can't write: it sends undefined as null and has no DBPointer.
    static func check(_ document: BSONDocument?, _ field: String) throws {
        var found: String?
        document?.walk { _, value in
            if case .undefined = value { found = "undefined" } else if case .dbPointer = value { found = "DBPointer(…)" }
        }
        if let found {
            throw MongoQueryText.Problem(field: field, message: "\(found) is a deprecated type mongosh can't write, so the script would change it")
        }
    }
}
