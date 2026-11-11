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
        + aggregationCommands + [editValue, removeField] + mongoIndexCommands + mongoBulkCommands
}

// MARK: Aggregation (lane M4-app)

extension Commands {
    static let newAggregation = Command("New Aggregation", #selector(SidebarController.newAggregation(_:)), "a", [.command, .option],
                                        tip: "Open a tab that runs and explains an aggregation pipeline on the collection")

    static let aggregationCommands = [newAggregation]
}

// MARK: Export and import (lane M5)

extension Commands {
    static let exportDocuments = Command("Export Documents…", #selector(MongoTransferMenu.exportDocuments(_:)),
                                         tip: "Write the collection's documents, or what its tab finds, to Extended JSON or CSV")
    static let importDocuments = Command("Import Documents…", #selector(MongoTransferMenu.importDocuments(_:)),
                                         tip: "Insert the documents of an Extended JSON or CSV file into a collection")

    static let mongoTransferCommands = [exportDocuments, importDocuments]
}

// MARK: Editing documents (lane M3-app). Insert, duplicate, delete, revert and Apply are the grid's commands, which a
// collection tab answers under its own titles.
extension Commands {
    static let editValue = Command("Edit Value…", #selector(MongoCollectionController.editValue(_:)),
                                   tip: "Edit the selected field in shell form, or change its type; a new document opens whole")
    static let removeField = Command("Remove Field", #selector(MongoCollectionController.removeField(_:)),
                                     tip: "Remove the selected fields from their documents, as a pending change")
}

// MARK: Indexes (lane M-index)

extension Commands {
    static let collectionIndexes = Command("Indexes", #selector(MongoCollectionController.showCollectionPage(_:)), "7", [.control, .option],
                                           tag: MongoCollectionController.Page.indexes.rawValue,
                                           tip: "Show the collection's indexes with their sizes and how often each is used")
    static let createIndex = Command("Create Index…", #selector(MongoCollectionController.createIndex(_:)),
                                     tip: "Make a new index on the collection; its command shows before it runs")
    static let dropIndex = Command("Drop Index…", #selector(MongoCollectionController.dropIndex(_:)),
                                   tip: "Delete the selected index; its command shows before it runs")
    static let hideIndex = Command("Hide Index…", #selector(MongoCollectionController.toggleIndexHidden(_:)),
                                   tip: "Hide the selected index from the query planner, or show it again; it stays up to date")

    static let mongoIndexCommands = [collectionIndexes, createIndex, dropIndex, hideIndex]
}

// MARK: Update Many and Delete Many (lane P2-bulk)

extension Commands {
    static let updateMany = Command("Update Many…", #selector(MongoCollectionController.updateMany(_:)),
                                    tip: "Change every document a filter matches; the command and how many it matches show first")
    static let deleteMany = Command("Delete Many…", #selector(MongoCollectionController.deleteMany(_:)),
                                    tip: "Delete every document a filter matches; the command and how many it matches show first")

    static let mongoBulkCommands = [updateMany, deleteMany]
}
