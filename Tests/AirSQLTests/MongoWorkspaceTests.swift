// MongoDB in the window as MySQL is (mongo-plan, Phase 2's integrator list), against the Mongo lab
// (AIRSQL_MONGO_LAB=1): Quick Open and Select in Tree find collections.
import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

extension AppTests {
    /// Quick Open lists the databases and the collections the tree has read, and opens one in its tab; Select in Tree
    /// goes back to the tab's collection.
    @Test(.enabled(if: MongoLab.enabled)) func quickOpenAndSelectInTreeFindMongoDBCollections() async throws {
        let (main, harness, mongo) = try await mongoWindow()
        _ = try await open(MongoTreeItem(database: "fixture"), in: main, mongo)
        #expect(await call(harness, "menu", ["path": "File > Quick Open…"]).error == nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        let sheet = try #require(main.window?.attachedSheet?.windowController as? QuickOpenSheet)
        sheet.field.stringValue = "all_types_names"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let view = try #require(sheet.shown.first)
        #expect(view.name == "all_types_names" && view.place == "View in fixture on Mongo solo", "\(view.place)")
        sheet.field.stringValue = "many"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let many = try #require(sheet.shown.first)
        #expect(many.name == "many" && many.place == "fixture on Mongo solo")
        sheet.close()
        many.open()
        let tab = try #require(main.selectedTab?.content as? MongoCollectionController)
        #expect(tab.name == "many" && tab.database == "fixture")

        main.sidebar.select([mongo.saved.id])
        main.selectInTree(nil)
        let row = SidebarNode.Kind.mongo(mongo.saved.id, MongoTreeItem(database: "fixture", collection: "many"))
        #expect(await eventually(timeout: 5) { main.sidebar.selectedNodes.map(\.kind) == [row] })
        #expect(main.selectedTab?.content === tab)
    }

    /// A relaunch brings a collection tab back with its query bar and page and a pipeline tab with its pipeline, as
    /// placeholders that connect only when the person presses Connect and Open.
    @Test(.enabled(if: MongoLab.enabled)) func mongoDBTabsComeBackAfterARelaunch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        ConsoleDocuments.shared.fileURL = url
        defer {
            ConsoleDocuments.shared.fileURL = ConsoleTabStore.fileURL
            try? FileManager.default.removeItem(at: url)
        }
        let (main, _, mongo) = try await mongoWindow()
        ConsoleDocuments.shared.main = main
        _ = try await open(MongoTreeItem(database: "fixture"), in: main, mongo)
        let tab = try await openTab("many", in: main, mongo)
        let query = MongoQueryText(filter: "{ n: { $lt: 5 } }", sort: "{ n: -1 }")
        tab.bar.query = query
        tab.show(.json)
        main.openAggregation("many", database: "fixture", connection: mongo.saved.id)
        let pipeline = try #require(main.selectedTab?.content as? MongoAggregationController)
        pipeline.editor.string = "[\n  { $match: { n: 7 } }\n]\n"
        ConsoleDocuments.shared.saveNow()
        main.model.connector.disconnect(mongo.saved.id)

        let fresh = testModel(main.model.data.connections)
        fresh.setSavedPassword(mongo.saved.id.uuidString, MongoLab.airsql.password)
        let (relaunched, harness) = appWindow(fresh)
        ConsoleDocuments.shared.restore(into: relaunched)
        await ConsoleDocuments.shared.restoring?.value
        #expect(relaunched.tabs.map(\.title) == ["many", "many pipeline"])
        #expect(relaunched.tabs.allSatisfy { $0.shown is RestoredTabContent } && fresh.states.isEmpty && fresh.openMongo.isEmpty)
        relaunched.window?.layoutIfNeeded()
        let what = find(NSTextField.self, id: "restored.what", in: try #require(relaunched.selectedTab?.shown.view))
        #expect(what?.stringValue == "A pipeline on many in fixture, on Mongo solo")

        #expect(await call(harness, "press", ["id": "restored.open"]).error == nil)
        let restoredPipeline = try await eventuallyValue { relaunched.selectedTab?.shown as? MongoAggregationController }
        #expect(restoredPipeline.editor.string == pipeline.editor.string)
        relaunched.select(relaunched.tabs[0])
        #expect(await call(harness, "press", ["id": "restored.open"]).error == nil)
        let restored = try await eventuallyValue { relaunched.selectedTab?.shown as? MongoCollectionController }
        #expect(restored.bar.query == query && restored.page == .json)
        _ = await eventually(timeout: 20) { restored.loading == nil && restored.source.rowCount == 5 }
        #expect(restored.source.rowCount == 5, "\(restored.source.rowCount) \(restored.problem ?? "") \(restored.shown)")
        relaunched.model.connector.disconnect(mongo.saved.id)
    }
}

/// Waits until `body` gives a value (10 s at most).
@MainActor private func eventuallyValue<T>(_ body: @escaping () -> T?) async throws -> T {
    _ = await eventually(timeout: 10) { body() != nil }
    return try #require(body())
}
