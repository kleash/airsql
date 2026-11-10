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
}
