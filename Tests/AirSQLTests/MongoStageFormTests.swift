// The stage builder's cards (docs/dev/mongo-plan.md, Phase 5 B; lane P5-core): cards to stages and back, one card per
// stage, a card's stage spliced into the pipeline's text leaving the rest byte for byte, the fields after each stage,
// and the join's warnings.
import Foundation
import Testing
@testable import AirSQLCore

private typealias F = MongoStageForm
private func shell(_ text: String) -> BSONDocument { try! BSONDocument(shellForm: text) }

struct MongoStageFormTests {
    @Test func eachCardWritesItsStageAndReadsItBack() throws {
        let cases: [(F, String)] = [
            (.filter(MongoBuilder.Group([.rule(MongoBuilder.Rule("name", .contains, ["ada"], ignoreCase: true))])),
             "{ $match: { name: /ada/i } }"),
            (.join(F.Join(from: "customers", localField: "customerId", foreignField: "_id", as: "customer")),
             #"{ $lookup: { from: "customers", localField: "customerId", foreignField: "_id", as: "customer" } }"#),
            (.group(F.Grouping(by: ["status"], outputs: [F.Output(.count), F.Output(.sum, "total"), F.Output(.average, "items.qty")])),
             #"{ $group: { _id: "$status", count: { $sum: 1 }, sum_total: { $sum: "$total" }, avg_items_qty: { $avg: "$items.qty" } } }"#),
            (.group(F.Grouping(by: ["a", "b.c"], outputs: [F.Output(.smallest, "x"), F.Output(.largest, "x"), F.Output(.first, "x"),
                                                           F.Output(.last, "x"), F.Output(.list, "x"), F.Output(.distinctList, "x")])),
             #"{ $group: { _id: { a: "$a", b_c: "$b.c" }, min_x: { $min: "$x" }, max_x: { $max: "$x" }, first_x: { $first: "$x" }, "#
                + #"last_x: { $last: "$x" }, list_x: { $push: "$x" }, distinct_x: { $addToSet: "$x" } } }"#),
            (.group(F.Grouping(by: ["a"], byDocument: true)), #"{ $group: { _id: { a: "$a" } } }"#),
            (.group(F.Grouping(outputs: [F.Output(.count)])), "{ $group: { _id: null, count: { $sum: 1 } } }"),
            (.sort([MongoBuilder.SortKey("a", ascending: false)]), "{ $sort: { a: -1 } }"),
            (.show(MongoBuilder.Projection(paths: ["a"], includeId: false)), "{ $project: { a: 1, _id: 0 } }"),
            (.limit(10), "{ $limit: 10 }"),
            (.limit(5_000_000_000), "{ $limit: NumberLong(5000000000) }"),
            (.unwind(F.Unwind(path: "items")), #"{ $unwind: "$items" }"#),
            (.unwind(F.Unwind(path: "customer", preserve: true)), #"{ $unwind: { path: "$customer", preserveNullAndEmptyArrays: true } }"#),
            (.shell(shell("{ $facet: { a: [] } }")), "{ $facet: { a: [] } }"),
        ]
        for (form, text) in cases {
            #expect(try form.stage().shellForm() == text)
            #expect(F(stage: shell(text)) == form, "\(text)")
        }
        #expect(F.forms(from: cases.map { shell($0.1) }) == cases.map(\.0))
        #expect(F.limit(1).title == "Limit — LIMIT" && F.join(F.Join(from: "", localField: "", foreignField: "", as: "")).title == "Join — JOIN")
        // Plain forms a card also shows.
        #expect(F(stage: shell(#"{ $unwind: { path: "$a" } }"#)) == .unwind(F.Unwind(path: "a")))
        #expect(F(stage: shell("{ $limit: 3.0 }")) == .limit(3))
        #expect(F(stage: shell(#"{ $group: { _id: "$a", count: { $sum: NumberLong(1) } } }"#)) == .group(F.Grouping(by: ["a"], outputs: [F.Output(.count)])))
    }

    @Test func stagesNoCardShowsExactlyAreShellCards() {
        let shells = [
            #"{ $match: { a: { $elemMatch: { b: 1 } } } }"#, #"{ $lookup: { from: "c", pipeline: [], as: "x" } }"#,
            #"{ $lookup: { from: "c", localField: "a", foreignField: "b", as: "x", let: {} } }"#,
            #"{ $group: { _id: "$a", total: { $sum: "$t" } } }"#, #"{ $group: { _id: "$a", count: { $sum: 2 } } }"#,
            #"{ $group: { _id: { k: "$a" } } }"#, #"{ $group: { _id: "$$ROOT" } }"#, #"{ $group: { _id: "$a", n: { $count: {} } } }"#,
            #"{ $group: { _id: "$a", sum_t: { $sum: "$t" }, sum_t: { $sum: "$t" } } }"#,
            "{ $sort: {} }", #"{ $sort: { s: { $meta: "textScore" } } }"#, "{ $project: { a: 0 } }", #"{ $project: { a: "$b" } }"#,
            "{ $limit: 0 }", "{ $limit: 2.5 }", #"{ $unwind: { path: "$a", includeArrayIndex: "i" } }"#, #"{ $unwind: "a" }"#,
            "{ $skip: 2 }", "{ $count: \"n\" }", #"{ $addFields: { a: 1 } }"#,
        ]
        for text in shells { #expect(F(stage: shell(text)) == .shell(shell(text)), "\(text)") }
    }

    @Test func aCardSaysWhatToFillIn() {
        let bad: [(F, String)] = [
            (.join(F.Join(from: "", localField: "a", foreignField: "b", as: "c")), "Choose the collection to join"),
            (.join(F.Join(from: "c", localField: "a", foreignField: "", as: "c")), "Choose their field"),
            (.group(F.Grouping(by: ["a"], outputs: [F.Output(.sum)])), "Choose a field for Sum"),
            (.group(F.Grouping(outputs: [F.Output(.count), F.Output(.count)])), "Two results are both named count"),
            (.sort([]), "Add a field to sort by"), (.show(MongoBuilder.Projection()), "Tick the fields to show"),
            (.limit(0), "Type a limit of 1 or more"), (.unwind(F.Unwind(path: "")), "Choose the array field to unwind"),
            (.filter(MongoBuilder.Group([.rule(MongoBuilder.Rule("n", .is, ["x"], type: .number))])), "n: ‘x’ isn't a number"),
        ]
        for (form, message) in bad {
            #expect { try form.stage() } throws: { ($0 as? BSONError)?.message == message }
        }
    }

    // MARK: Splicing

    static let pipeline = """
    [
      { $match: { a:   1 } },
      { $limit:5 },
      {$sort: {
          b: -1
      }}
    ]
    """

    @Test func aCardsStageReplacesOnlyItsText() throws {
        let text = Self.pipeline
        #expect(try MongoPipeline.replacingStage(1, with: shell("{ $limit: 7 }"), in: text)
                == text.replacingOccurrences(of: "{ $limit:5 }", with: "{ $limit: 7 }"))
        // A stage on several lines is written on several, indented as it was.
        #expect(try MongoPipeline.replacingStage(2, with: shell("{ $sort: { b: 1, c: 1 } }"), in: text)
                == "[\n  { $match: { a:   1 } },\n  { $limit:5 },\n  {\n    $sort: {\n      b: 1,\n      c: 1\n    }\n  }\n]")
        #expect(throws: BSONError.self) { try MongoPipeline.replacingStage(3, with: shell("{ $limit: 1 }"), in: text) }
        #expect(throws: MongoPipeline.ParseError.self) { try MongoPipeline.replacingStage(0, with: shell("{ $limit: 1 }"), in: "[ { $match: ") }
    }

    @Test func stagesAreInsertedAndRemovedInPlace() throws {
        let text = Self.pipeline, skip = shell("{ $skip: 2 }")
        #expect(try MongoPipeline.insertingStage(skip, at: 0, in: text)
                == text.replacingOccurrences(of: "[\n  { $match", with: "[\n  { $skip: 2 },\n  { $match"))
        #expect(try MongoPipeline.insertingStage(skip, at: 1, in: text)
                == text.replacingOccurrences(of: "  { $limit:5 }", with: "  { $skip: 2 },\n  { $limit:5 }"))
        // Laid out as its neighbour: this one is on several lines.
        #expect(try MongoPipeline.insertingStage(skip, at: 3, in: text)
                == text.replacingOccurrences(of: "}}\n]", with: "}},\n  {\n    $skip: 2\n  }\n]"))
        #expect(try MongoPipeline.insertingStage(skip, at: 0, in: "") == MongoPipeline.text([skip]))
        #expect(try MongoPipeline.insertingStage(skip, at: 1, in: "[{ $limit: 1 }]") == "[{ $limit: 1 }, { $skip: 2 }]")
        #expect(throws: BSONError.self) { try MongoPipeline.insertingStage(skip, at: 5, in: text) }

        #expect(try MongoPipeline.removingStage(0, in: text) == text.replacingOccurrences(of: "{ $match: { a:   1 } },\n  ", with: ""))
        #expect(try MongoPipeline.removingStage(1, in: text) == text.replacingOccurrences(of: ",\n  { $limit:5 }", with: ""))
        #expect(try MongoPipeline.removingStage(2, in: text).hasSuffix("{ $limit:5 }\n]"))
        #expect(try MongoPipeline.removingStage(0, in: "[{ $limit: 1 }]") == "[]")
        // Each result still reads as the pipeline it should be.
        let stages = try MongoPipeline.stages(in: text).map(\.document)
        for n in 0...3 {
            #expect(try MongoPipeline.stages(in: MongoPipeline.insertingStage(skip, at: n, in: text)).map(\.document)
                    == Array(stages[..<n]) + [skip] + Array(stages[n...]))
        }
        for n in 0..<3 {
            var less = stages
            less.remove(at: n)
            #expect(try MongoPipeline.stages(in: MongoPipeline.removingStage(n, in: text)).map(\.document) == less)
        }
    }

    // MARK: Fields downstream

    @Test func fieldsFollowTheStages() {
        let base = ["_id", "customerId", "status", "items", "items.[]", "items.[].sku", "items.[].qty", "total"]
        let forms: [F] = [
            .filter(MongoBuilder.Group()),
            .join(F.Join(from: "customers", localField: "customerId", foreignField: "_id", as: "customer")),
            .unwind(F.Unwind(path: "items")),
            .show(MongoBuilder.Projection(paths: ["items.sku", "customer.name", "total"])),
            .group(F.Grouping(by: ["customer.name"], outputs: [F.Output(.sum, "total")])),
            .group(F.Grouping(by: ["a", "b"])),
        ]
        let after = F.fields(after: forms, base: base) { $0 == "customers" ? ["_id", "name"] : [] }
        #expect(after[0] == base)
        #expect(after[1] == base + ["customer", "customer._id", "customer.name"])
        #expect(after[2] == ["_id", "customerId", "status", "items", "items.sku", "items.qty", "total", "customer", "customer._id", "customer.name"])
        #expect(after[3] == ["_id", "items", "items.sku", "total", "customer", "customer.name"])
        #expect(after[4] == ["_id", "sum_total"])
        #expect(after[5] == ["_id", "_id.a", "_id.b"])
        // A join's `as` replaces what was there.
        #expect(F.fields(after: [.join(F.Join(from: "c", localField: "a", foreignField: "b", as: "items"))], base: base) { _ in ["x"] }[0]
                == ["_id", "customerId", "status", "total", "items", "items.x"])
    }

    // MARK: Join warnings

    @Test func joinWarningsInPlainWords() {
        let orders = MongoSample(schema: MongoSchema(sample: [shell(#"{ customerId: "65a1b2c3d4e5f60718293a4b", customer: 1, n: NumberLong(2) }"#)]))
        let customers = MongoSample(schema: MongoSchema(sample: [shell(#"{ _id: ObjectId("65a1b2c3d4e5f60718293a4b"), n: 2.5 }"#)]),
                                    indexes: [shell("{ _id: 1 }")])
        #expect(MongoJoinCheck.warnings(from: "customers", localField: "customerId", foreignField: "_id", as: "customer",
                                        here: orders, there: customers)
                == ["‘customerId’ is text here but ‘_id’ is an ObjectId in customers: values of different types never match, so nothing joins",
                    "‘customer’ is already a field here: the join replaces it"])
        #expect(MongoJoinCheck.warnings(from: "customers", localField: "n", foreignField: "n", as: "c", here: orders, there: customers)
                == ["customers has no index starting with ‘n’: each document's join reads all of customers"])
        #expect(MongoJoinCheck.warnings(from: "customers", localField: "customerId", foreignField: "_id", as: "x", here: nil, there: nil).isEmpty)
        // Indexes that couldn't be listed say nothing.
        let unlisted = MongoSample(schema: customers.schema)
        #expect(MongoJoinCheck.warnings(from: "customers", localField: "n", foreignField: "n", as: "c", here: orders, there: unlisted).isEmpty)
    }
}
