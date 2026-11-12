// MongoDB in the main window around a collection tab: the toolbar's SQL controls say "Not for MongoDB"; the tree hides
// system.* collections and lists MongoDB's own databases last (the Mongo lab, AIRSQL_MONGO_LAB=1).
import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

extension AppTests {
    @MainActor @Suite struct MongoWindowTests {
        /// A window with a MongoDB connection (never connected: the port leads nowhere) and a MySQL one, the MongoDB one
        /// selected.
        static func window() async -> (MainWindowController, AgentServer, SavedConnection) {
            var mongo = SavedConnection(name: "Documents", host: "127.0.0.1", port: 1, user: "root")
            mongo.engine = .mongodb
            let model = testModel([mongo] + Fixtures.shop)
            let (main, harness) = appWindow(model)
            _ = await call(harness, "select", ["pane": "sidebar", "names": ["Documents"]])
            return (main, harness, mongo)
        }

        /// The database, the transaction mode, Run All, Commit and Roll Back are SQL's (hidden on macOS 15 and later), Explain
        /// too; Run and Cancel stay for a collection tab, and say so.
        @Test func theToolbarsSQLControlsAreNotForMongoDB() async throws {
            let (main, _, _) = await Self.window()
            let toolbar = try #require(main.window?.toolbar)
            func button(_ id: NSToolbarItem.Identifier) -> NSControl? {
                toolbar.items.first { $0.itemIdentifier == id }?.view as? NSControl
            }
            main.toolbarController.update()
            toolbar.validateVisibleItems()
            let sqlOnly: [NSToolbarItem.Identifier] = [.database, .runAll, .transactionMode, .commit, .rollback]
            func hidden(_ id: NSToolbarItem.Identifier) -> Bool? {
                guard #available(macOS 15.0, *) else { return nil }
                return toolbar.items.first { $0.itemIdentifier == id }?.isHidden
            }
            for id in sqlOnly { #expect(hidden(id) ?? true, "\(id.rawValue)") }
            for id in [NSToolbarItem.Identifier.runAll, .explain, .commit, .rollback] where hidden(id) != true {
                #expect(button(id)?.isEnabled == false && button(id)?.toolTip == NotForMongo.reason, "\(id.rawValue)")
            }
            for popup in [main.toolbarController.databasePopup, main.toolbarController.transactionPopup] {
                #expect(!popup.isEnabled && popup.toolTip == NotForMongo.reason)
            }
            #expect(button(.run)?.isEnabled == false && button(.run)?.toolTip?.hasPrefix("Open a collection") == true)
            #expect(button(.cancel)?.toolTip == "Nothing is running in this tab")
            #expect(main.toolbarController.connectionPopup.isEnabled)
            // A MySQL connection's toolbar is as it was.
            main.sidebar.select([Fixtures.production.id])
            main.toolbarController.update()
            toolbar.validateVisibleItems()
            for id in sqlOnly { #expect(hidden(id) != true, "\(id.rawValue)") }
            #expect(button(.commit)?.toolTip == "No transaction is open in this tab")
            #expect(main.toolbarController.databasePopup.toolTip != NotForMongo.reason)
        }

        /// The log's link and window say Command Log on a MongoDB connection (the same file), SQL Log on MySQL's.
        @Test func theLogIsTheCommandLogOnMongoDB() async throws {
            let (main, harness, _) = await Self.window()
            main.updateStatus()
            #expect(main.statusBar.sqlLog.title == "Command Log")
            #expect(main.statusBar.sqlLog.toolTip?.contains("every command") == true, "\(main.statusBar.sqlLog.toolTip ?? "")")
            main.showSQLLog(nil)  // nothing is connected: the log's window
            let window = try #require(NSApp.windows.first { $0.windowController is SQLLogWindowController && $0.isVisible })
            #expect(window.title == "Command Log")
            _ = await call(harness, "select", ["pane": "sidebar", "names": [Fixtures.production.name]])
            main.updateStatus()
            #expect(main.statusBar.sqlLog.title == "SQL Log")
            main.showSQLLog(nil)
            #expect(window.title == "SQL Log")
            window.close()
        }

        /// BSON null shows as mongosh writes it, `null`, still drawn and marked as null; a MySQL grid keeps its NULL.
        @Test func bsonNullShowsAsNull() throws {
            let source = MongoDocumentSource()
            source.append([try BSONDocument([(key: "_id", value: .int32(1)), (key: "v", value: .null)]).bytes(),
                           try BSONDocument([(key: "_id", value: .int32(2)), (key: "v", value: .int32(3))]).bytes()])
            let viewer = GridViewer(source: nil)
            let sqlNull = viewer.grid.nullText
            viewer.show(source)
            #expect(viewer.grid.nullText == "null" && source.cell(0, 1) == .null && source.value(0, 1) == nil)
            #expect(source.columns[1].marks.contains(.nullable) && source.columns[1].type == "int")
            #expect(GridViewer(source: nil).grid.nullText == sqlNull && sqlNull == "NULL")
        }

        /// The tree leaves out system.* collections (the fixture's view and time-series make system.views and
        /// system.buckets.readings), and lists admin, config and local after the person's databases, quieter.
        @Test(.enabled(if: MongoLab.enabled)) func theTreeHidesSystemCollectionsAndListsMongoDBsOwnLast() async throws {
            let (main, harness, mongo) = try await mongoWindow()
            let names = mongo.databases?.map(\.name) ?? []
            let own = names.drop(while: { !["admin", "config", "local"].contains($0) })
            #expect(names.contains("fixture") && Set(own) == ["admin", "config", "local"], "\(names)")
            let fixture = try await open(MongoTreeItem(database: "fixture"), in: main, mongo)
            #expect(fixture.children.compactMap(\.name).contains("readings"))
            #expect(!fixture.children.compactMap(\.name).contains { $0.hasPrefix("system.") } && mongo.collections["fixture"]?
                .contains { $0.name.hasPrefix("system.") } == false)
            let admin = try #require(main.sidebar.treeNodes[.mongo(mongo.saved.id, MongoTreeItem(database: "admin"))])
            let cell = try #require(main.sidebar.outline.view(atColumn: 0, row: main.sidebar.outline.row(forItem: admin),
                                                              makeIfNecessary: true) as? TreeCell)
            #expect(cell.toolTip?.hasPrefix("admin, MongoDB's own database") == true, "\(cell.toolTip ?? "")")
            #expect(cell.textField?.textColor == .secondaryLabelColor)
            main.sidebar.select([mongo.saved.id])
            let disconnect = await call(harness, "menu", ["path": "Connection > Disconnect"])
            #expect(disconnect.error == nil, "\(disconnect.error ?? "")")
        }
    }
}
