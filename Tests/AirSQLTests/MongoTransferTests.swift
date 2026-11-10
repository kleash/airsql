// Export and Import Documents (docs/dev/mongo-plan.md, lane M5): the formats' text, JSON Lines read a line at a time
// with bad lines skipped, the file's preview and the import's summary; then, against the Mongo lab (AIRSQL_MONGO_LAB=1)
// on the standalone and the replica set, every BSON type exported in each format and imported again, bad lines and
// duplicates in both modes, and Cancel in the middle of each; and the sheets' pictures (AIRSQL_SCREENSHOTS=1 too).
import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

private func doc(_ fields: KeyValuePairs<String, BSONValue>) -> BSONDocument { BSONDocument(fields.map { ($0.key, $0.value) }) }

/// A file of `text` in the tests' own folder.
private func file(_ text: String, _ name: String = "import.json") throws -> URL {
    let folder = URL(fileURLWithPath: TestEnvironment.root).appendingPathComponent("transfer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
}

struct MongoTransferTests {
    @Test func eachFormatWritesItsText() {
        let documents = [doc(["_id": .int32(1), "n": .int64(5), "sub": .document(doc(["a": .bool(true)]))]),
                         doc(["_id": .int32(2), "when": .datetime(0)])]
        #expect(MongoExport.Encoder.text(.json(.relaxed, .lines), documents)
                == "{\"_id\":1,\"n\":5,\"sub\":{\"a\":true}}\n{\"_id\":2,\"when\":{\"$date\":\"1970-01-01T00:00:00Z\"}}\n")
        #expect(MongoExport.Encoder.text(.json(.canonical, .array), [documents[0]])
                == "[\n{\"_id\":{\"$numberInt\":\"1\"},\"n\":{\"$numberLong\":\"5\"},\"sub\":{\"a\":true}}\n]\n")
        #expect(MongoExport.Encoder.text(.json(.relaxed, .array), []) == "[]\n")
        let paths = MongoCSVWriter.paths(of: documents)
        #expect(paths == ["_id", "n", "sub.a", "when"])
        #expect(MongoExport.Encoder.text(.csv(paths, .shell), documents)
                == "_id,n,sub.a,when\n1,NumberLong(5),true,\n2,,,\"ISODate(\"\"1970-01-01T00:00:00.000Z\"\")\"\n")
    }

    @Test func badLinesAreSkippedWithTheirNumbers() throws {
        // A byte order mark, Windows line endings, a blank line, no newline at the end.
        let url = try file("\u{FEFF}{\"_id\": 1}\r\nnot json\r\n\r\n{\"_id\": 2, \"a\": [1,\n{\"_id\": 3}")
        var report = MongoImport.Report()
        var source = try MongoImport.Source(url, skipBad: true)
        var found: [String] = []
        while let (document, place) = try source.next(&report) { found.append("\(place): \(document.extendedJSON())") }
        #expect(found == ["Line 1: {\"_id\":1}", "Line 5: {\"_id\":3}"])
        #expect(report.skipped == 2 && report.noted == 2)
        #expect(report.problems.count == 2 && report.problems[0].hasPrefix("Line 2, column 1:") && report.problems[1].hasPrefix("Line 4, "),
                "\(report.problems)")

        // Without skipping, the reader stops at the bad line and says where.
        var strict = try MongoImport.Source(url, skipBad: false)
        #expect(try strict.next(&report)?.1 == "Document 1")
        do {
            _ = try strict.next(&report)
            Issue.record("no error")
        } catch {
            #expect("\(error)".hasPrefix("Line 2, column 1:"), "\(error)")
        }
    }

    @Test func thePreviewShowsTheFirstDocumentsAndEstimatesTheRest() throws {
        let lines = (0..<1000).map { "{\"_id\": \($0 + 1000)}" }.joined(separator: "\n") + "\n"
        let many = MongoImport.preview(try file(lines), skipBad: false)
        #expect(many.documents.count == 5 && many.problems.isEmpty)
        #expect((900...1100).contains(many.estimate), "\(many.estimate)")
        let few = MongoImport.preview(try file("[{\"a\": 1}, {\"a\": 2}]"), skipBad: false)
        #expect(few.documents.count == 2 && few.estimate == 2)
        let broken = MongoImport.preview(try file("{\"a\": "), skipBad: false)
        #expect(broken.documents.isEmpty && broken.problems.count == 1)
    }

    @Test func theSummarySaysWhatWentInAndWhy() {
        var report = MongoImport.Report(inserted: 1200, refused: 3, duplicates: 2, skipped: 1)
        for n in 0..<12 { report.note("Line \(n): bad") }
        let (title, text) = MongoImportSheet.summary(report, collection: "people")
        #expect(title == "1,200 documents imported into people")
        #expect(text.contains("Refused by the server: 3 (2 with an _id the collection holds already)"))
        #expect(text.contains("Lines skipped, which couldn't be read: 1") && text.contains("… and 2 more"))
        report.cancelled = true
        #expect(MongoImportSheet.summary(report, collection: "people").0 == "Import cancelled: 1,200 documents inserted into people")
    }
}

// MARK: The lab

@Suite(.serialized, .enabled(if: MongoLab.enabled, "Mongo lab: AIRSQL_MONGO_LAB=1 ./test.sh --filter Mongo"))
struct MongoTransferLabTests {
    static let database = "lane_mongo_transfer"

    /// The standalone directly, and the replica set through the SOCKS proxy.
    private func both() -> [MongoConnection] {
        let solo = SavedConnection(name: "Mongo lab", host: "127.0.0.1", port: MongoLab.soloPort, user: "airsql", route: .direct)
        var set = SavedConnection(name: "Mongo lab", host: MongoLab.members[0], port: 27017, user: "airsql", route: .proxy)
        let proxy = Lab.socksProxy
        set.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: proxy.port, user: proxy.user)
        return [
            MongoConnection(uri: "mongodb://127.0.0.1:\(MongoLab.soloPort)/", user: "airsql", password: "airsql-pass",
                            route: MongoRoute(solo), name: "Mongo lab"),
            MongoConnection(uri: MongoLab.allSeeds, user: "airsql", password: "airsql-pass", tls: MongoLab.tls,
                            route: MongoRoute(set, proxyPassword: proxy.password), name: "Mongo lab"),
        ]
    }

    /// Each server's data session, with this suite's database dropped after.
    private func eachServer(_ body: (MongoSession) async throws -> Void) async throws {
        for connection in both() {
            _ = try await connection.connect()
            let session = try await connection.session(.data)
            _ = try? await session.command(doc(["dropDatabase": .int32(1)]), database: Self.database)
            do { try await body(session) } catch { Issue.record(error) }
            _ = try await session.command(doc(["dropDatabase": .int32(1)]), database: Self.database)
            await connection.close()
        }
    }

    private func all(_ session: MongoSession, _ collection: String) async throws -> [BSONDocument] {
        let cursor = try await session.find(database: Self.database, collection: collection, MongoFind(sort: doc(["_id": .int32(1)])))
        var documents: [BSONDocument] = []
        while !cursor.isExhausted { documents += try await cursor.next().map { try BSONDocument(bytes: $0) } }
        return documents
    }

    private func export(_ session: MongoSession, _ collection: String, _ format: MongoExport.Format, to url: URL,
                        stop: StopFlag = StopFlag(), progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> Int {
        try await MongoExport.write(session, database: Self.database, collection: collection, find: MongoFind(sort: doc(["_id": .int32(1)])),
                                    format: format, to: url, stop: stop, progress: progress)
    }

    private func importFile(_ session: MongoSession, _ url: URL, into collection: String, skipBad: Bool, stop: StopFlag = StopFlag(),
                            progress: @escaping @Sendable (Int, Double) -> Void = { _, _ in }) async -> MongoImport.Report {
        await MongoImport.run(session, database: Self.database, collection: collection, file: url, skipBad: skipBad, stop: stop,
                              progress: progress)
    }

    /// The seed's documents of every type, and one of the types the shell no longer makes: exported in each format and
    /// imported into new collections. Canonical keeps every type exactly; relaxed keeps what the file says; CSV's columns
    /// are the documents' paths.
    @Test func everyTypeGoesOutAndComesBack() async throws {
        try await eachServer { session in
            let seed = try await session.find(database: "fixture", collection: "all_types", MongoFind(sort: doc(["_id": .int32(1)])))
                .next().map { try BSONDocument(bytes: $0) }
            #expect(seed.count == 19)
            let old = doc(["_id": .int32(200), "nan": .double(.nan), "negZero": .double(-0.0), "inf": .double(.infinity),
                           "before1970": .datetime(-284_643_869_501), "after9999": .datetime(253_402_300_800_000),
                           "int64small": .int64(5), "symbol": .symbol("sym"), "undefined": .undefined,
                           "dbPointer": .dbPointer(namespace: "db.c", id: BSONObjectId(hex: "56e1fc72e0c917e9c4714161")!),
                           "codeWithScope": .javascriptWithScope(code: "x", scope: doc(["x": .int64(5)])),
                           "oldBinary": .binary(subtype: 2, data: Data([2, 0, 0, 0, 0xAB, 0xCD]))])
            _ = try await session.insertMany(database: Self.database, collection: "source", seed + [old])
            let source = try await all(session, "source")
            #expect(source.count == 20)

            for (index, (format, ext)) in [(MongoExport.Format.json(.canonical, .lines), "jsonl"), (.json(.canonical, .array), "json"),
                                           (.json(.relaxed, .lines), "json")].enumerated() {
                let url = try file("", "out.\(ext)")
                #expect(try await export(session, "source", format, to: url) == 20)
                let report = await importFile(session, url, into: "back\(index)", skipBad: false)
                #expect(report.inserted == 20 && report.stopped == nil && report.problems.isEmpty, "\(report)")
                let back = try await all(session, "back\(index)")
                if case .json(.canonical, _) = format {
                    #expect(back.count == source.count)
                    for (a, b) in zip(source, back) { #expect(a.typeExactEqual(b), "\(format): \(a.extendedJSON(.canonical)) ≠ \(b.extendedJSON(.canonical))") }
                } else {
                    // Relaxed: the file's numbers come back as the smallest type that holds them; the rest as written.
                    var reader = ExtendedJSONReader(try Data(contentsOf: url))
                    var read: [BSONDocument] = []
                    while let next = try reader.next() { read.append(next) }
                    #expect(read.count == back.count)
                    for (a, b) in zip(read, back) { #expect(a.typeExactEqual(b), "\(a.extendedJSON(.canonical)) ≠ \(b.extendedJSON(.canonical))") }
                    #expect(back.last?["int64small"] == .int32(5) && back.last?["symbol"] == .symbol("sym"))
                }
            }

            let csv = try file("", "out.csv")
            let paths = MongoCSVWriter.paths(of: source)
            #expect(try await export(session, "source", .csv(paths, .shell), to: csv) == 20)
            let text = try String(contentsOf: csv, encoding: .utf8)
            #expect(text.hasPrefix(paths.joined(separator: ",") + "\n") && paths.prefix(3) == ["_id", "type", "value"], "\(paths)")
            #expect(text.contains("\"ObjectId(\"\"65f000000000000000000001\"\")\"") && text.contains("NumberDecimal(\"\"1234567890.123456789012345678901234\"\")"), "\(text)")
            let relaxed = try file("", "relaxed.csv")
            _ = try await export(session, "source", .csv(["_id", "value"], .relaxedJSON), to: relaxed)
            #expect(try String(contentsOf: relaxed, encoding: .utf8).contains("\"{\"\"$oid\"\":\"\"65f000000000000000000001\"\"}\""))
        }
    }

    @Test func badLinesAndDuplicatesStopOrAreSkipped() async throws {
        try await eachServer { session in
            let bad = try file("{\"_id\": 1}\nnot json\n{\"_id\": 1, \"dup\": true}\n\n{\"_id\": 3}\n")
            // Stop: the document before the bad line goes in, nothing after.
            var report = await importFile(session, bad, into: "stop", skipBad: false)
            #expect(report.inserted == 1 && report.stopped?.hasPrefix("Line 2, column 1:") == true, "\(report)")
            #expect(try await all(session, "stop").count == 1)
            // Stop at a duplicate _id: counted, and named by its document.
            let dup = try file("{\"_id\": 1}\n{\"_id\": 2}\n{\"_id\": 2}\n{\"_id\": 4}\n")
            report = await importFile(session, dup, into: "stopDup", skipBad: false)
            #expect(report.inserted == 2 && report.refused == 1 && report.duplicates == 1, "\(report)")
            #expect(report.stopped?.hasPrefix("Document 3: A document with the same key already exists") == true, "\(report)")
            // Skip: the good lines go in; the bad line and the duplicate are counted with their lines.
            report = await importFile(session, bad, into: "skip", skipBad: true)
            #expect(report.inserted == 2 && report.skipped == 1 && report.refused == 1 && report.duplicates == 1 && report.stopped == nil,
                    "\(report)")
            #expect(report.problems.contains { $0.hasPrefix("Line 2, column 1:") } && report.problems.contains { $0.hasPrefix("Line 3: ") },
                    "\(report.problems)")
            #expect(try await all(session, "skip").map { $0["_id"] } == [.int32(1), .int32(3)])
        }
    }

    @Test func cancelLeavesNoPartFileAndSaysHowManyWentIn() async throws {
        try await eachServer { session in
            let lines = (0..<3500).map { "{\"_id\": \($0), \"pad\": \"\(String(repeating: "x", count: 100))\"}" }.joined(separator: "\n")
            let big = try file(lines)
            let stop = StopFlag()
            let report = await importFile(session, big, into: "many", skipBad: false, stop: stop) { _, _ in stop.set() }
            #expect(report.cancelled && report.inserted == MongoImport.batchCount, "\(report)")
            #expect(try await all(session, "many").count == report.inserted)

            // A cancelled export leaves the file that was there, and no part of the new one.
            let url = try file("old", "many.json")
            let stopExport = StopFlag()
            await #expect(throws: CancellationError.self) {
                _ = try await export(session, "many", .json(.relaxed, .lines), to: url, stop: stopExport) { _ in stopExport.set() }
            }
            #expect(try String(contentsOf: url, encoding: .utf8) == "old")
            #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["many.json"])
            #expect(try await export(session, "many", .json(.relaxed, .lines), to: url) == 1000)
        }
    }
}

// MARK: The sheets in the app, and their pictures

/// The standalone connected in a window of its own, the tree's fixture database read.
@MainActor private func transferWindow() async throws -> (MainWindowController, AgentServer, OpenMongoConnection) {
    var solo = SavedConnection(name: "Mongo solo", host: "127.0.0.1", port: MongoLab.soloPort, user: MongoLab.airsql.user)
    solo.engine = .mongodb
    solo.tls.mode = .off
    let model = testModel([solo])
    model.setSavedPassword(solo.id.uuidString, MongoLab.airsql.password)
    let (main, harness) = appWindow(model)
    _ = await call(harness, "select", ["pane": "sidebar", "names": [solo.name]])
    #expect(await call(harness, "menu", ["path": "Connection > Connect"]).error == nil)
    #expect(await eventually(timeout: 30) { model.openMongo[solo.id]?.databases != nil })
    let open = try #require(model.openMongo[solo.id])
    open.loadDatabase("fixture")
    #expect(await eventually(timeout: 20) { open.collections["fixture"] != nil })
    return (main, harness, open)
}

extension AppTests {
    /// Data ▸ Collection ▸ Export and Import Documents… act on the collection tab in front, with its query; the export
    /// sheet shows its documents. (The menu's target finds the front main window, as `CollectionMenu` does: of the several
    /// windows a test run has open, not reliably this one, so the target is asked of this window.)
    @Test(.enabled(if: MongoLab.enabled)) func theCollectionMenuExportsAndImportsTheTabsCollection() async throws {
        let (main, harness, open) = try await transferWindow()
        let collection = try #require(NSApp.mainMenu?.items.first { $0.title == "Data" }?.submenu?.items.first { $0.title == "Collection" }?.submenu)
        #expect(collection.items.suffix(2).map(\.title) == ["Export Documents…", "Import Documents…"])
        main.openCollection(MongoCollectionInfo(name: "all_types", kind: .collection), database: "fixture", connection: open.saved.id)
        let tab = try #require(main.selectedTab?.content as? MongoCollectionController)
        #expect(await eventually(timeout: 20) { tab.loading == nil })
        let ref = try #require(MongoTransferMenu.shared.target(in: main))
        #expect(ref.database == "fixture" && ref.collection == "all_types" && ref.kind == .collection && ref.query == tab.shown)
        #expect(MongoImportSheet.refusal(ref) == nil)
        MongoExportSheet.show(ref, activity: main.model.activity, on: main.window!)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        let export = try #require(main.window?.attachedSheet?.windowController as? MongoExportSheet)
        #expect(await eventually(timeout: 20) { export.preview.stringValue.hasPrefix("{\"_id\":1,") })
        _ = await call(harness, "press", ["title": "Cancel"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        tab.close()
    }
}

extension AppTests.MongoScreenshotTests {
    @Test func transferSheets() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let (main, harness, open) = try await transferWindow()
            main.window?.appearance = NSAppearance(named: appearance)
            main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
            main.window?.orderFront(nil)
            let tab = MongoQueryText(filter: "{ type: { $ne: 'every' } }", sort: "{ _id: 1 }")
            let ref = MongoCollectionRef(open: open, database: "fixture", collection: "all_types", kind: .collection, query: tab)
            MongoExportSheet.show(ref, activity: main.model.activity, on: main.window!)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            let export = try #require(main.window?.attachedSheet?.windowController as? MongoExportSheet)
            #expect(await eventually(timeout: 20) { export.preview.stringValue.hasPrefix("{") })
            try await shoot(harness, "mongo-export-\(suffix)")
            _ = await call(harness, "press", ["title": "Cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])

            MongoImportSheet.show(ref, activity: main.model.activity, on: main.window!)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            let sheet = try #require(main.window?.attachedSheet?.windowController as? MongoImportSheet)
            let lines = (1...240).map { "{\"_id\": \($0), \"name\": \"Customer \($0)\", \"since\": {\"$date\": \"2024-0\($0 % 9 + 1)-01T00:00:00Z\"}}" }
            sheet.look(at: try file(lines.joined(separator: "\n"), "customers.json"))
            #expect(await eventually(timeout: 20) { sheet.statement.stringValue.hasPrefix("Import adds about") })
            try await shoot(harness, "mongo-import-\(suffix)")
            _ = await call(harness, "press", ["title": "Cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            main.window?.orderOut(nil)
        }
    }

    private func shoot(_ harness: AgentServer, _ name: String) async throws {
        let reply = await call(harness, "screenshot", ["target": "main", "scale": 2])
        let image = try #require(reply.image, "\(name): \(reply.error ?? "")")
        try #require(image.representation(using: .png, properties: [:])).write(to: AppTests.ScreenshotTests.folder.appendingPathComponent(name + ".png"))
    }
}
