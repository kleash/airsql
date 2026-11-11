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
        + aggregationCommands + [editValue, removeField] + mongoIndexCommands + mongoHostCommands
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
                                         tip: "Insert the documents of an Extended JSON file into a collection")

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

// MARK: Host (lane P2-host)

extension Commands {
    static let mongoServer = Command("Server", #selector(SidebarController.showMongoHost(_:)), tag: MongoHostContent.Pane.server.rawValue,
                                     tip: MongoHostContent.Pane.server.tip)
    static let mongoMembers = Command("Members", #selector(SidebarController.showMongoHost(_:)), tag: MongoHostContent.Pane.members.rawValue,
                                      tip: MongoHostContent.Pane.members.tip)
    static let mongoOperations = Command("Operations", #selector(SidebarController.showMongoHost(_:)), tag: MongoHostContent.Pane.operations.rawValue,
                                         tip: MongoHostContent.Pane.operations.tip)
    static let mongoDiskUsage = Command("Disk Usage", #selector(SidebarController.showMongoDiskUsage(_:)),
                                        tip: "Show where the space went on the MongoDB server, or in the selected database")
    static let killOperation = Command("Kill Operation…", #selector(MongoHostContent.killOperation(_:)),
                                       tip: "Stop the selected operations on the server (asks first)")

    static let mongoHostCommands = [mongoServer, mongoMembers, mongoOperations, mongoDiskUsage, killOperation]
}
