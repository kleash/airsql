import AirSQLCore
import AppKit

/// A collection that Export and Import Documents act on, and the query of its tab when they start from one.
struct MongoCollectionRef {
    let open: OpenMongoConnection
    let database: String
    /// Empty when Import starts from a database: the person types the new collection's name.
    let collection: String
    let kind: MongoCollectionInfo.Kind
    /// The tab's query, which Export can write instead of every document.
    var query: MongoQueryText?
}

/// What Export Documents… writes (mongo-plan, Export): every document of a collection, or what its tab's query finds,
/// as Extended JSON or CSV, read from a cursor a byte-bounded batch at a time and written as it goes, never held whole.
enum MongoExport {
    enum Format: Equatable, Sendable {
        case json(ExtendedJSONMode, ExtendedJSONWriter.Layout)
        case csv([String], MongoCSVWriter.CellForm)

        var fileExtension: String {
            if case .csv = self { return "csv" }
            return "json"
        }
    }

    /// The text of documents in a format, a part at a time: what the file and the sheet's preview both get.
    struct Encoder {
        private var json: ExtendedJSONWriter?
        private var csv: MongoCSVWriter?

        init(_ format: Format) {
            switch format {
            case .json(let mode, let layout): json = ExtendedJSONWriter(mode, layout: layout)
            case .csv(let paths, let form): csv = MongoCSVWriter(paths: paths, form: form)
            }
        }

        func header() -> String { json?.header() ?? csv?.header() ?? "" }
        mutating func document(_ document: BSONDocument) -> String { json?.document(document) ?? csv?.row(document) ?? "" }
        func footer() -> String { json?.footer() ?? "" }

        static func text(_ format: Format, _ documents: [BSONDocument]) -> String {
            var encoder = Encoder(format)
            return encoder.header() + documents.map { encoder.document($0) }.joined() + encoder.footer()
        }
    }

    /// Writes what `find` gives to `url` through a hidden file beside it, which takes `url`'s name only once every document
    /// is written: a failed or cancelled export leaves the file that was there (or none). `progress` gets the count after
    /// each batch. How many were written.
    static func write(_ session: MongoSession, database: String, collection: String, find: MongoFind, format: Format, to url: URL,
                      stop: StopFlag, progress: @escaping @Sendable (Int) -> Void) async throws -> Int {
        let partial = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".airsql-partial")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o644]) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        var renamed = false
        defer { if !renamed { try? FileManager.default.removeItem(at: partial) } }
        let file = try FileHandle(forWritingTo: partial)
        defer { try? file.close() }
        var encoder = Encoder(format)
        try file.write(contentsOf: Data(encoder.header().utf8))
        let cursor = try await session.find(database: database, collection: collection, find)
        var count = 0
        do {
            while !cursor.isExhausted {
                if stop.isSet { throw CancellationError() }
                let batch = try await cursor.next(maxCount: 1000, maxBytes: 4 << 20)
                var text = ""
                for bytes in batch { text += encoder.document(try BSONDocument(bytes: bytes)) }
                try file.write(contentsOf: Data(text.utf8))
                count += batch.count
                progress(count)
            }
        } catch {
            await cursor.close()
            throw error
        }
        if stop.isSet { throw CancellationError() }
        try file.write(contentsOf: Data(encoder.footer().utf8))
        try file.synchronize()
        guard rename(partial.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        renamed = true
        return count
    }
}

/// The target of Data ▸ Collection ▸ Export Documents… and Import Documents…: the collection selected in the tree while
/// the tree has the focus, else the collection tab in front (as `CollectionMenu` finds it).
@MainActor
final class MongoTransferMenu: NSObject, NSMenuItemValidation {
    static let shared = MongoTransferMenu()

    private var main: MainWindowController? {
        let windows = [NSApp.mainWindow, NSApp.keyWindow].compactMap { $0 } + NSApp.orderedWindows
        return windows.lazy.compactMap { $0.windowController as? MainWindowController }.first
    }

    /// The collection (or, for Import, the database) the commands act on now.
    func target(in main: MainWindowController) -> MongoCollectionRef? {
        let sidebar = main.sidebar
        if let focus = main.window?.firstResponder as? NSView, focus.isDescendant(of: sidebar.view), let (open, items) = sidebar.mongoSelection {
            guard items.count == 1, items[0].index == nil else { return nil }
            let item = items[0]
            let kind = item.collection.flatMap { _ in sidebar.mongoInfo(open.saved.id, item)?.kind } ?? .collection
            return MongoCollectionRef(open: open, database: item.database, collection: item.collection ?? "", kind: kind)
        }
        guard let tab = main.selectedTab?.shown as? MongoCollectionController, let open = main.model.openMongo[tab.connectionID] else { return nil }
        return MongoCollectionRef(open: open, database: tab.database, collection: tab.name, kind: tab.info.kind, query: tab.shown)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let ref = main.flatMap(target)
        var reason: String?
        if ref == nil {
            reason = "Select a MongoDB collection in the tree, or open one in a tab"
        } else if item.action == Commands.exportDocuments.action, ref?.collection.isEmpty == true {
            reason = "Select a collection, not a database"
        } else if item.action == Commands.importDocuments.action, let ref {
            reason = MongoImportSheet.refusal(ref)
        }
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }

    @objc func exportDocuments(_ sender: Any?) {
        guard let main, let window = main.window, let ref = target(in: main), !ref.collection.isEmpty else { return }
        MongoExportSheet.show(ref, activity: main.model.activity, on: window)
    }

    @objc func importDocuments(_ sender: Any?) {
        guard let main, let window = main.window, let ref = target(in: main), MongoImportSheet.refusal(ref) == nil else { return }
        MongoImportSheet.show(ref, activity: main.model.activity, on: window)
    }
}
