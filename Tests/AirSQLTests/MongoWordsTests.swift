// MongoDB's words (MongoWords): the lookups completion and agents use.
import Foundation
import Testing
@testable import AirSQLCore

struct MongoWordsTests {
    @Test func lookups() throws {
        #expect(MongoWords.query(for: "string").contains { $0.name == "$regex" })
        #expect(!MongoWords.query(for: "int").contains { $0.name == "$regex" })
        #expect(Set(MongoWords.query(for: "array").map(\.name)).isSuperset(of: ["$size", "$all", "$elemMatch", "$in"]))
        #expect(MongoWords.query(for: "date").contains { $0.name == "$gte" })
        #expect(!MongoWords.query(for: nil).contains { $0.topLevel || $0.name == "$regex" }, "a field of unknown type: any-type operators")
        #expect(MongoWords.named("$or", kind: .query).first?.topLevel == true)
        #expect(MongoWords.update(for: "long").contains { $0.name == "$inc" } && !MongoWords.update(for: "string").contains { $0.name == "$inc" })

        let lookup = try #require(MongoWords.stage("$lookup"))
        #expect(lookup.slot("from") == .collection && lookup.slot("foreignField") == .field && lookup.slot("pipeline") == .pipeline)
        #expect(MongoWords.stage("$match")?.argument == .query && MongoWords.stage("$group")?.argument == .accumulators)
        #expect(MongoWords.stage("$unionWith")?.slot("coll") == .collection)
        #expect(MongoWords.stage("$nope") == nil)

        #expect(MongoWords.named("$sum").map(\.kind) == [.expression, .accumulator])
        #expect(MongoWords.accumulators(in: "$group").contains { $0.name == "$push" })
        #expect(!MongoWords.accumulators(in: "$group").contains { $0.name == "$rank" })
        #expect(MongoWords.accumulators(in: "$setWindowFields").contains { $0.name == "$rank" })
        #expect(!MongoWords.expressions.contains { $0.name == "$push" }, "$push is an accumulator only")
        #expect(Set(MongoWords.variables.map(\.name)).isSuperset(of: ["$$ROOT", "$$NOW", "$$REMOVE", "$$CURRENT"]))

        let fill = try #require(MongoWords.stage("$fill"))
        #expect(fill.since == "5.3" && !fill.isAvailable(on: "5.0.2") && fill.isAvailable(on: "7.0.45") && fill.isAvailable(on: "5.3"))
        #expect(MongoWords.stage("$match")?.isAvailable(on: "4.4.0") == true)
        #expect(MongoWords.all.allSatisfy { !$0.summary.isEmpty && !$0.summary.hasSuffix(".") })
        for kind in [MongoWord.Kind.query, .update, .stage, .expression, .accumulator, .variable] {
            let names = MongoWords.all.filter { $0.kind == kind }.map(\.name)
            #expect(names.count == Set(names).count, "\(kind) names once each")
        }
    }

    /// The agents' allow-list is the guard's own, narrower on purpose; every name on it is a stage the table knows.
    @Test func guardStagesAreWords() {
        #expect(MongoAgentGuard.allowedStages.allSatisfy { MongoWords.stage($0) != nil })
        #expect(MongoWords.stage("$out") != nil && !MongoAgentGuard.allowedStages.contains("$out"))
    }
}
