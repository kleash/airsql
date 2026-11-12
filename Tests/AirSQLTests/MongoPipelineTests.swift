// Aggregation pipelines and explain plans (docs/dev/mongo-plan.md, lane M4): the pipeline editor's text to stages and
// back, with every error at its stage, line and column; explain's answer as PlanView's steps, from answers the lab
// gave (MongoPipelineFixtures.swift) and from the lab itself (AIRSQL_MONGO_LAB=1).
import Foundation
import Testing
@testable import AirSQLCore

private func shell(_ text: String) -> BSONDocument { try! BSONDocument(shellForm: text) }

private func explain(_ json: String) throws -> MongoExplain { MongoExplain(try BSONDocument(extendedJSON: json)) }

/// The first child of each step, down from the root: a plan's chain of inputs.
private func chain(_ node: PlanNode) -> [PlanNode] { [node] + (node.children.first.map(chain) ?? []) }

struct MongoPipelineTests {
    // MARK: Pipeline text

    @Test func stagesInAnArrayKeepTheirPlaces() throws {
        let text = """
        [
          {$match: {n: {$gt: 5}, s: "a}b{", r: /[}\\]]x/i}},
          {$group: {_id: "$n", c: {$sum: 1}}},
        ]
        """
        let stages = try MongoPipeline.stages(in: text)
        #expect(stages.map(\.name) == ["$match", "$group"])
        let units = Array(text.utf16)
        #expect(stages.map { String(decoding: units[$0.range], as: UTF16.self) }
                == [#"{$match: {n: {$gt: 5}, s: "a}b{", r: /[}\]]x/i}}"#, #"{$group: {_id: "$n", c: {$sum: 1}}}"#])
        #expect(stages[0].document == shell(#"{$match: {n: {$gt: 5}, s: "a}b{", r: /[}\]]x/i}}"#))
    }

    @Test func stagesAloneWithOrWithoutCommas() throws {
        #expect(try MongoPipeline.stages(in: "").isEmpty && MongoPipeline.stages(in: " [ ] ").isEmpty)
        let bare = try MongoPipeline.stages(in: "{$match: {}}\n{$limit: 2},\n{$skip: 1}")
        #expect(bare.map(\.name) == ["$match", "$limit", "$skip"] && bare[1].range == 13..<24)
    }

    @Test func stagesFormatOnePerBlockAndReadBack() throws {
        let stages = [shell(#"{$match: {n: {$in: [1, NumberLong(2)]}, d: ISODate("2024-02-29T12:34:56.789Z")}}"#),
                      shell("{$sort: {n: -1}}"), shell("{$project: {_id: 0, n: 1}}")]
        let text = MongoPipeline.text(stages)
        #expect(text.hasPrefix("[\n  {\n    $match: {") && text.hasSuffix("\n  }\n]"))
        #expect(try MongoPipeline.stages(in: text).map(\.document) == stages)
        #expect(MongoPipeline.text([]) == "[]")
    }

    @Test func everyErrorSaysWhere() throws {
        func failure(_ text: String) -> MongoPipeline.ParseError? {
            do { _ = try MongoPipeline.stages(in: text); return nil } catch { return error as? MongoPipeline.ParseError }
        }
        // In a stage: the shell parser's own words, at the whole text's line and column.
        let syntax = try #require(failure("[\n  {$match: {}},\n  {$sort: {n: -1 x}}\n]"))
        #expect(syntax.stage == 1 && syntax.line == 3 && syntax.column == 18 && syntax.offset == 35)
        #expect(syntax.message.hasPrefix("Expected ‘,’ or ‘}’") && syntax.description.hasPrefix("Line 3, column 18: "))
        // Columns count characters, offsets UTF-16 units.
        let wide = try #require(failure(#"[{$match: {a: "😀"}}, {$limit: @}]"#))
        #expect(wide.stage == 1 && wide.line == 1 && wide.column == 31 && wide.offset == 31 && wide.message.hasPrefix("Expected a value"))
        let open = try #require(failure("{$match: {a: 1}"))
        #expect(open.stage == 0 && open.column == 16 && open.message.contains("end of the text"))

        // Between stages.
        let notStage = try #require(failure("[{$match: {}}, 5]"))
        #expect(notStage.stage == nil && notStage.column == 16 && notStage.message == "Expected a stage such as {$match: {…}}, found ‘5’")
        let unclosed = try #require(failure("[{$match: {}}"))
        #expect(unclosed.stage == nil && unclosed.column == 14 && unclosed.message.contains("no closing ‘]’"))
        let after = try #require(failure("[{$match: {}}] x"))
        #expect(after.column == 16 && after.message.contains("after the pipeline’s ‘]’"))

        // A stage that isn't one operator.
        let empty = try #require(failure("[{$match: {}},\n {}]"))
        #expect(empty.stage == 1 && empty.line == 2 && empty.column == 2 && empty.message.hasPrefix("Stage 2 is empty"))
        let plain = try #require(failure("[{match: {}}]"))
        #expect(plain.stage == 0 && plain.column == 2 && plain.message.contains("‘match’ isn’t a stage"))
        let two = try #require(failure("[{$match: {}, $sort: {a: 1}}]"))
        #expect(two.message == "Stage 1 has 2 fields ($match, $sort): a stage is one operator, so put each in a stage of its own")
    }

    // MARK: Explain

    @Test func anIndexedFindReadsItsIndex() throws {
        let plan = try explain(MongoExplainFixtures.indexedFind)
        let steps = chain(try #require(plan.nodes.first))
        #expect(plan.nodes.count == 1 && plan.warnings.isEmpty)
        #expect(steps.map(\.operation) == ["FETCH, 10 documents examined", "IXSCAN _id_ (_id: [10, 20)), 10 keys examined"])
        #expect(steps.map(\.actualRows) == [10, 10] && steps.map(\.time) == [0, 0])
        #expect(steps[1].details.contains("works: 11") && steps[1].details.contains("indexName: _id_"))
        #expect(plan.tree == "FETCH, 10 documents examined (returned 10, 0 ms)\n    IXSCAN _id_ (_id: [10, 20)), 10 keys examined (returned 10, 0 ms)")
    }

    @Test func aCollectionScanIsWarnedOf() throws {
        let plan = try explain(MongoExplainFixtures.unindexedFind)
        let scan = try #require(plan.nodes.first)
        #expect(scan.operation == "COLLSCAN, 1000 documents examined" && scan.actualRows == 9 && scan.children.isEmpty)
        #expect(plan.warnings == ["Reads the whole collection (1000 documents): an index on the filter’s fields would read fewer",
                                  "Examined 1000 documents to return 9: an index on the filter’s fields would read fewer"])
        #expect(scan.details.prefix(2).allSatisfy { $0.hasPrefix("Warning: ") })
    }

    @Test func aSortWithoutAnIndexSortsInMemory() throws {
        let plan = try explain(MongoExplainFixtures.sortedFind)
        let steps = chain(try #require(plan.nodes.first))
        #expect(steps.map(\.operation) == ["PROJECTION_SIMPLE", "SKIP 2", "SORT { n: -1 }, in memory", "COLLSCAN, 1000 documents examined"])
        #expect(steps.map(\.actualRows) == [5, 5, 7, 900])
        #expect(plan.warnings.contains("Sorts in memory: an index in the sort’s order would return the documents sorted"))
    }

    @Test func anAggregatesStagesFollowItsCursor() throws {
        let plan = try explain(MongoExplainFixtures.aggregate)
        #expect(plan.nodes.map { $0.operation.prefix { $0 != " " } } == ["$cursor", "$group", "$sort", "$lookup"])
        #expect(plan.nodes.map(\.actualRows) == [50, 5, 5, 5] && plan.nodes.map(\.time) == [1, 1, 1, 12])
        #expect(chain(plan.nodes[0].children[0]).map(\.operation) == ["PROJECTION_SIMPLE", "COLLSCAN, 1000 documents examined"])
        #expect(plan.nodes[3].operation.hasPrefix(#"$lookup { from: "all_types""#)
                && plan.nodes[3].details.contains(#"indexesUsed: [ "_id_" ]"#))
        #expect(plan.warnings.contains("$sort sorts in memory") && plan.warnings.contains { $0.hasPrefix("Reads the whole collection") })

        let pushed = try explain(MongoExplainFixtures.pushedDownAggregate)
        #expect(chain(pushed.nodes[0]).map(\.operation)
                == ["LIMIT 3", "FETCH, 3 documents examined", "IXSCAN _id_ (_id: (50, -inf.0]), 3 keys examined"])
        #expect(pushed.warnings.isEmpty)
    }

    @Test func rejectedPlansAreCounted() throws {
        let plan = try explain(MongoExplainFixtures.rejectedPlans)
        #expect(chain(plan.nodes[0]).map(\.operation) == ["FETCH, 20 documents examined", "IXSCAN a_1 (a: [3, 3]), 20 keys examined"])
        #expect(plan.warnings == ["The planner tried 2 other plans and rejected them"])
    }

    /// 7.0's slot-based engine (the lab forces the classic one): the steps from queryPlan, figures by planNodeId.
    @Test func slotBasedPlansTakeTheirFiguresByPlanNode() throws {
        let plan = try explain("""
        {"explainVersion": "2", "queryPlanner": {"namespace": "fixture.many", "winningPlan": {"queryPlan": {
          "stage": "GROUP", "planNodeId": 3, "inputStage": {"stage": "EQ_LOOKUP", "planNodeId": 2, "foreignCollection": "fixture.all_types",
          "strategy": "HashJoin", "inputStage": {"stage": "COLLSCAN", "planNodeId": 1, "direction": "forward"}}},
          "slotBasedPlan": {"slots": "", "stages": ""}}, "rejectedPlans": []},
         "executionStats": {"nReturned": 5, "totalDocsExamined": 1000, "executionStages": {
          "stage": "project", "planNodeId": 3, "nReturned": 5, "executionTimeMillisEstimate": 2, "inputStage": {
          "stage": "group", "planNodeId": 3, "nReturned": 5, "executionTimeMillisEstimate": 1, "inputStage": {
          "stage": "hj", "planNodeId": 2, "nReturned": 50, "executionTimeMillisEstimate": 1, "outerStage": {
          "stage": "scan", "planNodeId": 1, "nReturned": 1000, "executionTimeMillisEstimate": 0, "numReads": 1000}}}}}, "ok": 1}
        """)
        let steps = chain(try #require(plan.nodes.first))
        #expect(steps.map(\.operation) == ["GROUP", "EQ_LOOKUP fixture.all_types (HashJoin)", "COLLSCAN"])
        #expect(steps.map(\.actualRows) == [5, 50, 1000] && steps.map(\.time) == [2, 1, 0])
        #expect(plan.warnings.first == "Reads the whole collection (1000 documents): an index on the filter’s fields would read fewer")
    }

    @Test func aShardedFindShowsEachShard() throws {
        let plan = try explain("""
        {"queryPlanner": {"winningPlan": {"stage": "SHARD_MERGE", "shards": []}}, "executionStats": {"nReturned": 2,
         "executionStages": {"stage": "SHARD_MERGE", "nReturned": 2, "executionTimeMillisEstimate": 1, "shards": [
          {"shardName": "s0", "executionStages": {"stage": "IXSCAN", "indexName": "a_1", "nReturned": 1, "keysExamined": 1}},
          {"shardName": "s1", "executionStages": {"stage": "SORT", "usedDisk": true, "nReturned": 1}}]}}, "ok": 1}
        """)
        let merge = try #require(plan.nodes.first)
        #expect(merge.operation == "SHARD_MERGE" && merge.children.map(\.operation) == ["Shard s0", "Shard s1"])
        #expect(merge.children.map { $0.children[0].operation } == ["IXSCAN a_1, 1 keys examined", "SORT, spilled to disk"])
        #expect(plan.warnings == ["Sorts on disk, as the sort outgrew its memory: an index in the sort’s order would return the documents sorted"])
        #expect(MongoExplain(BSONDocument()).nodes.isEmpty)
    }
}

// MARK: - Lab

@Suite(.serialized, .enabled(if: MongoLab.enabled, "Mongo lab: AIRSQL_MONGO_LAB=1 ./test.sh --filter MongoPipeline"))
struct MongoPipelineLabTests {
    /// The standalone directly, and the replica set through the SOCKS proxy.
    private func both() -> [MongoConnection] {
        var solo = SavedConnection(name: "Mongo lab", host: "127.0.0.1", port: MongoLab.soloPort, user: "airsql", route: .direct)
        var set = SavedConnection(name: "Mongo lab", host: MongoLab.members[0], port: 27017, user: "airsql", route: .proxy)
        set.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: Lab.socksProxy.port, user: Lab.socksProxy.user)
        solo.engine = .mongodb
        set.engine = .mongodb
        return [MongoConnection(uri: "mongodb://127.0.0.1:\(MongoLab.soloPort)/?authMechanism=SCRAM-SHA-256", user: "airsql",
                                password: MongoLab.airsql.password, route: MongoRoute(solo)),
                MongoConnection(uri: MongoLab.allSeeds, user: "airsql", password: MongoLab.airsql.password, tls: MongoLab.tls,
                                route: MongoRoute(set, proxyPassword: Lab.socksProxy.password))]
    }

    @Test func explainsOfTheFixture() async throws {
        for connection in both() {
            try await connection.connect()
            let session = try await connection.session(.main)
            func find(_ query: MongoFind) async throws -> MongoExplain {
                MongoExplain(try await session.explain(database: "fixture", collection: "many", query))
            }
            let indexed = try await find(MongoFind(filter: shell("{_id: {$gte: 10, $lt: 20}}")))
            #expect(chain(indexed.nodes[0]).map(\.operation) == ["FETCH, 10 documents examined", "IXSCAN _id_ (_id: [10, 20)), 10 keys examined"])
            #expect(indexed.warnings.isEmpty)

            let unindexed = try await find(MongoFind(filter: shell("{n: {$gt: 990}}")))
            #expect(unindexed.nodes[0].operation == "COLLSCAN, 1000 documents examined" && unindexed.nodes[0].actualRows == 9)
            #expect(unindexed.warnings.contains { $0.hasPrefix("Reads the whole collection (1000 documents)") })

            let sorted = try await find(MongoFind(filter: shell("{n: {$gte: 100}}"), sort: shell("{n: -1}"), limit: 5))
            #expect(chain(sorted.nodes[0]).map(\.operation) == ["SORT { n: -1 }, in memory", "COLLSCAN, 1000 documents examined"])
            #expect(sorted.warnings.contains { $0.hasPrefix("Sorts in memory") })

            // The editor's text, run and explained.
            let stages = try MongoPipeline.stages(in: """
            [
              {$match: {n: {$lt: 50}}},
              {$group: {_id: {$mod: ["$n", 5]}, c: {$sum: 1}}},
              {$lookup: {from: "all_types", localField: "_id", foreignField: "_id", as: "t"}},
              {$sort: {_id: 1}}
            ]
            """).map(\.document)
            let cursor = try await session.aggregate(database: "fixture", collection: "many", pipeline: stages)
            let rows = try await cursor.next().map { try BSONDocument(bytes: $0) }
            await cursor.close()
            #expect(rows.map { $0["c"] } == Array(repeating: .int32(10), count: 5))
            let aggregated = MongoExplain(try await session.explain(database: "fixture", collection: "many", pipeline: stages))
            #expect(aggregated.nodes.map { $0.operation.prefix { $0 != " " } } == ["$cursor", "$group", "$sort", "$lookup"])
            #expect(aggregated.nodes.map(\.actualRows) == [50, 5, 5, 5])
            #expect(aggregated.nodes[0].children.first.map(chain)?.last?.operation == "COLLSCAN, 1000 documents examined")
            await connection.close()
        }
    }
}
