// Autofill for MongoDB (docs/dev/mongo-plan.md, Phase 3): where the caret is (MongoCaret) and what each place offers
// (MongoCompletion), from a sample like the lab's `shop.orders`; then the editors' lists against the Mongo lab
// (AIRSQL_MONGO_LAB=1) and their pictures (AIRSQL_SCREENSHOTS=1 too).
import AppKit
import Foundation
import Testing
@testable import AirSQL
@testable import AirSQLCore

struct MongoCompletionTests {
    /// Orders as `shop` has them: an id, a customer's, a status of six, a date, items with skus, a total, a flag.
    static let sample: MongoSample = {
        let statuses = ["delivered", "delivered", "shipped", "paid", "pending", "cancelled", "refunded"]
        let documents = (0..<50).map { n in
            BSONDocument([
                ("_id", .objectId(BSONObjectId.generate())), ("customerId", .objectId(BSONObjectId.generate())),
                ("status", .string(statuses[n % statuses.count])), ("createdAt", .datetime(Int64(n) * 86_400_000)),
                ("items", .array([.document(BSONDocument([("sku", .string("SKU-\(n)")), ("qty", .int32(2))]))])),
                ("total", .double(Double(n))), ("gift", n % 5 == 0 ? .null : .bool(n % 2 == 0)),
            ] + (n % 2 == 0 ? [("statusNote", .string("note \(n)"))] : []))
        }
        return MongoSample(schema: MongoSchema(sample: documents),
                           indexes: [BSONDocument([("_id", .int32(1))]), BSONDocument([("customerId", .int32(1))]),
                                     BSONDocument([("status", .int32(1)), ("createdAt", .int32(-1))])])
    }()

    func items(_ root: MongoCaret.Root, _ text: String, version: String? = nil, collections: [String] = [],
               foreign: @escaping (String) -> MongoSample? = { _ in nil }) -> [CompletionItem] {
        MongoCompletion.items(root: root, text: text, caret: text.utf16.count, sample: Self.sample, collections: collections,
                              serverVersion: version, foreign: foreign).items
    }

    func labels(_ root: MongoCaret.Root, _ text: String, version: String? = nil, collections: [String] = [],
                foreign: @escaping (String) -> MongoSample? = { _ in nil }) -> [String] {
        items(root, text, version: version, collections: collections, foreign: foreign).map(\.label)
    }

    @Test func theCaretKnowsItsKeysSlotAndPrefix() {
        let pipeline = "[{ $match: {} }, { $group: { _id: \"$status\", total: { $sum: \"$to"
        let group = MongoCaret(text: pipeline, caret: pipeline.utf16.count, root: .pipeline)
        #expect(group.chain == ["$group", "total", "$sum"] && group.slot == .reference && group.prefix == "$to")
        #expect(group.stagesBefore == [1..<15])
        let key = MongoCaret(text: "{ status: \"paid\", \"items.s", caret: 26, root: .filter)
        #expect(key.slot == .key && key.quoted && key.prefix == "items.s" && key.siblings == ["status"] && key.values["status"] == "paid")
        // Strings and regular expressions don't fool it; a bare filter is a document.
        let past = "{ name: \"a { b\", re: /x}[}]/i, n: { $g"
        let inside = MongoCaret(text: past, caret: past.utf16.count, root: .filter)
        #expect(inside.chain == ["n"] && inside.slot == .key && inside.prefix == "$g")
        #expect(MongoCaret(text: "status: ", caret: 8, root: .filter).chain == ["status"])
        #expect(MongoCaret(text: "{ a: /ab", caret: 8, root: .filter).slot == .none)
        #expect(MongoCaret(text: "{ a: ObjectId(\"", caret: 15, root: .filter).slot == .string)
    }

    @Test func aFilterOffersPathsIndexedFirstThenItsOperators() {
        let all = labels(.filter, "{ ")
        // The indexed leading fields first, then by share; $and and the like after the paths.
        #expect(Array(all.prefix(3)) == ["_id", "customerId", "status"], "\(all)")
        #expect(all.firstIndex(of: "$and")! > all.firstIndex(of: "items.sku")!)
        #expect(all.contains("$or") && all.contains("$expr") && !all.contains("$gt"))
        #expect(labels(.filter, "{ st").prefix(2) == ["status", "statusNote"])
        // A nested path, quoted when dotted.
        let nested = items(.filter, "{ items.s")
        #expect(nested.first?.label == "items.sku" && nested.first?.text == "\"items.sku\"")
        #expect(items(.filter, "{ \"items.s").first?.text == "items.sku")
        // The keys typed drop out.
        #expect(!labels(.filter, "{ status: \"paid\", ").contains("status"))
        #expect(items(.filter, "{ st").first?.detail == "indexed · string · 100%")
    }

    @Test func aFieldsDocumentOffersOperatorsByItsType() {
        let number = labels(.filter, "{ total: { ")
        #expect(Array(number.prefix(4)) == ["$gt", "$gte", "$lt", "$lte"], "\(number)")
        #expect(!number.contains("$regex") && !number.contains("$or"))
        let text = labels(.filter, "{ status: { ")
        #expect(text.contains("$regex") && text.firstIndex(of: "$regex")! < text.firstIndex(of: "$eq")!)
        #expect(labels(.filter, "{ items: { ").prefix(3).contains("$elemMatch"))
        #expect(labels(.filter, "{ total: { $g") == ["$gt", "$gte"])
    }

    @Test func aValueOffersWhatItsTypeTakes() {
        #expect(labels(.filter, "{ customerId: ") == ["ObjectId(\"\")"])
        #expect(labels(.filter, "{ createdAt: { $gte: ") == ["ISODate(\"\")"])
        #expect(labels(.filter, "{ gift: ") == ["true", "false", "null"])
        // A string with few values: its values, quoted unless the caret is in quotes.
        let status = items(.filter, "{ status: ")
        #expect(status.first?.label == "delivered" && status.first?.text == "\"delivered\"" && status.count == 6)
        #expect(items(.filter, "{ status: \"sh").map(\.text) == ["shipped"])
        #expect(items(.filter, "{ status: { $in: [\"paid\", ").count == 6)
        #expect(labels(.filter, "{ statusNote: ").isEmpty)  // 25 values: too many to list
        #expect(labels(.filter, "{ gift: { $exists: ") == ["true", "false"])
    }

    @Test func sortProjectionHintAndUpdateOfferTheirs() {
        #expect(labels(.sort, "{ ").prefix(3) == ["_id", "customerId", "status"])
        #expect(labels(.sort, "{ total: ") == ["1", "-1"])
        #expect(labels(.projection, "{ total: ") == ["1", "0"])
        #expect(labels(.hint, "") == ["_id_1", "customerId_1", "status_1_createdAt_-1"])
        #expect(items(.hint, "\"st").first?.text == "status_1_createdAt_-1")
        #expect(labels(.hint, "{ ") == ["_id", "customerId", "status", "createdAt"])
        let update = labels(.update, "{ ")
        #expect(update.first == "$set" && update.firstIndex(of: "status")! > update.firstIndex(of: "$bit")!)
        // In $inc the numbers first.
        #expect(labels(.update, "{ $inc: { ").prefix(2).contains("total"))
        #expect(labels(.update, "{ $set: { status: \"de").first == "delivered")
        #expect(labels(.collation, "{ lo") == ["locale"])
    }

    @Test func aPipelineOffersStagesAsTemplatesAndTheirKeys() throws {
        let start = items(.pipeline, "[{ $gr")
        #expect(start.map(\.label) == ["$group", "$graphLookup"] || start.map(\.label) == ["$graphLookup", "$group"])
        let group = try #require(start.first { $0.label == "$group" })
        #expect(group.kind == .template && SQLTemplate.expand(group.text).text == "$group: { _id: _id }")
        let lookup = try #require(items(.pipeline, "[{ $look").first)
        #expect(SQLTemplate.expand(lookup.text).text == "$lookup: { from: \"from\", localField: \"localField\", foreignField: \"foreignField\", as: \"as\" }")
        #expect(SQLTemplate.expand(try #require(items(.pipeline, "[{ $unw").first).text).text == "$unwind: \"$path\"")
        // Without its braces, a stage brings them; a stage's document holds one stage.
        #expect(SQLTemplate.expand(try #require(items(.pipeline, "[ $lim").first).text).text == "{ $limit: value }")
        #expect(labels(.pipeline, "[{ $match: {}, ").isEmpty)
        // $lookup: its keys, the collections, the other collection's paths when cached.
        #expect(labels(.pipeline, "[{ $lookup: { ").prefix(3) == ["from", "localField", "foreignField"])
        #expect(labels(.pipeline, "[{ $lookup: { from: ", collections: ["customers", "orders"]) == ["customers", "orders"])
        #expect(items(.pipeline, "[{ $lookup: { from: \"cu", collections: ["customers", "orders"]).map(\.text) == ["customers"])
        let customers = MongoSample(schema: MongoSchema(sample: [BSONDocument([("_id", .int32(1)), ("email", .string("a"))])]))
        #expect(labels(.pipeline, "[{ $lookup: { from: \"customers\", localField: \"customerId\", foreignField: ",
                       foreign: { $0 == "customers" ? customers : nil }) == ["_id", "email"])
        #expect(labels(.pipeline, "[{ $lookup: { from: \"customers\", localField: \"cust").first == "customerId")
        #expect(labels(.pipeline, "[{ $match: { st").first == "status")
        #expect(labels(.pipeline, "[{ $sort: { total: ") == ["1", "-1"])
    }

    @Test func expressionsAccumulatorsReferencesAndVariables() {
        // Accumulators only in $group (and the stages MongoWords names), expressions elsewhere.
        let accumulators = labels(.pipeline, "[{ $group: { _id: null, n: { ")
        #expect(accumulators.contains("$sum") && accumulators.contains("$push") && !accumulators.contains("$concat"))
        let expressions = labels(.pipeline, "[{ $project: { n: { ")
        #expect(expressions.contains("$concat") && !expressions.contains("$push"))
        #expect(labels(.pipeline, "[{ $group: { ") == ["_id"])
        #expect(labels(.pipeline, "[{ $group: { _id: null, n: { $sum: { ").contains("$multiply"))
        // "$ gives the paths, "$$ the variables; before its quote, a reference comes quoted.
        #expect(labels(.pipeline, "[{ $group: { _id: \"$st").prefix(2) == ["$status", "$statusNote"])
        #expect(items(.pipeline, "[{ $group: { _id: $cust").first?.text == "\"$customerId\"")
        #expect(items(.pipeline, "[{ $group: { _id: $am").isEmpty)
        #expect(labels(.pipeline, "[{ $project: { now: \"$$N") == ["$$NOW"])
        #expect(labels(.filter, "{ $expr: { $gt: [\"$tot").first == "$total")
    }

    @Test func afterAStageItsOwnKeysAreTheFields() {
        let group = "[{ $group: { _id: \"$status\", revenue: { $sum: \"$total\" } } }, { $sort: { "
        #expect(labels(.pipeline, group) == ["_id", "revenue"])
        #expect(labels(.pipeline, "[{ $project: { status: 1, total: 1 } }, { $match: { ").prefix(3) == ["_id", "status", "total"])
        #expect(!labels(.pipeline, "[{ $project: { _id: 0, items: 0 } }, { $match: { ").contains("items.sku"))
        #expect(labels(.pipeline, "[{ $addFields: { year: { $year: \"$createdAt\" } } }, { $match: { ye") == ["year"])
        #expect(!labels(.pipeline, "[{ $unset: [\"items\", \"gift\"] }, { $match: { ").contains("gift"))
        let replaced = labels(.pipeline, "[{ $replaceRoot: { newRoot: { a: \"$status\" } } }, { $match: { ")
        #expect(replaced.first == "a" && !replaced.contains("status"))
        #expect(labels(.pipeline, "[{ $lookup: { from: \"c\", localField: \"a\", foreignField: \"b\", as: \"buyer\" } }, { $unwind: \"$bu")
            == ["$buyer"])
        // A stage that doesn't parse yet changes nothing.
        #expect(labels(.pipeline, "[{ $group: { _id: } }, { $match: { st").first == "status")
    }

    @Test func wordsNewerThanTheServerAreLeftOut() {
        #expect(labels(.pipeline, "[{ $dens", version: "5.0.3").isEmpty)
        #expect(labels(.pipeline, "[{ $dens", version: "7.0.2") == ["$densify"])
        #expect(!labels(.pipeline, "[{ $group: { _id: null, m: { $med", version: "6.0.1").contains("$median"))
        #expect(labels(.pipeline, "[{ $group: { _id: null, m: { $med", version: "7.0.2") == ["$median"])
    }

    @Test func aDocumentOffersItsChildrenAndAFieldsValue() {
        #expect(labels(.document, "{\n  ").prefix(3) == ["_id", "customerId", "status"])
        #expect(labels(.document, "{ items: [{ ") == ["sku", "qty"])
        #expect(MongoCompletion.items(root: .document, text: "", caret: 0, sample: Self.sample, path: "gift").items.map(\.label)
                == ["true", "false", "null"])
    }

    @Test func twoThousandPathsCompleteInAFewMilliseconds() {
        let document = BSONDocument((0..<2_000).map { ("field_\($0)_name", BSONValue.int32(Int32($0))) })
        let sample = MongoSample(schema: MongoSchema(sample: [document]))
        let text = "[{ $match: { status: \"x\" } }, { $addFields: { x: 1 } }, { $match: { $or: [{ "
        _ = MongoCompletion.items(root: .pipeline, text: text, caret: text.utf16.count, sample: sample)  // warm the word table
        let started = Date()
        var count = 0
        for prefix in ["", "f", "fnam", "zz", "field_19"] {
            let typed = text + prefix
            count += MongoCompletion.items(root: .pipeline, text: typed, caret: typed.utf16.count, sample: sample).items.count
        }
        let elapsed = Date().timeIntervalSince(started) / 5
        #expect(count > 0)
        // Under 5 ms optimized (./test.sh -c release -Xswiftc -enable-testing); a debug build is many times slower.
        #if DEBUG
        let limit = 0.1
        #else
        let limit = 0.005
        #endif
        #expect(elapsed < limit, "\(elapsed * 1000) ms a completion")
    }
}

// MARK: The lab

/// `shop.orders` in a collection tab of the lab's standalone, its sample read.
@MainActor func shopOrders() async throws -> (MainWindowController, AgentServer, OpenMongoConnection, MongoCollectionController) {
    let (main, harness, mongo) = try await mongoWindow()
    let kind = SidebarNode.Kind.mongo(mongo.saved.id, MongoTreeItem(database: "shop", collection: "orders"))
    _ = try await open(MongoTreeItem(database: "shop"), in: main, mongo)
    #expect(main.sidebar.reveal(kind))
    main.sidebar.treeDoubleClicked(try #require(main.sidebar.treeNodes[kind]))
    let tab = try #require(main.selectedTab?.content as? MongoCollectionController)
    #expect(await eventually(timeout: 20) { tab.loading == nil && mongo.connection.samples.cached(database: "shop", collection: "orders") != nil })
    return (main, harness, mongo, tab)
}

/// Types `text` a character at a time, as the keyboard does.
@MainActor func typeEach(_ text: String, into view: NSTextView) {
    for character in text { view.insertText(String(character), replacementRange: view.selectedRange()) }
}

extension AppTests {
    @Test(.enabled(if: MongoLab.enabled)) func theQueryBarAndThePipelineEditorAutofillFromTheSample() async throws {
        let (main, harness, mongo, tab) = try await shopOrders()
        let window = try #require(main.window)
        // The filter: an indexed field first, then its values once a quote is typed; Return takes one.
        #expect(window.makeFirstResponder(tab.bar.filter))
        let field = try #require(tab.bar.filter.currentEditor() as? NSTextView)
        typeEach("{ st", into: field)
        #expect(tab.bar.autofill.isShown && tab.bar.autofill.items.first?.label == "status", "\(tab.bar.autofill.items.map(\.label))")
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(!tab.bar.autofill.isShown && field.string == "{ status")
        typeEach(": \"", into: field)
        #expect(tab.bar.autofill.items.first?.label == "delivered", "\(tab.bar.autofill.items.map(\.label))")
        field.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!tab.bar.autofill.isShown)
        // Esc in the sort lists the fields, indexed first.
        #expect(window.makeFirstResponder(tab.bar.sort))
        let sort = try #require(tab.bar.sort.currentEditor() as? NSTextView)
        typeEach("{ ", into: sort)
        sort.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(tab.bar.autofill.items.prefix(3).map(\.label) == ["_id", "customerId", "status"], "\(tab.bar.autofill.items.map(\.label))")
        tab.bar.autofill.close()

        // Insert Document: the collection's fields; Esc closes the list, not the sheet.
        tab.addRow(nil)
        #expect(await eventually(timeout: 5) { window.attachedSheet?.windowController is MongoValueSheet })
        let sheet = try #require(window.attachedSheet?.windowController as? MongoValueSheet)
        sheet.textView.setSelectedRange(NSRange(location: 4, length: 0))
        typeEach("cu", into: sheet.textView)
        #expect(sheet.autofill.items.first?.label == "customerId", "\(sheet.autofill.items.map(\.label))")
        _ = await call(harness, "key", ["combo": "escape"])
        #expect(!sheet.autofill.isShown && window.attachedSheet != nil)
        sheet.cancel(nil)
        #expect(await eventually(timeout: 5) { window.attachedSheet == nil })

        // The pipeline editor: stages as templates, then the fields after "$.
        main.window?.makeFirstResponder(main.sidebar.outline)
        #expect(await call(harness, "menu", ["path": "Data > Collection > New Aggregation"]).error == nil)
        let pipeline = try #require(main.selectedTab?.content as? MongoAggregationController)
        #expect(await eventually(timeout: 20) { pipeline.loading == nil })
        let editor = pipeline.editor
        editor.string = "[\n  { "
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        window.makeFirstResponder(editor)
        typeEach("$gr", into: editor)
        let popup = try #require(editor.completionPopup)
        #expect(popup.isShown && popup.selected?.label == "$group", "\(popup.items.map(\.label))")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(editor.string == "[\n  { $group: { _id: _id }")
        typeEach("\"$cu", into: editor)
        #expect(popup.isShown && popup.selected?.label == "$customerId", "\(popup.items.map(\.label))")
        popup.close()
        pipeline.close()
        tab.close()
        _ = mongo
    }
}

// MARK: Pictures

extension AppTests {
    @MainActor @Suite(.enabled(if: MongoLab.enabled && ProcessInfo.processInfo.environment["AIRSQL_SCREENSHOTS"] == "1"))
    struct MongoAutofillScreenshotTests {
        @Test func autofillLists() async throws {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let (main, _, _, tab) = try await shopOrders()
                let window = try #require(main.window)
                // A harness that sees the list's panel over the window.
                let harness = AgentServer(main: main, model: main.model, windows: { window.childWindows ?? [] })
                window.appearance = NSAppearance(named: appearance)
                window.setFrameOrigin(NSPoint(x: 40, y: 40))
                window.orderFront(nil)
                window.makeFirstResponder(tab.bar.filter)
                let field = try #require(tab.bar.filter.currentEditor() as? NSTextView)
                typeEach("{ status: \"delivered\", cre", into: field)
                #expect(tab.bar.autofill.isShown)
                try await save(harness, "mongo-autofill-query-\(suffix)")
                tab.bar.autofill.close()

                window.makeFirstResponder(main.sidebar.outline)
                #expect(await call(harness, "menu", ["path": "Data > Collection > New Aggregation"]).error == nil)
                let pipeline = try #require(main.selectedTab?.content as? MongoAggregationController)
                #expect(await eventually(timeout: 20) { pipeline.loading == nil })
                pipeline.editor.string = "[\n  { $match: { status: \"delivered\" } },\n  { $group: { _id: \"$customerId\", spent: { "
                pipeline.editor.setSelectedRange(NSRange(location: (pipeline.editor.string as NSString).length, length: 0))
                window.makeFirstResponder(pipeline.editor)
                typeEach("$", into: pipeline.editor)
                #expect(pipeline.editor.completionPopup?.isShown == true)
                try await save(harness, "mongo-autofill-pipeline-\(suffix)")
                pipeline.editor.completionPopup?.close()
                pipeline.close()
                tab.close()
                window.orderOut(nil)
            }
        }

        private func save(_ harness: AgentServer, _ name: String) async throws {
            let reply = await call(harness, "screenshot", ["target": "main", "scale": 2])
            let image = try #require(reply.image, "\(name): \(reply.error ?? "")")
            try #require(image.representation(using: .png, properties: [:])).write(to: ScreenshotTests.folder.appendingPathComponent(name + ".png"))
        }
    }
}
