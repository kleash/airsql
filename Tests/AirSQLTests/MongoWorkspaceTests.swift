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

        // Away from the collection's row without a click on the connection, which would show its server page.
        main.sidebar.outline.deselectAll(nil)
        #expect(main.sidebar.selectedNodes.isEmpty && main.selectedTab?.content === tab)
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

/// Sessions (mongo-plan, Phase 2): the route's ssh ending is reported, its planned restart for a new member is not, and
/// the keep-alive's `hello` fails once the route is gone; reads follow the read preference.
@Suite(.serialized, .enabled(if: MongoLab.enabled, "Mongo lab: AIRSQL_MONGO_LAB=1 ./test.sh --filter Mongo"))
struct MongoSessionLabTests {
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

    /// readPreference in the connection string sends reads to a secondary, which the cursor names; writes and a
    /// transaction's reads stay on the primary.
    @Test func readsFollowTheReadPreference() async throws {
        let scratch = "lane_mongo_p2int_rp"
        let secondary = try connection(MongoLab.allSeeds + "&readPreference=secondary", route: .proxy)
        let server = try await secondary.connect()
        let data = try await secondary.session(.data)
        let cursor = try await data.find(database: "fixture", collection: "many", MongoFind(limit: 3))
        #expect(try await cursor.next().count == 3)
        let member = try #require(cursor.secondary)
        #expect(MongoLab.members.contains { member.hasPrefix($0) } && member != server.primary, "\(member)")
        #expect(try await data.count(database: "fixture", collection: "many") == 1000)
        #expect(try await data.distinct(database: "fixture", collection: "all_types", key: "type").count == 19)
        try await data.insertOne(database: scratch, collection: "rp", BSONDocument([("_id", .int32(1))]))
        try await data.startTransaction()
        #expect(try await data.find(database: scratch, collection: "rp").secondary == nil)
        try await data.abortTransaction()
        _ = try await data.command(BSONDocument([("dropDatabase", .int32(1))]), database: scratch)
        await secondary.close()

        let primary = try connection(MongoLab.allSeeds, route: .proxy)
        try await primary.connect()
        #expect(try await primary.session(.data).find(database: "fixture", collection: "many").secondary == nil)
        await primary.close()
    }
}

/// X.509 logins (mongo-plan, Phase 2): the connection string says MONGODB-X509 and the client certificate goes to TLS.
struct MongoX509Tests {
    @Test func anX509LoginIsInTheAddressBothWays() throws {
        var saved = SavedConnection(name: "Certs")
        saved.engine = .mongodb
        _ = saved.apply(try MongoURI("mongodb://db1:27017/?tls=true&authMechanism=MONGODB-X509&tlsCertificateKeyFile=%2Ftmp%2Fme.pem"
                                     + "&authSource=%24external"))
        #expect(saved.mongoX509 && saved.tls.certFile == "/tmp/me.pem" && saved.mongoOptions.isEmpty)
        let uri = saved.mongoURI
        #expect(uri.option("authMechanism") == "MONGODB-X509" && uri.option("authSource") == nil && uri.option("tls") == "true")
        saved.mongoX509 = false
        #expect(saved.mongoURI.option("authMechanism") == nil && saved.mongoURI.option("authSource") == "$external")
    }

    /// The lab CA's client certificate (CN=airsql-lab-client) logs in to the replica set as $external's user of that
    /// name, made for the test and dropped after.
    @Test(.enabled(if: MongoLab.enabled)) func theClientCertificateLogsIn() async throws {
        let pem = TestEnvironment.root + "/mongo-x509-\(UUID().uuidString).pem"
        try (String(contentsOfFile: Lab.clientCertificate, encoding: .utf8) + String(contentsOfFile: Lab.clientKey, encoding: .utf8))
            .write(toFile: pem, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: pem) }
        var saved = SavedConnection(name: "Mongo X.509", host: MongoLab.members[0], port: 27017, route: .proxy)
        saved.engine = .mongodb
        saved.mongoHosts = MongoLab.members.dropFirst().map { $0 + ":27017" }
        saved.replicaSet = "rs0"
        saved.mongoX509 = true
        saved.tls = TLSOptions(mode: .verifyIdentity, caFile: Lab.caFile, certFile: pem)
        saved.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: Lab.socksProxy.port, user: Lab.socksProxy.user)
        func connection(user: String?, password: String?, tls: TLSOptions) -> MongoConnection {
            MongoConnection(uri: user == nil ? saved.mongoURI.string : MongoLab.allSeeds, user: user, password: password, tls: tls,
                            route: MongoRoute(saved, proxyPassword: Lab.socksProxy.password), name: saved.name)
        }
        let admin = connection(user: MongoLab.airsql.user, password: MongoLab.airsql.password, tls: MongoLab.tls)
        try await admin.connect()
        let external = try await admin.session(.main)
        let subject = "CN=airsql-lab-client"
        _ = try? await external.command(BSONDocument([("createUser", .string(subject)),
                                                      ("roles", .array([.document(BSONDocument([("role", .string("read")),
                                                                                                ("db", .string("fixture"))]))]))]),
                                        database: "$external")
        var failure: Error?
        do {
            let x509 = connection(user: nil, password: nil, tls: saved.tls)
            let server = try await x509.connect()
            // mongosh too, with `MongoShell.arguments` through the primary's socket: logged in by the certificate alone.
            if let mongosh = MongoShell.find() {
                let home = TestEnvironment.root + "/mongosh-\(UUID().uuidString)"
                defer { try? FileManager.default.removeItem(atPath: home) }
                let socket = try MongoShell.socket(x509.route, saved: saved, primary: server.primary)
                let user = "db.runCommand({connectionStatus: 1}).authInfo.authenticatedUsers[0].user"
                let argv = MongoShell.arguments(saved, mongosh: mongosh, socket: socket).argv + ["--quiet", "--eval", user]
                let ran = await Runner.run(argv, environment: ["HOME": home], timeout: 30)
                #expect(String(decoding: ran.stdout, as: UTF8.self) == subject + "\n", "\(ran.status) \(ran.stderr)")
            }
            let status = try await x509.session(.main).command(BSONDocument([("connectionStatus", .int32(1))]), database: "admin")
            let users: BSONValue? = if case .document(let auth)? = status["authInfo"] { auth["authenticatedUsers"] } else { nil }
            #expect(users == .array([.document(BSONDocument([("user", .string(subject)), ("db", .string("$external"))]))]), "\(status)")
            #expect(try await x509.session(.data).estimatedCount(database: "fixture", collection: "many") == 1000)
            await x509.close()
            // Its key in a file of its own: refused before anything is sent, with what to do.
            let apart = connection(user: nil, password: nil, tls: TLSOptions(mode: .verifyIdentity, caFile: Lab.caFile,
                                                                              certFile: Lab.clientCertificate, keyFile: Lab.clientKey))
            await #expect { try await apart.connect() } throws: { ($0 as? AirSQLError)?.message.contains("one PEM file") == true }
            await apart.close()
        } catch {
            failure = error
        }
        _ = try? await external.command(BSONDocument([("dropUser", .string(subject))]), database: "$external")
        await admin.close()
        if let failure { throw failure }
    }
}

extension AppTests {
    /// The X.509 choice in the editor's General and TLS tabs, and a collection tab read from a secondary, light and dark
    /// (AIRSQL_SCREENSHOTS=1 with the Mongo lab).
    @Test(.enabled(if: MongoLab.enabled && ProcessInfo.processInfo.environment["AIRSQL_SCREENSHOTS"] == "1"))
    func mongoX509AndReadPreferencePictures() async throws {
        func save(_ harness: AgentServer, _ name: String, _ target: String) async throws {
            let image = try #require(await call(harness, "screenshot", ["target": target, "scale": 2]).image, "\(name)")
            try #require(image.representation(using: .png, properties: [:]))
                .write(to: ScreenshotTests.folder.appendingPathComponent(name + ".png"))
        }
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            var set = SavedConnection(name: "Mongo set", host: MongoLab.members[0], port: 27017, user: MongoLab.airsql.user,
                                      route: .proxy)
            set.engine = .mongodb
            set.mongoHosts = MongoLab.members.dropFirst().map { $0 + ":27017" }
            set.replicaSet = "rs0"
            set.mongoOptions = "readPreference=secondary"
            set.tls = TLSOptions(mode: .verifyIdentity, caFile: Lab.caFile)
            set.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: Lab.socksProxy.port, user: Lab.socksProxy.user)
            let model = testModel([set])
            model.setSavedPassword(set.id.uuidString, MongoLab.airsql.password)
            model.setSavedPassword(set.proxySecretKey, Lab.socksProxy.password)
            let (main, harness) = appWindow(model)
            main.window?.appearance = NSAppearance(named: appearance)
            main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
            main.window?.orderFront(nil)

            var x509 = set
            x509.mongoX509 = true
            x509.tls.certFile = "/Users/me/certs/reports-client.pem"
            let editor = ConnectionEditor.show(x509, isNew: false, model: model, on: try #require(main.window)) { _, _ in }
            try await save(harness, "mongo-x509-general-\(suffix)", "sheet")
            _ = await call(harness, "press", ["title": "TLS"])
            try await save(harness, "mongo-x509-tls-\(suffix)", "sheet")
            if let sheet = editor.window { main.window?.endSheet(sheet) }

            _ = await call(harness, "select", ["pane": "sidebar", "names": [set.name]])
            #expect(await call(harness, "menu", ["path": "Connection > Connect"]).error == nil)
            #expect(await eventually(timeout: 30) { model.openMongo[set.id]?.databases != nil })
            let mongo = try #require(model.openMongo[set.id])
            _ = try await open(MongoTreeItem(database: "fixture"), in: main, mongo)
            let tab = try await openTab("many", in: main, mongo)
            #expect(tab.viewer.status.rows.stringValue.contains(" · from mongo-rs"), "\(tab.viewer.status.rows.stringValue)")
            try await save(harness, "mongo-secondary-\(suffix)", "main")
            model.connector.disconnect(set.id)
            main.window?.orderOut(nil)
        }
    }
}

/// Waits until `body` gives a value (10 s at most).
@MainActor private func eventuallyValue<T>(_ body: @escaping () -> T?) async throws -> T {
    _ = await eventually(timeout: 10) { body() != nil }
    return try #require(body())
}
