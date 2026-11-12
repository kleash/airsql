// Collections, views and databases (docs/dev/mongo-plan.md, Phase 2 admin; lane P2-admin): the commands the sheets'
// fields give and the names refused; then, on the Mongo lab, create (plain, capped, time-series, clustered), views,
// validation rules with the count of documents that fail them, rename and drop, on the standalone and the replica set;
// then the tree's menus in the app: a collection made from its sheet, Production's typed name before a drop, the tab of
// what was dropped, refusals and a read-only connection; and the sheets' pictures.
import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

struct MongoAdminTests {
    @Test func theSheetsFieldsGiveTheCommandOrSayWhichIsWrong() throws {
        #expect(try MongoAdmin.createCollection(database: "d", name: " c ").shellForm == "db.getSiblingDB(\"d\").runCommand({ create: \"c\" })")
        #expect(try MongoAdmin.createCollection(database: "d", name: "c", size: "4096", max: "10").command.shellForm()
                == "{ create: \"c\", capped: true, size: NumberLong(4096), max: NumberLong(10) }")
        #expect(try MongoAdmin.createCollection(database: "d", name: "c", timeField: "at", metaField: "sensor", granularity: "minutes")
            .command.shellForm() == "{ create: \"c\", timeseries: { timeField: \"at\", metaField: \"sensor\", granularity: \"minutes\" } }")
        #expect(try MongoAdmin.createCollection(database: "d", name: "c", clustered: true, collation: "{ locale: 'fr' }",
                                                validator: "{ n: { $gte: 0 } }", level: "moderate", action: "warn").command.shellForm()
                == "{ create: \"c\", clusteredIndex: { key: { _id: 1 }, unique: true }, collation: { locale: \"fr\" }, "
                + "validator: { n: { $gte: 0 } }, validationLevel: \"moderate\", validationAction: \"warn\" }")
        #expect(try MongoAdmin.createView(database: "d", name: "v", on: "c", pipeline: "[{ $match: { n: 1 } }, { $project: { n: 1 } }]")
            .command.shellForm() == "{ create: \"v\", viewOn: \"c\", pipeline: [ { $match: { n: 1 } }, { $project: { n: 1 } } ] }")
        #expect(try MongoAdmin.drop(database: "d", collection: "c").command.shellForm() == "{ drop: \"c\" }")
        #expect(try MongoAdmin.dropDatabase("d").command.shellForm() == "{ dropDatabase: 1 }")
        let rename = try MongoAdmin.rename(database: "d", collection: "c", to: "e")
        #expect(rename.database == "admin" && rename.command.shellForm() == "{ renameCollection: \"d.c\", to: \"d.e\", dropTarget: false }")
        let rules = try MongoAdmin.validator("{ $jsonSchema: { required: ['n'] } }")
        #expect(try MongoAdmin.setValidation(database: "d", collection: "c", validator: rules, level: "strict", action: "error").command.shellForm()
                == "{ collMod: \"c\", validator: { $jsonSchema: { required: [ \"n\" ] } }, validationLevel: \"strict\", validationAction: \"error\" }")
        #expect(MongoAdmin.failing(rules).shellForm() == "{ $nor: [ { $jsonSchema: { required: [ \"n\" ] } } ] }")
        #expect(try MongoAdmin.validator("  ").fields.isEmpty)

        for (make, field) in [({ try MongoAdmin.createCollection(database: "d", name: "") }, "Name"),
                              ({ try MongoAdmin.createCollection(database: "a b", name: "c") }, "Database"),
                              ({ try MongoAdmin.createCollection(database: "d", name: "c$") }, "Name"),
                              ({ try MongoAdmin.createCollection(database: "d", name: "c", size: "-1") }, "Size"),
                              ({ try MongoAdmin.createCollection(database: "d", name: "c", max: "5") }, "Size"),
                              ({ try MongoAdmin.createCollection(database: "d", name: "c", metaField: "m") }, "Time Field"),
                              ({ try MongoAdmin.createCollection(database: "d", name: "c", validator: "{ n: ") }, "Validator"),
                              ({ try MongoAdmin.createView(database: "d", name: "v", on: "c", pipeline: "[{ n: 1 }]") }, "Pipeline"),
                              ({ try MongoAdmin.rename(database: "d", collection: "c", to: "c") }, "Name"),
                              // MongoDB's own databases and system collections: refused, with the reason.
                              ({ try MongoAdmin.dropDatabase("admin") }, "Database"),
                              ({ try MongoAdmin.createCollection(database: "Config", name: "c") }, "Database"),
                              ({ try MongoAdmin.drop(database: "d", collection: "system.views") }, "Name")] as [(() throws -> MongoAdminCommand, String)] {
            #expect { try make() } throws: { ($0 as? MongoQueryText.Problem)?.field == field }
        }
        #expect(MongoAdmin.refusal(database: "local") == "local is MongoDB's own database: AirSQL doesn't change it")
        #expect(MongoAdmin.refusal(database: "d", collection: "system.js") == "system.js is a system collection, which MongoDB keeps itself")
    }

    @Test func theRulesNowComeFromListCollections() throws {
        let info = MongoCollectionInfo(name: "c", kind: .collection, options: try BSONDocument(shellForm:
            "{ validator: { n: { $gte: 0 } }, validationLevel: 'moderate', validationAction: 'warn' }"))
        let now = MongoAdmin.validation(info)
        #expect(try BSONDocument(shellForm: now.validator) == BSONDocument([("n", .document(BSONDocument([("$gte", .int32(0))])))]))
        #expect(now.level == "moderate" && now.action == "warn")
        #expect(MongoAdmin.validation(MongoCollectionInfo(name: "c", kind: .collection)) == ("", "strict", "error"))
    }

    @Test @MainActor func everyCommandIsOffWithItsReason() {
        let saved = SavedConnection(name: "m", host: "h", port: 1, user: "")
        let open = OpenMongoConnection(saved: saved, connection: MongoConnection(uri: "mongodb://h:1/", route: MongoRoute(saved), name: "m"),
                                       server: MongoServerInfo(version: "7.0"))
        func why(_ command: Command, _ ref: MongoCollectionRef?) -> String? {
            var title = command.title
            return MongoAdminActions.reason(command.action, ref, model: nil, title: &title)
        }
        let view = MongoCollectionRef(open: open, database: "d", collection: "v", kind: .view)
        #expect(why(Commands.renameCollection, view) == "A view can't be renamed: drop it and create it again under the new name")
        #expect(why(Commands.editValidation, view) == "Views and time-series collections have no validation rules")
        var title = Commands.dropCollection.title
        #expect(MongoAdminActions.reason(Commands.dropCollection.action, view, model: nil, title: &title) == nil && title == "Drop View…")
        let admin = MongoCollectionRef(open: open, database: "admin", collection: "", kind: .collection)
        #expect(why(Commands.createCollection, admin) == "admin is MongoDB's own database: AirSQL doesn't change it")
        #expect(why(Commands.dropMongoDatabase, admin) == "admin is MongoDB's own database: AirSQL doesn't change it")
        let connectionOnly = MongoCollectionRef(open: open, database: "", collection: "", kind: .collection)
        #expect(why(Commands.createMongoDatabase, connectionOnly) == nil)
        #expect(why(Commands.createCollection, connectionOnly) == "Select a database or collection in the tree first")
        #expect(why(Commands.dropCollection, nil)?.hasPrefix("Select a MongoDB") == true)
    }
}

@Suite(.serialized, .enabled(if: MongoLab.enabled, "Mongo lab: AIRSQL_MONGO_LAB=1 ./test.sh --filter MongoAdmin"))
struct MongoAdminLabTests {
    static let database = "lane_mongo_admin"

    @Test func createValidateRenameAndDropOnEachServer() async throws {
        for connection in MongoIndexLabTests.both() {
            try await connection.connect()
            let session = try await connection.session(.data)
            defer { Task { await connection.close() } }
            let db = Self.database
            _ = try? await session.run(MongoAdmin.dropDatabase(db))
            func kinds() async throws -> [String: MongoCollectionInfo] {
                Dictionary(uniqueKeysWithValues: try await session.listCollections(database: db).filter { !$0.name.hasPrefix("system.") }.map { ($0.name, $0) })
            }

            try await session.run(MongoAdmin.createCollection(database: db, name: "plain"))
            try await session.run(MongoAdmin.createCollection(database: db, name: "ring", size: "4096", max: "3"))
            try await session.run(MongoAdmin.createCollection(database: db, name: "readings", timeField: "at", metaField: "sensor",
                                                              granularity: "minutes"))
            try await session.run(MongoAdmin.createCollection(database: db, name: "ordered", clustered: true))
            _ = try await session.insertMany(database: db, collection: "plain", (1...6).map {
                BSONDocument([("_id", .int32(Int32($0))), ("n", .int32(Int32($0 - 3)))])
            })
            try await session.run(MongoAdmin.createView(database: db, name: "positive", on: "plain", pipeline: "[{ $match: { n: { $gt: 0 } } }]"))
            var found = try await kinds()
            #expect(found["plain"]?.kind == .collection && found["readings"]?.kind == .timeseries && found["positive"]?.kind == .view)
            #expect(found["ring"]?.options["capped"] == .bool(true) && found["ring"]?.options["max"]?.integer == 3)
            #expect(found["ordered"]?.options["clusteredIndex"] != nil)
            #expect(try await session.count(database: db, collection: "positive") == 3)
            // A capped collection keeps its newest three.
            _ = try await session.insertMany(database: db, collection: "ring", (1...5).map { BSONDocument([("_id", .int32(Int32($0)))]) })
            #expect(try await session.count(database: db, collection: "ring") == 3)

            // Rules: two documents already fail them; the count says so before the collMod, which then refuses a fourth.
            let rules = try MongoAdmin.validator("{ n: { $gte: 0 } }")
            #expect(try await session.countFailing(database: db, collection: "plain", validator: rules) == 2)
            try await session.run(MongoAdmin.setValidation(database: db, collection: "plain", validator: rules, level: "strict", action: "error"))
            found = try await kinds()
            let now = MongoAdmin.validation(try #require(found["plain"]))
            #expect(try BSONDocument(shellForm: now.validator) == rules && now.level == "strict" && now.action == "error")
            await #expect(throws: AirSQLError.self) {
                try await session.insertOne(database: db, collection: "plain", BSONDocument([("_id", .int32(99)), ("n", .int32(-1))]))
            }
            let schema = try MongoAdmin.validator("{ $jsonSchema: { required: ['n', 'tag'] } }")
            #expect(try await session.countFailing(database: db, collection: "plain", validator: schema) == 6)
            try await session.run(MongoAdmin.setValidation(database: db, collection: "plain", validator: BSONDocument(), level: "strict", action: "error"))
            #expect(MongoAdmin.validation(try #require(try await kinds()["plain"])).validator.isEmpty)

            // Rename, then over an existing name only with dropTarget.
            try await session.run(MongoAdmin.rename(database: db, collection: "plain", to: "renamed"))
            await #expect(throws: AirSQLError.self) { try await session.run(MongoAdmin.rename(database: db, collection: "renamed", to: "ordered")) }
            try await session.run(MongoAdmin.rename(database: db, collection: "renamed", to: "ordered", dropTarget: true))
            found = try await kinds()
            #expect(found["plain"] == nil && found["renamed"] == nil && found["ordered"]?.options["clusteredIndex"] == nil)

            try await session.run(MongoAdmin.drop(database: db, collection: "positive"))
            try await session.run(MongoAdmin.drop(database: db, collection: "ring"))
            #expect(Set(try await kinds().keys) == ["ordered", "readings"])
            try await session.run(MongoAdmin.dropDatabase(db))
            #expect(!(try await session.listDatabases()).contains { $0["name"] == .string(db) })
        }
    }
}

// MARK: The app

/// Presses the preview sheet's Run (typing `confirm` first, when it asks for it) and waits until nothing is under way.
@MainActor private func approve(_ main: MainWindowController, _ harness: AgentServer, showing text: String, confirm: String? = nil) async throws {
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
    #expect(await eventually(timeout: 20) { main.model.activity.running.isEmpty })
}

/// The standalone's window with a scratch database of one collection, open in the tree.
@MainActor private func adminWindow(_ db: String) async throws -> (MainWindowController, AgentServer, OpenMongoConnection) {
    let (main, harness, mongo) = try await mongoWindow()
    let session = try await mongo.connection.session(.main)
    _ = try? await session.run(MongoAdmin.dropDatabase(db))
    _ = try await session.insertMany(database: db, collection: "first", (1...4).map { BSONDocument([("_id", .int32(Int32($0))), ("n", .int32(Int32($0) - 2))]) })
    mongo.refresh()
    #expect(await eventually(timeout: 20) { mongo.databases?.contains { $0.name == db } == true && !mongo.isLoading })
    _ = try await open(MongoTreeItem(database: db), in: main, mongo)
    return (main, harness, mongo)
}

@MainActor private func select(_ item: MongoTreeItem, in main: MainWindowController, _ mongo: OpenMongoConnection) throws {
    #expect(main.sidebar.reveal(.mongo(mongo.saved.id, item)))
    main.window?.makeFirstResponder(main.sidebar.outline)
}

extension AppTests {
    @Test(.enabled(if: MongoLab.enabled)) func collectionsAreMadeRenamedAndDroppedFromTheTreeWithTheirNamesTypedOnProduction() async throws {
        let db = MongoAdminLabTests.database + "_ui"
        let (main, harness, mongo) = try await adminWindow(db)
        let id = mongo.saved.id

        // The database row's menu: Create Collection… asks its name, More Options its kind; a wrong field says so.
        try select(MongoTreeItem(database: db), in: main, mongo)
        let menu = main.sidebar.treeMenu([try #require(main.sidebar.treeNodes[.mongo(id, MongoTreeItem(database: db))])])
        #expect(["Create Collection…", "Create View…", "Create Database…", "Drop Database…"].allSatisfy(menu.items.map(\.title).contains))
        main.sidebar.createCollection(nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        #expect(await call(harness, "set", ["id": "mongoCreate.name", "value": "ring"]).error == nil)
        #expect(await call(harness, "press", ["id": "mongoCreate.more"]).error == nil)
        let sheet = try #require(main.window?.attachedSheet?.windowController as? MongoCreateSheet)
        sheet.kind.selectItem(at: 1)
        sheet.showOptions(nil)
        #expect(await call(harness, "set", ["id": "mongoCreate.size", "value": "lots"]).error == nil)
        #expect(await call(harness, "press", ["id": "mongoCreate.preview"]).error == nil)
        #expect(sheet.problem.stringValue.hasPrefix("Size:") && !sheet.problem.isHidden)
        #expect(await call(harness, "set", ["id": "mongoCreate.size", "value": "8192"]).error == nil)
        #expect(await call(harness, "press", ["id": "mongoCreate.preview"]).error == nil)
        try await approve(main, harness, showing: "db.getSiblingDB(\"\(db)\").runCommand({ create: \"ring\", capped: true, size: NumberLong(8192) })")
        #expect(await eventually(timeout: 20) { mongo.collections[db]?.contains { $0.name == "ring" && $0.options["capped"] == .bool(true) } == true })

        // Validation Rules… shows the count of documents that fail before the collMod.
        try select(MongoTreeItem(database: db, collection: "first"), in: main, mongo)
        main.sidebar.editValidation(nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        let rules = try #require(main.window?.attachedSheet?.windowController as? MongoValidationSheet)
        rules.validator.string = "{ n: { $gte: 0 } }"
        #expect(await call(harness, "press", ["id": "mongoValidation.check"]).error == nil)
        #expect(await eventually(timeout: 20) { rules.checked.stringValue == "1 document fails these rules." }, "\(rules.checked.stringValue)")
        #expect(await call(harness, "press", ["id": "mongoValidation.preview"]).error == nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        let words = Self.texts(in: try #require(main.window?.attachedSheet?.contentView)).joined(separator: " ")
        #expect(words.contains("1 document already fails these rules"), "\(words)")
        try await approve(main, harness, showing: "collMod: \"first\", validator: { n: { $gte: 0 } }, validationLevel: \"strict\"")
        #expect(await eventually(timeout: 20) { mongo.collections[db]?.first { $0.name == "first" }?.options["validator"] != nil })

        // A tab of the collection; on Production, Drop Collection… waits for its name, then the tab says it's gone.
        let first = SidebarNode.Kind.mongo(id, MongoTreeItem(database: db, collection: "first"))
        #expect(main.sidebar.reveal(first))
        main.sidebar.treeDoubleClicked(try #require(main.sidebar.treeNodes[first]))
        let tab = try #require(main.selectedTab?.content as? MongoCollectionController)
        #expect(await eventually(timeout: 20) { tab.loading == nil })
        var saved = try #require(main.model.connection(id))
        saved.colour = .production
        main.model.save(saved)
        try select(MongoTreeItem(database: db, collection: "first"), in: main, mongo)
        main.sidebar.dropCollection(nil)
        try await approve(main, harness, showing: "runCommand({ drop: \"first\" })", confirm: "first")
        #expect(await eventually(timeout: 20) { mongo.collections[db]?.contains { $0.name == "first" } == false })
        #expect(tab.problem == "\(db).first was dropped: close this tab.")
        tab.close()

        // MongoDB's own databases: every command off, with the reason.
        _ = try await open(MongoTreeItem(database: "admin"), in: main, mongo)
        try select(MongoTreeItem(database: "admin"), in: main, mongo)
        let create = Commands.createCollection.item(), dropDB = Commands.dropMongoDatabase.item()
        #expect(!main.sidebar.validateMenuItem(create) && create.toolTip == "admin is MongoDB's own database: AirSQL doesn't change it")
        #expect(!main.sidebar.validateMenuItem(dropDB))

        // Read-only: every admin command is off, and says why, in the tree and Data ▸ Collection.
        saved.readOnly = true
        main.model.save(saved)
        try select(MongoTreeItem(database: db, collection: "ring"), in: main, mongo)
        for command in Commands.mongoAdminCommands {
            let item = command.item()
            #expect(!main.sidebar.validateMenuItem(item) && item.toolTip?.hasPrefix("This connection is read-only") == true, "\(command.title)")
            item.target = MongoAdminMenu.shared
            #expect(!MongoAdminMenu.shared.validateMenuItem(item), "\(command.title)")
        }
        try await mongo.connection.session(.main).run(MongoAdmin.dropDatabase(db))
    }
}

extension AppTests.MongoScreenshotTests {
    @Test func createCollectionAndValidationSheets() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let db = MongoAdminLabTests.database + "_shots"
            let (main, harness, mongo) = try await adminWindow(db)
            main.window?.appearance = NSAppearance(named: appearance)
            main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
            main.window?.orderFront(nil)
            try select(MongoTreeItem(database: db), in: main, mongo)
            main.sidebar.createCollection(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            let sheet = try #require(main.window?.attachedSheet?.windowController as? MongoCreateSheet)
            _ = await call(harness, "set", ["id": "mongoCreate.name", "value": "readings"])
            _ = await call(harness, "press", ["id": "mongoCreate.more"])
            sheet.kind.selectItem(at: 2)
            sheet.showOptions(nil)
            _ = await call(harness, "set", ["id": "mongoCreate.timeField", "value": "at"])
            _ = await call(harness, "set", ["id": "mongoCreate.metaField", "value": "sensor"])
            try await shot(harness, "mongo-create-collection-\(suffix)")
            _ = await call(harness, "press", ["id": "mongoCreate.cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])

            let session = try await mongo.connection.session(.main)
            try await session.run(MongoAdmin.setValidation(database: db, collection: "first", validator: try MongoAdmin.validator(
                "{ $jsonSchema: { bsonType: 'object', required: ['n'], properties: { n: { bsonType: 'int', minimum: 0 } } } }"),
                                                           level: "moderate", action: "error"))
            try select(MongoTreeItem(database: db, collection: "first"), in: main, mongo)
            main.sidebar.editValidation(nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            let rules = try #require(main.window?.attachedSheet?.windowController as? MongoValidationSheet)
            _ = await call(harness, "press", ["id": "mongoValidation.check"])
            #expect(await eventually(timeout: 20) { rules.checked.stringValue.hasSuffix("these rules.") })
            try await shot(harness, "mongo-validation-\(suffix)")
            _ = await call(harness, "press", ["id": "mongoValidation.cancel"])
            _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
            try await session.run(MongoAdmin.dropDatabase(db))
            main.window?.orderOut(nil)
        }
    }

    private func shot(_ harness: AgentServer, _ name: String) async throws {
        let reply = await call(harness, "screenshot", ["target": "main", "scale": 2])
        let image = try #require(reply.image, "\(name): \(reply.error ?? "")")
        try #require(image.representation(using: .png, properties: [:])).write(to: AppTests.ScreenshotTests.folder.appendingPathComponent(name + ".png"))
    }
}
