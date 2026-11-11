// MongoDB in the app (docs/dev/mongo-plan.md, lane M2): the query bar's fields, its history, field completion and the
// schema's figures; then, against the Mongo lab (AIRSQL_MONGO_LAB=1), the tree, a collection tab's pages, filters,
// errors, the schema of the seed, JSON, the value panel's tree, sub-documents, copying and Cancel; and its pictures
// (AIRSQL_SCREENSHOTS=1 too).
import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

struct MongoAppTests {
    @Test func theQueryBarReadsEveryFieldAndSaysWhichIsWrong() throws {
        let full = MongoQueryText(filter: "{ n: { $gt: NumberLong(5) } }", projection: "{ n: 1 }", sort: "{ n: -1 }", limit: " 10 ",
                                  skip: "2", collation: "{ locale: 'en', strength: 2 }", hint: "n_1", maxTimeMS: "500")
        let find = try full.find()
        #expect(find.filter == BSONDocument([("n", .document(BSONDocument([("$gt", .int64(5))])))]))
        #expect(find.projection == BSONDocument([("n", .int32(1))]) && find.sort == BSONDocument([("n", .int32(-1))]))
        #expect(find.limit == 10 && find.skip == 2 && find.maxTimeMS == 500 && find.hint == .string("n_1"))
        #expect(find.collation?["strength"] == .int32(2))
        #expect(try MongoQueryText(hint: "\"n_1\"").find().hint == .string("n_1"))
        #expect(try MongoQueryText(hint: "{ n: 1 }").find().hint == .document(BSONDocument([("n", .int32(1))])))
        // Empty: every document, nothing else.
        let empty = try MongoQueryText().find()
        #expect(empty.filter.fields.isEmpty && empty.projection == nil && empty.limit == nil && empty.hint == nil)
        for (bad, field) in [(MongoQueryText(filter: "{ n: "), "Filter"), (MongoQueryText(sort: "[1]"), "Sort"),
                             (MongoQueryText(limit: "-1"), "Limit"), (MongoQueryText(skip: "two"), "Skip"),
                             (MongoQueryText(maxTimeMS: "1.5"), "Max Time"), (MongoQueryText(hint: "{ n: "), "Hint")] {
            #expect(throws: MongoQueryText.Problem.self, "\(bad)") { try bad.find() }
            do { _ = try bad.find() } catch let problem as MongoQueryText.Problem { #expect(problem.field == field, "\(problem)") }
        }
        #expect(full.summary.hasPrefix("{ n: { $gt: NumberLong(5) } } · project { n: 1 } · sort { n: -1 }"))
        #expect(MongoQueryText().summary == "{} (every document)")
    }

    @Test func theHistoryKeepsTheNewestQueriesAndTheFavourites() async throws {
        let folder = URL(fileURLWithPath: TestEnvironment.root).appendingPathComponent("mongo-history-\(UUID().uuidString)")
        let history = MongoQueryHistory(directory: folder, limit: 2)
        let id = UUID()
        let (a, b, c) = (MongoQueryText(filter: "{ a: 1 }"), MongoQueryText(filter: "{ b: 1 }"), MongoQueryText(filter: "{ c: 1 }"))
        history.add(a, connection: id, database: "d", collection: "x")
        history.setFavourite(true, a, connection: id, database: "d", collection: "x")
        for query in [b, c, b] { history.add(query, connection: id, database: "d", collection: "x") }
        history.add(c, connection: id, database: "d", collection: "other")
        history.flush()
        var kept = await history.entries(id, database: "d", collection: "x")
        // Newest first, a run again moves up, the favourite stays beyond the limit.
        #expect(kept.map(\.query) == [b, c, a] && kept.map(\.favourite) == [false, false, true])
        history.add(MongoQueryText(filter: "{ d: 1 }"), connection: id, database: "d", collection: "x")
        history.clear(id, database: "d", collection: "x")
        history.flush()
        kept = await history.entries(id, database: "d", collection: "x")
        #expect(kept.map(\.query) == [a])
        #expect(await history.entries(id, database: "d", collection: "other").count == 1)
        let mode = try FileManager.default.attributesOfItem(atPath: history.file(id).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test @MainActor func theSchemaSaysEachFieldsTypesAndRange() {
        let documents = [BSONDocument([("n", .int32(1)), ("tag", .string("a"))]), BSONDocument([("n", .double(2.5)), ("tag", .null)]),
                         BSONDocument([("n", .int32(1))])]
        let schema = MongoSchema(sample: documents)
        let n = schema["n"]!, tag = schema["tag"]!
        #expect(MongoSchemaView.text(n, "types", of: 3) == "int 67%, double 33%")
        #expect(MongoSchemaView.text(n, "min", of: 3) == "1" && MongoSchemaView.text(n, "max", of: 3) == "2.5")
        #expect(MongoSchemaView.text(n, "top", of: 3) == "1 (2), 2.5 (1)")
        #expect(MongoSchemaView.text(tag, "nulls", of: 3) == "1" && MongoSchemaView.text(tag, "missing", of: 3) == "1")
    }
}

// MARK: The lab

    /// The standalone of the Mongo lab, connected in a window of its own; rows per page `pageSize`.
    @MainActor func mongoWindow(pageSize: Int = 100) async throws -> (MainWindowController, AgentServer, OpenMongoConnection) {
        var solo = SavedConnection(name: "Mongo solo", host: "127.0.0.1", port: MongoLab.soloPort, user: MongoLab.airsql.user)
        solo.engine = .mongodb
        solo.tls.mode = .off
        let model = testModel([solo])
        model.data.settings.rowsPerPage = pageSize
        model.setSavedPassword(solo.id.uuidString, MongoLab.airsql.password)
        let (main, harness) = appWindow(model)
        _ = await call(harness, "select", ["pane": "sidebar", "names": [solo.name]])
        #expect(await call(harness, "menu", ["path": "Connection > Connect"]).error == nil)
        #expect(await eventually(timeout: 30) { model.openMongo[solo.id]?.databases != nil })
        return (main, harness, try #require(model.openMongo[solo.id]))
    }

    /// Opens a tree row (the reads its arrow starts) and waits until what is under it has been read.
    @MainActor func open(_ item: MongoTreeItem, in main: MainWindowController, _ mongo: OpenMongoConnection) async throws -> SidebarNode {
        let node = try #require(main.sidebar.treeNodes[.mongo(mongo.saved.id, item)], "\(item)")
        main.sidebar.outline.expandItem(node)
        #expect(await eventually(timeout: 20) { !mongo.isLoading })
        return try #require(main.sidebar.treeNodes[.mongo(mongo.saved.id, item)])
    }

    /// Opens a collection in its own tab with a double-click on its row, and waits for its first documents.
    @MainActor func openTab(_ collection: String, in main: MainWindowController, _ mongo: OpenMongoConnection) async throws -> MongoCollectionController {
        let kind = SidebarNode.Kind.mongo(mongo.saved.id, MongoTreeItem(database: "fixture", collection: collection))
        #expect(main.sidebar.reveal(kind))
        main.sidebar.treeDoubleClicked(try #require(main.sidebar.treeNodes[kind]))
        let content = try #require(main.selectedTab?.content as? MongoCollectionController)
        #expect(await eventually(timeout: 20) { content.loading == nil })
        #expect(content.problem == nil, "\(content.problem ?? "")")
        return content
    }

extension AppTests {
    @Test(.enabled(if: MongoLab.enabled)) func aMongoTreeShowsTheSeedAndACollectionTabPagesFiltersAndCancels() async throws {
        let (main, harness, mongo) = try await mongoWindow()
        let id = mongo.saved.id
        #expect(mongo.databases?.map(\.name).contains("fixture") == true)
        let fixture = try await open(MongoTreeItem(database: "fixture"), in: main, mongo)
        let kinds = Dictionary(uniqueKeysWithValues: (mongo.collections["fixture"] ?? []).map { ($0.name, $0.kind) })
        #expect(kinds["all_types"] == .collection && kinds["names_ci"] == .collection && kinds["many"] == .collection)
        #expect(kinds["all_types_names"] == .view && kinds["readings"] == .timeseries)
        #expect(fixture.children.compactMap(\.name).contains("readings") && mongo.stats["fixture"] != nil)
        // Views and time-series say they're read-only; a database shows its size once opened.
        for (name, words) in [("all_types_names", "a view, read-only"), ("readings", "a time-series collection, read-only")] {
            let row = main.sidebar.outline.row(forItem: main.sidebar.treeNodes[.mongo(id, MongoTreeItem(database: "fixture", collection: name))])
            let cell = try #require(main.sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? TreeCell)
            #expect(cell.toolTip?.contains(words) == true, "\(cell.toolTip ?? "")")
        }
        let many = try await open(MongoTreeItem(database: "fixture", collection: "many"), in: main, mongo)
        #expect(many.children.compactMap(\.name) == ["_id_"])

        // A click previews; a double-click opens its own tab, in place of the preview.
        let manyKind = SidebarNode.Kind.mongo(id, MongoTreeItem(database: "fixture", collection: "many"))
        #expect(main.sidebar.reveal(manyKind, showing: true))
        #expect(await eventually(timeout: 10) { (main.selectedTab?.content as? PreviewContent)?.shown is MongoCollectionController })
        let tab = try await openTab("many", in: main, mongo)
        #expect(!main.tabs.contains { $0.content is PreviewContent && $0.title == "many" })
        #expect(tab.source.rowCount == 100 && tab.total.map { $0.count == 1000 && !$0.exact } == true)
        #expect(tab.viewer.status.rows.stringValue == "100 of about 1,000 documents")

        // Paging: the grid's end reads the next batch; Count Exactly counts.
        tab.dataGridReachedLastRow(tab.grid)
        #expect(await eventually(timeout: 20) { tab.loading == nil && tab.source.rowCount == 200 })
        let counted = await call(harness, "menu", ["path": "Data > Pages > Count Rows Exactly"])
        #expect(counted.error == nil, "\(counted.error ?? "")")
        #expect(await eventually(timeout: 20) { tab.total.map { $0.count == 1000 && $0.exact } == true })

        // A filter runs with ⌘↩ (Query ▸ Run Statement answers for the collection); a bad one says why and runs nothing.
        tab.bar.filter.stringValue = "{ n: { $lt: 5 } }"
        tab.bar.sort.stringValue = "{ n: -1 }"
        #expect(await call(harness, "menu", ["path": "Query > Run Statement"]).error == nil)
        #expect(await eventually(timeout: 20) { tab.loading == nil && tab.source.rowCount == 5 })
        #expect(tab.source.value(0, 1) == "4" && tab.grid.sortOrder.first?.ascending == false)
        #expect(tab.viewer.status.rows.stringValue == "5 documents")
        tab.bar.filter.stringValue = "{ n: "
        tab.run()
        #expect(!tab.bar.problem.isHidden && tab.bar.problem.stringValue.hasPrefix("Filter:") && tab.loading == nil)
        #expect(tab.source.rowCount == 5, "the documents shown stay")
        tab.bar.filter.stringValue = "{ n: { $lt: 5 } }"
        tab.run()
        #expect(await eventually(timeout: 20) { tab.loading == nil && tab.bar.problem.isHidden })

        // The history keeps what ran, newest first.
        MongoQueryHistory.shared.flush()
        let ran = await MongoQueryHistory.shared.entries(id, database: "fixture", collection: "many")
        #expect(ran.first?.query.filter == "{ n: { $lt: 5 } }" && ran.contains { $0.query.filter.isEmpty })

        // JSON: the loaded documents as relaxed Extended JSON.
        #expect(await call(harness, "menu", ["path": "Data > Collection > JSON"]).error == nil)
        #expect(await eventually(timeout: 10) { tab.jsonView.string.contains("\"n\": 4") })
        #expect(tab.page == .json && tab.jsonView.string.hasPrefix("["))

        // Copy Documents: a row as Extended JSON.
        tab.show(.documents)
        tab.grid.selection.select(GridPosition(row: 0, column: 0))
        tab.copyDocuments(nil)
        #expect(NSPasteboard.general.string(forType: .string) == "{\"_id\":4,\"n\":4}")

        // Cancel ends a slow find on the server.
        tab.bar.filter.stringValue = "{ $where: \"sleep(20) || true\" }"
        tab.bar.sort.stringValue = ""
        tab.run()
        #expect(tab.loading != nil && tab.isBusy)
        try await Task.sleep(nanoseconds: 700_000_000)
        let started = Date()
        tab.cancelQuery(nil)
        #expect(await eventually(timeout: 10) { tab.loading == nil })
        #expect(Date().timeIntervalSince(started) < 5 && tab.problem?.hasPrefix("Cancelled") == true, "\(tab.problem ?? "")")
        #expect(main.model.activity.isIdle)

        #expect(await call(harness, "menu", ["path": "Connection > Disconnect"]).error == nil)
        #expect(await eventually(timeout: 10) { main.model.openMongo[id] == nil })
    }

    @Test(.enabled(if: MongoLab.enabled)) func aCollectionsSchemaValuePanelAndSubDocuments() async throws {
        let (main, _, mongo) = try await mongoWindow()
        _ = try await open(MongoTreeItem(database: "fixture"), in: main, mongo)
        let tab = try await openTab("all_types", in: main, mongo)
        #expect(tab.source.rowCount == 19)

        // The schema of the seed: one document per type under `value`, and one with every type, which has none.
        tab.show(.schema)
        #expect(await eventually(timeout: 20) { tab.loading == nil && tab.schemaView.schema != nil })
        let schema = try #require(tab.schemaView.schema)
        #expect(schema.documents == 19)
        let value = try #require(schema["value"])
        #expect(value.present == 18 && value.missing == 1 && value.nulls == 1 && value.types.count == 17)
        #expect(MongoSchemaView.text(try #require(schema["type"]), "types", of: 19) == "string 100%")
        let ids = try #require(schema["_id"])
        #expect(MongoSchemaView.text(ids, "min", of: 19) == "1" && MongoSchemaView.text(ids, "max", of: 19) == "100")
        #expect(tab.knownPaths.contains("value.nested.b") && tab.schemaView.table.numberOfRows == schema.fields.count)
        // A path double-clicked finds the documents that have it.
        tab.schemaView.choose?("value")
        #expect(await eventually(timeout: 20) { tab.loading == nil && tab.page == .documents && tab.source.rowCount == 18 })
        #expect(tab.bar.filter.stringValue == "{ value: { $exists: true } }")

        // The value panel shows a sub-document as a BSON tree.
        let valueColumn = try #require(tab.source.paths.firstIndex(of: ["value"]))
        let object = try #require((0..<tab.source.rowCount).first { tab.source.value($0, 1) == "\"object\"" })
        tab.grid.selection.select(GridPosition(row: object, column: try #require(tab.grid.columnOrder.firstIndex(of: valueColumn))))
        tab.viewer.toggleValuePanel(nil)
        let panel = try #require(tab.viewer.valuePanel)
        #expect(panel.mode == .json && panel.footer.stringValue.hasPrefix("BSON object"))
        let tree = try #require(find(BSONTreeView.self, in: panel))
        #expect(!tree.isHidden && tree.outline.numberOfRows == 3, "the document and its two fields")

        // Expand Field shows a sub-document's fields as columns; again on one of them, one column again.
        let item = Commands.expandField.item()
        item.representedObject = valueColumn
        #expect(tab.validateMenuItem(item))
        tab.toggleField(item)
        #expect(tab.source.paths.contains(["value", "nested"]) && !tab.source.paths.contains(["value"]))
        item.representedObject = tab.source.paths.firstIndex(of: ["value", "a"])
        #expect(tab.validateMenuItem(item) && item.title == "Collapse Field")
        tab.toggleField(item)
        #expect(tab.source.paths.contains(["value"]))
        tab.close()
    }
}

// MARK: Pictures

extension AppTests {
    @MainActor @Suite(.enabled(if: MongoLab.enabled && ProcessInfo.processInfo.environment["AIRSQL_SCREENSHOTS"] == "1"))
    struct MongoScreenshotTests {
        @Test func mongoScreens() async throws {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let (main, harness, mongo) = try await mongoWindow(pageSize: 1_000)
                main.window?.appearance = NSAppearance(named: appearance)
                _ = try await open(MongoTreeItem(database: "fixture"), in: main, mongo)
                _ = try await open(MongoTreeItem(database: "fixture", collection: "all_types"), in: main, mongo)
                let tab = try await openTab("all_types", in: main, mongo)
                tab.grid.selection.select(GridPosition(row: 2, column: min(2, tab.grid.columnCount - 1)))
                tab.viewer.toggleValuePanel(nil)
                main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
                main.window?.orderFront(nil)
                try await save(harness, "mongo-collection-\(suffix)")
                tab.show(.schema)
                #expect(await eventually(timeout: 20) { tab.loading == nil && tab.schemaView.schema != nil })
                try await save(harness, "mongo-schema-\(suffix)")
                tab.show(.json)
                #expect(await eventually(timeout: 10) { !tab.jsonView.string.isEmpty })
                try await save(harness, "mongo-json-\(suffix)")
                tab.close()
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
