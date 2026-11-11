// The aggregation tab (docs/dev/mongo-plan.md, lane M4-app): its folds and error places (completion: MongoCompletionTests); then, against the
// Mongo lab (AIRSQL_MONGO_LAB=1), opening it, running, an error at its stage, Load More, Cancel, Explain with its warnings
// and Text page, a collection tab's Explain; and its pictures (AIRSQL_SCREENSHOTS=1 too).
import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

struct MongoAggregationTests {
    @Test @MainActor func eachStageOfSeveralLinesFoldsAndAnErrorSaysItsStage() throws {
        let text = "[\n  { $match: {\n    n: 1\n  } },\n  { $limit: 2 }\n]"
        let folds = MongoAggregationController.folds(text)
        #expect(folds.count == 1)
        let units = Array(text.utf16)
        let fold = try #require(folds.first)
        #expect(units[fold.lowerBound] == 0x0A && units[fold.upperBound] == UInt16(UInt8(ascii: "}")))
        #expect(MongoAggregationController.folds("[{ $match: ").isEmpty)

        let bad = "[\n  {$match: {}},\n  {$sort: {n: -1 x}}\n]"
        do {
            _ = try MongoPipeline.stages(in: bad)
            Issue.record("the pipeline should not parse")
        } catch let error as MongoPipeline.ParseError {
            let problem = MongoAggregationController.problem(error, in: bad)
            #expect(problem.message.hasPrefix("Stage 2, line 3, column 18: Expected ‘,’ or ‘}’"), "\(problem.message)")
            #expect(problem.range == 35..<36)
        }
    }
}

// MARK: The lab

/// The standalone of the Mongo lab, connected in a window of its own, with the fixture database open.
@MainActor func aggregationWindow(pageSize: Int = 100) async throws -> (MainWindowController, AgentServer, OpenMongoConnection) {
    var solo = SavedConnection(name: "Mongo pipelines", host: "127.0.0.1", port: MongoLab.soloPort, user: MongoLab.airsql.user)
    solo.engine = .mongodb
    solo.tls.mode = .off
    let model = testModel([solo])
    model.data.settings.rowsPerPage = pageSize
    model.setSavedPassword(solo.id.uuidString, MongoLab.airsql.password)
    let (main, harness) = appWindow(model)
    _ = await call(harness, "select", ["pane": "sidebar", "names": [solo.name]])
    #expect(await call(harness, "menu", ["path": "Connection > Connect"]).error == nil)
    #expect(await eventually(timeout: 30) { model.openMongo[solo.id]?.databases != nil })
    let mongo = try #require(model.openMongo[solo.id])
    let fixture = try #require(main.sidebar.treeNodes[.mongo(solo.id, MongoTreeItem(database: "fixture"))])
    main.sidebar.outline.expandItem(fixture)
    #expect(await eventually(timeout: 20) { !mongo.isLoading })
    return (main, harness, mongo)
}

/// A new aggregation tab on `collection`, from Data ▸ Collection with the collection selected in the tree; its first run done.
@MainActor func openAggregation(_ collection: String, _ main: MainWindowController, _ harness: AgentServer,
                                        _ mongo: OpenMongoConnection) async throws -> MongoAggregationController {
    #expect(main.sidebar.reveal(.mongo(mongo.saved.id, MongoTreeItem(database: "fixture", collection: collection))))
    main.window?.makeFirstResponder(main.sidebar.outline)
    let opened = await call(harness, "menu", ["path": "Data > Collection > New Aggregation"])
    #expect(opened.error == nil, "\(opened.error ?? "")")
    let tab = try #require(main.selectedTab?.content as? MongoAggregationController)
    #expect(tab.collection == collection)
    #expect(await eventually(timeout: 20) { tab.loading == nil })
    #expect(tab.problem == nil, "\(tab.problem ?? "")")
    return tab
}

@MainActor func run(_ tab: MongoAggregationController, _ text: String, explain: Bool = false) async {
    tab.editor.string = text
    if explain { tab.explain() } else { tab.run() }
    #expect(await eventually(timeout: 30) { tab.loading == nil })
}

extension AppTests {
    @Test(.enabled(if: MongoLab.enabled)) func anAggregationTabRunsExplainsAndCancels() async throws {
        let (main, harness, mongo) = try await aggregationWindow()
        let tab = try await openAggregation("many", main, harness, mongo)
        // The first run: every document, a batch at a time.
        #expect(tab.source.rowCount == 100 && tab.viewer.status.rows.stringValue == "100 documents loaded")
        tab.dataGridReachedLastRow(tab.grid)
        #expect(await eventually(timeout: 20) { tab.loading == nil && tab.source.rowCount == 200 })

        // $match and $group, run from the menu (⌘↩).
        tab.editor.string = "[\n  { $match: { n: { $lt: 10 } } },\n  { $group: { _id: { $mod: [\"$n\", 2] }, count: { $sum: 1 } } },\n  { $sort: { _id: 1 } }\n]"
        #expect(await call(harness, "menu", ["path": "Query > Run Statement"]).error == nil)
        #expect(await eventually(timeout: 20) { tab.loading == nil && tab.source.rowCount == 2 })
        #expect(tab.source.document(0)?["count"] == .int32(5) && tab.viewer.status.rows.stringValue == "2 documents")

        // A syntax error points at its stage, line and column; nothing runs.
        await run(tab, "[\n  {$match: {}},\n  {$sort: {n: -1 x}}\n]")
        #expect(tab.problem?.hasPrefix("Stage 2, line 3, column 18:") == true, "\(tab.problem ?? "")")
        #expect(tab.editor.runProblem?.range == 35..<36 && tab.editor.selectedRange().location == 35)
        #expect(tab.source.rowCount == 2, "the documents shown stay")
        tab.maxTime.stringValue = "soon"
        await run(tab, "[]")
        #expect(tab.problem?.hasPrefix("Max Time:") == true, "\(tab.problem ?? "")")
        tab.maxTime.stringValue = ""

        // Cancel ends a slow pipeline on the tab's own session.
        tab.editor.string = "[{ $match: { $expr: { $function: { body: 'function() { sleep(20); return true }', args: [], lang: 'js' } } } }]"
        tab.run()
        #expect(tab.loading != nil && tab.isBusy)
        try await Task.sleep(nanoseconds: 700_000_000)
        let started = Date()
        #expect(await call(harness, "menu", ["path": "Query > Cancel"]).error == nil)
        #expect(await eventually(timeout: 10) { tab.loading == nil })
        #expect(Date().timeIntervalSince(started) < 5 && tab.problem?.hasPrefix("Cancelled") == true, "\(tab.problem ?? "")")
        #expect(main.model.activity.isIdle)

        // Explain: a scan of the whole collection, and what it costs, said first.
        tab.editor.string = "[{ $match: { n: { $lt: 5 } } }]"
        #expect(await call(harness, "menu", ["path": "Query > Explain"]).error == nil)
        #expect(await eventually(timeout: 20) { tab.loading == nil && tab.explainView != nil })
        var plan = try #require(tab.explainView)
        #expect(tab.page == .explain && plan.plan.operations != nil)
        #expect(plan.warnings.contains { $0.hasPrefix("Reads the whole collection (1000 documents)") }, "\(plan.warnings)")
        #expect(find(PlanView.self, in: tab.view) === plan.plan)
        // By _id: the index.
        await run(tab, "[{ $match: { _id: { $gt: 990 } } }]", explain: true)
        plan = try #require(tab.explainView)
        #expect(plan.warnings.isEmpty, "\(plan.warnings)")
        // The Text page: the plan as indented lines.
        plan.plan.choice.selectedSegment = 4
        NSApp.sendAction(try #require(plan.plan.choice.action), to: plan.plan.choice.target, from: plan.plan.choice)
        let text = try #require(find(NSTextView.self, id: "console.planTree", in: plan.plan))
        #expect(text.string.contains("IXSCAN _id_"), "\(text.string)")
        #expect(!plan.plan.choice.isEnabled(forSegment: 3) && plan.plan.choice.label(forSegment: 4) == "Text")

        // A collection tab's find, explained in a window of its own.
        let kind = SidebarNode.Kind.mongo(mongo.saved.id, MongoTreeItem(database: "fixture", collection: "many"))
        #expect(main.sidebar.reveal(kind))
        main.sidebar.openCollection(nil)
        let collection = try #require(main.selectedTab?.content as? MongoCollectionController)
        #expect(await eventually(timeout: 20) { collection.loading == nil })
        collection.bar.filter.stringValue = "{ n: { $gte: 500 } }"
        collection.bar.sort.stringValue = "{ n: 1 }"
        let window = try #require(MongoExplainWindow.explain(collection))
        #expect(await eventually(timeout: 20) { !window.isRunning })
        let found = try #require(window.explainView, "\(window.problem ?? "")")
        #expect(found.plan.operations != nil && found.warnings.contains { $0.hasPrefix("Reads the whole collection") })
        #expect(found.warnings.contains { $0.hasPrefix("Sorts in memory") }, "\(found.warnings)")
        window.close()
        #expect(MongoExplainWindow.open.isEmpty)

        // The tab closes with its session; Disconnect then leaves nothing running.
        main.close(try #require(main.tabs.first { $0.content === tab }))
        #expect(await eventually(timeout: 10) { !main.tabs.contains { $0.content === tab } })
        #expect(await call(harness, "menu", ["path": "Connection > Disconnect"]).error == nil)
        #expect(await eventually(timeout: 10) { main.model.openMongo[mongo.saved.id] == nil })
    }
}

// MARK: Pictures

extension AppTests {
    @MainActor @Suite(.enabled(if: MongoLab.enabled && ProcessInfo.processInfo.environment["AIRSQL_SCREENSHOTS"] == "1"))
    struct MongoAggregationScreenshotTests {
        @Test func aggregationScreens() async throws {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let (main, harness, mongo) = try await aggregationWindow()
                main.window?.appearance = NSAppearance(named: appearance)
                let tab = try await openAggregation("many", main, harness, mongo)
                await run(tab, "[\n  { $match: { n: { $lt: 40 } } },\n  {\n    $group: {\n      _id: { $mod: [\"$n\", 4] },\n"
                          + "      count: { $sum: 1 },\n      total: { $sum: \"$n\" }\n    }\n  },\n  { $sort: { _id: 1 } }\n]")
                main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
                main.window?.orderFront(nil)
                try await save(harness, "mongo-aggregation-\(suffix)")
                await run(tab, "[\n  { $match: { n: { $lt: 40 } } },\n  { $sort: { n: -1 } }\n]", explain: true)
                try await save(harness, "mongo-aggregation-explain-\(suffix)")
                main.close(try #require(main.tabs.first { $0.content === tab }))
                main.window?.orderOut(nil)
            }
        }

        private func save(_ harness: AgentServer, _ name: String) async throws {
            let reply = await call(harness, "screenshot", ["target": "main", "scale": 2])
            let image = try #require(reply.image, "\(name): \(reply.error ?? "")")
            try #require(image.representation(using: .png, properties: [:])).write(to: ScreenshotTests.folder.appendingPathComponent(name + ".png"))
        }
    }
}

extension AppTests {
    /// A pipeline ending in $out or $merge writes: a read-only connection refuses it, and otherwise nothing runs until
    /// the preview sheet is approved (Run and Explain alike, since executionStats runs it).
    @Test(.enabled(if: MongoLab.enabled)) func aWritingPipelineIsRefusedOrPreviewedFirst() async throws {
        let (main, harness, mongo) = try await aggregationWindow()
        let tab = try await openAggregation("many", main, harness, mongo)
        let target = "agg_out_\(UUID().uuidString.prefix(8))"
        let session = try await mongo.connection.session(.main)
        func written() async throws -> Bool {
            try await session.listCollections(database: "fixture").contains { $0.name == target }
        }

        let index = try #require(tab.model.data.connections.firstIndex { $0.id == mongo.saved.id })
        tab.model.data.connections[index].readOnly = true
        for explain in [false, true] {
            tab.editor.string = "[{ $match: {} }, { $out: \"\(target)\" }]"
            if explain { tab.explain() } else { tab.run() }
            #expect(tab.problem == "$out writes to a collection, and this connection is read-only.", "\(tab.problem ?? "")")
            #expect(main.window?.attachedSheet == nil)
        }

        tab.model.data.connections[index].readOnly = false
        tab.editor.string = "[{ $match: {} }, { $merge: { into: \"\(target)\" } }]"
        tab.run()
        #expect(await eventually(timeout: 5) { main.window?.attachedSheet?.windowController is SQLPreviewSheet })
        #expect(try await !written())
        #expect(await call(harness, "press", ["id": "preview.cancel"]).error == nil)
        #expect(await eventually(timeout: 5) { main.window?.attachedSheet == nil })
        #expect(try await !written())
    }
}
