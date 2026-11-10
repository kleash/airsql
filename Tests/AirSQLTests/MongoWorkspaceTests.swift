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

    /// A dropped route is reported as a MySQL one is: the connection marked, its sessions closed, a tab's pending
    /// changes kept with Apply saying to connect again, nothing run again; Connect makes it anew.
    @Test(.enabled(if: MongoLab.enabled)) func aDroppedMongoDBConnectionIsReportedAndKeepsPendingChanges() async throws {
        let (main, harness, mongo) = try await mongoWindow()
        let id = mongo.saved.id, model = main.model
        _ = try await open(MongoTreeItem(database: "fixture"), in: main, mongo)
        let tab = try await openTab("many", in: main, mongo)
        #expect(tab.change { try $0.insert(BSONDocument([("_id", .string("p2-liveness"))])) } == nil)
        #expect(mongo.keepAlive?.isValid == true)

        mongo.connection.route.onExit?(AirSQLError(.disconnected, "The SSH tunnel closed: the network went away."))
        #expect(await eventually(timeout: 5) { model.openMongo[id] == nil })
        #expect(model.states[id] == .failed("The SSH tunnel closed: the network went away.") && mongo.keepAlive?.isValid == false)
        #expect(await eventually(timeout: 10) { await (try? mongo.connection.session(.main)) == nil }, "its sessions are closed")
        #expect(!tab.changes.isEmpty && main.selectedTab?.content === tab)
        tab.applyChanges(nil)
        let sheet = try #require(main.window?.attachedSheet)
        main.window?.endSheet(sheet)
        #expect(!tab.changes.isEmpty)

        _ = await call(harness, "select", ["pane": "sidebar", "names": [mongo.saved.name]])
        #expect(await call(harness, "menu", ["path": "Connection > Connect"]).error == nil)
        #expect(await eventually(timeout: 30) { model.openMongo[id] != nil })
        #expect(!tab.changes.isEmpty && tab.connection != nil && model.openMongo[id] !== mongo)
        model.connector.disconnect(id)
    }
}

/// Liveness (mongo-plan, Phase 2): the route's ssh ending is reported, its planned restart for a new member is not, and
/// the keep-alive's `hello` fails once the route is gone.
@Suite(.serialized, .enabled(if: MongoLab.enabled, "Mongo lab: AIRSQL_MONGO_LAB=1 ./test.sh --filter Mongo"))
struct MongoLivenessLabTests {
    final class Exits: @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [String] = []
        var messages: [String] { lock.locked { _messages } }
        func add(_ error: AirSQLError) { lock.locked { _messages.append(error.message) } }
    }

    private func connection(_ uri: String, route: Route) throws -> MongoConnection {
        var saved = SavedConnection(name: "Mongo liveness", host: MongoLab.members[0], port: 27017, user: "airsql", route: route)
        saved.sshHost = SSHHop(host: Lab.bastion.host, port: Lab.bastion.port, user: Lab.bastion.user, login: .keyFile, keyFile: Lab.key)
        saved.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: Lab.socksProxy.port, user: Lab.socksProxy.user)
        let askpass = route == .ssh ? try RouteTesting.askpass(for: saved.id) : nil
        return MongoConnection(uri: uri, user: MongoLab.airsql.user, password: MongoLab.airsql.password, tls: MongoLab.tls,
                               route: MongoRoute(saved, proxyPassword: Lab.socksProxy.password, askpass: askpass), name: saved.name)
    }

    @Test func aMemberRestartIsNoDropAndSSHEndingIs() async throws {
        let connection = try connection(MongoLab.oneSeed, route: .ssh)
        let exits = Exits()
        connection.route.onExit = { exits.add($0) }
        try await connection.connect()
        // One seed: ssh started again once the members were known, which isn't a drop.
        #expect(connection.route.logins == 2 && exits.messages.isEmpty)
        // A server not forwarded yet starts ssh once more: the sockets the old one carried go, and the next hello
        // connects again.
        _ = try connection.route.socket(host: MongoLab.solo, port: 27017)
        #expect(connection.route.logins == 3)
        #expect(await connection.isAlive())
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(exits.messages.isEmpty, "\(exits.messages)")

        // ssh ending by itself (the network went away) is.
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", connection.route.base]
        try kill.run()
        kill.waitUntilExit()
        #expect(await eventually(timeout: 10) { !exits.messages.isEmpty })
        #expect(exits.messages.first?.hasPrefix("The SSH tunnel closed") == true, "\(exits.messages)")
        await connection.close()
    }

    @Test func theKeepAliveFailsOnceTheRouteIsGone() async throws {
        let connection = try connection(MongoLab.allSeeds, route: .proxy)
        try await connection.connect()
        #expect(await connection.isAlive())
        connection.route.close()
        #expect(await !connection.isAlive())
        await connection.close()
    }
}

/// Waits until `body` gives a value (10 s at most).
@MainActor private func eventuallyValue<T>(_ body: @escaping () -> T?) async throws -> T {
    _ = await eventually(timeout: 10) { body() != nil }
    return try #require(body())
}
