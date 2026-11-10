// MongoDB in the main window around a collection tab: the toolbar's SQL controls say "Not for MongoDB".
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

        /// The database, the transaction mode, Run All, Explain, Commit and Roll Back are SQL's; Run and Cancel stay for a
        /// collection tab, and say so.
        @Test func theToolbarsSQLControlsAreNotForMongoDB() async throws {
            let (main, _, _) = await Self.window()
            let toolbar = try #require(main.window?.toolbar)
            func button(_ id: NSToolbarItem.Identifier) -> NSControl? {
                toolbar.items.first { $0.itemIdentifier == id }?.view as? NSControl
            }
            main.toolbarController.update()
            toolbar.validateVisibleItems()
            for id in [NSToolbarItem.Identifier.runAll, .explain, .commit, .rollback] {
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
            #expect(button(.commit)?.toolTip == "No transaction is open in this tab")
            #expect(main.toolbarController.databasePopup.toolTip != NotForMongo.reason)
        }
    }
}
