// A tab's query as JavaScript for mongosh (Copy and Export Query as JavaScript): the find with its cursor's methods, the
// pipeline with its options, names as escaped string literals, values that read back with their types, and what is
// refused; then the command in a collection tab.
import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

private let header = "// The query on collection \"orders\" of database \"shop\", for mongosh\n"
private let prefix = "db.getSiblingDB(\"shop\").getCollection(\"orders\")"

/// Every type mongosh writes back as it is (not undefined or DBPointer), with the doubles mongosh would make int32s.
private let typed = BSONDocument([
    ("double", .double(1.5)), ("whole", .double(5)), ("big", .double(1e18)), ("negZero", .double(-0.0)),
    ("nan", .double(.nan)), ("inf", .double(-.infinity)), ("string", .string("héllo \"q\" \n\u{2028} 😀")),
    ("document", .document(BSONDocument([("a", .int32(1))]))), ("array", .array([.int32(1), .string("x"), .array([])])),
    ("binary", .binary(subtype: 0, data: Data([0, 1, 2, 255]))),
    ("uuid", .binary(subtype: 4, data: Data((0..<16).map { UInt8($0 * 17) }))),
    ("oid", .objectId(BSONObjectId(hex: "5f2b1c3d4e5f6a7b8c9d0e1f")!)), ("t", .bool(true)), ("null", .null),
    ("date", .datetime(1_700_000_000_123)), ("oldDate", .datetime(-62_198_755_200_001)),
    ("regex", .regex(pattern: "^a.*b$", options: "im")), ("regexSlash", .regex(pattern: "a/b", options: "x")),
    ("code", .javascript("function() { return 1 }")), ("symbol", .symbol("sym")),
    ("codeWithScope", .javascriptWithScope(code: "x", scope: BSONDocument([("x", .int64(1))]))),
    ("int32", .int32(-2_147_483_648)), ("ts", .timestamp(t: 4_294_967_295, i: 7)), ("int64", .int64(.max)),
    ("smallLong", .int64(-5)), ("decimal", .decimal128(BSONDecimal128("-1.230E-8")!)), ("min", .minKey), ("max", .maxKey),
    ("a.b", .string("dotted")), ("$odd", .int32(1)),
])

struct MongoScriptTests {
    @Test func aFindWritesEachPartSet() throws {
        let query = MongoQueryText(filter: "{ status: \"paid\" }", projection: "{ _id: 0, total: 1 }", sort: "{ total: -1 }",
                                   limit: "50", skip: "10", collation: "{ locale: \"en\", strength: 2 }", hint: "status_1",
                                   maxTimeMS: "5000")
        #expect(try MongoScript.find(query, database: "shop", collection: "orders") == header + prefix
            + ".find({ status: \"paid\" }, { _id: 0, total: 1 }).sort({ total: -1 }).skip(10).limit(50)"
            + ".collation({ locale: \"en\", strength: 2 }).hint(\"status_1\").maxTimeMS(5000)\n")
        // A filter only; an empty bar finds every document; a hint of keys is a document.
        #expect(try MongoScript.find(MongoQueryText(filter: "{ status: \"paid\" }"), database: "shop", collection: "orders")
            == header + prefix + ".find({ status: \"paid\" })\n")
        #expect(try MongoScript.find(MongoQueryText(), database: "shop", collection: "orders") == header + prefix + ".find({})\n")
        #expect(try MongoScript.find(MongoQueryText(hint: "{ status: 1 }"), database: "shop", collection: "orders")
            == header + prefix + ".find({}).hint({ status: 1 })\n")
    }

    @Test func aPipelineWritesAStageALineAndItsOptions() throws {
        let stages = try MongoPipeline.stages(in: "[{ $match: { n: 2.0 } }, { $group: { _id: \"$k\", n: { $sum: NumberLong(1) } } }]")
            .map(\.document)
        let options = try MongoQueryText(collation: "{ locale: \"fr\" }", maxTimeMS: "900").find()
        #expect(try MongoScript.aggregate(stages, options: options, database: "shop", collection: "orders") == header + prefix + """
            .aggregate([
              { $match: { n: Double(2.0) } },
              { $group: { _id: "$k", n: { $sum: NumberLong("1") } } }
            ], { allowDiskUse: true, collation: { locale: "fr" }, maxTimeMS: 900 })

            """)
        #expect(try MongoScript.aggregate([], options: MongoFind(), database: "shop", collection: "orders")
            == header + prefix + ".aggregate([], { allowDiskUse: true })\n")
        // Each line between the brackets reads back as its stage.
        let lines = try MongoScript.aggregate(stages, options: MongoFind(), database: "shop", collection: "orders")
            .split(separator: "\n").dropFirst(2).dropLast()
        #expect(try lines.map { try BSONDocument(shellForm: String($0.hasSuffix(",") ? $0.dropLast() : $0)) } == stages)
    }

    @Test func namesAreEscapedStringLiterals() throws {
        let (database, collection) = ("we\"ird\\db", "a.b$c'\"\\\n\u{2028}end")
        let script = try MongoScript.find(MongoQueryText(), database: database, collection: collection)
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3 && lines[0].hasPrefix("// ") && lines[2].isEmpty, "a name never breaks a line: \(script)")
        #expect(!script.contains("\u{2028}"))
        let call = try #require(lines[1].wholeMatch(of: #/db\.getSiblingDB\((.*)\)\.getCollection\((.*)\)\.find\(\{\}\)/#))
        #expect(try BSONValue(shellForm: String(call.1)) == .string(database))
        #expect(try BSONValue(shellForm: String(call.2)) == .string(collection))
    }

    @Test func valuesReadBackWithTheirTypes() throws {
        let script = try MongoScript.find(MongoQueryText(filter: typed.shellForm()), database: "shop", collection: "orders")
        let argument = try #require(script.split(separator: "\n")[1].wholeMatch(of: #/.*\.find\((.*)\)/#)?.1)
        #expect(try BSONDocument(shellForm: String(argument)) == typed, "\(argument)")
        // mongosh sends 5 and 5.0 alike as an int32, and warns about NumberLong(5).
        #expect(argument.contains("whole: Double(5.0)") && argument.contains("big: Double(1e+18)") && argument.contains("negZero: Double(-0.0)"))
        #expect(argument.contains("double: 1.5,") && argument.contains("smallLong: NumberLong(\"-5\")"))
    }

    @Test func whatDoesntParseOrMongoshCantWriteIsRefused() throws {
        for (query, field) in [(MongoQueryText(filter: "{ n: "), "Filter"), (MongoQueryText(limit: "-1"), "Limit"),
                               (MongoQueryText(filter: "{ n: undefined }"), "Filter"),
                               (MongoQueryText(sort: "{ p: DBPointer(\"d.c\", ObjectId(\"000000000000000000000001\")) }"), "Sort")] {
            #expect(throws: MongoQueryText.Problem.self, "\(query)") { try MongoScript.find(query, database: "d", collection: "c") }
            do { _ = try MongoScript.find(query, database: "d", collection: "c") } catch let problem as MongoQueryText.Problem {
                #expect(problem.field == field, "\(problem)")
            }
        }
        let stages = [BSONDocument([("$match", .document(BSONDocument([("n", .undefined)])))])]
        #expect(throws: MongoQueryText.Problem(field: "Stage 1", message: "undefined is a deprecated type mongosh can't write, so the script would change it")) {
            try MongoScript.aggregate(stages, options: MongoFind(), database: "d", collection: "c")
        }
    }
}

extension AppTests {
    /// Data ▸ Collection ▸ Copy Query as JavaScript puts the bar's find on the clipboard, with no part of the connection's
    /// address or login; a field that doesn't parse says why and copies nothing.
    @Test @MainActor func copyQueryAsJavaScriptPutsTheFindOnTheClipboard() async throws {
        var saved = SavedConnection(name: "Mongo script", host: "db.example.test", port: 27017, user: "scriptuser")
        saved.engine = .mongodb
        let (main, harness) = appWindow(testModel([saved]))
        main.openCollection(MongoCollectionInfo(name: "orders", kind: .collection), database: "shop", connection: saved.id)
        let tab = try #require(main.selectedTab?.content as? MongoCollectionController)
        tab.bar.query = MongoQueryText(filter: "{ n: NumberLong(5) }", limit: "3")
        let reply = await call(harness, "menu", ["path": "Data > Collection > Copy Query as JavaScript"])
        #expect(reply.error == nil, "\(reply.error ?? "")")
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        #expect(copied == header + prefix + ".find({ n: NumberLong(\"5\") }).limit(3)\n", "\(copied)")
        #expect(!copied.contains("example") && !copied.contains("scriptuser") && !copied.contains("27017"))

        tab.bar.filter.stringValue = "{ n: "
        tab.copyQueryScript(nil)
        #expect(!tab.bar.problem.isHidden && tab.bar.problem.stringValue.hasPrefix("Filter:"))
        #expect(NSPasteboard.general.string(forType: .string) == copied)
    }
}
