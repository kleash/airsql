// The aggregation tab's Stages mode (docs/dev/mongo-plan.md, Phase 5 B), against the Mongo lab (AIRSQL_MONGO_LAB=1):
// a Join and a Group built on the cards over `shop` give what plain finds add up to; a hand-written pipeline opens with
// its $facet as a Shell card and its text as it was; reordering, removing and editing a card keep every other stage's
// text byte for byte; a join of an ObjectId with text warns; and its pictures (AIRSQL_SCREENSHOTS=1 too).
import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

/// The Mongo lab's standalone or replica set (through the SOCKS proxy) connected in a window, `shop`'s collections read.
@MainActor private func shopWindow(replicaSet: Bool) async throws -> (MainWindowController, OpenMongoConnection, AgentServer) {
    var saved: SavedConnection
    var password = MongoLab.airsql.password
    if replicaSet {
        saved = SavedConnection(name: "Mongo set stages", route: .proxy)
        password = saved.apply(try MongoURI("mongodb://airsql:airsql-pass@" + MongoLab.allSeeds.dropFirst(10))) ?? ""
        saved.tls.caFile = Lab.caFile
        saved.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: Lab.socksProxy.port, user: Lab.socksProxy.user)
    } else {
        saved = SavedConnection(name: "Shop · MongoDB", host: "127.0.0.1", port: MongoLab.soloPort, user: MongoLab.airsql.user)
        saved.tls.mode = .off
    }
    saved.engine = .mongodb
    let model = testModel([saved])
    model.setSavedPassword(saved.id.uuidString, password)
    if replicaSet { model.setSavedPassword(saved.proxySecretKey, Lab.socksProxy.password) }
    let (main, harness) = appWindow(model)
    _ = await call(harness, "select", ["pane": "sidebar", "names": [saved.name]])
    #expect(await call(harness, "menu", ["path": "Connection > Connect"]).error == nil)
    #expect(await eventually(timeout: 40) { model.openMongo[saved.id]?.databases != nil })
    let mongo = try #require(model.openMongo[saved.id])
    mongo.loadDatabase("shop")
    #expect(await eventually(timeout: 20) { mongo.collections["shop"] != nil })
    return (main, mongo, harness)
}

@MainActor private func stagesTab(_ collection: String, _ main: MainWindowController, _ mongo: OpenMongoConnection) async throws
    -> MongoAggregationController {
    main.openAggregation(collection, database: "shop", connection: mongo.saved.id)
    let tab = try #require(main.selectedTab?.content as? MongoAggregationController)
    #expect(await eventually(timeout: 20) { tab.loading == nil })
    return tab
}

/// What a person's click or Return does to a control: its action.
@MainActor private func fire(_ control: NSControl?) {
    guard let control, let action = control.action else {
        Issue.record("no control")
        return
    }
    NSApp.sendAction(action, to: control.target, from: control)
}

@MainActor private func control<T: NSControl>(_ type: T.Type, _ id: String, _ tab: MongoAggregationController) -> T? {
    find(type, id: id, in: tab.stagesView)
}

@MainActor private func type(_ text: String, into id: String, _ tab: MongoAggregationController) {
    let box = control(NSTextField.self, id, tab)
    box?.stringValue = text
    fire(box)
}

extension AppTests {
    /// orders JOIN customers, one document per match, GROUP BY the customer's country with SUM(total), built on the
    /// cards and run, against the same sums worked out from plain finds of both collections.
    @Test(.enabled(if: MongoLab.enabled), arguments: [false, true])
    func aJoinAndAGroupBuiltOnTheCardsGiveTheFindsSums(replicaSet: Bool) async throws {
        let (main, mongo, _) = try await shopWindow(replicaSet: replicaSet)
        let tab = try await stagesTab("orders", main, mongo)
        #expect(tab.mode == .stages && tab.stagesView.forms.count == 1, "a new tab opens on its cards")
        tab.stagesView.remove(0)
        #expect(tab.editor.string == "[]" && tab.stagesView.cards.isEmpty)

        tab.stagesView.add(.join, at: 0)
        let from = try #require(control(NSPopUpButton.self, "stage.0.join.from", tab))
        from.selectItem(withTitle: "customers")
        fire(from)
        type("customerId", into: "stage.0.join.local", tab)
        type("_id", into: "stage.0.join.foreign", tab)
        type("customer", into: "stage.0.join.as", tab)
        let perMatch = try #require(control(NSButton.self, "stage.0.join.perMatch", tab))
        perMatch.state = .on
        fire(perMatch)
        #expect(tab.stagesView.forms.count == 2 && tab.stagesView.forms[1] == .unwind(.init(path: "customer")))

        tab.stagesView.add(.group, at: 2)
        fire(control(NSButton.self, "stage.2.group.addBy", tab))
        type("customer.country", into: "stage.2.group.by.0", tab)
        let op = try #require(control(NSPopUpButton.self, "stage.2.group.op.0", tab))
        op.selectItem(at: MongoStageForm.Accumulator.allCases.firstIndex(of: .sum)!)
        fire(op)
        type("total", into: "stage.2.group.field.0", tab)
        #expect(tab.stagesView.forms[2] == .group(.init(by: ["customer.country"], outputs: [.init(.sum, "total")])), "\(tab.stagesView.forms)")
        #expect(tab.stagesView.firstProblem == nil, "\(tab.stagesView.firstProblem ?? "")")
        let stages = try MongoPipeline.stages(in: tab.editor.string).map(\.document)
        #expect(stages.map { $0.shellForm() } == [
            "{ $lookup: { from: \"customers\", localField: \"customerId\", foreignField: \"_id\", as: \"customer\" } }",
            "{ $unwind: \"$customer\" }",
            "{ $group: { _id: \"$customer.country\", sum_total: { $sum: \"$total\" } } }",
        ], "\(tab.editor.string)")
        #expect(MongoStageForm.forms(from: stages).map { MongoStagesView.Kind($0) } == [.join, .unwind, .group])

        // A Filter card first, its condition in rows: WHERE status IN the paid ones; the other stages' text stays.
        let built = tab.editor.string
        tab.stagesView.add(.filter, at: 0)
        let rows = try #require(tab.stagesView.cards.first?.conditions)
        rows.group = MongoBuilder.Group([.rule(.init("status", .oneOf, ["paid", "shipped", "delivered"]))])
        rows.onChange?()
        let first = try MongoPipeline.stages(in: tab.editor.string).first?.document
        let wanted = try BSONDocument(shellForm: "{ $match: { status: { $in: [\"paid\", \"shipped\", \"delivered\"] } } }")
        #expect(first == wanted, "\(first?.shellForm() ?? "")")
        #expect(tab.editor.string.hasSuffix(String(built.dropFirst(4))), "\(tab.editor.string)")
        let paid: Set<String> = ["paid", "shipped", "delivered"]

        tab.run()
        #expect(await eventually(timeout: 30) { tab.loading == nil })
        #expect(tab.problem == nil, "\(tab.problem ?? "")")
        var got: [String: Decimal] = [:]
        for row in 0..<tab.source.rowCount {
            let document = try #require(tab.source.document(row))
            guard case .string(let country)? = document["_id"], case .decimal128(let sum)? = document["sum_total"] else {
                Issue.record("\(document.shellForm())")
                continue
            }
            got[country] = Decimal(string: sum.description)
        }

        // The oracle: both collections read with find, joined and summed here.
        let session = try await mongo.connection.session(.data)
        let customers = try await session.all(session.find(database: "shop", collection: "customers"))
        let orders = try await session.all(session.find(database: "shop", collection: "orders"))
        var country: [String: String] = [:]
        for c in customers { if case .objectId(let id)? = c["_id"], case .string(let land)? = c["country"] { country[id.hex] = land } }
        var expected: [String: Decimal] = [:]
        for o in orders {
            guard case .objectId(let id)? = o["customerId"], let land = country[id.hex], case .decimal128(let total)? = o["total"],
                  case .string(let status)? = o["status"], paid.contains(status) else { continue }
            expected[land, default: 0] += Decimal(string: total.description) ?? .nan
        }
        #expect(!expected.isEmpty && got == expected, "\(got) ≠ \(expected)")
        main.close(try #require(main.tabs.first { $0.content === tab }))
    }

    /// A hand-written pipeline: its $facet is a Shell card of its own text; switching modes, moving, removing and
    /// editing a card change only the stages they are about.
    @Test(.enabled(if: MongoLab.enabled)) func aHandWrittenPipelineKeepsItsTextOnTheCards() async throws {
        let (main, mongo, _) = try await shopWindow(replicaSet: false)
        let tab = try await stagesTab("orders", main, mongo)
        let match = "{ $match: { status: \"paid\" } }"
        let facet = "{   $facet: {\n      byStatus: [ { $sortByCount: \"$status\" } ],   n: [{$count:'n'}]\n  }   }"
        let limit = "{ $limit:   5 }"
        let text = "[\n  \(match),\n  \(facet),\n\n  \(limit)\n]\n"
        tab.show(.shell)
        tab.replacePipeline(text)
        tab.show(.stages)
        #expect(tab.mode == .stages && tab.editor.string == text, "switching modes doesn't touch the text")
        let forms = tab.stagesView.forms
        #expect(forms.count == 3 && MongoStagesView.Kind(forms[1]) == .shell && forms[2] == .limit(5), "\(forms)")
        #expect(tab.stagesView.cards[1].shellEditor?.string == facet, "the Shell card has the stage's own text")
        tab.show(.shell)
        tab.show(.stages)
        #expect(tab.editor.string == text)

        // Move the $limit up: the two swap, as written; the rest stays.
        tab.stagesView.move(2, by: -1)
        #expect(tab.editor.string == "[\n  \(match),\n  \(limit),\n\n  \(facet)\n]\n", "\(tab.editor.string)")
        // Edit the limit's card: only its stage is written again.
        type("7", into: "stage.1.limit", tab)
        #expect(tab.editor.string == "[\n  \(match),\n  { $limit: 7 },\n\n  \(facet)\n]\n", "\(tab.editor.string)")
        // Remove the $match: the others as they were.
        tab.stagesView.remove(0)
        #expect(tab.editor.string == "[\n  { $limit: 7 },\n\n  \(facet)\n]\n", "\(tab.editor.string)")
        // A Shell card's text goes in as typed.
        let editor = try #require(tab.stagesView.cards[1].shellEditor)
        let typed = "{ $facet: { n: [ {$count:'n'} ] } }"
        editor.string = typed
        editor.didChangeText()
        #expect(tab.editor.string == "[\n  { $limit: 7 },\n\n  \(typed)\n]\n", "\(tab.editor.string)")
        editor.string = "{ $facet: "
        editor.didChangeText()
        #expect(tab.stagesView.cards[1].problemText != nil && tab.editor.string.contains(typed), "a stage that doesn't parse isn't written")

        // Text that isn't a pipeline stays in Shell, saying why.
        tab.show(.shell)
        tab.replacePipeline("[{ $match: ")
        tab.show(.stages)
        #expect(tab.mode == .shell && tab.problem?.hasPrefix("The pipeline isn't one the cards can show") == true, "\(tab.problem ?? "")")
        #expect(tab.editor.string == "[{ $match: ")
        main.close(try #require(main.tabs.first { $0.content === tab }))
    }

    /// Joining orders' ObjectId customerId with customers' text name: the card says nothing will match.
    @Test(.enabled(if: MongoLab.enabled)) func aJoinOfAnObjectIdWithTextWarns() async throws {
        let (main, mongo, _) = try await shopWindow(replicaSet: false)
        let tab = try await stagesTab("orders", main, mongo)
        tab.replacePipeline("[{ $lookup: { from: \"customers\", localField: \"customerId\", foreignField: \"name\", as: \"customer\" } }]")
        tab.updateBars()
        let card = try #require(tab.stagesView.cards.first)
        #expect(MongoStagesView.Kind(card.form) == .join)
        #expect(await eventually(timeout: 20) {
            card.warnings.stringValue.contains("‘customerId’ is an ObjectId here but ‘name’ is text in customers")
        }, "\(card.warnings.stringValue)")
        #expect(card.warnings.stringValue.contains("customers has no index starting with ‘name’"), "\(card.warnings.stringValue)")
        #expect(!card.warnings.isHidden)
        type("_id", into: "stage.0.join.foreign", tab)
        #expect(card.warnings.isHidden, "\(card.warnings.stringValue)")
        main.close(try #require(main.tabs.first { $0.content === tab }))
    }
}

// MARK: Pictures

extension AppTests {
    @MainActor @Suite(.enabled(if: MongoLab.enabled && ProcessInfo.processInfo.environment["AIRSQL_SCREENSHOTS"] == "1"))
    struct MongoStagesScreenshotTests {
        @Test func stagesScreens() async throws {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let (main, mongo, harness) = try await shopWindow(replicaSet: false)
                main.window?.appearance = NSAppearance(named: appearance)
                let tab = try await stagesTab("orders", main, mongo)
                tab.replacePipeline("""
                    [
                      { $match: { status: { $in: ["paid", "shipped", "delivered"] } } },
                      { $lookup: { from: "customers", localField: "customerId", foreignField: "_id", as: "customer" } },
                      { $unwind: "$customer" },
                      { $group: { _id: "$customer.country", sum_total: { $sum: "$total" }, count: { $sum: 1 } } },
                      { $sort: { sum_total: -1 } },
                      { $limit: 5 }
                    ]
                    """)
                tab.updateBars()
                tab.countStages()
                #expect(await eventually(timeout: 30) { tab.loading == nil && tab.count(ofStage: 6) != nil })
                tab.run()
                #expect(await eventually(timeout: 30) { tab.loading == nil })
                main.window?.setContentSize(NSSize(width: 1180, height: 900))
                main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
                main.window?.orderFront(nil)
                // The Filter and Join cards, then the Group card.
                let top = await call(harness, "screenshot", ["target": "main", "scale": 2])
                let topImage = try #require(top.image)
                try #require(topImage.representation(using: .png, properties: [:]))
                    .write(to: ScreenshotTests.folder.appendingPathComponent("mongo-stages-\(suffix).png"))
                let group = tab.stagesView.cards[3].box
                group.scrollToVisible(group.bounds)
                let reply = await call(harness, "screenshot", ["target": "main", "scale": 2])
                let image = try #require(reply.image, "\(reply.error ?? "")")
                try #require(image.representation(using: .png, properties: [:]))
                    .write(to: ScreenshotTests.folder.appendingPathComponent("mongo-stages-group-\(suffix).png"))
                // The SQL page, translated and run.
                tab.show(.sql)
                tab.sqlPage.editor.string = "SELECT c.country, SUM(o.total) AS revenue, COUNT(*) AS orders\nFROM orders o JOIN customers c ON o.customerId = c._id\n"
                    + "WHERE o.status IN ('paid', 'shipped', 'delivered')\nGROUP BY c.country ORDER BY revenue DESC LIMIT 5"
                tab.sqlPage.translate(thenRun: true)
                if main.window?.attachedSheet != nil { _ = await call(harness, "press", ["title": "Replace"]) }
                #expect(await eventually(timeout: 30) { tab.loading == nil && tab.source.rowCount == 5 })
                let sql = await call(harness, "screenshot", ["target": "main", "scale": 2])
                let sqlImage = try #require(sql.image)
                try #require(sqlImage.representation(using: .png, properties: [:]))
                    .write(to: ScreenshotTests.folder.appendingPathComponent("mongo-sql-\(suffix).png"))
                main.close(try #require(main.tabs.first { $0.content === tab }))
                main.window?.orderOut(nil)
            }
        }
    }
}

// MARK: Query with SQL

extension AppTests {
    /// Query with SQL… on the tree's reviews: the starter SELECT runs; a refusal is underlined; a JOIN + GROUP BY + HAVING
    /// gives the oracle's average rating per category; a pipeline edited by hand is asked about before it is replaced;
    /// Open as Stages shows Join, Unwind and Group cards.
    @Test(.enabled(if: MongoLab.enabled)) func aSelectWithAJoinAndAGroupGivesTheOraclesAnswerAndOpensAsStages() async throws {
        let (main, mongo, harness) = try await shopWindow(replicaSet: false)
        let shop = try #require(main.sidebar.treeNodes[.mongo(mongo.saved.id, MongoTreeItem(database: "shop"))])
        main.sidebar.outline.expandItem(shop)
        #expect(await eventually(timeout: 20) { !mongo.isLoading })
        #expect(main.sidebar.reveal(.mongo(mongo.saved.id, MongoTreeItem(database: "shop", collection: "reviews"))))
        main.window?.makeFirstResponder(main.sidebar.outline)
        #expect(await call(harness, "menu", ["path": "Data > Collection > Query with SQL…"]).error == nil)
        let tab = try #require(main.selectedTab?.content as? MongoAggregationController)
        #expect(tab.collection == "reviews" && tab.mode == .sql && tab.sqlPage.editor.string == "SELECT * FROM reviews LIMIT 100")
        #expect(await eventually(timeout: 20) { tab.loading == nil && tab.source.rowCount == 100 }, "\(tab.problem ?? "")")
        #expect(try MongoPipeline.stages(in: tab.editor.string).map(\.name).last == "$limit", "\(tab.editor.string)")
        #expect(try MongoPipeline.stages(in: tab.editor.string).map(\.document) == MongoPipeline.stages(in: tab.sqlPage.pipeline.string).map(\.document))

        // Refused, with the part underlined; another collection's FROM is said so.
        tab.sqlPage.editor.string = "SELECT * FROM reviews WHERE rating IN (SELECT 1)"
        tab.runStatement(nil)
        #expect(tab.problem?.contains("Subqueries") == true && tab.sqlPage.editor.runProblem != nil, "\(tab.problem ?? "")")
        tab.sqlPage.editor.string = "SELECT * FROM orders"
        tab.runStatement(nil)
        #expect(tab.problem?.hasPrefix("This tab's pipeline runs on reviews") == true, "\(tab.problem ?? "")")

        // The oracle's q08.
        tab.sqlPage.editor.string = """
            SELECT p.category, COUNT(*) AS reviews, AVG(r.rating) AS average FROM reviews r JOIN products p ON r.productSku = p.sku
            GROUP BY p.category HAVING COUNT(*) >= 20 ORDER BY p.category
            """
        tab.runStatement(nil)
        #expect(await eventually(timeout: 30) { tab.loading == nil })
        #expect(tab.problem == nil, "\(tab.problem ?? "")")
        let q08 = try #require(MongoSQLLabTests.answers()["q08_avg_rating_by_category"] as? [[String: Any]])
        let rows = (0..<tab.source.rowCount).compactMap { tab.source.document($0) }
        #expect(rows.map { $0["category"] } == q08.map { .string($0["category"] as! String) })
        #expect(rows.map { MongoSQLLabTests.number($0["reviews"]) } == q08.map { Double($0["reviews"] as! Int) })
        #expect(rows.map { MongoSQLLabTests.number($0["average"]).map { ($0 * 100).rounded() / 100 } }
                == q08.map { ($0["average"] as! NSNumber).doubleValue })
        #expect(!tab.sqlPage.notes.isHidden && tab.sqlPage.notes.stringValue.contains("GROUP BY"), "\(tab.sqlPage.notes.stringValue)")

        // Edited by hand: translating asks first, and Cancel keeps the edit.
        let edited = tab.editor.string.replacingOccurrences(of: "\n]", with: ",\n  { $limit: 3 }\n]")
        tab.replacePipeline(edited)
        tab.sqlPage.translate(thenRun: false)
        #expect(await eventually(timeout: 5) { main.window?.attachedSheet != nil })
        #expect(await call(harness, "press", ["title": "Cancel"]).error == nil)
        #expect(await eventually(timeout: 5) { main.window?.attachedSheet == nil })
        #expect(tab.editor.string == edited)

        // Open as Stages: Replace, then the cards.
        tab.sqlPage.openAsStages(nil)
        #expect(await eventually(timeout: 5) { main.window?.attachedSheet != nil })
        #expect(await call(harness, "press", ["title": "Replace"]).error == nil)
        #expect(await eventually(timeout: 5) { tab.mode == .stages })
        let kinds = tab.stagesView.forms.map { MongoStagesView.Kind($0) }
        #expect(Array(kinds.prefix(3)) == [.join, .unwind, .group], "\(tab.editor.string)")
        #expect(try MongoPipeline.stages(in: tab.editor.string).map(\.document) == MongoPipeline.stages(in: tab.sqlPage.pipeline.string).map(\.document))
        main.close(try #require(main.tabs.first { $0.content === tab }))
    }
}
