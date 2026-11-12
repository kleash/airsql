// A collection's indexes (docs/dev/mongo-plan.md, Indexes; lane M-index): the Create Index sheet's fields read as
// createIndexes takes them, an index's options in a few words, and then, on the Mongo lab, listing with sizes and use,
// create (single, compound, unique over duplicates, TTL, partial), hide and unhide, and drop, on the standalone and the
// replica set; then the Indexes page, the Create Index sheet and the tree's index commands in the app, and their pictures.
import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

struct MongoIndexTests {
    @Test func theSheetsFieldsGiveTheCommandOrSayWhichIsWrong() throws {
        let made = try MongoIndex.create(keys: "{ a: 1, b: -1 }", unique: true, expireAfterSeconds: " 60 ",
                                         partial: "{ a: { $gt: 5 } }", collation: "{ locale: 'fr' }")
        let command = MongoIndex.createCommand(collection: "c", keys: made.keys, options: made.options)
        #expect(MongoIndex.shellForm(command, database: "d") == "db.getSiblingDB(\"d\").runCommand({ createIndexes: \"c\", indexes: "
                + "[ { key: { a: 1, b: -1 }, name: \"a_1_b_-1\", unique: true, expireAfterSeconds: 60, partialFilterExpression: "
                + "{ a: { $gt: 5 } }, collation: { locale: \"fr\" } } ] })")
        let named = try MongoIndex.create(keys: "{ body: 'text' }", name: " words ", hidden: true)
        #expect(MongoIndex.createCommand(collection: "c", keys: named.keys, options: named.options).shellForm()
                == "{ createIndexes: \"c\", indexes: [ { key: { body: \"text\" }, name: \"words\", hidden: true } ] }")
        for (fields, field) in [(("", "", ""), "Keys"), (("{}", "", ""), "Keys"), (("{ a: 1 }", "-1", ""), "Expire After"),
                                (("{ a: 1 }", "", "{ a: "), "Partial Filter")] {
            #expect { try MongoIndex.create(keys: fields.0, expireAfterSeconds: fields.1, partial: fields.2) } throws: {
                ($0 as? MongoQueryText.Problem)?.field == field
            }
        }
        #expect(MongoIndex.hideCommand(collection: "c", name: "a_1", hidden: true).shellForm()
                == "{ collMod: \"c\", index: { name: \"a_1\", hidden: true } }")
        #expect(MongoIndex.dropCommand(collection: "c", name: "a_1").shellForm() == "{ dropIndexes: \"c\", index: \"a_1\" }")
    }

    @Test func anIndexsOptionsInAFewWords() throws {
        let spec = try BSONDocument(shellForm: "{ v: 2, key: { loc: '2dsphere', 'a.$**': 1, t: 'text' }, name: 'x', unique: true, "
                                    + "sparse: true, expireAfterSeconds: 3600, partialFilterExpression: { a: 1 }, "
                                    + "collation: { locale: 'fr', strength: 2 }, hidden: true }")
        #expect(MongoIndex(spec: spec).options == ["2dsphere", "wildcard", "text", "unique", "sparse", "TTL 3600 s", "partial { a: 1 }",
                                                   "collation fr", "hidden"])
        #expect(MongoIndex(spec: try BSONDocument(shellForm: "{ key: { _id: 1 }, name: '_id_' }")).options.isEmpty)
    }

    @Test func aDuplicateKeyNamesTheFirstDuplicate() {
        let error = AirSQLError(.duplicate, "A document with the same key already exists.",
                                details: "Error 11000: Index build failed: 1: Collection d.c ( 2 ) :: caused by :: E11000 duplicate "
                                    + "key error collection: d.c index: n_1 dup key: { n: 1 }", code: 11000)
        #expect(MongoIndex.createFailure(error) == "The index can't be unique: some documents share the same keys, such as { n: 1 }. "
                + "Remove the duplicates, or make the index without Unique.")
    }
}

@Suite(.serialized, .enabled(if: MongoLab.enabled, "Mongo lab: AIRSQL_MONGO_LAB=1 ./test.sh --filter MongoIndex"))
struct MongoIndexLabTests {
    static let database = "lane_mongo_index"

    /// The standalone directly, and the replica set through the SOCKS proxy.
    static func both() -> [MongoConnection] {
        let solo = SavedConnection(name: "Mongo lab", host: "127.0.0.1", port: MongoLab.soloPort, user: "airsql", route: .direct)
        var set = SavedConnection(name: "Mongo lab", host: MongoLab.members[0], port: 27017, user: "airsql", route: .proxy)
        let proxy = Lab.socksProxy
        set.proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: proxy.port, user: proxy.user)
        return [MongoConnection(uri: "mongodb://127.0.0.1:\(MongoLab.soloPort)/", user: "airsql", password: "airsql-pass",
                                route: MongoRoute(solo), name: "Mongo lab"),
                MongoConnection(uri: MongoLab.allSeeds, user: "airsql", password: "airsql-pass", tls: MongoLab.tls,
                                route: MongoRoute(set, proxyPassword: proxy.password), name: "Mongo lab")]
    }

    @Test func listCreateHideAndDropOnEachServer() async throws {
        for connection in Self.both() {
            try await connection.connect()
            let session = try await connection.session(.data)
            defer { Task { await connection.close() } }

            // The seed: only _id_, with its size and use on the member that answered.
            let seed = try await session.indexes(database: "fixture", collection: "many")
            #expect(seed.unavailable == nil, "\(seed.unavailable ?? "")")
            let id = try #require(seed.indexes.first)
            #expect(seed.indexes.map(\.name) == ["_id_"] && (id.size ?? 0) > 0 && id.ops != nil && id.since != nil && id.host != nil)

            let db = Self.database, c = "things"
            _ = try? await session.command(BSONDocument([("drop", .string(c))]), database: db)
            _ = try await session.insertMany(database: db, collection: c, (1...20).map {
                BSONDocument([("_id", .int32(Int32($0))), ("n", .int32(Int32($0 % 5))), ("at", .datetime(0)), ("tag", .string("t\($0)"))])
            })
            func create(_ keys: String, unique: Bool = false, ttl: String = "", partial: String = "") async throws {
                let made = try MongoIndex.create(keys: keys, unique: unique, expireAfterSeconds: ttl, partial: partial)
                try await session.createIndex(database: db, collection: c, keys: made.keys, options: made.options)
            }
            try await create("{ n: 1 }")
            try await create("{ n: 1, tag: -1 }")
            try await create("{ at: 1 }", ttl: "3600")
            try await create("{ tag: 1 }", partial: "{ n: { $gt: 2 } }")
            // Unique over documents that share n: the error names the first duplicate.
            do {
                try await create("{ n: -1 }", unique: true)
                Issue.record("a unique index over duplicates was made")
            } catch {
                #expect(MongoIndex.createFailure(error).hasPrefix("The index can't be unique: some documents share the same keys, such as { n: "),
                        "\(MongoIndex.createFailure(error))")
            }
            try await create("{ tag: -1 }", unique: true)
            var listed = try await session.indexes(database: db, collection: c)
            #expect(listed.indexes.map(\.name) == ["_id_", "n_1", "n_1_tag_-1", "at_1", "tag_1", "tag_-1"])
            #expect(listed.indexes.allSatisfy { $0.size != nil && $0.ops != nil }, "\(listed.unavailable ?? "")")
            #expect(listed.indexes[3].options == ["TTL 3600 s"] && listed.indexes[4].options == ["partial { n: { $gt: 2 } }"])
            #expect(listed.indexes[5].options == ["unique"])

            try await session.setIndexHidden(database: db, collection: c, name: "n_1", hidden: true)
            listed = try await session.indexes(database: db, collection: c)
            #expect(listed.indexes[1].isHidden && listed.indexes[1].options == ["hidden"])
            try await session.setIndexHidden(database: db, collection: c, name: "n_1", hidden: false)
            try await session.dropIndex(database: db, collection: c, name: "tag_-1")
            listed = try await session.indexes(database: db, collection: c)
            #expect(!listed.indexes[1].isHidden && !listed.indexes.contains { $0.name == "tag_-1" })
            await #expect(throws: AirSQLError.self) { try await session.dropIndex(database: db, collection: c, name: "_id_") }
            _ = try await session.command(BSONDocument([("dropDatabase", .int32(1))]), database: db)
        }
    }
}

// MARK: The app

/// A scratch collection of 20 documents on the standalone, its tab open from the tree on its Indexes page.
@MainActor private func indexesTab(_ collection: String) async throws -> (MainWindowController, AgentServer, OpenMongoConnection, MongoCollectionController) {
    let (main, harness, mongo) = try await mongoWindow()
    let session = try await mongo.connection.session(.main), db = MongoIndexLabTests.database
    _ = try? await session.command(BSONDocument([("drop", .string(collection))]), database: db)
    _ = try await session.insertMany(database: db, collection: collection, (1...20).map {
        BSONDocument([("_id", .int32(Int32($0))), ("n", .int32(Int32($0 % 5))), ("tag", .string("t\($0)"))])
    })
    mongo.refresh()
    #expect(await eventually(timeout: 20) { mongo.databases?.contains { $0.name == db } == true && !mongo.isLoading })
    _ = try await open(MongoTreeItem(database: db), in: main, mongo)
    _ = try await open(MongoTreeItem(database: db, collection: collection), in: main, mongo)
    let kind = SidebarNode.Kind.mongo(mongo.saved.id, MongoTreeItem(database: db, collection: collection))
    #expect(main.sidebar.reveal(kind))
    main.sidebar.treeDoubleClicked(try #require(main.sidebar.treeNodes[kind]))
    let tab = try #require(main.selectedTab?.content as? MongoCollectionController)
    #expect(await call(harness, "menu", ["path": "Data > Collection > Indexes"]).error == nil)
    #expect(await eventually(timeout: 20) { tab.loading == nil && tab.page == .indexes && !tab.indexesView.indexes.isEmpty })
    return (main, harness, mongo, tab)
}

/// Presses the preview sheet's Run (typing `confirm` first, when it asks) and waits until the tab is idle again.
@MainActor private func approve(_ main: MainWindowController, _ harness: AgentServer, _ tab: MongoCollectionController,
                                showing text: String, confirm: String? = nil) async throws {
    _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
    let sheet = try #require(main.window?.attachedSheet?.windowController as? SQLPreviewSheet)
    let content = try #require(sheet.window?.contentView)
    let shown = try #require(find(NSTextView.self, id: "preview.sql", in: content)).string
    #expect(shown.contains(text), "\(shown)")
    if let confirm {
        #expect(!(find(NSButton.self, id: "preview.run", in: content)?.isEnabled ?? true), "Drop waits for the name")
        #expect(await call(harness, "set", ["id": "preview.confirm", "value": confirm]).error == nil)
    }
    #expect(await call(harness, "press", ["id": "preview.run"]).error == nil)
    _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
    #expect(await eventually(timeout: 20) { tab.loading == nil })
}

extension AppTests {
    @Test(.enabled(if: MongoLab.enabled)) func aCollectionsIndexesAreListedMadeHiddenAndDroppedFromItsTabAndTheTree() async throws {
        let (main, harness, mongo, tab) = try await indexesTab("ui_things")
        let id = mongo.saved.id, db = MongoIndexLabTests.database
        defer { Task { _ = try? await mongo.connection.session(.main).command(BSONDocument([("dropDatabase", .int32(1))]), database: db) } }
        // _id_ with its size and use, on the member named; it can't be dropped or hidden, and says why.
        #expect(tab.indexesView.indexes.map(\.name) == ["_id_"])
        #expect(!MongoIndexesView.text(tab.indexesView.indexes[0], "size").isEmpty && MongoIndexesView.text(tab.indexesView.indexes[0], "ops") == "0")
        #expect(tab.indexesView.caption.stringValue.hasPrefix("Uses on "), "\(tab.indexesView.caption.stringValue)")
        tab.indexesView.table.selectRowIndexes([0], byExtendingSelection: false)
        #expect(!tab.indexesView.dropButton.isEnabled && tab.indexesView.dropButton.toolTip?.hasPrefix("The _id index can't be dropped") == true)
        #expect(!tab.indexesView.hideButton.isEnabled && tab.indexesView.createButton.isEnabled)

        // Create Index…: a field that's wrong says so in the sheet; then the exact command, and the index made.
        tab.createIndex(nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        #expect(await call(harness, "set", ["id": "mongoIndex.keys", "value": "{ n: "]).error == nil)
        #expect(await call(harness, "press", ["id": "mongoIndex.preview"]).error == nil)
        let sheet = try #require(main.window?.attachedSheet?.windowController as? MongoIndexSheet)
        #expect(sheet.problem.stringValue.hasPrefix("Keys:") && !sheet.problem.isHidden)
        #expect(await call(harness, "set", ["id": "mongoIndex.keys", "value": "{ n: 1, tag: -1 }"]).error == nil)
        #expect(await call(harness, "set", ["id": "mongoIndex.partial", "value": "{ n: { $gt: 1 } }"]).error == nil)
        #expect(await call(harness, "press", ["id": "mongoIndex.preview"]).error == nil)
        try await approve(main, harness, tab, showing: "db.getSiblingDB(\"\(db)\").runCommand({ createIndexes: \"ui_things\", indexes: "
                          + "[ { key: { n: 1, tag: -1 }, name: \"n_1_tag_-1\", partialFilterExpression: { n: { $gt: 1 } } } ] })")
        #expect(await eventually(timeout: 20) { tab.indexesView.selected?.name == "n_1_tag_-1" })
        #expect(tab.indexesView.selected?.options == ["partial { n: { $gt: 1 } }"])
        #expect(await eventually(timeout: 20) { mongo.indexes[db + ".ui_things"]?.count == 2 }, "the tree's too")

        // Unique over documents that share n: the error says so in plain words and names the first duplicate.
        tab.createIndex(nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        #expect(await call(harness, "set", ["id": "mongoIndex.keys", "value": "{ n: 1 }"]).error == nil)
        #expect(await call(harness, "set", ["id": "mongoIndex.unique", "value": true]).error == nil)
        #expect(await call(harness, "press", ["id": "mongoIndex.preview"]).error == nil)
        try await approve(main, harness, tab, showing: "unique: true")
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        let alert = try #require(main.window?.attachedSheet)
        let words = Self.texts(in: alert.contentView!).joined(separator: " ")
        #expect(words.contains("The index can't be unique: some documents share the same keys, such as { n: "), "\(words)")
        _ = await call(harness, "press", ["title": "OK"])
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])

        // From the tree: the index row's menu hides it, then (on a Production connection, its name typed) drops it.
        let row = SidebarNode.Kind.mongo(id, MongoTreeItem(database: db, collection: "ui_things", index: "n_1_tag_-1"))
        #expect(main.sidebar.reveal(row))
        let menu = main.sidebar.treeMenu([try #require(main.sidebar.treeNodes[row])])
        #expect(menu.items.map(\.title).contains("Drop Index…") && menu.items.map(\.title).contains("Hide Index…"))
        main.sidebar.toggleIndexHidden(nil)
        try await approve(main, harness, tab, showing: "collMod: \"ui_things\", index: { name: \"n_1_tag_-1\", hidden: true }")
        #expect(await eventually(timeout: 20) { tab.indexesView.indexes.first { $0.name == "n_1_tag_-1" }?.isHidden == true })
        #expect(await eventually(timeout: 20) { !mongo.isLoading })
        let item = Commands.hideIndex.item()
        #expect(main.sidebar.validateMenuItem(item) && item.title == "Unhide Index…")
        var saved = try #require(main.model.connection(id))
        saved.colour = .production
        main.model.save(saved)
        main.sidebar.dropIndex(nil)
        try await approve(main, harness, tab, showing: "dropIndexes: \"ui_things\", index: \"n_1_tag_-1\"", confirm: "n_1_tag_-1")
        #expect(await eventually(timeout: 20) { tab.indexesView.indexes.map(\.name) == ["_id_"] })

        // Read-only: every index command is off, and says why.
        saved.readOnly = true
        main.model.save(saved)
        tab.indexesView.table.selectRowIndexes([0], byExtendingSelection: false)
        tab.updateIndexButtons()
        #expect(!tab.indexesView.createButton.isEnabled && tab.indexesView.createButton.toolTip?.hasPrefix("This connection is read-only") == true)
        let create = Commands.createIndex.item()
        #expect(!tab.validateMenuItem(create) && create.toolTip?.hasPrefix("This connection is read-only") == true)
        tab.close()
    }

    /// The strings of an alert's labels and text views.
    @MainActor static func texts(in view: NSView) -> [String] {
        view.subviews.flatMap { sub -> [String] in
            ((sub as? NSTextField).map { [$0.stringValue] } ?? []) + texts(in: sub)
        }
    }
}

extension AppTests.MongoScreenshotTests {
    @Test func indexesPageAndCreateSheet() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let (main, harness, mongo, tab) = try await indexesTab("shots_\(suffix)")
            main.window?.appearance = NSAppearance(named: appearance)
            main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
            main.window?.orderFront(nil)
            let session = try await mongo.connection.session(.main), db = MongoIndexLabTests.database, c = "shots_\(suffix)"
            for (keys, unique, ttl, partial) in [("{ n: 1, tag: -1 }", false, "", ""), ("{ tag: 1 }", true, "", ""),
                                                 ("{ at: 1 }", false, "86400", ""), ("{ n: -1 }", false, "", "{ n: { $gt: 2 } }")] {
                let made = try MongoIndex.create(keys: keys, unique: unique, expireAfterSeconds: ttl, partial: partial)
                try await session.createIndex(database: db, collection: c, keys: made.keys, options: made.options)
            }
            tab.refresh(nil)
            #expect(await eventually(timeout: 20) { tab.loading == nil && tab.indexesView.indexes.count == 5 })
            tab.indexesView.table.selectRowIndexes([1], byExtendingSelection: false)
            try await shot(harness, "mongo-indexes-\(suffix)")
            tab.createIndex(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await call(harness, "set", ["id": "mongoIndex.keys", "value": "{ email: 1 }"])
            _ = await call(harness, "set", ["id": "mongoIndex.unique", "value": true])
            _ = await call(harness, "set", ["id": "mongoIndex.collation", "value": "{ locale: \"en\", strength: 2 }"])
            try await shot(harness, "mongo-index-create-\(suffix)")
            _ = await call(harness, "press", ["id": "mongoIndex.cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            _ = try await session.command(BSONDocument([("dropDatabase", .int32(1))]), database: db)
            tab.close()
            main.window?.orderOut(nil)
        }
    }

    private func shot(_ harness: AgentServer, _ name: String) async throws {
        let reply = await call(harness, "screenshot", ["target": "main", "scale": 2])
        let image = try #require(reply.image, "\(name): \(reply.error ?? "")")
        try #require(image.representation(using: .png, properties: [:])).write(to: AppTests.ScreenshotTests.folder.appendingPathComponent(name + ".png"))
    }
}
