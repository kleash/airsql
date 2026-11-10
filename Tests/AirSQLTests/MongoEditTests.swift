// Editing documents in a collection tab (docs/dev/mongo-plan.md, Safe editing; lane M3-app): what typed text means over
// each type, the pending changes drawn over the grid, and new ObjectIds; then, against the Mongo lab
// (AIRSQL_MONGO_LAB=1), edits that keep or change types, removed fields, new, duplicated and deleted documents, Apply on
// the standalone and the replica set, a conflict, what can't be edited and why, closing with changes, and each tab's own
// data session; and the pictures of the pending marks and the Apply sheet (AIRSQL_SCREENSHOTS=1 too).
import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

private func doc(_ fields: KeyValuePairs<String, BSONValue>) -> BSONDocument {
    BSONDocument(fields.map { ($0.key, $0.value) })
}

struct MongoEditTests {
    @Test func typedTextKeepsTheFieldsType() throws {
        func value(_ text: String, _ old: BSONValue?) throws -> BSONValue { try MongoChanges.value(text, keeping: old) }
        let id = BSONObjectId(hex: "65a1b2c3d4e5f60718293a4b")!
        #expect(try value("5", .int64(1)) == .int64(5))
        #expect(try value("9007199254740993", .int64(1)) == .int64(9_007_199_254_740_993), "every digit, not a double's")
        #expect(try value("NumberInt(7)", .int64(1)) == .int64(7))
        #expect(try value("2", .double(1.5)) == .double(2))
        #expect(try value("2.50", .decimal128(BSONDecimal128("1")!)) == .decimal128(BSONDecimal128("2.50")!))
        #expect(try value("3", .int32(1)) == .int32(3))
        #expect(try value("hello world", .string("a")) == .string("hello world"))
        #expect(try value("42", .string("a")) == .string("42"))
        #expect(try value("\"quoted\"", .string("a")) == .string("quoted"))
        #expect(try value("2024-01-02T03:04:05Z", .datetime(0)) == .datetime(1_704_164_645_000))
        #expect(try value(id.hex, .objectId(BSONObjectId.generate())) == .objectId(id))
        #expect(try value("null", .string("a")) == .null)
        // What can't be read as the type comes back as typed, for `edit` to refuse; over null or missing, as typed.
        #expect(try value("1.5", .int32(1)) == .double(1.5))
        #expect(try value("\"x\"", .bool(true)) == .string("x"))
        #expect(try value("[1, 2]", nil) == .array([.int32(1), .int32(2)]))
        #expect(try value("7", .null) == .int32(7))
        #expect(throws: (any Error).self) { try value("{ a: ", nil) }
        var changes = MongoChanges(database: "d", collection: "c", kind: .collection)
        let loaded = doc(["_id": .int32(1), "n": .int32(1)])
        #expect(throws: AirSQLError.self) { try changes.edit(loaded, path: ["n"], to: try value("1.5", .int32(1))) }
    }

    @Test func pendingChangesShowOverTheDocuments() throws {
        let one = doc(["_id": .int32(1), "a": .document(doc(["b": .int32(1)])), "c": .string("x")])
        let two = doc(["_id": .int32(2), "c": .string("y")])
        let source = MongoDocumentSource()
        source.append([try one.bytes(), try two.bytes()])
        var changes = MongoChanges(database: "d", collection: "c", kind: .collection)
        try changes.edit(one, path: ["c"], to: .string("z"))
        try changes.edit(one, path: ["a", "b"], to: nil)
        try changes.delete(two)
        try changes.insert(doc(["_id": .int32(3), "c": .string("new")]))
        source.changes = changes
        let c = try #require(source.paths.firstIndex(of: ["c"])), a = try #require(source.paths.firstIndex(of: ["a"]))
        #expect(source.rowCount == 3 && source.loadedCount == 2)
        #expect(source.bsonValue(0, c) == .string("z") && source.mark(0, c) == .edited && source.mark(0, a) == .edited)
        #expect(source.bsonValue(0, a) == .document(BSONDocument()))
        #expect(source.mark(0, 0) == .none && source.mark(1, c) == .deleted)
        #expect(source.bsonValue(2, c) == .string("new") && source.mark(2, 0) == .inserted && source.document(2)?["_id"] == .int32(3))
        #expect(source.row(of: .int32(2)) == 1 && source.document(0) == one, "the document as loaded")

        // Taking changes back, and what a stopped Apply leaves: deletes, edits, inserts in that order.
        var rest = changes
        rest.dropApplied(2)
        #expect(rest.deletes.isEmpty && rest.edits.isEmpty && rest.inserts.count == 1)
        changes.revert(.int32(1))
        changes.removeInserts([0])
        #expect(changes.edits.isEmpty && changes.inserts.isEmpty && changes.deletes.count == 1)
    }

    @Test func newObjectIdsDiffer() {
        let ids = (0..<1_000).map { _ in BSONObjectId.generate() }
        #expect(Set(ids).count == 1_000)
        let seconds = ids[0].bytes.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
        #expect(abs(Double(seconds) - Date().timeIntervalSince1970) < 60)
    }
}

// MARK: The lab

private let database = "lane_mongo_edit"

/// A Mongo lab server connected in a window of its own: the standalone, or the replica set through the SOCKS proxy.
@MainActor private func editWindow(replicaSet: Bool = false) async throws -> (MainWindowController, AgentServer, OpenMongoConnection) {
    var saved = SavedConnection(name: "Mongo solo", host: "127.0.0.1", port: MongoLab.soloPort, user: MongoLab.airsql.user)
    var password = MongoLab.airsql.password
    if replicaSet {
        saved = SavedConnection(name: "Mongo set", route: .proxy)
        password = saved.apply(try MongoURI("mongodb://airsql:airsql-pass@" + MongoLab.allSeeds.dropFirst(10))) ?? ""
        saved.tls.caFile = Lab.caFile
        saved.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: Lab.socksProxy.port, user: Lab.socksProxy.user)
    } else {
        saved.tls.mode = .off
    }
    saved.engine = .mongodb
    let model = testModel([saved])
    model.setSavedPassword(saved.id.uuidString, password)
    model.setSavedPassword(saved.proxySecretKey, Lab.socksProxy.password)
    let (main, harness) = appWindow(model)
    _ = await call(harness, "select", ["pane": "sidebar", "names": [saved.name]])
    #expect(await call(harness, "menu", ["path": "Connection > Connect"]).error == nil)
    #expect(await eventually(timeout: 40) { model.openMongo[saved.id] != nil })
    return (main, harness, try #require(model.openMongo[saved.id]))
}

/// A fresh `collection` of the scratch database holding `documents`.
private func scratch(_ open: OpenMongoConnection, _ collection: String, _ documents: [BSONDocument]) async throws {
    let session = try await open.connection.session(.main)
    _ = try? await session.command(doc(["drop": .string(collection)]), database: database)
    _ = try await session.command(doc(["create": .string(collection)]), database: database)
    if !documents.isEmpty { _ = try await session.insertMany(database: database, collection: collection, documents) }
}

private func dropScratch(_ open: OpenMongoConnection) async throws {
    _ = try await open.connection.session(.main).command(doc(["dropDatabase": .int32(1)]), database: database)
}

private func stored(_ open: OpenMongoConnection, _ collection: String) async throws -> [BSONDocument] {
    try await open.connection.session(.main).find(database: database, collection: collection, MongoFind(sort: doc(["_id": .int32(1)])))
        .next().map { try BSONDocument(bytes: $0) }
}

/// A collection's tab, its first documents loaded.
@MainActor private func editTab(_ collection: String, kind: MongoCollectionInfo.Kind = .collection, in database: String = database,
                                _ main: MainWindowController, _ open: OpenMongoConnection) async throws -> MongoCollectionController {
    main.openCollection(MongoCollectionInfo(name: collection, kind: kind), database: database, connection: open.saved.id)
    let tab = try #require(main.selectedTab?.content as? MongoCollectionController)
    #expect(await eventually(timeout: 20) { tab.loading == nil })
    #expect(tab.problem == nil, "\(tab.problem ?? "")")
    return tab
}

extension MongoCollectionController {
    func column(_ path: String) -> Int { source.paths.firstIndex(of: path.components(separatedBy: ".")) ?? -1 }

    /// Types `text` into a cell, as the grid's editor hands it over.
    func type(_ text: String, row: Int, _ path: String) {
        dataGrid(grid, didEditRow: row, column: column(path), text: text)
    }
}

/// The document editor on the window, its text set, then kept.
@MainActor private func keepInSheet(_ main: MainWindowController, _ text: String, type: Int? = nil) async throws {
    #expect(await eventually(timeout: 5) { main.window?.attachedSheet?.windowController is MongoValueSheet })
    let sheet = try #require(main.window?.attachedSheet?.windowController as? MongoValueSheet)
    sheet.textView.string = text
    if let type { sheet.type?.selectItem(at: type + 2) }
    sheet.keepText(nil)
}

/// Apply, its sheet's Run pressed; back when it has run. The sheet's words, for the checks.
@MainActor private func apply(_ tab: MongoCollectionController, _ main: MainWindowController, _ harness: AgentServer) async throws -> String {
    tab.applyChanges(nil)
    #expect(await eventually(timeout: 5) { main.window?.attachedSheet?.windowController is SQLPreviewSheet })
    let content = try #require(main.window?.attachedSheet?.contentView)
    let words = [find(NSTextField.self, id: "preview.heading", in: content)?.stringValue ?? "",
                 find(NSView.self, id: "preview.warning", in: content)?.accessibilityLabel() ?? "",
                 (find(NSTextView.self, id: "preview.sql", in: content)?.string ?? "")].joined(separator: "\n")
    #expect(await call(harness, "press", ["id": "preview.run"]).error == nil)
    #expect(await eventually(timeout: 30) { tab.loading == nil && !tab.isApplying })
    return words
}

extension AppTests {
    @Test(.enabled(if: MongoLab.enabled)) func mongoEditsKeepTypesAndApplyOnAStandalone() async throws {
        let (main, harness, open) = try await editWindow()
        let oid = BSONObjectId.generate()
        try await scratch(open, "types", [
            doc(["_id": .int32(1), "s": .string("a"), "i": .int32(1), "l": .int64(1), "d": .double(1.5),
                 "dec": .decimal128(BSONDecimal128("1.5")!), "b": .bool(true), "t": .datetime(0), "o": .objectId(oid),
                 "arr": .array([.int32(1)]), "gone": .string("x")]),
            doc(["_id": .int32(2), "s": .string("b")]), doc(["_id": .int32(3), "s": .string("c")]),
        ])
        let tab = try await editTab("types", main, open)
        #expect(tab.source.loadedCount == 3 && tab.editingOff == nil && tab.notice.isHidden)

        // Each common type, typed as the editor shows it, keeps its type.
        let newID = BSONObjectId.generate()
        for (path, text, expected) in [("s", "hello", BSONValue.string("hello")), ("i", "5", .int32(5)), ("l", "7", .int64(7)),
                                       ("d", "2", .double(2)), ("dec", "2.50", .decimal128(BSONDecimal128("2.50")!)),
                                       ("b", "false", .bool(false)), ("t", "ISODate(\"2024-01-02T03:04:05Z\")", .datetime(1_704_164_645_000)),
                                       ("o", newID.hex, .objectId(newID)), ("arr", "[1, \"two\"]", .array([.int32(1), .string("two")]))] {
            #expect(tab.dataGrid(tab.grid, check: text, row: 0, column: tab.column(path)) == nil, "\(path)")
            tab.type(text, row: 0, path)
            #expect(tab.source.bsonValue(0, tab.column(path)) == expected, "\(path)")
            #expect(tab.source.mark(0, tab.column(path)) == .edited)
        }
        // Another type is refused with the reason, until it is chosen.
        #expect(tab.dataGrid(tab.grid, check: "\"x\"", row: 0, column: tab.column("b"))?.contains("Choose the new type") == true)
        #expect(tab.whyReadOnly(0, tab.column("_id"))?.contains("_id is read-only") == true)
        #expect(!tab.dataGrid(tab.grid, canEditRow: 0, column: tab.column("_id")))
        tab.grid.selection.select(GridPosition(row: 0, column: tab.grid.columnOrder.firstIndex(of: tab.column("i"))!))
        tab.editValue(nil)
        try await keepInSheet(main, "\"5\"", type: MongoValueSheet.types.firstIndex(of: "string"))
        #expect(tab.source.bsonValue(0, tab.column("i")) == .string("5"))
        // Remove Field.
        tab.grid.selection.select(GridPosition(row: 0, column: tab.grid.columnOrder.firstIndex(of: tab.column("gone"))!))
        tab.removeField(nil)
        #expect(tab.source.bsonValue(0, tab.column("gone")) == nil && tab.source.mark(0, tab.column("gone")) == .edited)

        // Insert Document (an ObjectId given), Duplicate Document (a new one), Delete Documents; Undo and Redo.
        tab.addRow(nil)
        try await keepInSheet(main, "{ s: 'new' }")
        #expect(tab.source.rowCount == 4 && tab.source.mark(3, 0) == .inserted)
        guard case .objectId? = tab.source.document(3)?["_id"] else { Issue.record("no ObjectId"); return }
        tab.grid.selection.selectRow(1)
        tab.duplicateRow(nil)
        #expect(tab.source.rowCount == 5 && tab.source.document(4)?["s"] == .string("b") && tab.source.document(4)?["_id"] != .int32(2))
        tab.grid.selection.selectRow(2)
        tab.deleteRows(nil)
        #expect(tab.source.mark(2, 0) == .deleted && !tab.dataGrid(tab.grid, canEditRow: 2, column: tab.column("s")))
        tab.undo(nil)
        #expect(tab.source.mark(2, 0) == .none)
        tab.redo(nil)
        #expect(tab.source.mark(2, 0) == .deleted && tab.isEdited && tab.notice.text.stringValue.hasPrefix("4 pending changes"))

        // Apply: the standalone's warning first, the exact commands, then the documents read back.
        let sheet = try await apply(tab, main, harness)
        #expect(sheet.contains("Apply 4 changes to \(database).types?") && sheet.contains("standalone"), "\(sheet)")
        #expect(sheet.contains("updateOne({ _id: 1, s: { $eq: \"a\" }") && sheet.contains("deleteOne({ _id: 3 }"), "\(sheet)")
        #expect(tab.changes.isEmpty && !tab.isEdited && main.window?.attachedSheet == nil)
        let now = try await stored(open, "types")
        #expect(now.count == 4 && !now.contains { $0["_id"] == .int32(3) })
        let first = try #require(now.first { $0["_id"] == .int32(1) })
        #expect(first["s"] == .string("hello") && first["i"] == .string("5") && first["l"] == .int64(7) && first["d"] == .double(2))
        #expect(first["dec"] == .decimal128(BSONDecimal128("2.50")!) && first["t"] == .datetime(1_704_164_645_000) && first["gone"] == nil)
        #expect(now.contains { $0["s"] == .string("new") })
        #expect(tab.source.loadedCount == 4 && tab.source.rowCount == 4 && tab.source.document(0)?["s"] == .string("hello"))
        tab.close()
        try await dropScratch(open)
    }

    @Test(.enabled(if: MongoLab.enabled)) func mongoApplyOnAReplicaSetIsAllOrNothing() async throws {
        let (main, harness, open) = try await editWindow(replicaSet: true)
        try await scratch(open, "conflict", [doc(["_id": .int32(1), "n": .int32(1)]), doc(["_id": .int32(2), "n": .int32(2)])])
        let tab = try await editTab("conflict", main, open)
        tab.type("10", row: 0, "n")
        tab.type("20", row: 1, "n")
        // Someone else changes the second document: Apply stops there, and the first one's change is rolled back too.
        _ = try await open.connection.session(.main).updateOne(database: database, collection: "conflict", filter: doc(["_id": .int32(2)]),
                                                                update: doc(["$set": .document(doc(["n": .int32(99)]))]))
        let sheet = try await apply(tab, main, harness)
        #expect(sheet.contains("Apply 2 changes") && !sheet.contains("standalone"), "\(sheet)")
        #expect(await eventually(timeout: 5) { main.window?.attachedSheet != nil }, "the report")
        let report = try #require(main.window?.attachedSheet?.contentView)
        let said = [find(NSTextField.self, in: report)].compactMap { $0?.stringValue }
        #expect(await call(harness, "press", ["title": "OK"]).error == nil, "\(said)")
        #expect(try await stored(open, "conflict").map { $0["n"] } == [.int32(1), .int32(99)], "nothing applied")
        #expect(tab.changes.edits.count == 2, "the changes stay to fix or revert")
        // Revert All, then a change that applies.
        tab.revertAllChanges(nil)
        #expect(!tab.isEdited)
        tab.refresh(nil)
        #expect(await eventually(timeout: 20) { tab.loading == nil && tab.source.document(1)?["n"] == .int32(99) })
        tab.type("3", row: 0, "n")
        _ = try await apply(tab, main, harness)
        #expect(main.window?.attachedSheet == nil && !tab.isEdited)
        #expect(try await stored(open, "conflict").map { $0["n"] } == [.int32(3), .int32(99)])
        tab.close()
        try await dropScratch(open)
    }

    @Test(.enabled(if: MongoLab.enabled)) func mongoEditingSaysWhyNotAndEachTabReadsOnItsOwn() async throws {
        let (main, harness, open) = try await editWindow()
        try await scratch(open, "rules", [doc(["_id": .int32(1), "s": .string("a")]), doc(["_id": .int32(2), "s": .string("b")]),
                                          doc(["_id": .int32(3), "s": .string("c")])])
        let tab = try await editTab("rules", main, open)

        // A projection: whole documents aren't loaded, so nothing is edited.
        tab.bar.projection.stringValue = "{ s: 1 }"
        tab.run()
        #expect(await eventually(timeout: 20) { tab.loading == nil })
        #expect(tab.editingOff?.hasPrefix("Clear Project to edit") == true && !tab.dataGrid(tab.grid, canEditRow: 0, column: tab.column("s")))
        let insert = Commands.addRow.item()
        #expect(!tab.validateMenuItem(insert) && insert.toolTip?.hasPrefix("Clear Project") == true)
        #expect(tab.notice.text.stringValue.hasPrefix("Read-only. Clear Project"))
        tab.bar.projection.stringValue = ""
        tab.run()
        #expect(await eventually(timeout: 20) { tab.loading == nil && tab.editingOff == nil })

        // Closing with changes asks: Cancel stays, Discard closes.
        tab.type("z", row: 0, "s")
        var closes: Bool?
        tab.shouldClose { closes = $0 }
        #expect(await eventually(timeout: 5) { main.window?.attachedSheet != nil })
        #expect(await call(harness, "press", ["title": "Cancel"]).error == nil)
        #expect(await eventually(timeout: 5) { closes == false } && tab.isEdited)
        #expect(main.unfinishedWork().contains { $0.hasPrefix("rules on Mongo solo: 1 pending change") })
        tab.shouldClose { closes = $0 }
        #expect(await eventually(timeout: 5) { main.window?.attachedSheet != nil })
        #expect(await call(harness, "press", ["title": "Discard"]).error == nil)
        #expect(await eventually(timeout: 5) { closes == true } && !tab.isEdited)

        // A view is read-only, and says why.
        let view = try await editTab("all_types_names", kind: .view, in: "fixture", main, open)
        #expect(view.whyReadOnly(0, 0)?.contains("is a view") == true && view.notice.text.stringValue.hasPrefix("Read-only."))

        // Cancel in one tab ends its read only: another tab's read, on its own session, goes on.
        let slow = try await editTab("rules", main, open)
        slow.bar.filter.stringValue = "{ $where: \"sleep(1000) || true\" }"
        slow.run()
        let many = try await editTab("many", in: "fixture", main, open)
        many.bar.filter.stringValue = "{ $where: \"sleep(20) || true\" }"
        many.run()
        try await Task.sleep(nanoseconds: 500_000_000)
        many.cancelQuery(nil)
        #expect(await eventually(timeout: 10) { many.loading == nil })
        #expect(slow.loading != nil, "still reading")
        #expect(await eventually(timeout: 20) { slow.loading == nil })
        #expect(slow.problem == nil && slow.source.rowCount == 3, "\(slow.problem ?? "")")
        for tab in [view, slow, many] { tab.close() }
        try await dropScratch(open)
    }
}

// MARK: Pictures

extension AppTests {
    @MainActor @Suite(.enabled(if: MongoLab.enabled && ProcessInfo.processInfo.environment["AIRSQL_SCREENSHOTS"] == "1"))
    struct MongoEditScreenshotTests {
        @Test func mongoEditScreens() async throws {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let (main, harness, open) = try await editWindow()
                main.window?.appearance = NSAppearance(named: appearance)
                try await scratch(open, "people", (1...6).map { n in
                    doc(["_id": .int32(Int32(n)), "name": .string(["Ann", "Bo", "Cy", "Di", "Ed", "Flo"][n - 1]), "age": .int32(Int32(20 + n)),
                         "city": .string(["Oslo", "Rome", "Lima", "Kyiv", "Pune", "Bern"][n - 1])])
                })
                let tab = try await editTab("people", main, open)
                tab.type("Anna", row: 0, "name")
                tab.type("41", row: 1, "age")
                tab.grid.selection.selectRow(3)
                tab.deleteRows(nil)
                tab.addRow(nil)
                try await keepInSheet(main, "{ name: 'Gus', age: 30, city: 'Oslo' }")
                main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
                main.window?.orderFront(nil)
                try await save(harness, "mongo-pending-\(suffix)", target: "main")
                tab.applyChanges(nil)
                #expect(await eventually(timeout: 5) { main.window?.attachedSheet?.windowController is SQLPreviewSheet })
                try await save(harness, "mongo-apply-\(suffix)", target: "sheet")
                _ = await call(harness, "press", ["id": "preview.cancel"])
                tab.revertAllChanges(nil)
                tab.close()
                try await dropScratch(open)
                main.window?.orderOut(nil)
            }
        }

        private func save(_ harness: AgentServer, _ name: String, target: String) async throws {
            let reply = await call(harness, "screenshot", ["target": target, "scale": 2])
            let image = try #require(reply.image, "\(name): \(reply.error ?? "")")
            try #require(image.representation(using: .png, properties: [:])).write(to: ScreenshotTests.folder.appendingPathComponent(name + ".png"))
        }
    }
}
