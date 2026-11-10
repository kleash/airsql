// The aggregation tab's tools (docs/dev/mongo-plan.md, Phase 2 aggregate): the stage at the caret, saved pipelines, the
// view command, mongosh's command line (never a password); then, against the Mongo lab (AIRSQL_MONGO_LAB=1), Run to
// Here and Count Each Stage on the seed, saving and opening pipelines, Save as View in a scratch database (and its
// refusals), and exporting a pipeline's documents in each format; and their pictures (AIRSQL_SCREENSHOTS=1 too).
import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

struct MongoPipelineToolsTests {
    @Test @MainActor func theStageAtTheCaretIsTheOneItIsInOrAfter() throws {
        let text = "[\n  { $match: {} },\n  { $group: { _id: 1 } },\n  { $sort: { _id: 1 } }\n]"
        let stages = try MongoPipeline.stages(in: text)
        #expect(MongoAggregationController.stage(at: 0, in: stages) == 0)
        #expect(MongoAggregationController.stage(at: stages[1].range.lowerBound + 3, in: stages) == 1)
        #expect(MongoAggregationController.stage(at: stages[1].range.upperBound + 1, in: stages) == 1, "between stages: the one before")
        #expect(MongoAggregationController.stage(at: text.utf16.count, in: stages) == 2)
    }

    @Test func aViewIsOneCreateCommandAndWritingStagesAreFound() throws {
        let stages = try MongoPipeline.stages(in: "[{ $match: { n: 1 } }, { $project: { n: 1 } }]").map(\.document)
        let command = MongoPipeline.viewCommand("v", on: "c", stages, collation: try BSONDocument(shellForm: "{ locale: \"en\" }"))
        #expect(command.keys == ["create", "viewOn", "pipeline", "collation"])
        #expect(command["create"] == .string("v") && command["viewOn"] == .string("c") && command["pipeline"] == .array(stages.map { .document($0) }))
        #expect(MongoPipeline.viewCommand("v", on: "c", []).keys == ["create", "viewOn", "pipeline"])
        #expect(MongoPipeline.writingStage(stages) == nil)
        #expect(MongoPipeline.writingStage(stages + [try BSONDocument(shellForm: "{ $merge: { into: \"x\" } }")]) == "$merge")
    }

    @Test func savedPipelinesComeBackByCollectionAndName() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-pipelines-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MongoSavedPipelines(directory: folder), id = UUID()
        store.save("b", text: "[{ $match: {} }]", connection: id, database: "d", collection: "c")
        store.save("a", text: "[]", connection: id, database: "d", collection: "c")
        store.save("a", text: "[{ $limit: 1 }]", connection: id, database: "d", collection: "c")
        store.save("other", text: "[]", connection: id, database: "d", collection: "elsewhere")
        store.flush()
        // A new store over the same folder: what a relaunch reads.
        let again = MongoSavedPipelines(directory: folder)
        var found = await again.entries(id, database: "d", collection: "c")
        #expect(found.map(\.name) == ["a", "b"] && found[0].text == "[{ $limit: 1 }]")
        let attributes = try FileManager.default.attributesOfItem(atPath: again.file(id).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        again.rename("b", to: "a", connection: id, database: "d", collection: "c")
        found = await again.entries(id, database: "d", collection: "c")
        #expect(found.map(\.name) == ["a"] && found[0].text == "[{ $match: {} }]", "a rename over a name replaces it")
        again.delete("a", connection: id, database: "d", collection: "c")
        #expect(await again.entries(id, database: "d", collection: "c").isEmpty)
        #expect(await again.entries(id, database: "d", collection: "elsewhere").map(\.name) == ["other"])
    }

    /// mongosh gets the user and never a password: not in its arguments, nor in Terminal's script; over a route, the
    /// socket with directConnection and the name check off (said in a note); for Direct, the servers as saved.
    @Test func mongoshsCommandLineHasTheUserOnly() throws {
        var saved = SavedConnection(name: "Shop", host: "db1.example.internal", port: 27018, user: "ana", route: .ssh)
        saved.engine = .mongodb
        saved.mongoHosts = ["db2.example.internal:27018"]
        saved.replicaSet = "rs0"
        saved.authSource = "admin"
        saved.database = "shop"
        saved.tls = TLSOptions(mode: .verifyIdentity, caFile: "/Users/x/ca.pem")
        let socket = "/Users/x/Library/Application Support/AirSQL/Routes/abc-s0.sock"
        let (argv, unchecked) = MongoShell.arguments(saved, mongosh: "/opt/homebrew/bin/mongosh", socket: socket)
        #expect(unchecked)
        #expect(argv.count == 4 && argv[0] == "/opt/homebrew/bin/mongosh" && Array(argv[2...]) == ["--username", "ana"])
        let uri = try MongoURI(argv[1])
        #expect(uri.hosts == ["%2FUsers%2Fx%2FLibrary%2FApplication%20Support%2FAirSQL%2FRoutes%2Fabc-s0.sock"] && uri.database == "shop")
        #expect(uri.option("directConnection") == "true" && uri.option("replicaSet") == nil && uri.option("authSource") == "admin")
        #expect(uri.option("tls") == "true" && uri.option("tlsCAFile") == "/Users/x/ca.pem" && uri.option("tlsAllowInvalidHostnames") == "true")
        #expect(uri.option("connectTimeoutMS") == nil && uri.user == nil && uri.password == nil)
        let script = MongoShell.script(argv, notes: ["the name isn't checked"])
        #expect(script.hasPrefix("#!/bin/sh\nrm -f -- \"$0\"\necho 'AirSQL: the name isn'\\''t checked'\nexec /opt/homebrew/bin/mongosh 'mongodb://"),
                "\(script)")
        for text in argv + [script] { #expect(!text.lowercased().contains("password") && !text.contains("secret")) }

        // Direct: the saved servers and replica set, the name checked; no user, no --username.
        saved.route = .direct
        saved.user = ""
        saved.tls = TLSOptions(mode: .required)
        let direct = MongoShell.arguments(saved, mongosh: "mongosh", socket: nil)
        #expect(!direct.nameUnchecked && direct.argv.count == 2)
        let plain = try MongoURI(direct.argv[1])
        #expect(plain.hosts == ["db1.example.internal:27018", "db2.example.internal:27018"] && plain.option("replicaSet") == "rs0")
        #expect(plain.option("tlsAllowInvalidCertificates") == "true" && plain.option("tlsAllowInvalidHostnames") == nil)
        saved.tls.mode = .off
        #expect(try MongoURI(MongoShell.arguments(saved, mongosh: "mongosh", socket: "/s.sock").argv[1]).option("tls") == nil)
        #expect(!MongoShell.arguments(saved, mongosh: "mongosh", socket: "/s.sock").nameUnchecked)
    }

    @Test func mongoshIsFoundInTheToolsFolders() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-mongosh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(MongoShell.find(folders: [folder.path]) == nil)
        let tool = folder.appendingPathComponent("mongosh")
        #expect(FileManager.default.createFile(atPath: tool.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]))
        #expect(MongoShell.find(folders: ["/nowhere", folder.path]) == tool.path)
    }
}

// MARK: The lab

extension AppTests {
    /// Run to Here on the seed shows the stage at the caret's documents and says so; Count Each Stage counts every stage;
    /// a pipeline saved by name opens again, is renamed and deleted.
    @Test(.enabled(if: MongoLab.enabled)) func runToHereCountsStagesAndSavesPipelines() async throws {
        let (main, harness, mongo) = try await aggregationWindow()
        let tab = try await openAggregation("many", main, harness, mongo)
        let text = "[\n  { $match: { n: { $lt: 10 } } },\n  { $group: { _id: { $mod: [\"$n\", 2] }, count: { $sum: 1 } } },\n  { $sort: { _id: 1 } }\n]"
        tab.editor.string = text
        tab.editor.setSelectedRange(NSRange(location: 8, length: 0))
        #expect(await call(harness, "menu", ["path": "Data > Collection > Run to Here"]).error == nil)
        #expect(await eventually(timeout: 20) { tab.loading == nil && tab.source.rowCount == 10 })
        #expect(tab.notice.text.stringValue.hasPrefix("These are the documents stage 1 of 3 ($match) gives."), "\(tab.notice.text.stringValue)")
        #expect(tab.count(ofStage: 1) == 10 && tab.count(ofStage: 2) == nil)
        // The button's menu: each stage, to run up to it.
        let second = try #require(tab.stageItems().first { $0.title == "2  $group" })
        NSApp.sendAction(try #require(second.action), to: second.target, from: second)
        #expect(await eventually(timeout: 20) { tab.loading == nil && tab.source.rowCount == 2 && tab.count(ofStage: 2) == 2 })

        #expect(await call(harness, "menu", ["path": "Data > Collection > Count Each Stage"]).error == nil)
        #expect(await eventually(timeout: 20) { tab.loading == nil && tab.count(ofStage: 3) == 2 })
        #expect(tab.problem == nil && tab.info == "Documents after each stage: 1 $match 10  →  2 $group 2  →  3 $sort 2", "\(tab.info ?? "")")
        #expect(tab.stageItems().first?.title == "1  $match  —  10 documents")
        // An edit leaves the counts behind.
        tab.editor.string = text.replacingOccurrences(of: "$lt: 10", with: "$lt: 20")
        #expect(tab.count(ofStage: 1) == nil)
        await run(tab, tab.editor.string)
        #expect(tab.source.rowCount == 2 && tab.notice.isHidden && tab.count(ofStage: 3) == 2)

        // Save Pipeline… keeps it by name; it opens again in a new tab of the collection.
        #expect(await call(harness, "menu", ["path": "Data > Collection > Save Pipeline…"]).error == nil)
        _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
        _ = await call(harness, "type", ["text": "Evens and odds"])
        #expect(await call(harness, "press", ["title": "Save"]).error == nil)
        _ = await call(harness, "wait", ["until": "no_sheet", "timeout": 10])
        #expect(await eventually(timeout: 5) { tab.saved.map(\.name) == ["Evens and odds"] && tab.savedName == "Evens and odds" })
        let other = try await openAggregation("many", main, harness, mongo)
        #expect(await eventually(timeout: 5) { other.saved.count == 1 })
        let item = try #require(other.savedItems().first { $0.title == "Evens and odds" })
        NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        #expect(other.editor.string == tab.editor.string && other.savedName == "Evens and odds")
        #expect(await eventually(timeout: 20) { other.loading == nil && other.source.rowCount == 2 })
        other.rename("Evens and odds", to: "By remainder")
        #expect(await eventually(timeout: 5) { other.saved.map(\.name) == ["By remainder"] })
        other.deleteSaved("By remainder")
        #expect(await eventually(timeout: 5) { other.saved.isEmpty && other.savedName == nil })
        for content in [tab, other] { main.close(try #require(main.tabs.first { $0.content === content })) }
    }

    /// Save as View in a scratch database: the create command previewed, then the view there with the pipeline's
    /// documents; refused for a pipeline that writes and on a read-only connection. Export writes the pipeline's documents
    /// in each format, which read back as they were.
    @Test(.enabled(if: MongoLab.enabled)) func aPipelineIsSavedAsAViewAndExported() async throws {
        let (main, harness, mongo) = try await aggregationWindow()
        let scratch = "agg2_\(UUID().uuidString.prefix(8).lowercased())"
        let session = try await mongo.connection.session(.main)
        let documents = (0..<6).map { BSONDocument([("_id", .int32(Int32($0))), ("n", .int32(Int32($0))), ("name", .string("doc \($0)"))]) }
        _ = try await session.insertMany(database: scratch, collection: "src", documents)
        do {
            main.openAggregation("src", database: scratch, connection: mongo.saved.id)
            let tab = try #require(main.selectedTab?.content as? MongoAggregationController)
            #expect(await eventually(timeout: 20) { tab.loading == nil && tab.source.rowCount == 6 })
            let pipeline = "[{ $match: { n: { $gte: 3 } } }, { $sort: { n: -1 } }]"
            await run(tab, pipeline)

            #expect(await call(harness, "menu", ["path": "Data > Collection > Save as View…"]).error == nil)
            _ = await call(harness, "wait", ["until": "sheet", "timeout": 10])
            _ = await call(harness, "type", ["text": "big"])
            #expect(await call(harness, "press", ["title": "Continue"]).error == nil)
            #expect(await eventually(timeout: 5) { main.window?.attachedSheet?.windowController is SQLPreviewSheet })
            #expect(await call(harness, "press", ["id": "preview.run"]).error == nil)
            #expect(await eventually(timeout: 20) { tab.loading == nil && tab.info == "Made the view big in \(scratch)." }, "\(tab.problem ?? "")")
            let made = try await session.listCollections(database: scratch).first { $0.name == "big" }
            #expect(made?.kind == .view && made?.options["viewOn"] == .string("src"))
            let viewed = try await session.find(database: scratch, collection: "big").next().map { try BSONDocument(bytes: $0) }
            #expect(viewed.map { $0["n"] } == [.int32(5), .int32(4), .int32(3)])

            // A pipeline that writes, and a read-only connection: no name asked, nothing made.
            tab.editor.string = "[{ $match: {} }, { $out: \"copy\" }]"
            tab.saveAsView(nil)
            #expect(tab.problem == "$out writes to a collection, so a view can't run it: remove that stage first.")
            #expect(main.window?.attachedSheet == nil)
            let index = try #require(tab.model.data.connections.firstIndex { $0.id == mongo.saved.id })
            tab.model.data.connections[index].readOnly = true
            tab.editor.string = pipeline
            tab.saveAsView(nil)
            #expect(tab.problem?.hasPrefix("This connection is read-only") == true && main.window?.attachedSheet == nil)
            tab.model.data.connections[index].readOnly = false

            // Export Documents… from the tab's toolbar: the pipeline's documents only. (The menu bar's item asks the front main
            // window, not reliably this one in a test run: its target is asked of this window.)
            let ref = try #require(MongoTransferMenu.shared.target(in: main))
            #expect(ref.collection == "src" && ref.refusal == nil && ref.pipeline?.count == 2)
            tab.exportDocuments(nil)
            #expect(await eventually(timeout: 5) { main.window?.attachedSheet?.windowController is MongoExportSheet })
            let sheet = try #require(main.window?.attachedSheet?.windowController as? MongoExportSheet)
            #expect(await eventually(timeout: 10) { sheet.preview.stringValue.contains("\"doc 5\"") && !sheet.preview.stringValue.contains("\"doc 2\"") },
                    "\(sheet.preview.stringValue)")
            #expect(await call(harness, "press", ["id": "mongoExport.cancel"]).error == nil)
            #expect(await eventually(timeout: 5) { main.window?.attachedSheet == nil })

            // Each format, written from the pipeline's cursor, reads back as the pipeline gave it.
            let (stages, _, refusal) = tab.exportPipeline()
            #expect(refusal == nil)
            let expected = Array(documents.reversed().prefix(3))
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("airsql-agg-export-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let data = try await mongo.connection.session(.data)
            for (index, format) in [MongoExport.Format.json(.canonical, .lines), .json(.canonical, .array), .json(.relaxed, .lines)].enumerated() {
                let url = folder.appendingPathComponent("out\(index).json")
                #expect(try await MongoExport.write(data, database: scratch, collection: "src", find: MongoFind(), pipeline: stages, format: format,
                                                    to: url, stop: StopFlag()) { _ in } == 3)
                var reader = ExtendedJSONReader(try Data(contentsOf: url))
                var read: [BSONDocument] = []
                while let next = try reader.next() { read.append(next) }
                #expect(read.count == 3)
                for (a, b) in zip(read, expected) { #expect(a.typeExactEqual(b), "\(format): \(a.shellForm()) ≠ \(b.shellForm())") }
            }
            let csv = folder.appendingPathComponent("out.csv")
            _ = try await MongoExport.write(data, database: scratch, collection: "src", find: MongoFind(), pipeline: stages,
                                            format: .csv(["_id", "n", "name"], .shell), to: csv, stop: StopFlag()) { _ in }
            #expect(try String(contentsOf: csv, encoding: .utf8) == "_id,n,name\n5,5,doc 5\n4,4,doc 4\n3,3,doc 3\n")

            // A pipeline that writes isn't exported.
            tab.editor.string = "[{ $out: \"copy\" }]"
            #expect(tab.exportPipeline().refusal?.hasPrefix("The pipeline writes with $out") == true)
            main.close(try #require(main.tabs.first { $0.content === tab }))
        } catch {
            Issue.record(error)
        }
        _ = try? await session.command(BSONDocument([("dropDatabase", .int32(1))]), database: scratch)
    }
}

// MARK: Pictures

extension AppTests {
    @MainActor @Suite(.enabled(if: MongoLab.enabled && ProcessInfo.processInfo.environment["AIRSQL_SCREENSHOTS"] == "1"))
    struct MongoPipelineToolsScreenshotTests {
        @Test func pipelineToolScreens() async throws {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let (main, harness, mongo) = try await aggregationWindow()
                main.window?.appearance = NSAppearance(named: appearance)
                let tab = try await openAggregation("many", main, harness, mongo)
                tab.editor.string = "[\n  { $match: { n: { $lt: 40 } } },\n  {\n    $group: {\n      _id: { $mod: [\"$n\", 4] },\n"
                    + "      count: { $sum: 1 }\n    }\n  },\n  { $sort: { _id: 1 } }\n]"
                tab.countStages()
                #expect(await eventually(timeout: 20) { tab.loading == nil })
                tab.run(through: 0)
                #expect(await eventually(timeout: 20) { tab.loading == nil && tab.source.rowCount == 40 })
                tab.save(as: "By remainder")
                tab.save(as: "Small numbers")
                #expect(await eventually(timeout: 5) { tab.saved.count == 2 })
                main.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
                main.window?.orderFront(nil)
                try await save(harness, "mongo-aggregation-run-to-here-\(suffix)")
                // A dark menu's glass doesn't draw outside the screen's compositing: its picture comes out blank.
                if suffix == "light" {
                    try await shootMenu(tab.stageItems(), from: try #require(tab.toolbar.button(Commands.runToStage)),
                                        "mongo-aggregation-stages-menu", appearance)
                    try await shootMenu(tab.savedItems(), from: try #require(tab.toolbar.button(Commands.savePipeline)),
                                        "mongo-aggregation-saved-menu", appearance)
                }
                for name in ["By remainder", "Small numbers"] { tab.deleteSaved(name) }
                main.close(try #require(main.tabs.first { $0.content === tab }))
                main.window?.orderOut(nil)
            }
        }

        private func save(_ harness: AgentServer, _ name: String) async throws {
            let reply = await call(harness, "screenshot", ["target": "main", "scale": 2])
            let image = try #require(reply.image, "\(name): \(reply.error ?? "")")
            try #require(image.representation(using: .png, properties: [:])).write(to: ScreenshotTests.folder.appendingPathComponent(name + ".png"))
        }

        /// The menu a toolbar button opens, drawn while it is up (a menu tracks in a loop of its own, so a timer in that
        /// mode draws it, then closes it).
        private func shootMenu(_ items: [NSMenuItem], from button: NSButton, _ name: String, _ appearance: NSAppearance.Name) async throws {
            let shooter = MenuShooter()
            shooter.menu.appearance = NSAppearance(named: appearance)
            for item in items {
                if item.action != nil, item.target == nil { item.target = button.window?.windowController.flatMap { ($0 as? MainWindowController)?.selectedTab?.content } }
                shooter.menu.addItem(item)
            }
            RunLoop.main.add(Timer(timeInterval: 0.5, target: shooter, selector: #selector(MenuShooter.fire), userInfo: nil, repeats: false),
                             forMode: .eventTracking)
            shooter.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
            let shot = try #require(shooter.png, "\(name): the menu's window wasn't found")
            try shot.write(to: ScreenshotTests.folder.appendingPathComponent(name + ".png"))
        }
    }
}

/// Draws the menu that is up into a PNG, then closes it.
@MainActor
private final class MenuShooter: NSObject {
    let menu = NSMenu()
    var png: Data?

    @objc func fire() {
        // The items' window: the smallest (macOS 26 puts a larger glass window under it).
        let window = NSApp.windows.filter { $0.isVisible && $0.level == .popUpMenu }.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        if let view = window?.contentView?.superview ?? window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            // On the menu's own colour: what it draws over is see-through.
            let ground = NSImage(size: view.bounds.size, flipped: false) { rect in
                NSColor(white: 0.97, alpha: 1).setFill()
                rect.fill()
                rep.draw(in: rect)
                return true
            }
            png = ground.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
        }
        menu.cancelTracking()
    }
}
