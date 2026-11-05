import AppKit
import AirSQLCore

private let f1 = String(UnicodeScalar(NSF1FunctionKey)!)
private let f4 = String(UnicodeScalar(NSF4FunctionKey)!)
private let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
private let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)

/// View ▸ Tree: how the sidebar's tree shows things, each an on or off choice told apart by its tag.
enum TreeOption: Int, CaseIterable {
    case flat, favouritesOnly, sizes, comments, prefixes, followTab, databaseBox
}

/// The sidebar's commands. They live on `SidebarController`, which `supplementalTarget` reaches from anywhere in the window.
extension Commands {
    private static func option(_ title: String, _ option: TreeOption, tip: String) -> Command {
        Command(title, #selector(SidebarController.toggleTreeOption(_:)), tag: option.rawValue, tip: tip)
    }

    static let treeFlat = option("Flat List", .flat, tip: "List a database's objects straight under it, without a group for each kind")
    static let treeFavouritesOnly = option("Favourites Only", .favouritesOnly, tip: "Show only the objects marked with a star")
    static let treeSizes = option("Sizes", .sizes, tip: "Show each table's size with a bar, once its database's sizes are read")
    static let treeComments = option("Comments", .comments, tip: "Show tables' and routines' comments beside their names")
    static let treePrefixes = option("Group by Prefix", .prefixes, tip: "Fold objects that share a name's first part, such as wp_, into a group")
    static let treeFollowTab = option("Follow Tab", .followTab, tip: "Select in the tree what the tab shown is about, as you change tabs")
    static let treeDatabaseBox = option("Database Filter", .databaseBox, tip: "Show a second box that filters the databases by name")
    static let treeKind = Command("Kind", #selector(SidebarController.toggleTreeKind(_:)), tip: "Show or hide this kind of object in the tree")
    static let hideNames = Command("Hide Names…", #selector(SidebarController.hideTreeNames(_:)),
                                   tip: "Leave objects out of the tree by name or pattern, such as tmp_*")
    static let databasesShown = Command("Databases Shown…", #selector(SidebarController.chooseDatabases(_:)),
                                        tip: "Choose which of the server's databases the tree shows")
    static let favourite = Command("Add to Favourites", #selector(SidebarController.toggleFavourite(_:)),
                                   tip: "Mark the selected objects with a star, or take it off")

    static let pageData = Command("Data", #selector(TableDataController.showTablePage(_:)), "1", [.control, .option], tag: TablePage.data.rawValue,
                                  tip: "Show the table's rows")
    static let pageStructure = Command("Structure", #selector(TableDataController.showTablePage(_:)), "2", [.control, .option],
                                       tag: TablePage.structure.rawValue, tip: "Show the table's columns, indexes and keys, and change them")
    static let pageDDL = Command("DDL", #selector(TableDataController.showTablePage(_:)), "3", [.control, .option], tag: TablePage.ddl.rawValue,
                                 tip: "Show the statement that makes the table, as the server gives it")

    static let quickDefinition = Command("Quick Definition", #selector(SidebarController.quickDefinition(_:)), f1, .option,
                                         tip: "Peek at the CREATE statement of the row selected in the tree or the name at the cursor")
    static let openNameData = Command("Open Table at Cursor", #selector(SidebarController.openNameData(_:)), f4, [],
                                      tip: "Open the rows of the table at the cursor or selected, or a group of the tree as a list")
    static let goToDDL = Command("Go to DDL", #selector(SidebarController.goToDDL(_:)), "b", [.command, .option],
                                 tip: "Show the statement that makes the table or object selected, or the one at the cursor")

    static let goBack = Command("Back", #selector(MainWindowController.goBack(_:)), left, [.command, .control],
                                tip: "Go back to the tab shown before this one")
    static let goForward = Command("Forward", #selector(MainWindowController.goForward(_:)), right, [.command, .control],
                                   tip: "Go forward again to the tab left by Back")
    static let recentTabs = Command("Recent Tabs…", #selector(MainWindowController.showRecentTabs(_:)), "e", [.command, .control],
                                    tip: "Choose from the tabs, the one seen last first, and recent files")
    static let statementList = Command("Go to Statement…", #selector(ConsoleViewController.showStatementList(_:)), "o", [.command, .control],
                                       tip: "List this tab's statements and jump to one by typing letters of it")
    static let findUsedBy = Command("Find Where Used…", #selector(SidebarController.findWhereUsed(_:)),
                                    tip: "List the views, routines, triggers, events and keys that name the object or column")
    static let editComment = Command("Edit Comment…", #selector(SidebarController.editComment(_:)),
                                     tip: "Change the comment of the selected table or routine; the SQL shows first")
    static let newColumn = Command("New Column…", #selector(SidebarController.addToTable(_:)), tag: TableEditorController.Section.columns.rawValue,
                                   tip: "Open the table's structure with a new column to fill in")
    static let newIndex = Command("New Index…", #selector(SidebarController.addToTable(_:)), tag: TableEditorController.Section.indexes.rawValue,
                                  tip: "Open the table's structure with a new index to fill in")
    static let newForeignKey = Command("New Foreign Key…", #selector(SidebarController.addToTable(_:)), tag: TableEditorController.Section.foreignKeys.rawValue,
                                       tip: "Open the table's structure with a new foreign key to fill in")
    static let moveConnectionUp = Command("Move Up", #selector(SidebarController.moveConnectionUp(_:)),
                                          tip: "Move the selected connection up its list")
    static let moveConnectionDown = Command("Move Down", #selector(SidebarController.moveConnectionDown(_:)),
                                            tip: "Move the selected connection down its list")

    static let findInFiles = Command("Find in Tabs and Files…", #selector(MainWindowController.findInFiles(_:)), "f", [.control, .option],
                                     tip: "Search the text of every query tab and the .sql files of a folder")

    static let treeCommands = [findInFiles, pageData, pageStructure, pageDDL, quickDefinition, openNameData, goToDDL, goBack, goForward, recentTabs, statementList,
                               findUsedBy, editComment, newColumn, newIndex, newForeignKey, moveConnectionUp, moveConnectionDown, treeFlat, treeFavouritesOnly, treeSizes, treeComments, treePrefixes, treeFollowTab, treeDatabaseBox, treeKind,
                               hideNames, databasesShown, favourite]
    /// What the window sends to the sidebar wherever the focus is.
    static let treeActions = [treeFlat.action, treeKind.action, hideNames.action, databasesShown.action, moveConnectionUp.action, moveConnectionDown.action]

    /// The choices of View ▸ Tree and the sidebar's options button.
    @MainActor static func treeMenuItems() -> [NSMenuItem] {
        let kinds = DatabaseObject.Kind.allCases.enumerated().map { index, kind in
            let item = treeKind.item()
            item.title = kind.group
            item.tag = index
            item.toolTip = "Show or hide \(kind.group.lowercased()) in the tree"
            return item
        }
        return [treeFlat, treeFavouritesOnly, treeSizes, treeComments, treePrefixes, treeFollowTab, treeDatabaseBox].map { $0.item() }
            + [.separator(), MainMenu.submenu("Object Kinds", kinds), .separator(), hideNames.item(), databasesShown.item()]
    }
}
