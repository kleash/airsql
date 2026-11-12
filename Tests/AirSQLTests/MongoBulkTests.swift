// Update Many, Delete Many and CSV import (docs/dev/mongo-plan.md, Phase 2 bulk): what the sheets read and refuse, the
// command shown, a CSV file's types, dotted names and bad rows; then, against the Mongo lab (AIRSQL_MONGO_LAB=1) on the
// standalone and the replica set, the count shown against what the server matched, a pipeline update, a delete, Cancel
// and a CSV import; and in the app, the sheets, the typed count and name, the read-only refusal and their pictures.
import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

private func doc(_ fields: KeyValuePairs<String, BSONValue>) -> BSONDocument { BSONDocument(fields.map { ($0.key, $0.value) }) }

private func csvFile(_ text: String, _ name: String = "import.csv") throws -> URL {
    let folder = URL(fileURLWithPath: TestEnvironment.root).appendingPathComponent("bulk-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
}

private func reason(_ body: () throws -> Void) -> String? {
    do { try body() } catch { return (error as? AirSQLError)?.message ?? "\(error)" }
    return nil
}

struct MongoBulkTests {
    @Test func anUpdateMustBeOperatorsOrAPipeline() throws {
        func update(_ text: String) throws -> MongoBulk {
            try MongoBulk(database: "shop", collection: "orders", filter: "{ status: 'old' }", update: text, collation: nil)
        }
        #expect(reason { _ = try update("{ status: 'new' }") }?.hasPrefix("This is a replacement document") == true)
        #expect(reason { _ = try update("{ $set: { a: 1 }, b: 2 }") }?.hasSuffix("b isn't.") == true)
        #expect(reason { _ = try update("{}") }?.hasPrefix("The update is empty") == true)
        #expect(reason { _ = try update("[]") }?.hasPrefix("The pipeline is empty") == true)
        #expect(reason { _ = try update("[ { a: 1 } ]") }?.hasPrefix("Each stage") == true)
        #expect(reason { _ = try update("42") }?.hasPrefix("Write the update as operators") == true)
        #expect(reason { _ = try update("{ $set: ") }?.hasPrefix("Update: ") == true)
        #expect(reason { _ = try MongoBulk(database: "d", collection: "c", filter: "{ a: ", collation: nil) }?.hasPrefix("Filter: ") == true)

        let set = try update("{ $set: { status: 'new' } }")
        #expect(set.shellForm == #"db.getSiblingDB("shop").getCollection("orders").updateMany({ status: "old" }, { $set: { status: "new" } }, { upsert: false })"#)
        #expect(set.confirmation(count: 1234) == "1234" && set.heading(count: 1) == "Update the 1 document of shop.orders that the filter matches?")
        let pipeline = try MongoBulk(database: "shop", collection: "orders", filter: "", update: "[ { $set: { n: { $add: ['$n', 1] } } } ]",
                                     collation: doc(["locale": .string("en"), "strength": .int32(2)]))
        #expect(pipeline.shellForm.hasSuffix(#".updateMany({}, [ { $set: { n: { $add: [ "$n", 1 ] } } } ], { upsert: false, collation: { locale: "en", strength: 2 } })"#),
                "\(pipeline.shellForm)")
        // A delete of everything is confirmed by the collection's name, else by the count.
        let all = try MongoBulk(database: "shop", collection: "orders", filter: "  ", collation: nil)
        #expect(all.shellForm.hasSuffix(".deleteMany({})") && all.confirmation(count: 9) == "orders")
        #expect(all.heading(count: 9) == "Delete every document of shop.orders (9 documents)?")
        #expect(try MongoBulk(database: "shop", collection: "orders", filter: "{ a: 1 }", collation: nil).confirmation(count: 0) == "0")

        // The report: matched against the count shown.
        #expect(set.report(counted: 3, matched: 3, modified: 2) == ("Updated orders: 3 matched, 2 modified.", false))
        let moved = all.report(counted: 3, matched: 4, modified: nil)
        #expect(moved.differs && moved.message.hasPrefix("Deleted 4 documents from orders. The count shown was 3"))
        #expect(set.failure(AirSQLError(.outcomeUnknown, "")).hasPrefix("Unknown whether documents were updated"))
        #expect(set.failure(AirSQLError(.cancelled, "")).hasPrefix("Cancelled. The server keeps the documents it had updated"))
    }

    @Test func csvCellsTakeTheirTypes() throws {
        func auto(_ cell: String) throws -> BSONValue { try MongoCSVReader.value(cell, as: .auto) }
        #expect(try auto("42") == .int32(42) && auto("-7") == .int32(-7) && auto("4000000000") == .int64(4_000_000_000))
        #expect(try auto("1.5") == .double(1.5) && auto("2e3") == .double(2000) && auto("-0.25E-1") == .double(-0.025))
        #expect(try auto("true") == .bool(true) && auto("null") == .null)
        #expect(try auto("2024-05-01T12:00:00Z") == .datetime(1_714_564_800_000))
        #expect(try auto("5f1d7a3e9c1b2a0012345678") == .objectId(BSONObjectId(hex: "5f1d7a3e9c1b2a0012345678")!))
        #expect(try auto("NumberLong(5)") == .int64(5) && auto(#"ISODate("1970-01-01T00:00:00.000Z")"#) == .datetime(0))
        // Not exactly a shape: text.
        for text in ["007", "1.", ".5", "1,5", "TRUE", "Null", "12abc", "99999999999999999999", "5f1d7a3e9c1b2a001234567", "f(x)", " 1"] {
            #expect(try auto(text) == .string(text), "\(text)")
        }
        // Forced: every cell as the type, or why not.
        #expect(try MongoCSVReader.value("007", as: .string) == .string("007") && MongoCSVReader.value("7", as: .long) == .int64(7))
        #expect(try MongoCSVReader.value("7", as: .double) == .double(7) && MongoCSVReader.value("TRUE", as: .bool) == .bool(true))
        #expect(try MongoCSVReader.value("1.10", as: .decimal) == .decimal128(BSONDecimal128("1.10")!))
        #expect(try MongoCSVReader.value("2024-05-01", as: .date) == .datetime(1_714_521_600_000))
        #expect(reason { _ = try MongoCSVReader.value("4000000000", as: .int) }?.hasPrefix("“4000000000” isn't an int") == true)
        #expect(reason { _ = try MongoCSVReader.value("yes", as: .bool) } == "“yes” isn't a bool (true or false)")
        #expect(reason { _ = try MongoCSVReader.value("abc", as: .objectId) } == "“abc” isn't an ObjectId (24 hex digits)")
    }

    @Test func csvRowsBecomeDocumentsWithSubDocuments() throws {
        let url = try csvFile("_id,name,address.city,address.zip,score\n1,Ann,Oslo,0150,2.5\n2,\"Bo, Jr\",,,\n\n3,Cy,Rome,00184,7\n")
        let reader = try MongoCSVReader(url)
        reader.types = ["score": .double]
        var found: [String] = []
        while let (document, row) = try reader.next() { found.append("\(row): \(document.shellForm())") }
        #expect(found == [#"2: { _id: 1, name: "Ann", address: { city: "Oslo", zip: "0150" }, score: 2.5 }"#,
                          #"3: { _id: 2, name: "Bo, Jr" }"#,
                          #"5: { _id: 3, name: "Cy", address: { city: "Rome", zip: "00184" }, score: 7.0 }"#], "\(found)")

        // Semicolons, guessed from the first line.
        let semi = try MongoCSVReader(try csvFile("a;b\n1;x\n"))
        #expect(try semi.next()?.0 == doc(["a": .int32(1), "b": .string("x")]))

        // A header that can't name a document's fields.
        for (header, why) in [("a,,b", "Column 2 of the header has no name."), ("a,a", "Two columns are named “a”."),
                              ("a,a.b", "“a” is a column, and “a.b” would make it a sub-document."),
                              ("x..y", "The column “x..y” has an empty part in its name."), ("", "The file has no header row to name the fields.")] {
            #expect(reason { _ = try MongoCSVReader(try csvFile(header + "\n1\n")) } == why, "\(header)")
        }
    }

    @Test func badCSVRowsStopOrAreSkippedWithTheirNumbers() throws {
        let url = try csvFile("_id,n\n1,1\n2,two\n3\n4,4\n")
        var report = MongoImport.Report()
        var skipping = try MongoImport.Source(url, skipBad: true, types: ["n": .int])
        var places: [String] = []
        while let (_, place) = try skipping.next(&report) { places.append(place) }
        #expect(places == ["Row 2", "Row 5"] && report.skipped == 2)
        #expect(report.problems == ["Row 3, n: “two” isn't an int (a whole number from -2147483648 to 2147483647)",
                                    "Row 4: it has 1 field, and the header names 2"], "\(report.problems)")

        var strict = try MongoImport.Source(url, skipBad: false, types: ["n": .int])
        #expect(try strict.next(&report)?.1 == "Row 2")
        #expect(reason { _ = try strict.next(&report) }?.hasPrefix("Row 3, n: ") == true)

        // The sheet's preview: the documents as they'll be inserted, and the problems.
        let preview = MongoImport.preview(url, skipBad: true, types: [:])
        #expect(preview.documents.map { $0.shellForm() } == [#"{ _id: 1, n: 1 }"#, #"{ _id: 2, n: "two" }"#, #"{ _id: 4, n: 4 }"#])
        #expect(preview.estimate == 3 && preview.problems.count == 1)
    }
}

// MARK: The lab

@Suite(.serialized, .enabled(if: MongoLab.enabled, "Mongo lab: AIRSQL_MONGO_LAB=1 ./test.sh --filter Mongo"))
struct MongoBulkLabTests {
    static let database = "lane_mongo_bulk"

    /// The standalone directly, and the replica set through the SOCKS proxy.
    private func both() -> [MongoConnection] {
        var set = SavedConnection(name: "Mongo lab", host: MongoLab.members[0], port: 27017, user: "airsql", route: .proxy)
        let proxy = Lab.socksProxy
        set.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: proxy.port, user: proxy.user)
        let solo = SavedConnection(name: "Mongo lab", host: "127.0.0.1", port: MongoLab.soloPort, user: "airsql", route: .direct)
        return [
            MongoConnection(uri: "mongodb://127.0.0.1:\(MongoLab.soloPort)/", user: "airsql", password: "airsql-pass",
                            route: MongoRoute(solo), name: "Mongo lab"),
            MongoConnection(uri: MongoLab.allSeeds, user: "airsql", password: "airsql-pass", tls: MongoLab.tls,
                            route: MongoRoute(set, proxyPassword: proxy.password), name: "Mongo lab"),
        ]
    }

    /// Each server's data session and another (someone else), the collection `c` holding `count` documents
    /// { _id: n, n, s: "a" }, this suite's database dropped after.
    private func eachServer(count: Int32 = 10, _ body: (MongoSession, MongoSession) async throws -> Void) async throws {
        for connection in both() {
            _ = try await connection.connect()
            let session = try await connection.session(.data), other = try await connection.session(.main)
            _ = try? await session.command(doc(["dropDatabase": .int32(1)]), database: Self.database)
            _ = try await other.insertMany(database: Self.database, collection: "c", (1...count).map {
                doc(["_id": .int32($0), "n": .int32($0), "s": .string("a")])
            })
            do { try await body(session, other) } catch { Issue.record(error) }
            _ = try await other.command(doc(["dropDatabase": .int32(1)]), database: Self.database)
            await connection.close()
        }
    }

    private func all(_ session: MongoSession, _ collection: String = "c") async throws -> [BSONDocument] {
        try await session.all(session.find(database: Self.database, collection: collection, MongoFind(sort: doc(["_id": .int32(1)]))))
    }

    private func bulk(filter: String, update: String? = nil, collation: BSONDocument? = nil) throws -> MongoBulk {
        try update.map { try MongoBulk(database: Self.database, collection: "c", filter: filter, update: $0, collation: collation) }
            ?? MongoBulk(database: Self.database, collection: "c", filter: filter, collation: collation)
    }

    @Test func updateManyMatchesTheCountOrSaysItDiffers() async throws {
        try await eachServer { session, other in
            let update = try bulk(filter: "{ n: { $gt: 6 } }", update: "{ $set: { s: 'b' } }")
            #expect(try await session.count(update) == 4)
            let first = try await session.run(update)
            #expect(first == (4, 4) && update.report(counted: 4, matched: first.matched, modified: first.modified).differs == false)
            #expect(try await all(session).filter { $0["s"] == .string("b") }.count == 4)

            // Someone adds a matching document between the count and the run: matched differs from the count shown.
            let counted = try await session.count(update)
            _ = try await other.insertMany(database: Self.database, collection: "c", [doc(["_id": .int32(11), "n": .int32(11), "s": .string("a")])])
            let second = try await session.run(update)
            #expect(second == (5, 1))
            #expect(update.report(counted: counted, matched: second.matched, modified: second.modified).differs)

            // A pipeline update, and a collation from the tab: "A" matches "a" at strength 2.
            let pipeline = try bulk(filter: "{ s: 'A' }", update: "[ { $set: { n: { $multiply: ['$n', 10] } } } ]",
                                    collation: doc(["locale": .string("en"), "strength": .int32(2)]))
            #expect(try await session.count(pipeline) == 6)
            #expect(try await session.run(pipeline) == (6, 6))
            #expect(try await all(session).prefix(6).map { $0["n"] } == [10, 20, 30, 40, 50, 60].map { BSONValue.int32($0) as BSONValue? })
        }
    }

    @Test func deleteManyAndCancel() async throws {
        try await eachServer(count: 40) { session, _ in
            let delete = try bulk(filter: "{ n: { $lte: 5 } }")
            #expect(try await session.count(delete) == 5)
            #expect(try await session.run(delete) == (5, 5))
            #expect(try await all(session).count == 35)

            // Cancel ends it on the server, which keeps what it did; nothing is run again.
            let slow = try bulk(filter: "{ $where: 'sleep(100) || true' }", update: "{ $set: { s: 'slow' } }")
            let task = Task { try await session.run(slow) }
            try await Task.sleep(nanoseconds: 800_000_000)
            await session.cancel()
            do {
                _ = try await task.value
                Issue.record("not cancelled")
            } catch {
                #expect((error as? AirSQLError)?.kind == .cancelled, "\(error)")
                #expect(slow.failure(error).hasPrefix("Cancelled. The server keeps"))
            }
            let changed = try await all(session).filter { $0["s"] == .string("slow") }.count
            #expect(changed < 35, "\(changed)")

            let everything = try bulk(filter: "{}")
            #expect(try await session.run(everything).matched == 35)
            #expect(try await all(session).isEmpty)
        }
    }

    @Test func aCSVFileImportsWithItsTypes() async throws {
        try await eachServer(count: 1) { session, _ in
            let url = try csvFile("_id,when,price,tags.first,code\n1,2024-05-01T00:00:00Z,1.50,a,007\n2,x,2,b,8\n3,2024-06-01,3,c,9\n")
            for skipBad in [false, true] {
                let target = skipBad ? "skipped" : "stopped"
                let report = await MongoImport.run(session, database: Self.database, collection: target, file: url, skipBad: skipBad,
                                                   types: ["when": .date, "price": .decimal, "code": .string], stop: StopFlag()) { _, _ in }
                #expect(report.inserted == (skipBad ? 2 : 1) && report.problems.first?.hasPrefix("Row 3, when: ") == true, "\(report)")
                #expect((report.stopped != nil) == !skipBad && report.skipped == (skipBad ? 1 : 0))
                let stored = try await all(session, target)
                #expect(stored.first == doc(["_id": .int32(1), "when": .datetime(1_714_521_600_000), "price": .decimal128(BSONDecimal128("1.50")!),
                                             "tags": .document(doc(["first": .string("a")])), "code": .string("007")]))
            }
        }
    }
}

// MARK: The sheets in the app, and their pictures

private let appDatabase = "lane_mongo_bulk_app"

/// The standalone connected in a window of its own (read-only when asked), `people` holding six documents, and its tab.
@MainActor private func bulkTab(readOnly: Bool = false) async throws -> (MainWindowController, AgentServer, OpenMongoConnection, MongoCollectionController) {
    var saved = SavedConnection(name: "Mongo solo", host: "127.0.0.1", port: MongoLab.soloPort, user: MongoLab.airsql.user)
    saved.engine = .mongodb
    saved.tls.mode = .off
    saved.readOnly = readOnly
    let model = testModel([saved])
    model.setSavedPassword(saved.id.uuidString, MongoLab.airsql.password)
    let (main, harness) = appWindow(model)
    _ = await call(harness, "select", ["pane": "sidebar", "names": [saved.name]])
    #expect(await call(harness, "menu", ["path": "Connection > Connect"]).error == nil)
    #expect(await eventually(timeout: 40) { model.openMongo[saved.id] != nil })
    let open = try #require(model.openMongo[saved.id])
    let session = try await open.connection.session(.main)
    _ = try? await session.command(doc(["drop": .string("people")]), database: appDatabase)
    _ = try await session.insertMany(database: appDatabase, collection: "people", (1...6).map { n in
        doc(["_id": .int32(Int32(n)), "name": .string(["Ann", "Bo", "Cy", "Di", "Ed", "Flo"][n - 1]), "age": .int32(Int32(20 + n * 5))])
    })
    main.openCollection(MongoCollectionInfo(name: "people", kind: .collection), database: appDatabase, connection: saved.id)
    let tab = try #require(main.selectedTab?.content as? MongoCollectionController)
    #expect(await eventually(timeout: 20) { tab.loading == nil })
    return (main, harness, open, tab)
}

@MainActor private func dropAppDatabase(_ open: OpenMongoConnection) async throws {
    _ = try await open.connection.session(.main).command(doc(["dropDatabase": .int32(1)]), database: appDatabase)
}

/// The words of the sheet on the window (an alert's among them).
@MainActor private func sheetWords(_ main: MainWindowController) -> String {
    func texts(_ view: NSView) -> [String] { ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts) }
    return main.window?.attachedSheet?.contentView.map(texts)?.joined(separator: "\n") ?? ""
}

/// The preview sheet's confirmation typed, as the person types it.
@MainActor private func typeConfirmation(_ text: String, _ main: MainWindowController) throws {
    let sheet = try #require(main.window?.attachedSheet?.windowController as? SQLPreviewSheet)
    let field = try #require(find(NSTextField.self, id: "preview.confirm", in: sheet.window!.contentView!))
    field.stringValue = text
    sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
}

extension AppTests {
    @Test(.enabled(if: MongoLab.enabled)) func updateAndDeleteManyShowTheCountToConfirm() async throws {
        let (main, harness, open, tab) = try await bulkTab()
        let menu = try #require(NSApp.mainMenu?.items.first { $0.title == "Data" }?.submenu?.items.first { $0.title == "Collection" }?.submenu)
        #expect(menu.items.contains { $0.title == "Update Many…" } && menu.items.contains { $0.title == "Delete Many…" })
        #expect(tab.validateMenuItem(Commands.updateMany.item()))

        // The filter starts as the tab's; a replacement document is refused in the sheet, with why.
        tab.bar.filter.stringValue = "{ age: { $gt: 35 } }"
        tab.updateMany(nil)
        #expect(await eventually(timeout: 5) { main.window?.attachedSheet?.windowController is MongoBulkSheet })
        let sheet = try #require(main.window?.attachedSheet?.windowController as? MongoBulkSheet)
        #expect(sheet.filter.stringValue == "{ age: { $gt: 35 } }")
        sheet.update?.string = "{ name: 'X' }"
        sheet.preview(nil)
        #expect(sheetWords(main).contains("This is a replacement document"))
        sheet.update?.string = "{ $set: { senior: true } }"
        sheet.preview(nil)

        // The preview: the exact command and the count, which must be typed before Update runs.
        #expect(await eventually(timeout: 20) { main.window?.attachedSheet?.windowController is SQLPreviewSheet })
        let preview = try #require(main.window?.attachedSheet)
        #expect(find(NSTextField.self, id: "preview.heading", in: preview.contentView!)?.stringValue
                == "Update the 3 documents of \(appDatabase).people that the filter matches?")
        #expect(find(NSTextView.self, id: "preview.sql", in: preview.contentView!)?.string
                == #"db.getSiblingDB("\#(appDatabase)").getCollection("people").updateMany({ age: { $gt: 35 } }, { $set: { senior: true } }, { upsert: false });"#)
        let run = try #require(find(NSButton.self, id: "preview.run", in: preview.contentView!))
        #expect(!run.isEnabled)
        try typeConfirmation("4", main)
        #expect(!run.isEnabled)
        try typeConfirmation("3", main)
        #expect(run.isEnabled)
        #expect(await call(harness, "press", ["id": "preview.run"]).error == nil)
        #expect(await eventually(timeout: 20) { sheetWords(main).contains("Updated people: 3 matched, 3 modified.") }, "\(sheetWords(main))")
        _ = await call(harness, "press", ["title": "OK"])
        #expect(await eventually(timeout: 20) { tab.loading == nil && main.window?.attachedSheet == nil })
        #expect(tab.source.rowCount == 3)  // read again with the tab's filter

        // Delete Many with an empty filter: the collection's name is typed, not the count.
        tab.bar.filter.stringValue = ""
        tab.deleteMany(nil)
        #expect(await eventually(timeout: 5) { main.window?.attachedSheet?.windowController is MongoBulkSheet })
        (main.window?.attachedSheet?.windowController as? MongoBulkSheet)?.preview(nil)
        #expect(await eventually(timeout: 20) { main.window?.attachedSheet?.windowController is SQLPreviewSheet })
        #expect(sheetWords(main).contains("Type “people” to confirm:") && sheetWords(main).contains("Delete every document of"))
        try typeConfirmation("people", main)
        #expect(await call(harness, "press", ["id": "preview.run"]).error == nil)
        #expect(await eventually(timeout: 20) { sheetWords(main).contains("Deleted 6 documents from people.") }, "\(sheetWords(main))")
        _ = await call(harness, "press", ["title": "OK"])
        #expect(await eventually(timeout: 20) { tab.loading == nil && tab.source.rowCount == 0 })
        tab.close()
        try await dropAppDatabase(open)
    }

    @Test(.enabled(if: MongoLab.enabled)) func bulkCommandsSayWhyNot() async throws {
        let (_, _, open, tab) = try await bulkTab(readOnly: true)
        let item = Commands.deleteMany.item()
        #expect(!tab.validateMenuItem(item) && item.toolTip?.hasPrefix("This connection is read-only") == true)
        tab.close()
        try await dropAppDatabase(open)
    }
}

extension AppTests.MongoScreenshotTests {
    @Test func bulkSheets() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let (main, harness, open, tab) = try await bulkTab()
            main.window?.appearance = NSAppearance(named: appearance)
            main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
            main.window?.orderFront(nil)
            tab.bar.filter.stringValue = "{ age: { $gt: 35 } }"
            tab.updateMany(nil)
            #expect(await eventually(timeout: 5) { main.window?.attachedSheet?.windowController is MongoBulkSheet })
            (main.window?.attachedSheet?.windowController as? MongoBulkSheet)?.update?.string = "{\n  $set: { senior: true },\n  $inc: { visits: 1 }\n}"
            try await shoot(harness, "mongo-update-many-\(suffix)")
            (main.window?.attachedSheet?.windowController as? MongoBulkSheet)?.preview(nil)
            #expect(await eventually(timeout: 20) { main.window?.attachedSheet?.windowController is SQLPreviewSheet })
            try await shoot(harness, "mongo-update-many-preview-\(suffix)")
            _ = await call(harness, "press", ["id": "preview.cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])

            let ref = MongoCollectionRef(open: open, database: appDatabase, collection: "customers", kind: .collection)
            MongoImportSheet.show(ref, activity: main.model.activity, on: main.window!)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            let sheet = try #require(main.window?.attachedSheet?.windowController as? MongoImportSheet)
            let rows = (1...120).map { "\($0),Customer \($0),2024-0\($0 % 9 + 1)-01T00:00:00Z,\($0 % 2 == 0 ? "Oslo" : "Rome"),\($0 * 3).50" }
            sheet.look(at: try csvFile((["_id,name,since,address.city,balance"] + rows).joined(separator: "\n"), "customers.csv"))
            #expect(await eventually(timeout: 20) { sheet.statement.stringValue.hasPrefix("Import adds") && sheet.column.numberOfItems == 5 })
            sheet.column.selectItem(withTitle: "balance")
            sheet.columnType.selectItem(withTitle: "decimal")
            sheet.typeChosen(nil)
            #expect(await eventually(timeout: 20) { sheet.preview.stringValue.contains("NumberDecimal") })
            try await shoot(harness, "mongo-import-csv-\(suffix)")
            _ = await call(harness, "press", ["title": "Cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            tab.close()
            try await dropAppDatabase(open)
            main.window?.orderOut(nil)
        }
    }

    private func shoot(_ harness: AgentServer, _ name: String) async throws {
        let reply = await call(harness, "screenshot", ["target": "main", "scale": 2])
        let image = try #require(reply.image, "\(name): \(reply.error ?? "")")
        try #require(image.representation(using: .png, properties: [:])).write(to: AppTests.ScreenshotTests.folder.appendingPathComponent(name + ".png"))
    }
}
