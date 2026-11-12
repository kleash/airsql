// The collection tab's query builder (docs/dev/mongo-plan.md, Phase 5 A, lane P5-query): the bar's Builder | Shell, the
// conditions block driven through its controls, what can't be read staying text, Quick Filter's clauses, Aggregate…'s
// pipeline; then, against the Mongo lab (AIRSQL_MONGO_LAB=1), a built query's count against the server's own, Quick
// Filter and the header's sort in a tab, Aggregate… opening its tab; and the builder's pictures (AIRSQL_SCREENSHOTS=1).
import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

@MainActor
private func notify(_ control: NSControl, in row: ConditionRowView) {
    row.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: control))
}

/// A row filled through its controls: the field typed, the operator chosen, the values typed, Ignore case ticked.
@MainActor
private func fill(_ row: ConditionRowView, _ path: String, _ op: MongoBuilder.Operator, _ values: [String], ignoreCase: Bool = false) {
    row.field.stringValue = path
    notify(row.field, in: row)
    row.opPopup.selectItem(withTitle: op.label)
    row.opPopup.sendAction(row.opPopup.action, to: row.opPopup.target)
    for (box, value) in zip(row.boxes, values) {
        box.stringValue = value
        notify(box, in: row)
    }
    if ignoreCase {
        row.ignoreCase.state = .on
        row.ignoreCase.sendAction(row.ignoreCase.action, to: row.ignoreCase.target)
    }
}

/// "name contains 'customer 1' (ignore case)" and "country is one of DE, FR", built in the bar's conditions.
@MainActor
private func buildCustomers(_ bar: MongoQueryBar) {
    fill(bar.conditions.addCondition(), "name", .contains, ["CUSTOMER 1"], ignoreCase: true)
    fill(bar.conditions.addCondition(), "country", .oneOf, ["DE, FR"])
}

/// The server's own answer, from a filter typed by hand.
private let customersOracle = #"{ name: { $regex: "customer 1", $options: "i" }, country: { $in: ["DE", "FR"] } }"#

struct MongoQueryBuilderTests {
    @Test @MainActor func theBuilderWritesTheFilterAndSwitchingKeepsTheText() throws {
        let bar = MongoQueryBar()
        bar.collection = "customers"
        #expect(bar.mode == .builder && bar.conditions.isDescendant(of: bar) && !bar.filter.isDescendant(of: bar), "a new bar is a builder")
        buildCustomers(bar)
        let filter = try BSONDocument(shellForm: bar.filter.stringValue)
        let group = try #require(MongoBuilder.Group(filter: filter))
        #expect(group.children.count == 2 && !group.any)
        guard case .rule(let name)? = group.children.first, case .rule(let country)? = group.children.last else {
            Issue.record("\(group)")
            return
        }
        #expect(name.op == .contains && name.ignoreCase && name.values == ["CUSTOMER 1"])
        #expect(country.op == .oneOf && country.values == ["DE", "FR"])
        #expect(bar.shellLine.stringValue == "db.customers.find(\(bar.filter.stringValue))")

        // Builder → Shell → Builder: the text stays byte for byte, and the rows read it back.
        let text = bar.query
        bar.setMode(.shell)
        #expect(bar.query == text && bar.filter.isDescendant(of: bar) && !bar.conditions.isDescendant(of: bar))
        bar.setMode(.builder)
        #expect(bar.query == text && bar.conditions.group == group)

        // A bad value marks its row and Run is refused; the text keeps the last good filter.
        let row = bar.conditions.addCondition()
        row.typePopup.selectItem(at: MongoBuilder.ValueType.allCases.firstIndex(of: .number)!)
        row.typePopup.sendAction(row.typePopup.action, to: row.typePopup.target)
        fill(row, "age", .greater, ["x"])
        #expect(bar.builderProblem?.contains("isn't a number") == true, "\(bar.builderProblem ?? "")")
        #expect(!row.message.isHidden && row.message.stringValue == bar.builderProblem && bar.query == text)
        row.boxes[0].stringValue = "30"
        notify(row.boxes[0], in: row)
        #expect(bar.builderProblem == nil && row.message.isHidden && bar.filter.stringValue.contains("age: { $gt: 30 }"), "\(bar.filter.stringValue)")
    }

    @Test @MainActor func aPartTheBuilderCantReadStaysTextAndTheRestStaysGUI() throws {
        let bar = MongoQueryBar()
        bar.collection = "customers"
        bar.query = MongoQueryText(filter: #"{ $where: "this.a > 1" }"#, projection: "{ name: 1 }", sort: "{ name: -1, _id: 1 }",
                                   limit: "5", collation: "{ locale: \"fr\" }", hint: "name_1")
        #expect(bar.asText == ["Filter", "Collation"])
        #expect(bar.filter.isDescendant(of: bar) && !bar.conditions.isDescendant(of: bar))
        #expect(!bar.sort.isDescendant(of: bar) && bar.sortRows.isDescendant(of: bar) && bar.sortRows.arrangedSubviews.count == 2)
        #expect(!bar.projection.isDescendant(of: bar) && bar.showFields.title == "_id, name")
        #expect(bar.collation.isDescendant(of: bar) && !bar.ignoreCase.isDescendant(of: bar) && !bar.textNote.isHidden)
        #expect(bar.shellLine.stringValue == #"db.customers.find({ $where: "this.a > 1" }, { name: 1 }).sort({ name: -1, _id: 1 }).limit(5).collation({ locale: "fr" }).hint("name_1")"#,
                "\(bar.shellLine.stringValue)")
        // A sort row's edit rewrites only the sort; the unreadable filter's text is left alone.
        let before = bar.query
        let first = try #require(bar.sortRows.arrangedSubviews.first as? SortRowView)
        first.direction.selectItem(at: 0)
        first.direction.sendAction(first.direction.action, to: first.direction.target)
        var expected = before
        expected.sort = "{ name: 1, _id: 1 }"
        #expect(bar.query == expected)
        // Cleared, the filter is built here again.
        bar.filter.stringValue = ""
        bar.readText()
        #expect(!bar.asText.contains("Filter") && bar.conditions.isDescendant(of: bar) && bar.conditions.group.children.isEmpty)
        // Ignore case writes the collation it reads back.
        bar.collation.stringValue = ""
        bar.readText()
        bar.ignoreCase.state = .on
        bar.ignoreCase.sendAction(bar.ignoreCase.action, to: bar.ignoreCase.target)
        #expect(MongoBuilder.ignoresCase(try BSONDocument(shellForm: bar.collation.stringValue)) == true)
    }

    @Test @MainActor func quickFilterOffersClausesFromTheValueAndAddsToTheFilter() throws {
        let text = MongoCollectionController.quickFilters(path: "country", value: .string("DE"))
        #expect(text.map(\.title) == ["is", "is not", "greater than", "less than", "contains"])
        #expect(text[0].clause.shellForm() == #"{ country: "DE" }"#)
        #expect(MongoCollectionController.quickFilters(path: "a", value: .null).map(\.title) == ["is", "is not"])
        let sub = BSONValue.document(BSONDocument([("x", .int32(1))]))
        #expect(MongoCollectionController.quickFilters(path: "a", value: sub).map(\.title) == ["is", "is not"])
        let regex = MongoCollectionController.quickFilters(path: "r", value: .regex(pattern: "a", options: ""))
        #expect(regex[0].clause.shellForm().contains("$eq"), "a pattern value compares as a value")

        let old = try BSONDocument(shellForm: #"{ country: "DE" }"#)
        let added = MongoCollectionController.adding(try BSONDocument(shellForm: "{ age: { $gt: 30 } }"), to: old)
        #expect(added.shellForm() == #"{ country: "DE", age: { $gt: 30 } }"#)
        let any = try BSONDocument(shellForm: #"{ $or: [{ a: 1 }, { b: 2 }] }"#)
        let both = MongoCollectionController.adding(BSONDocument([("c", .int32(3))]), to: any)
        #expect(MongoBuilder.Group(filter: both) != nil && both.shellForm().contains("$or") && both.shellForm().contains("c: 3"), "\(both.shellForm())")
        let unread = try BSONDocument(shellForm: #"{ $where: "1" }"#)
        #expect(MongoCollectionController.adding(BSONDocument([("c", .int32(3))]), to: unread)
                == BSONDocument([("$and", .array([.document(unread), .document(BSONDocument([("c", .int32(3))]))]))]))
    }

    @Test @MainActor func aggregateStartsWithTheQuerysStages() throws {
        let find = try MongoQueryText(filter: #"{ country: "DE" }"#, projection: "{ name: 1 }", sort: "{ name: -1 }", limit: "5", skip: "2").find()
        #expect(MongoCollectionController.pipelineText(find) == """
            [
              { $match: { country: "DE" } },
              { $sort: { name: -1 } },
              { $project: { name: 1 } },
              { $skip: 2 },
              { $limit: 5 }
            ]

            """)
        #expect(MongoCollectionController.pipelineText(try MongoQueryText().find()) == "[\n  { $match: {} }\n]\n")
        #expect(MongoQueryBar.shellLine(MongoQueryText(skip: "2", hint: "a_1", maxTimeMS: "100"), collection: "my-coll")
                == #"db.getCollection("my-coll").find({}).skip(2).hint("a_1").maxTimeMS(100)"#)
    }
}

// MARK: The lab

/// The standalone, or the replica set through the SOCKS proxy, connected in a window of its own.
@MainActor private func builderWindow(replicaSet: Bool) async throws -> (MainWindowController, OpenMongoConnection) {
    var saved = SavedConnection(name: "Mongo solo", host: "127.0.0.1", port: MongoLab.soloPort, user: MongoLab.airsql.user)
    var password = MongoLab.airsql.password
    if replicaSet {
        saved = SavedConnection(name: "Mongo set", route: .proxy)
        password = saved.apply(try MongoURI("mongodb://airsql:airsql-pass@" + MongoLab.allSeeds.dropFirst(10))) ?? ""
        saved.tls.caFile = Lab.caFile
        saved.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: Lab.socksProxy.port, user: Lab.socksProxy.user)
    } else {
        saved.tls.mode = .off
    }
    saved.engine = .mongodb
    let model = testModel([saved])
    model.data.settings.rowsPerPage = 1_000
    model.setSavedPassword(saved.id.uuidString, password)
    model.setSavedPassword(saved.proxySecretKey, Lab.socksProxy.password)
    let (main, harness) = appWindow(model)
    _ = await call(harness, "select", ["pane": "sidebar", "names": [saved.name]])
    #expect(await call(harness, "menu", ["path": "Connection > Connect"]).error == nil)
    #expect(await eventually(timeout: 40) { model.openMongo[saved.id] != nil })
    return (main, try #require(model.openMongo[saved.id]))
}

/// shop.customers in a tab, its documents and sample read.
@MainActor private func customersTab(_ main: MainWindowController, _ open: OpenMongoConnection) async throws -> MongoCollectionController {
    main.openCollection(MongoCollectionInfo(name: "customers", kind: .collection), database: "shop", connection: open.saved.id)
    let tab = try #require(main.selectedTab?.content as? MongoCollectionController)
    #expect(await eventually(timeout: 30) { tab.loading == nil && tab.bar.conditions.schema != nil })
    #expect(tab.problem == nil, "\(tab.problem ?? "")")
    return tab
}

extension AppTests {
    @Test(.enabled(if: MongoLab.enabled), arguments: [false, true])
    func aBuiltQueryFindsWhatTheServerCounts(replicaSet: Bool) async throws {
        let (main, open) = try await builderWindow(replicaSet: replicaSet)
        let tab = try await customersTab(main, open)
        #expect(tab.bar.mode == .builder && tab.source.rowCount == 200)
        buildCustomers(tab.bar)
        tab.run()
        #expect(await eventually(timeout: 20) { tab.loading == nil })
        #expect(tab.problem == nil && tab.bar.problem.isHidden, "\(tab.problem ?? tab.bar.problem.stringValue)")
        let expected = try await open.connection.session(.main).count(database: "shop", collection: "customers",
                                                                      filter: try BSONDocument(shellForm: customersOracle))
        #expect(expected > 0 && Int64(tab.source.rowCount) == expected, "\(tab.source.rowCount) vs \(expected): \(tab.bar.filter.stringValue)")
        let countries = (0..<tab.source.rowCount).compactMap { tab.source.bsonValue($0, tab.column("country")) }
        #expect(countries.allSatisfy { $0 == .string("DE") || $0 == .string("FR") })
        tab.close()
    }

    @Test(.enabled(if: MongoLab.enabled)) func quickFilterHeaderSortAndAggregateInACollectionTab() async throws {
        let (main, open) = try await builderWindow(replicaSet: false)
        let tab = try await customersTab(main, open)
        let session = try await open.connection.session(.main)

        // Quick Filter ▸ is: the cell's value replaces the filter, and the builder shows it as a row.
        let country = tab.column("country")
        let first = try #require(tab.source.bsonValue(0, country))
        tab.grid.selection.select(GridPosition(row: 0, column: try #require(tab.grid.columnOrder.firstIndex(of: country))))
        let menu = try #require(tab.quickFilterItem()?.submenu)
        let isItem = try #require(menu.items.first { $0.tag == 0 && $0.title.hasPrefix("country is ") })
        tab.quickFilter(isItem)
        #expect(await eventually(timeout: 20) { tab.loading == nil })
        #expect(tab.bar.filter.stringValue == BSONDocument([("country", first)]).shellForm())
        #expect(tab.bar.conditions.allRows.count == 1 && tab.bar.conditions.allRows[0].rule?.op == .is)
        var expected = try await session.count(database: "shop", collection: "customers", filter: BSONDocument([("country", first)]))
        #expect(Int64(tab.source.rowCount) == expected)

        // ⌥ (Add to Filter) on a tier: both conditions.
        let tier = tab.column("tier")
        let value = try #require(tab.source.bsonValue(0, tier))
        tab.grid.selection.select(GridPosition(row: 0, column: try #require(tab.grid.columnOrder.firstIndex(of: tier))))
        let adding = try #require(tab.quickFilterItem()?.submenu?.items.first { $0.tag == 1 && $0.title.contains("tier is not") })
        #expect(adding.isAlternate && adding.keyEquivalentModifierMask == .option)
        tab.quickFilter(adding)
        #expect(await eventually(timeout: 20) { tab.loading == nil })
        #expect(tab.bar.conditions.allRows.count == 2, "\(tab.bar.filter.stringValue)")
        let both = BSONDocument([("country", first), ("tier", .document(BSONDocument([("$ne", value)])))])
        expected = try await session.count(database: "shop", collection: "customers", filter: both)
        #expect(Int64(tab.source.rowCount) == expected && expected > 0)

        // The header's menu sorts on the server; the builder shows the sort row.
        let headerMenu = try #require(tab.dataGrid(tab.grid, menuFor: .column(tab.column("name"))))
        let descending = try #require(headerMenu.items.first { $0.action == Commands.sortDescending.action })
        tab.sortDescending(descending)
        #expect(await eventually(timeout: 20) { tab.loading == nil })
        #expect(tab.bar.sort.stringValue == "{ name: -1 }" && tab.bar.sortRows.arrangedSubviews.count == 1)
        #expect(tab.source.rowCount > 1 && (tab.source.value(0, tab.column("name")) ?? "") >= (tab.source.value(1, tab.column("name")) ?? ""))

        // Aggregate…: a pipeline tab that starts with the query's stages.
        tab.bar.limit.stringValue = "5"
        tab.aggregateQuery(nil)
        let pipeline = try #require(main.selectedTab?.content as? MongoAggregationController)
        #expect(pipeline.collection == "customers")
        #expect(pipeline.editor.string == "[\n  { $match: \(both.shellForm()) },\n  { $sort: { name: -1 } },\n  { $limit: 5 }\n]\n",
                "\(pipeline.editor.string)")
        pipeline.close()
        tab.close()
    }
}

// MARK: Pictures

extension AppTests.MongoScreenshotTests {
    @Test func queryBuilder() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let (main, open) = try await builderWindow(replicaSet: false)
            main.window?.appearance = NSAppearance(named: appearance)
            main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
            main.window?.orderFront(nil)
            let tab = try await customersTab(main, open)
            buildCustomers(tab.bar)
            let date = tab.bar.conditions.addCondition()
            fill(date, "signupDate", .between, ["2024-01-01", "2024-06-30"])
            tab.bar.query.sort = "{ signupDate: -1 }"
            tab.bar.limit.stringValue = "50"
            tab.run()
            #expect(await eventually(timeout: 20) { tab.loading == nil })
            let harness = AgentServer(main: main, model: main.model)
            let reply = await call(harness, "screenshot", ["target": "main", "scale": 2])
            let image = try #require(reply.image, "\(reply.error ?? "")")
            try #require(image.representation(using: .png, properties: [:]))
                .write(to: AppTests.ScreenshotTests.folder.appendingPathComponent("mongo-builder-\(suffix).png"))
            tab.close()
            main.window?.orderOut(nil)
        }
    }
}
