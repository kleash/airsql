// A MongoDB server's host page (docs/dev/mongo-plan.md, Phase 2 "host"): serverStatus's figures and rates, the
// replica set's members, currentOp's operations and Disk Usage's rows; then, against the Mongo lab (AIRSQL_MONGO_LAB=1),
// the page on the standalone and the replica set, Kill on a slow find, the reader login's fallback, the seed's sizes,
// the timer stopping while hidden; and its pictures (AIRSQL_SCREENSHOTS=1 too).
import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

private func doc(_ fields: KeyValuePairs<String, BSONValue>) -> BSONDocument { BSONDocument(fields.map { ($0.key, $0.value) }) }

struct MongoHostTests {
    @Test func serverStatusGivesFiguresAndRatesBetweenTwoReads() {
        func status(uptime: Int64, inserts: Int64, bytesIn: Int64) -> BSONDocument {
            doc(["host": .string("db1"), "version": .string("7.0.45"), "process": .string("mongod"), "uptime": .double(90_061),
                 "uptimeMillis": .int64(uptime), "storageEngine": .document(doc(["name": .string("wiredTiger")])),
                 "connections": .document(doc(["current": .int32(6), "available": .int32(800), "totalCreated": .int64(40)])),
                 "opcounters": .document(doc(["insert": .int64(inserts), "query": .int64(7)])),
                 "mem": .document(doc(["resident": .int32(126)])), "network": .document(doc(["bytesIn": .int64(bytesIn)])),
                 "wiredTiger": .document(doc(["cache": .document(doc(["bytes currently in the cache": .double(2_000_000)]))]))])
        }
        let first = MongoHost.figures(status(uptime: 10_000, inserts: 100, bytesIn: 1_000), previous: nil)
        func figure(_ name: String, in found: [MongoHost.Figure]) -> MongoHost.Figure? { found.first { $0.name == name } }
        #expect(figure("Version", in: first)?.value == "7.0.45" && figure("Uptime", in: first)?.value == "1 d 1 h")
        #expect(figure("Storage Engine", in: first)?.value == "wiredTiger" && figure("Connections Open", in: first)?.value == "6")
        #expect(figure("Memory Resident", in: first)?.value == DiskUsage.size(126 << 20) && figure("Cache Used", in: first)?.bytes == true)
        #expect(first.allSatisfy { $0.perSecond == nil }, "one read gives no rate")
        #expect(figure("Replica Set", in: first) == nil, "a standalone has none")
        // Two seconds later: 50 inserts, 4,000 bytes in.
        let second = MongoHost.figures(status(uptime: 12_000, inserts: 150, bytesIn: 5_000), previous: status(uptime: 10_000, inserts: 100, bytesIn: 1_000))
        #expect(figure("Inserts", in: second)?.perSecond == 25 && figure("Network In", in: second)?.perSecond == 2_000)
        #expect(figure("Queries", in: second)?.perSecond == 0 && figure("Connections Open", in: second)?.perSecond == nil)
        // A restart in between (counters went down): no rate.
        #expect(figure("Inserts", in: MongoHost.figures(status(uptime: 500, inserts: 3, bytesIn: 9), previous: status(uptime: 10_000, inserts: 100, bytesIn: 1_000)))?
            .perSecond == nil)
    }

    @Test func membersSayTheirStateHealthLagAndPing() {
        let rs = doc(["members": .array([
            .document(doc(["name": .string("a:27017"), "health": .double(1), "stateStr": .string("PRIMARY"), "optimeDate": .datetime(100_000),
                           "self": .bool(true), "uptime": .int32(500)])),
            .document(doc(["name": .string("b:27017"), "health": .double(1), "stateStr": .string("SECONDARY"), "optimeDate": .datetime(97_000),
                           "pingMs": .int64(2), "lastHeartbeatMessage": .string("")])),
            .document(doc(["name": .string("c:27017"), "health": .double(0), "stateStr": .string("(not reachable/healthy)"),
                           "pingMs": .int64(0), "lastHeartbeatMessage": .string("Couldn't get a connection")])),
        ])])
        let members = MongoHost.members(rs)
        #expect(members.map(\.name) == ["a:27017", "b:27017", "c:27017"] && members.map(\.healthy) == [true, true, false])
        #expect(members[0].isSelf && members[0].lag == 0 && members[0].ping == nil && members[0].uptime == 500)
        #expect(members[1].lag == 3 && members[1].ping == 2 && members[1].message == nil)
        #expect(members[2].lag == nil && members[2].message == "Couldn't get a connection")
    }

    @Test func operationsKeepTheirIdsAndTheServersOwnCantBeKilled() {
        let ops = MongoHost.operations([
            doc(["opid": .int32(42), "op": .string("query"), "ns": .string("fixture.many"), "microsecs_running": .int64(2_500_000),
                 "client": .string("10.0.0.5:5000"), "appName": .string("AirSQL"), "planSummary": .string("COLLSCAN"),
                 "command": .document(doc(["find": .string("many"), "comment": .string("airsql:data:1a2b:3")]))]),
            doc(["opid": .int64(43), "op": .string("command"), "desc": .string("conn9"), "client": .string("10.0.0.6:1"),
                 "effectiveUsers": .array([.document(doc(["user": .string("__system"), "db": .string("local")]))])]),
            doc(["opid": .int32(44), "op": .string("none"), "desc": .string("TTLMonitor")]),
            doc(["desc": .string("an idle thread, no opid")]),
        ])
        #expect(ops.map(\.id) == ["42", "43", "44"])
        #expect(ops[0].client == "10.0.0.5:5000 (AirSQL)" && ops[0].description == "airsql:data:1a2b:3" && ops[0].plan == "COLLSCAN")
        #expect(ops[0].microseconds == 2_500_000 && ops[0].opid == .int32(42) && ops[0].killRefusal == nil)
        #expect(ops[1].isInternal && ops[1].killRefusal?.contains("server's own work") == true, "replication's __system")
        #expect(ops[2].isInternal && ops[2].client == nil && ops[2].description == "TTLMonitor")
        #expect(MongoHost.duration(0.35) == "350 ms" && MongoHost.duration(4.21) == "4.2 s" && MongoHost.duration(725) == "12 min 5 s")
    }

    @Test func diskUsageRowsLeaveFreeSpaceOutOfTheDocuments() {
        let db = MongoHost.database("shop", doc(["collections": .int32(3), "objects": .int64(1000), "dataSize": .double(9_000),
                                                "storageSize": .double(8_192), "freeStorageSize": .int32(2_048), "indexSize": .double(4_096)]))
        #expect(db.row == DiskUsageRow(name: "shop", detail: "3 collections", data: 6_144, index: 4_096, free: 2_048, rows: 1000))
        #expect(db.uncompressed == 9_000 && db.row.total == 10_240)
        let one = MongoHost.collection("orders", doc(["count": .int32(1), "size": .int32(50), "storageSize": .int32(4_096),
                                                       "totalIndexSize": .int32(4_096), "nindexes": .int32(1), "capped": .bool(true)]))
        #expect(one.row.detail == "Capped, 1 index" && one.row.data == 4_096 && one.row.free == nil && one.uncompressed == 50)
    }
}

// MARK: The lab

/// A Mongo lab server connected in a window of its own: the standalone (as `login`), or the replica set through the
/// SOCKS proxy.
@MainActor private func hostWindow(replicaSet: Bool = false, login: Lab.Login = MongoLab.airsql, readOnly: Bool = false) async throws
    -> (MainWindowController, AgentServer, OpenMongoConnection) {
    var saved = SavedConnection(name: replicaSet ? "Mongo set" : "Mongo solo", host: "127.0.0.1", port: MongoLab.soloPort, user: login.user)
    var password = login.password
    if replicaSet {
        saved = SavedConnection(name: "Mongo set", route: .proxy)
        password = saved.apply(try MongoURI("mongodb://airsql:airsql-pass@" + MongoLab.allSeeds.dropFirst(10))) ?? ""
        saved.tls.caFile = Lab.caFile
        saved.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: Lab.socksProxy.port, user: Lab.socksProxy.user)
    } else {
        saved.tls.mode = .off
    }
    saved.engine = .mongodb
    saved.readOnly = readOnly
    let model = testModel([saved])
    model.setSavedPassword(saved.id.uuidString, password)
    model.setSavedPassword(saved.proxySecretKey, Lab.socksProxy.password)
    let (main, harness) = appWindow(model)
    _ = await call(harness, "select", ["pane": "sidebar", "names": [saved.name]])
    #expect(await call(harness, "menu", ["path": "Connection > Connect"]).error == nil)
    #expect(await eventually(timeout: 40) { model.openMongo[saved.id] != nil })
    return (main, harness, try #require(model.openMongo[saved.id]))
}

/// The host page on `pane`, from the Connection menu, once it has read twice (so its rates show).
@MainActor private func hostPage(_ main: MainWindowController, _ harness: AgentServer, _ pane: String) async throws -> MongoHostContent {
    let shown = await call(harness, "menu", ["path": "Connection > MongoDB Server > " + pane])
    #expect(shown.error == nil, "\(shown.error ?? "")")
    let host = try #require(main.selectedTab?.shown as? MongoHostContent)
    #expect(await eventually(timeout: 30) { host.reads >= 2 && !host.isReading })
    return host
}

extension AppTests {
    @Test(.enabled(if: MongoLab.enabled)) func aMongoHostPageShowsTheStandaloneAndKillsASlowFind() async throws {
        let (main, harness, mongo) = try await hostWindow()
        let host = try await hostPage(main, harness, "Server")
        #expect(host.isPolling && host.pane == .server)
        let figures = Dictionary(host.figures.rows.map { ($0.key, $0.cells) }, uniquingKeysWith: { a, _ in a })
        #expect(figures["Version"]?["value"]?.hasPrefix("7.0") == true && figures["Storage Engine"]?["value"] == "wiredTiger")
        #expect(figures["Commands"]?["second"]?.isEmpty == false, "the second read gives the rates")
        #expect(host.properties.stringValue.contains("standalone") && host.properties.stringValue.contains("up "))
        host.show(.members)
        #expect(host.members.rows.isEmpty && host.members.caption.stringValue.contains("standalone"))

        // A slow find on another session shows among this login's operations; Kill ends it.
        let other = try await mongo.connection.session(.data, slot: "slow")
        let slow = Task { () -> Error? in
            do {
                let cursor = try await other.find(database: "fixture", collection: "many", MongoFind(filter: doc(["$where": .string("sleep(20) || true")])))
                _ = try await cursor.next()
                return nil
            } catch { return error }
        }
        host.show(.operations)
        #expect(host.allRefusal == .some(nil) && host.allOperations.isEnabled, "airsql may list everyone's")
        #expect(await eventually(timeout: 20) { host.operationsFound.contains { $0.namespace == "fixture.many" } })
        let op = try #require(host.operationsFound.first { $0.namespace == "fixture.many" })
        #expect(["query", "getmore"].contains(op.op) && op.plan == "COLLSCAN" && op.description.hasPrefix("airsql:data:") && op.killRefusal == nil, "\(op)")
        let row = try #require(host.operations.rows.firstIndex { $0.key == op.id })
        host.operations.table.selectRowIndexes([row], byExtendingSelection: false)
        #expect(host.kill.isEnabled)
        let started = Date()
        host.killOperation(nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        #expect(await call(harness, "press", ["title": "Kill Operation"]).error == nil)
        let ended = await slow.value
        #expect((ended as? AirSQLError)?.kind == .cancelled, "\(String(describing: ended))")
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(await eventually(timeout: 15) { !host.operationsFound.contains { $0.id == op.id } })

        // Hidden behind another tab, it stops reading; shown again, it reads again.
        main.open(TextContent(title: "Other", caption: "", text: "x"), title: "Other", connection: mongo.saved.id)
        #expect(!host.isPolling)
        let reads = host.reads
        try await Task.sleep(nanoseconds: (MongoHostContent.interval + 2) * 1_000_000_000)
        #expect(host.reads == reads)
        main.close(try #require(main.selectedTab))
        #expect(await eventually(timeout: 10) { host.isPolling && host.reads > reads })
        await mongo.connection.closeSession(.data, slot: "slow")
    }

    @Test(.enabled(if: MongoLab.enabled)) func aMongoHostPageListsTheReplicaSetsMembers() async throws {
        let (main, harness, _) = try await hostWindow(replicaSet: true)
        let host = try await hostPage(main, harness, "Members")
        #expect(host.members.rows.count == 3, "\(host.members.caption.stringValue)")
        let states = host.members.rows.map { $0.cells["state"] ?? "" }
        #expect(states.filter { $0 == "PRIMARY" }.count == 1 && states.filter { $0 == "SECONDARY" }.count == 2, "\(states)")
        #expect(host.members.rows.allSatisfy { $0.cells["health"] == "Up" && $0.cells["lag"]?.isEmpty == false })
        #expect(host.members.rows.contains { $0.cells["name"]?.hasSuffix("(answered)") == true && $0.cells["ping"] == "" })
        #expect(host.members.rows.filter { $0.cells["ping"]?.hasSuffix(" ms") == true }.count == 2)
        #expect(host.properties.stringValue.contains("replica set rs0"))

        // Everyone's operations list the server's own (replication's), which Kill refuses with the reason.
        host.show(.operations)
        host.allOperations.state = .on
        #expect(await eventually(timeout: 20) {
            host.refresh(nil)
            return host.operationsFound.contains(where: \.isInternal)
        })
        let own = try #require(host.operations.rows.firstIndex { row in host.operationsFound.contains { $0.id == row.key && $0.isInternal } })
        host.operations.table.selectRowIndexes([own], byExtendingSelection: false)
        #expect(!host.kill.isEnabled && host.kill.toolTip?.contains("server's own work") == true)
    }

    @Test(.enabled(if: MongoLab.enabled)) func aReadOnlyMongoLoginListsItsOwnOperationsAndSaysWhy() async throws {
        let (main, harness, _) = try await hostWindow(login: Lab.Login(user: "reader", password: "reader-pass"), readOnly: true)
        let host = try await hostPage(main, harness, "Operations")
        // serverStatus needs clusterMonitor; its own operations need nothing.
        #expect(host.figures.caption.stringValue.contains("clusterMonitor"), "\(host.figures.caption.stringValue)")
        #expect(host.allRefusal??.contains("inprog") == true && !host.allOperations.isEnabled && host.allOperations.state == .off)
        #expect(host.allOperations.toolTip?.contains("only its own") == true)
        #expect(host.operations.caption.stringValue.contains("this login's operations"), "\(host.operations.caption.stringValue)")
        // Read-only: Kill is off and says why, the listing works.
        #expect(!host.kill.isEnabled && host.kill.toolTip?.hasPrefix("This connection is read-only") == true)
        let item = Commands.killOperation.item()
        #expect(!host.validateMenuItem(item) && item.toolTip?.hasPrefix("This connection is read-only") == true)
    }

    @Test(.enabled(if: MongoLab.enabled)) func aMongoDiskUsageShowsTheSeedsSizes() async throws {
        let (main, harness, mongo) = try await hostWindow()
        _ = await call(harness, "select", ["pane": "sidebar", "names": [mongo.saved.name]])
        #expect(await call(harness, "menu", ["path": "Connection > MongoDB Server > Disk Usage"]).error == nil)
        let disk = try #require(main.selectedTab?.content as? MongoDiskUsageContent)
        #expect(await eventually(timeout: 30) { !disk.isReading })
        let fixture = try #require(disk.found.first { $0.row.name == "fixture" })
        #expect((fixture.row.total ?? 0) > 0 && (fixture.row.rows ?? 0) >= 1019 && (fixture.uncompressed ?? 0) > 0, "\(fixture)")
        // A double-click goes into its collections; Back comes out.
        let row = try #require(disk.list.rows.firstIndex { $0.key == "fixture" })
        disk.list.table.selectRowIndexes([row], byExtendingSelection: false)
        disk.list.onOpen?(disk.list.rows[row])
        #expect(await eventually(timeout: 30) { !disk.isReading && disk.database == "fixture" })
        let names = Set(disk.found.map(\.row.name))
        #expect(names.contains("all_types") && names.contains("many") && !names.contains("all_types_names"), "views take no space")
        #expect(disk.found.first { $0.row.name == "all_types" }?.row.rows == 19 && disk.found.first { $0.row.name == "many" }?.row.rows == 1000)
        #expect((disk.found.first { $0.row.name == "many" }?.row.index ?? 0) > 0 && !disk.back.isHidden)
        disk.goUp(nil)
        #expect(await eventually(timeout: 30) { !disk.isReading && disk.database == nil })
    }
}

// MARK: Pictures

extension AppTests.MongoScreenshotTests {
    @Test func mongoHostScreens() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let (main, harness, mongo) = try await hostWindow(replicaSet: true)
            main.window?.appearance = NSAppearance(named: appearance)
            main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
            main.window?.orderFront(nil)
            let host = try await hostPage(main, harness, "Server")
            try await picture(harness, "mongo-host-\(suffix)")
            host.show(.members)
            try await picture(harness, "mongo-host-members-\(suffix)")
            let other = try await mongo.connection.session(.data, slot: "slow")
            let slow = Task { try? await other.find(database: "fixture", collection: "many",
                                                     MongoFind(filter: doc(["$where": .string("sleep(5) || true")]))).next() }
            host.show(.operations)
            #expect(await eventually(timeout: 20) { host.operationsFound.contains { $0.namespace == "fixture.many" } })
            try await picture(harness, "mongo-operations-\(suffix)")
            slow.cancel()
            await mongo.connection.closeSession(.data, slot: "slow")
            host.showDiskUsage(nil)
            let disk = try #require(main.selectedTab?.content as? MongoDiskUsageContent)
            #expect(await eventually(timeout: 30) { !disk.isReading })
            try await picture(harness, "mongo-disk-usage-\(suffix)")
            main.window?.orderOut(nil)
        }
    }

    private func picture(_ harness: AgentServer, _ name: String) async throws {
        let reply = await call(harness, "screenshot", ["target": "main", "scale": 2])
        let image = try #require(reply.image, "\(name): \(reply.error ?? "")")
        try #require(image.representation(using: .png, properties: [:])).write(to: AppTests.ScreenshotTests.folder.appendingPathComponent(name + ".png"))
    }
}
