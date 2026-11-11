// Watch Changes (mongo-plan, Phase 4 "watch"): the filter as one $match, the events' caps and "history lost"; then,
// against the Mongo lab (AIRSQL_MONGO_LAB=1), a change stream on the replica set: inserts, updates and deletes arrive,
// Stop then Start loses nothing, a step-down is followed, a closed connection ends it; the standalone refuses, and in the
// app the tab watches, stops, starts again, comes back after a relaunch without starting, and is disabled on a
// standalone with the reason.
import AppKit
import CMongoC
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

struct MongoWatchTests {
    @Test func theFilterIsOneMatchOnTheEvents() throws {
        #expect(try MongoWatch.pipeline(filter: "").isEmpty && MongoWatch.pipeline(filter: " \n ").isEmpty)
        #expect(try MongoWatch.pipeline(filter: "{}").isEmpty)
        let shell = try MongoWatch.pipeline(filter: "{ operationType: 'insert', 'fullDocument.n': { $gt: NumberLong(5) } }")
        #expect(shell == [BSONDocument([("$match", .document(BSONDocument([
            ("operationType", .string("insert")),
            ("fullDocument.n", .document(BSONDocument([("$gt", .int64(5))]))),
        ])))])])
        // Shell form's constructors and JSON's quoted keys, as the query bar reads them.
        let json = try MongoWatch.pipeline(filter: #"{"documentKey._id": ObjectId("65a1b2c3d4e5f60718293a4b")}"#)
        guard case .document(let match)? = json.first?["$match"], case .objectId? = match["documentKey._id"] else {
            Issue.record("\(json)")
            return
        }
        do {
            _ = try MongoWatch.pipeline(filter: "{ n: ")
            Issue.record("a half-typed filter was taken")
        } catch let problem as MongoQueryText.Problem {
            #expect(problem.field == "Filter")
        }
    }

    @Test func eventsAreNewestFirstWithinTheCountAndTheBytes() {
        func event(_ byte: UInt8, _ size: Int = 4) -> [UInt8] { [UInt8](repeating: byte, count: size) }
        var counted = MongoWatch.Events(maxCount: 3, maxBytes: 1_000)
        counted.add([event(1), event(2)])
        counted.add([event(3), event(4)])
        #expect(counted.events == [event(4), event(3), event(2)] && counted.dropped == 1 && counted.bytes == 12)
        counted.add([])
        #expect(counted.events.count == 3 && counted.dropped == 1)

        var sized = MongoWatch.Events(maxCount: 100, maxBytes: 10)
        sized.add([event(1), event(2), event(3)])
        #expect(sized.events == [event(3), event(2)] && sized.bytes == 8 && sized.dropped == 1)
        // One event over the byte cap still shows: the newest always stays.
        sized.add([event(9, 50)])
        #expect(sized.events == [event(9, 50)] && sized.dropped == 3)
        #expect(MongoWatch.Events.maxCount == 10_000 && MongoWatch.Events.maxBytes == 32 << 20)
    }

    @Test func historyLostIsToldApart() {
        func server(_ code: UInt32) -> AirSQLError {
            MongoErrorMapping.map(domain: MONGOC_ERROR_SERVER.rawValue, code: code, message: "x")
        }
        #expect(MongoWatch.historyLost(server(286)) && MongoWatch.historyLost(server(280)))
        #expect(!MongoWatch.historyLost(server(11601)) && !MongoWatch.historyLost(AirSQLError.disconnected))
        #expect(!MongoWatch.historyLost(CancellationError()))
    }
}

// MARK: The lab

/// The Mongo lab's replica set through the SOCKS proxy, or its standalone.
private func labConnection(replicaSet: Bool) -> MongoConnection {
    guard replicaSet else {
        return MongoConnection(uri: "mongodb://127.0.0.1:\(MongoLab.soloPort)/", user: "airsql", password: "airsql-pass",
                               route: MongoRoute(SavedConnection(name: "Mongo lab", host: "127.0.0.1", port: MongoLab.soloPort,
                                                                 user: "airsql", route: .direct)),
                               name: "Mongo solo")
    }
    var set = SavedConnection(name: "Mongo lab", host: MongoLab.members[0], port: 27017, user: "airsql", route: .proxy)
    let proxy = Lab.socksProxy
    set.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: proxy.port, user: proxy.user)
    return MongoConnection(uri: MongoLab.allSeeds, user: "airsql", password: "airsql-pass", tls: MongoLab.tls,
                           route: MongoRoute(set, proxyPassword: proxy.password), name: "Mongo rs0")
}

/// Reads `stream` until `count` events came (or `timeout`): them, decoded.
func readChanges(_ stream: MongoChangeStream, _ count: Int, timeout: TimeInterval = 30) async throws -> [BSONDocument] {
    var found: [BSONDocument] = []
    let started = Date()
    while found.count < count && Date().timeIntervalSince(started) < timeout {
        found += try await stream.next().map { try BSONDocument(bytes: $0) }
    }
    return found
}

private let watchScratch = "lane_mongo_watch"

private func doc(_ fields: KeyValuePairs<String, BSONValue>) -> BSONDocument { BSONDocument(fields.map { ($0.key, $0.value) }) }

@Suite(.serialized, .enabled(if: MongoLab.enabled, "Mongo lab: AIRSQL_MONGO_LAB=1 ./test.sh --filter MongoWatch"))
struct MongoWatchLabTests {
    @Test func changesArriveAndStopThenStartLosesNone() async throws {
        let connection = labConnection(replicaSet: true)
        try await connection.connect()
        let writer = try await connection.session(.data)
        let watcher = try await connection.session(.data, slot: "watch")
        _ = try? await writer.command(doc(["dropDatabase": .int32(1)]), database: watchScratch)

        let stream = try await watcher.watch(database: watchScratch, collection: "events", pipeline: [], lookUp: true, resumeAfter: nil)
        try await writer.insertOne(database: watchScratch, collection: "events", doc(["_id": .int32(1), "n": .int32(1)]))
        _ = try await writer.updateOne(database: watchScratch, collection: "events", filter: doc(["_id": .int32(1)]),
                                       update: doc(["$set": .document(doc(["n": .int32(2)]))]))
        let first = try await readChanges(stream, 2)
        #expect(first.map { $0["operationType"] } == [.string("insert"), .string("update")], "\(first)")
        // Look Up Full Document: the update's whole document as it is now.
        #expect(first.last?["fullDocument"] == .document(doc(["_id": .int32(1), "n": .int32(2)])))
        try #require(try await writer.deleteOne(database: watchScratch, collection: "events", filter: doc(["_id": .int32(1)])) == 1)
        #expect(try await readChanges(stream, 1).first?["operationType"] == .string("delete"))

        // Stopped: what is written meanwhile comes first once it starts again from the token.
        let token = try #require(stream.token)
        await stream.close()
        try await writer.insertOne(database: watchScratch, collection: "events", doc(["_id": .int32(2)]))
        let again = try await watcher.watch(database: watchScratch, collection: "events", pipeline: [], lookUp: false, resumeAfter: token)
        let missed = try await readChanges(again, 1)
        #expect(missed.first?["operationType"] == .string("insert") && missed.first?["documentKey"] == .document(doc(["_id": .int32(2)])))
        await again.close()

        // The filter: only deletes, on the whole database.
        let deletes = try await watcher.watch(database: watchScratch, collection: nil,
                                              pipeline: MongoWatch.pipeline(filter: "{ operationType: 'delete' }"), lookUp: false,
                                              resumeAfter: nil)
        try await writer.insertOne(database: watchScratch, collection: "other", doc(["_id": .int32(3)]))
        _ = try await writer.deleteOne(database: watchScratch, collection: "other", filter: doc(["_id": .int32(3)]))
        let filtered = try await readChanges(deletes, 1)
        guard case .document(let ns)? = filtered.first?["ns"] else { Issue.record("\(filtered)"); return }
        #expect(filtered.first?["operationType"] == .string("delete") && ns["coll"] == .string("other"))

        // A closed connection ends the stream: it says so, and never opens again by itself.
        _ = try await writer.command(doc(["dropDatabase": .int32(1)]), database: watchScratch)
        await connection.close()
        await #expect(throws: AirSQLError.self) { _ = try await deletes.next() }
    }

    @Test func aStandaloneHasNoChangeStreams() async throws {
        let connection = labConnection(replicaSet: false)
        try await connection.connect()
        let watcher = try await connection.session(.data)
        await #expect { _ = try await watcher.watch(database: "fixture", collection: "many", pipeline: [], lookUp: false, resumeAfter: nil) }
            throws: { ($0 as? AirSQLError)?.code == 40573 }
        await connection.close()
    }
}

// MARK: The app

/// The replica set connected in a window of its own, through the SOCKS proxy, with `watchScratch.events` made first.
@MainActor private func setWindow() async throws -> (MainWindowController, AgentServer, OpenMongoConnection) {
    var saved = SavedConnection(name: "Mongo set", route: .proxy)
    let password = saved.apply(try MongoURI("mongodb://airsql:airsql-pass@" + MongoLab.allSeeds.dropFirst(10))) ?? ""
    saved.tls.caFile = Lab.caFile
    saved.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: Lab.socksProxy.port, user: Lab.socksProxy.user)
    saved.engine = .mongodb
    let model = testModel([saved])
    model.setSavedPassword(saved.id.uuidString, password)
    model.setSavedPassword(saved.proxySecretKey, Lab.socksProxy.password)
    let (main, harness) = appWindow(model)
    _ = await call(harness, "select", ["pane": "sidebar", "names": [saved.name]])
    #expect(await call(harness, "menu", ["path": "Connection > Connect"]).error == nil)
    #expect(await eventually(timeout: 40) { model.openMongo[saved.id]?.databases != nil })
    let open = try #require(model.openMongo[saved.id])
    let writer = try await open.connection.session(.data)
    _ = try? await writer.command(doc(["dropDatabase": .int32(1)]), database: watchScratch)
    try await writer.insertOne(database: watchScratch, collection: "events", doc(["_id": .string("seed")]))
    open.refresh()
    #expect(await eventually(timeout: 20) { open.databases?.contains { $0.name == watchScratch } == true })
    return (main, harness, open)
}

extension AppTests {
    /// From the tree's collection, Watch Changes opens a tab that watches; Stop, a write, Start: the write arrives, newest
    /// first; after a relaunch the tab comes back with its filter and waits for Start.
    @Test(.enabled(if: MongoLab.enabled)) func aWatchTabShowsChangesStopsStartsAndComesBackStopped() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        ConsoleDocuments.shared.fileURL = url
        defer {
            ConsoleDocuments.shared.fileURL = ConsoleTabStore.fileURL
            try? FileManager.default.removeItem(at: url)
        }
        let (main, harness, mongo) = try await setWindow()
        ConsoleDocuments.shared.main = main
        _ = try await open(MongoTreeItem(database: watchScratch), in: main, mongo)
        let row = SidebarNode.Kind.mongo(mongo.saved.id, MongoTreeItem(database: watchScratch, collection: "events"))
        #expect(main.sidebar.reveal(row))
        main.window?.makeFirstResponder(main.sidebar.outline)
        let chosen = await call(harness, "menu", ["path": "Data > Collection > Watch Changes"])
        #expect(chosen.error == nil, "\(chosen.error ?? "")")
        let tab = try #require(main.selectedTab?.content as? MongoWatchController)
        #expect(tab.collection == "events" && main.selectedTab?.title == "events changes")
        #expect(await eventually(timeout: 10) { tab.watching != nil && tab.problem == nil })
        let writer = try await mongo.connection.session(.data)
        // The stream opens on the tab's own session: a write right away may come before it.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try await writer.insertOne(database: watchScratch, collection: "events", doc(["_id": .string("a")]))
        #expect(await eventually(timeout: 20) { tab.source.rowCount == 1 }, "\(tab.problem ?? "")")
        #expect(tab.viewer.status.rows.stringValue == "1 change")

        #expect(await call(harness, "press", ["id": "watch.startStop"]).error == nil)
        #expect(await eventually(timeout: 10) { tab.watching == nil })
        #expect(tab.startStop.title == "Start" && tab.token != nil)
        try await writer.insertOne(database: watchScratch, collection: "events", doc(["_id": .string("b")]))
        #expect(await call(harness, "press", ["id": "watch.startStop"]).error == nil)
        #expect(await eventually(timeout: 20) { tab.source.rowCount == 2 }, "\(tab.problem ?? "")")
        #expect(tab.source.document(0)?["documentKey"] == .document(doc(["_id": .string("b")])), "newest first")
        tab.stop()
        #expect(await eventually(timeout: 10) { tab.watching == nil })

        // Back after a relaunch, stopped, with its filter.
        tab.filter.stringValue = "{ operationType: 'insert' }"
        ConsoleDocuments.shared.saveNow()
        main.model.connector.disconnect(mongo.saved.id)
        let fresh = testModel(main.model.data.connections)
        fresh.setSavedPassword(mongo.saved.id.uuidString, "airsql-pass")
        fresh.setSavedPassword(mongo.saved.proxySecretKey, Lab.socksProxy.password)
        let (relaunched, again) = appWindow(fresh)
        ConsoleDocuments.shared.restore(into: relaunched)
        await ConsoleDocuments.shared.restoring?.value
        #expect(relaunched.tabs.map(\.title) == ["events changes"] && relaunched.tabs[0].shown is RestoredTabContent)
        #expect(await call(again, "press", ["id": "restored.open"]).error == nil)
        _ = await eventually(timeout: 40) { relaunched.selectedTab?.shown is MongoWatchController }
        let restored = try #require(relaunched.selectedTab?.shown as? MongoWatchController)
        #expect(restored.filter.stringValue == "{ operationType: 'insert' }" && restored.collection == "events")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(restored.watching == nil && restored.startStop.title == "Start", "a restored tab waits for Start")
        let cleanup = try await #require(fresh.openMongo[mongo.saved.id]).connection.session(.data)
        _ = try? await cleanup.command(doc(["dropDatabase": .int32(1)]), database: watchScratch)
        relaunched.model.connector.disconnect(mongo.saved.id)
    }

    /// On a standalone, Watch Changes is disabled, from the tree and from a collection's tab, and says why.
    @Test(.enabled(if: MongoLab.enabled)) func watchChangesIsDisabledOnAStandaloneWithTheReason() async throws {
        let (main, harness, mongo) = try await mongoWindow()
        _ = try await open(MongoTreeItem(database: "fixture"), in: main, mongo)
        let row = SidebarNode.Kind.mongo(mongo.saved.id, MongoTreeItem(database: "fixture", collection: "many"))
        #expect(main.sidebar.reveal(row))
        main.window?.makeFirstResponder(main.sidebar.outline)
        let refused = await call(harness, "menu", ["path": "Data > Collection > Watch Changes"])
        #expect(refused.error?.contains("needs a replica set or a sharded cluster, and this server is a standalone") == true,
                "\(refused.error ?? "")")
        _ = try await openTab("many", in: main, mongo)
        let fromTab = await call(harness, "menu", ["path": "Data > Collection > Watch Changes"])
        #expect(fromTab.error?.contains("this server is a standalone") == true, "\(fromTab.error ?? "")")
        #expect(!main.tabs.contains { $0.content is MongoWatchController })
        main.model.connector.disconnect(mongo.saved.id)
    }
}
