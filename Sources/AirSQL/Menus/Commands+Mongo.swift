import AppKit

/// MongoDB's own commands (mongo-plan, Phase 1): opening a collection from the tree, a collection tab's pages and its
/// sub-documents, and copying documents. Running, refreshing, counting, cancelling and the history are the console's and
/// the grid's commands, which a collection tab answers too.
extension Commands {
    static let openCollection = Command("Open Collection", #selector(SidebarController.openCollection(_:)), "O", [.command, .option],
                                        tip: "Open the selected collections' documents in tabs of their own")
    static let collectionDocuments = Command("Documents", #selector(MongoCollectionController.showCollectionPage(_:)), "4", [.control, .option],
                                             tag: MongoCollectionController.Page.documents.rawValue, tip: "Show the collection's documents in the grid")
    static let collectionJSON = Command("JSON", #selector(MongoCollectionController.showCollectionPage(_:)), "5", [.control, .option],
                                        tag: MongoCollectionController.Page.json.rawValue,
                                        tip: "Show the documents loaded as Extended JSON, or the grid again")
    static let collectionSchema = Command("Schema", #selector(MongoCollectionController.showCollectionPage(_:)), "6", [.control, .option],
                                          tag: MongoCollectionController.Page.schema.rawValue,
                                          tip: "Sample the collection and show each field's types, values and range")
    static let expandField = Command("Expand Field", #selector(MongoCollectionController.toggleField(_:)),
                                     tip: "Show a sub-document's fields as columns of their own, or as one column again")
    static let copyDocuments = Command("Copy Documents", #selector(MongoCollectionController.copyDocuments(_:)), "C", [.command, .option],
                                       tip: "Copy the selected rows' documents as Extended JSON, one per line")

    static let mongoCommands = [openCollection, collectionDocuments, collectionJSON, collectionSchema, expandField, copyDocuments]
}

// MARK: Export and import (lane M5)

extension Commands {
    static let exportDocuments = Command("Export Documents…", #selector(MongoTransferMenu.exportDocuments(_:)),
                                         tip: "Write the collection's documents, or what its tab finds, to Extended JSON or CSV")
    static let importDocuments = Command("Import Documents…", #selector(MongoTransferMenu.importDocuments(_:)),
                                         tip: "Insert the documents of an Extended JSON file into a collection")

    static let mongoTransferCommands = [exportDocuments, importDocuments]
}
