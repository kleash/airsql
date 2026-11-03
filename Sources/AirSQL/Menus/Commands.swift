import AppKit

/// Every command of AirSQL as an action selector (plan §2.4, R17). Menu items, context menus, toolbar items and buttons
/// send these through the responder chain with a nil target; whatever implements one where the focus is (a console tab,
/// the grid, the navigator, the main window) handles it, and its validation enables the item or says why not. Lanes
/// implement the methods in their own responders; new commands are added here (a shared file) and in `Commands`.
@objc protocol AirSQLActions {
    // AirSQL and Help
    @objc optional func showSettings(_ sender: Any?)
    @objc optional func showHelpSite(_ sender: Any?)
    @objc optional func showGettingStarted(_ sender: Any?)
    @objc optional func reportProblem(_ sender: Any?)
    @objc optional func copyDiagnostics(_ sender: Any?)
    @objc optional func showMainWindow(_ sender: Any?)

    // File
    @objc optional func newConnection(_ sender: Any?)
    @objc optional func newQuery(_ sender: Any?)
    @objc optional func openSQLFile(_ sender: Any?)
    @objc optional func saveQuery(_ sender: Any?)
    @objc optional func saveQueryAs(_ sender: Any?)
    @objc optional func closeTab(_ sender: Any?)
    @objc optional func closeOtherTabs(_ sender: Any?)
    @objc optional func duplicateTab(_ sender: Any?)
    @objc optional func renameTab(_ sender: Any?)
    @objc optional func revealInFinder(_ sender: Any?)
    @objc optional func runSQLFile(_ sender: Any?)
    @objc optional func importCSV(_ sender: Any?)
    @objc optional func importSSHConfig(_ sender: Any?)

    // Edit
    @objc optional func copyWithHeaders(_ sender: Any?)
    @objc optional func copyAs(_ sender: Any?)
    @objc optional func copySummary(_ sender: Any?)
    @objc optional func copyName(_ sender: Any?)
    @objc optional func copyColumnNames(_ sender: Any?)
    @objc optional func copyCreateStatement(_ sender: Any?)
    @objc optional func copyQuery(_ sender: Any?)

    // View
    @objc optional func filterSidebar(_ sender: Any?)
    @objc optional func toggleValuePanel(_ sender: Any?)
    @objc optional func showRecordView(_ sender: Any?)
    @objc optional func transposeGrid(_ sender: Any?)
    @objc optional func viewAs(_ sender: Any?)
    @objc optional func showChart(_ sender: Any?)
    @objc optional func showColumnList(_ sender: Any?)
    @objc optional func showSQLLog(_ sender: Any?)
    @objc optional func clearSQLLog(_ sender: Any?)
    @objc optional func showActivity(_ sender: Any?)
    @objc optional func cancelAllActivities(_ sender: Any?)
    @objc optional func zoomIn(_ sender: Any?)
    @objc optional func zoomOut(_ sender: Any?)
    @objc optional func zoomReset(_ sender: Any?)
    @objc optional func refresh(_ sender: Any?)
    @objc optional func setAutoRefresh(_ sender: Any?)

    // Query (the console)
    @objc optional func runStatement(_ sender: Any?)
    @objc optional func runSelection(_ sender: Any?)
    @objc optional func runAll(_ sender: Any?)
    @objc optional func explain(_ sender: Any?)
    @objc optional func cancelQuery(_ sender: Any?)
    @objc optional func commit(_ sender: Any?)
    @objc optional func rollback(_ sender: Any?)
    @objc optional func setTransactionMode(_ sender: Any?)
    @objc optional func setIsolationLevel(_ sender: Any?)
    @objc optional func formatSQL(_ sender: Any?)
    @objc optional func showHistory(_ sender: Any?)
    @objc optional func changeConnection(_ sender: Any?)
    @objc optional func profileQuery(_ sender: Any?)
    @objc optional func saveAsChangeset(_ sender: Any?)
    @objc optional func editAsTable(_ sender: Any?)
    @objc optional func pinResult(_ sender: Any?)
    @objc optional func renameResult(_ sender: Any?)
    @objc optional func closeResult(_ sender: Any?)
    @objc optional func closeOtherResults(_ sender: Any?)
    @objc optional func exportResult(_ sender: Any?)
    @objc optional func compareResult(_ sender: Any?)
    @objc optional func toggleComment(_ sender: Any?)
    @objc optional func indentLines(_ sender: Any?)
    @objc optional func outdentLines(_ sender: Any?)
    @objc optional func toggleHelpers(_ sender: Any?)

    // Data (the grid)
    @objc optional func addRow(_ sender: Any?)
    @objc optional func duplicateRow(_ sender: Any?)
    @objc optional func duplicateRowWithoutKeys(_ sender: Any?)
    @objc optional func deleteRows(_ sender: Any?)
    @objc optional func setCellNull(_ sender: Any?)
    @objc optional func setCellDefault(_ sender: Any?)
    @objc optional func insertCellValue(_ sender: Any?)
    @objc optional func applyChanges(_ sender: Any?)
    @objc optional func previewChanges(_ sender: Any?)
    @objc optional func revertChanges(_ sender: Any?)
    @objc optional func focusFilter(_ sender: Any?)
    @objc optional func searchAllColumns(_ sender: Any?)
    @objc optional func quickFilter(_ sender: Any?)
    @objc optional func quickFilterEquals(_ sender: Any?)
    @objc optional func quickFilterNotEquals(_ sender: Any?)
    @objc optional func filterByValues(_ sender: Any?)
    @objc optional func clearFilter(_ sender: Any?)
    @objc optional func sortAscending(_ sender: Any?)
    @objc optional func sortDescending(_ sender: Any?)
    @objc optional func clearSort(_ sender: Any?)
    @objc optional func goToRow(_ sender: Any?)
    @objc optional func showRelatedRows(_ sender: Any?)
    @objc optional func showColumnSummary(_ sender: Any?)
    @objc optional func loadMore(_ sender: Any?)
    @objc optional func loadAll(_ sender: Any?)
    @objc optional func countRows(_ sender: Any?)
    @objc optional func hideColumn(_ sender: Any?)
    @objc optional func freezeColumns(_ sender: Any?)
    @objc optional func displayAs(_ sender: Any?)
    @objc optional func exportRows(_ sender: Any?)

    // Database (the navigator and editors)
    @objc optional func newDatabase(_ sender: Any?)
    @objc optional func createTable(_ sender: Any?)
    @objc optional func createObject(_ sender: Any?)
    @objc optional func openData(_ sender: Any?)
    @objc optional func openTable(_ sender: Any?)
    @objc optional func openStructure(_ sender: Any?)
    @objc optional func openObject(_ sender: Any?)
    @objc optional func runRoutine(_ sender: Any?)
    @objc optional func generateSelect(_ sender: Any?)
    @objc optional func generateInsert(_ sender: Any?)
    @objc optional func generateUpdate(_ sender: Any?)
    @objc optional func copyTable(_ sender: Any?)
    @objc optional func runMaintenance(_ sender: Any?)
    @objc optional func truncateTable(_ sender: Any?)
    @objc optional func renameObject(_ sender: Any?)
    @objc optional func dropObject(_ sender: Any?)
    @objc optional func expandAll(_ sender: Any?)
    @objc optional func collapseAll(_ sender: Any?)
    @objc optional func findOnServer(_ sender: Any?)
    @objc optional func showProcessList(_ sender: Any?)
    @objc optional func killQuery(_ sender: Any?)
    @objc optional func killConnection(_ sender: Any?)
    @objc optional func showERDiagram(_ sender: Any?)
    @objc optional func bulkEditTables(_ sender: Any?)

    // Connection
    @objc optional func connect(_ sender: Any?)
    @objc optional func disconnect(_ sender: Any?)
    @objc optional func editConnection(_ sender: Any?)
    @objc optional func duplicateConnection(_ sender: Any?)
    @objc optional func setConnectionColour(_ sender: Any?)
    @objc optional func deleteConnection(_ sender: Any?)
    @objc optional func openInTerminal(_ sender: Any?)

    // Tools
    @objc optional func exportDatabase(_ sender: Any?)
    @objc optional func restoreDatabase(_ sender: Any?)
    @objc optional func copyToServer(_ sender: Any?)
    @objc optional func compareDatabases(_ sender: Any?)
    @objc optional func showSyncScript(_ sender: Any?)
    @objc optional func exportReport(_ sender: Any?)
    @objc optional func copySyncScript(_ sender: Any?)
    @objc optional func leaveOutOfCompare(_ sender: Any?)
    @objc optional func generateLiquibase(_ sender: Any?)
    @objc optional func setUpAgents(_ sender: Any?)
    @objc optional func showAgentActivity(_ sender: Any?)
    @objc optional func turnAgentsOff(_ sender: Any?)
    @objc optional func showAgentGuide(_ sender: Any?)

    // Window
    @objc optional func showNextTab(_ sender: Any?)
    @objc optional func showPreviousTab(_ sender: Any?)
    @objc optional func selectTabNumber(_ sender: Any?)
}

/// A command as a menu item shows it: its title, action, shortcut and one-line tooltip (verb first, no full stop).
/// The menu bar and every context menu make their items from these, so a command reads, does and says the same
/// everywhere. `tag` tells apart the commands of one action (Find's, a submenu's choices).
struct Command {
    let title: String
    let action: Selector
    let key: String
    let modifiers: NSEvent.ModifierFlags
    let tip: String
    var tag = 0
    /// Not shown, its shortcut still works (F9 for Run All, as HeidiSQL has it).
    var hidden = false

    init(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0,
         hidden: Bool = false, tip: String) {
        self.title = title
        self.action = action
        self.key = key
        self.modifiers = key.isEmpty ? [] : modifiers
        self.tip = tip
        self.tag = tag
        self.hidden = hidden
    }

    /// A menu item for the menu bar or a context menu (nil target: the responder chain).
    func item() -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.toolTip = tip
        item.tag = tag
        if hidden {
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }
        return item
    }

    /// The shortcut as menus write it ("⇧⌘↩"), empty without one.
    var shortcut: String { Command.shortcut(key, modifiers) }

    static func shortcut(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> String {
        guard !key.isEmpty else { return "" }
        var flags = modifiers
        if key.lowercased() != key { flags.insert(.shift) }
        let names: [String: String] = ["\r": "↩", "\u{8}": "⌫", "\u{7f}": "⌫", "\t": "⇥", "\u{1b}": "⎋", " ": "Space",
                                       String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
                                       String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑",
                                       String(UnicodeScalar(NSF9FunctionKey)!): "F9"]
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + (names[key] ?? key.uppercased())
    }
}

private func sel(_ name: String) -> Selector { NSSelectorFromString(name) }

private let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
private let f9 = String(UnicodeScalar(NSF9FunctionKey)!)

/// Every command, by menu: the shortcut map (no shortcut is taken twice, and none that macOS keeps for itself:
/// `CommandsTests`). Settled for every lane in P0 (plan §2.4): ⌘↩ only runs; ⌘S saves a console's file and applies
/// a table's changes (whichever is enabled); Set DEFAULT has none (⌥⌘D is the Dock's); ⇧⌘↩ is Run All, so Record
/// View is ⌥⌘R; ⌘↑ and ⌘↓ stay the editor's and grid's (start and end), so Related Rows is ⌃⌘↓; F9 and ⌃F9 run as in
/// HeidiSQL; Commit and Rollback have none, so a slip never commits.
enum Commands {
    // MARK: AirSQL
    static let about = Command("About AirSQL", #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                               tip: "Show AirSQL's version and the licences of what it is built with")
    static let settings = Command("Settings…", #selector(AirSQLActions.showSettings(_:)), ",",
                                  tip: "Change the look, the editor and grid, safety checks, agents and client tools")
    static let hide = Command("Hide AirSQL", #selector(NSApplication.hide(_:)), "h",
                              tip: "Hide AirSQL's windows; connections and running work carry on")
    static let hideOthers = Command("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option],
                                    tip: "Hide every other app's windows")
    static let showAll = Command("Show All", #selector(NSApplication.unhideAllApplications(_:)),
                                 tip: "Show the windows of every app again")
    static let quit = Command("Quit AirSQL", #selector(NSApplication.terminate(_:)), "q",
                              tip: "Disconnect everything and quit; asks first about open transactions and pending edits")

    // MARK: File
    static let newConnection = Command("New Connection…", #selector(AirSQLActions.newConnection(_:)), "n",
                                       tip: "Save a MySQL or MariaDB server to connect to: its address, login and route")
    static let newQuery = Command("New Query", #selector(AirSQLActions.newQuery(_:)), "t",
                                  tip: "Open a new SQL console tab on the selected connection")
    static let open = Command("Open…", #selector(AirSQLActions.openSQLFile(_:)), "o", tip: "Open a .sql file in a new console tab")
    static let closeTab = Command("Close Tab", #selector(AirSQLActions.closeTab(_:)), "w",
                                  tip: "Close the tab shown; asks first about unsaved text or pending edits")
    static let closeOtherTabs = Command("Close Other Tabs", #selector(AirSQLActions.closeOtherTabs(_:)), "w", [.command, .option],
                                        tip: "Close every tab but the one shown; asks first about unsaved work")
    static let closeWindow = Command("Close Window", #selector(NSWindow.performClose(_:)), "W",
                                     tip: "Close the window; connections stay open")
    static let save = Command("Save", #selector(AirSQLActions.saveQuery(_:)), "s", tip: "Save the console's text to its .sql file")
    static let saveAs = Command("Save As…", #selector(AirSQLActions.saveQueryAs(_:)), "S",
                                tip: "Save the console's text to a new .sql file")
    static let duplicateTab = Command("Duplicate Tab", #selector(AirSQLActions.duplicateTab(_:)),
                                      tip: "Open a copy of the tab shown next to it")
    static let renameTab = Command("Rename Tab…", #selector(AirSQLActions.renameTab(_:)), tip: "Give the tab shown a name of your own")
    static let revealInFinder = Command("Reveal in Finder", #selector(AirSQLActions.revealInFinder(_:)),
                                        tip: "Show the tab's .sql file in Finder")
    static let runSQLFile = Command("Run SQL File…", #selector(AirSQLActions.runSQLFile(_:)),
                                    tip: "Run the statements of a .sql or .sql.gz file on this connection, with progress")
    static let importCSV = Command("Import CSV…", #selector(AirSQLActions.importCSV(_:)),
                                   tip: "Load rows from a CSV file into a table, choosing which column goes where")
    static let importSSHConfig = Command("Import from ~/.ssh/config…", #selector(AirSQLActions.importSSHConfig(_:)),
                                         tip: "Make connections that tunnel through the SSH hosts in your ~/.ssh/config")

    // MARK: Edit
    static let undo = Command("Undo", sel("undo:"), "z", tip: "Undo the last change")
    static let redo = Command("Redo", sel("redo:"), "Z", tip: "Redo what was undone")
    static let cut = Command("Cut", #selector(NSText.cut(_:)), "x", tip: "Cut the selection")
    static let copy = Command("Copy", #selector(NSText.copy(_:)), "c", tip: "Copy the selection: text, cells or names")
    static let copyWithHeaders = Command("Copy with Headers", #selector(AirSQLActions.copyWithHeaders(_:)), "c", [.command, .option],
                                         tip: "Copy the selected cells with their column names as the first line")
    static let copyAs = Command("Copy As", #selector(AirSQLActions.copyAs(_:)),
                                tip: "Copy the selected cells in this format; it becomes ⌘C's format")
    static let copySummary = Command("Copy Selection Summary", #selector(AirSQLActions.copySummary(_:)), "C",
                                     tip: "Copy the selection's count, sum, average, minimum and maximum")
    static let paste = Command("Paste", #selector(NSText.paste(_:)), "v", tip: "Paste text, or cells into the grid as pending edits")
    static let delete = Command("Delete", #selector(NSText.delete(_:)), tip: "Delete the selection")
    static let selectAll = Command("Select All", #selector(NSText.selectAll(_:)), "a",
                                   tip: "Select everything in the editor, grid or list that has the focus")
    static let copyName = Command("Copy Name", #selector(AirSQLActions.copyName(_:)), tip: "Copy the selected object's name, quoted for SQL")
    static let copyColumnName = Command("Copy Column Name", #selector(AirSQLActions.copyColumnNames(_:)),
                                        tip: "Copy the name of the selected column")
    static let copyCreate = Command("Copy CREATE", #selector(AirSQLActions.copyCreateStatement(_:)),
                                    tip: "Copy the statement that creates the selected object")
    static let copyQuery = Command("Copy Query", #selector(AirSQLActions.copyQuery(_:)),
                                   tip: "Copy the full query the selected process is running")
    static let find = Command("Find…", #selector(NSResponder.performTextFinderAction(_:)), "f",
                              tag: NSTextFinder.Action.showFindInterface.rawValue,
                              tip: "Find text in the editor, or values in the grid's loaded rows")
    static let findAndReplace = Command("Find and Replace…", #selector(NSResponder.performTextFinderAction(_:)), "f", [.command, .option],
                                        tag: NSTextFinder.Action.showReplaceInterface.rawValue,
                                        tip: "Find and replace text in the editor, or values in the grid as pending edits")
    static let findNext = Command("Find Next", #selector(NSResponder.performTextFinderAction(_:)), "g",
                                  tag: NSTextFinder.Action.nextMatch.rawValue, tip: "Show the next match")
    static let findPrevious = Command("Find Previous", #selector(NSResponder.performTextFinderAction(_:)), "G",
                                      tag: NSTextFinder.Action.previousMatch.rawValue, tip: "Show the previous match")
    static let useSelectionForFind = Command("Use Selection for Find", #selector(NSResponder.performTextFinderAction(_:)), "e",
                                             tag: NSTextFinder.Action.setSearchString.rawValue, tip: "Find the selected text")

    // MARK: View
    static let toggleSidebar = Command("Hide Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control],
                                       tip: "Hide or show the connections and the database tree")
    static let filterSidebar = Command("Filter Sidebar", #selector(AirSQLActions.filterSidebar(_:)), "j", [.command, .option],
                                       tip: "Type part of a name to narrow the connections and the tree")
    static let valuePanel = Command("Value Panel", #selector(AirSQLActions.toggleValuePanel(_:)), "\r", .shift,
                                    tip: "Show or hide the selected cell's full value beside the grid: text, JSON, hex")
    static let recordView = Command("Record View", #selector(AirSQLActions.showRecordView(_:)), "r", [.command, .option],
                                    tip: "Show the selected row as a form, one field per column")
    static let transpose = Command("Transpose", #selector(AirSQLActions.transposeGrid(_:)), "t", [.command, .option],
                                   tip: "Turn rows into columns to compare a few wide rows side by side")
    static let viewAs = Command("View As", #selector(AirSQLActions.viewAs(_:)),
                                tip: "Show the results as a table, as text in the copy format, or as a JSON tree")
    static let chart = Command("Chart", #selector(AirSQLActions.showChart(_:)),
                               tip: "Chart the results as bars, lines, areas, points or a histogram")
    static let columnList = Command("Column List…", #selector(AirSQLActions.showColumnList(_:)), "j",
                                    tip: "Find a column by name, jump to it, and show or hide columns")
    static let sqlLog = Command("SQL Log", #selector(AirSQLActions.showSQLLog(_:)), "l", [.command, .option],
                                tip: "Show every statement AirSQL sent, with times and results (passwords masked)")
    static let clearSQLLog = Command("Clear SQL Log", #selector(AirSQLActions.clearSQLLog(_:)),
                                     tip: "Remove the statements listed in the SQL log")
    static let activity = Command("Activity", #selector(AirSQLActions.showActivity(_:)),
                                  tip: "Show the work running now, with its progress and Cancel")
    static let cancelAll = Command("Cancel All Work", #selector(AirSQLActions.cancelAllActivities(_:)),
                                   tip: "Cancel every query, export and connect that is running")
    static let bigger = Command("Bigger", #selector(AirSQLActions.zoomIn(_:)), "+", tip: "Make the editor's and grid's text bigger")
    static let smaller = Command("Smaller", #selector(AirSQLActions.zoomOut(_:)), "-", tip: "Make the editor's and grid's text smaller")
    static let actualSize = Command("Actual Size", #selector(AirSQLActions.zoomReset(_:)), "0",
                                    tip: "Use the text sizes chosen in Settings again")
    static let refresh = Command("Refresh", #selector(AirSQLActions.refresh(_:)), "r",
                                 tip: "Load the tree, table or list shown again from the server")
    static let autoRefresh = Command("Refresh Every", #selector(AirSQLActions.setAutoRefresh(_:)),
                                     tip: "Refresh the grid by itself every few seconds, or stop")
    static let fullScreen = Command("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control],
                                    tip: "Fill the screen with AirSQL's window, or leave full screen")

    // MARK: Query
    static let runStatement = Command("Run Statement", #selector(AirSQLActions.runStatement(_:)), "\r",
                                      tip: "Run the statement at the cursor, or the selected text")
    static let runSelection = Command("Run Selection", #selector(AirSQLActions.runSelection(_:)), tip: "Run the selected text only")
    static let runAll = Command("Run All", #selector(AirSQLActions.runAll(_:)), "\r", [.command, .shift],
                                tip: "Run every statement in the console, one after another")
    static let runAllF9 = Command("Run All", #selector(AirSQLActions.runAll(_:)), f9, [], hidden: true,
                                  tip: "Run every statement in the console, one after another (F9)")
    static let runStatementF9 = Command("Run Statement", #selector(AirSQLActions.runStatement(_:)), f9, .control, hidden: true,
                                        tip: "Run the statement at the cursor, or the selected text (⌃F9)")
    static let explain = Command("Explain", #selector(AirSQLActions.explain(_:)), "e", [.command, .option],
                                 tip: "Show how the server would run the statement at the cursor, without running it")
    static let cancelQuery = Command("Cancel", #selector(AirSQLActions.cancelQuery(_:)), ".",
                                     tip: "Stop the statement that is running in this tab")
    static let commit = Command("Commit", #selector(AirSQLActions.commit(_:)), tip: "Make the open transaction's changes permanent")
    static let rollback = Command("Rollback", #selector(AirSQLActions.rollback(_:)), tip: "Undo every change of the open transaction")
    static let autoCommit = Command("Auto-commit", #selector(AirSQLActions.setTransactionMode(_:)), tag: 0,
                                    tip: "Commit each statement by itself (Auto-commit), or only when you press Commit (Manual)")
    static let manualCommit = Command("Manual", #selector(AirSQLActions.setTransactionMode(_:)), tag: 1,
                                      tip: "Commit each statement by itself (Auto-commit), or only when you press Commit (Manual)")
    static let isolation = Command("Isolation Level", #selector(AirSQLActions.setIsolationLevel(_:)),
                                   tip: "Set how the console's transactions see each other's changes")
    static let formatSQL = Command("Format SQL", #selector(AirSQLActions.formatSQL(_:)), "f", [.command, .option, .shift],
                                   tip: "Tidy the SQL's spacing and keyword case; values and comments stay as they are")
    static let history = Command("Query History", #selector(AirSQLActions.showHistory(_:)), "y",
                                 tip: "Search the statements run on this connection and insert one again")
    static let changeConnection = Command("Change Connection…", #selector(AirSQLActions.changeConnection(_:)),
                                          tip: "Run this console's statements on another connection")
    static let profile = Command("Profile", #selector(AirSQLActions.profileQuery(_:)),
                                 tip: "Run the statement and show where the server spent its time")
    static let saveAsChangeset = Command("Save as Changeset…", #selector(AirSQLActions.saveAsChangeset(_:)),
                                         tip: "Save the selected statements as a Liquibase changeset in a changelog")
    static let editAsTable = Command("Edit as Table", #selector(AirSQLActions.editAsTable(_:)),
                                     tip: "Open the selected INSERT statements as a grid to edit")
    static let pinResult = Command("Pin Result", #selector(AirSQLActions.pinResult(_:)),
                                   tip: "Keep this result tab: the next run opens a new one")
    static let renameResult = Command("Rename Result…", #selector(AirSQLActions.renameResult(_:)),
                                      tip: "Give this result tab a name of your own")
    static let closeResult = Command("Close Result", #selector(AirSQLActions.closeResult(_:)), tip: "Close this result tab")
    static let closeOtherResults = Command("Close Other Results", #selector(AirSQLActions.closeOtherResults(_:)),
                                           tip: "Close every result tab but this one")
    static let exportResult = Command("Export Result…", #selector(AirSQLActions.exportResult(_:)),
                                      tip: "Save this result's rows to a CSV, JSON, SQL, Excel or other file")
    static let compareResult = Command("Compare With…", #selector(AirSQLActions.compareResult(_:)),
                                       tip: "Compare this result with another result or a table, row by row")
    static let toggleComment = Command("Comment Lines", #selector(AirSQLActions.toggleComment(_:)), "/",
                                       tip: "Comment out the selected lines with --, or take the comment away")
    static let shiftRight = Command("Shift Right", #selector(AirSQLActions.indentLines(_:)), "]", tip: "Indent the selected lines")
    static let shiftLeft = Command("Shift Left", #selector(AirSQLActions.outdentLines(_:)), "[",
                                   tip: "Take one indent off the selected lines")
    static let helpers = Command("Query Helpers", #selector(AirSQLActions.toggleHelpers(_:)),
                                 tip: "Show or hide the columns, functions and keywords beside the editor")

    // MARK: Data
    static let addRow = Command("Add Row", #selector(AirSQLActions.addRow(_:)), "i",
                                tip: "Add a new row; it is saved when you apply the changes")
    static let duplicateRow = Command("Duplicate Row", #selector(AirSQLActions.duplicateRow(_:)), "d",
                                      tip: "Add a copy of the selected rows, keys included")
    static let duplicateRowWithoutKeys = Command("Duplicate Row Without Keys", #selector(AirSQLActions.duplicateRowWithoutKeys(_:)), "D",
                                                 tip: "Add a copy of the selected rows, leaving their keys to the server")
    static let deleteRows = Command("Delete Rows…", #selector(AirSQLActions.deleteRows(_:)), "\u{8}",
                                    tip: "Mark the selected rows for deletion; they are deleted when you apply")
    static let setNull = Command("Set NULL", #selector(AirSQLActions.setCellNull(_:)), "n", [.command, .option],
                                 tip: "Set the selected cells to NULL (a pending edit)")
    static let setDefault = Command("Set DEFAULT", #selector(AirSQLActions.setCellDefault(_:)),
                                    tip: "Set the selected cells to the column's default (a pending edit)")
    static let insertValue = Command("Insert Value", #selector(AirSQLActions.insertCellValue(_:)),
                                     tip: "Put this value or function in the selected cells (a pending edit)")
    static let apply = Command("Apply Changes", #selector(AirSQLActions.applyChanges(_:)), "s",
                               tip: "Write the pending edits, new rows and deletions to the server in one transaction")
    static let previewChanges = Command("Preview SQL…", #selector(AirSQLActions.previewChanges(_:)),
                                        tip: "Show the SQL that Apply would run, without running it")
    static let revert = Command("Revert", #selector(AirSQLActions.revertChanges(_:)), "z", [.command, .option],
                                tip: "Throw away the pending changes of the selected rows")
    static let filter = Command("Filter…", #selector(AirSQLActions.focusFilter(_:)), "F",
                                tip: "Type a WHERE condition to filter the table on the server")
    static let searchAllColumns = Command("Search All Columns", #selector(AirSQLActions.searchAllColumns(_:)), "E",
                                          tip: "Find rows with this text in any column")
    static let quickFilter = Command("Quick Filter", #selector(AirSQLActions.quickFilter(_:)),
                                     tip: "Filter by the selected value: equal, not equal, greater, like, NULL…")
    static let filterEquals = Command("Equal to Selection", #selector(AirSQLActions.quickFilterEquals(_:)), "1", [.command, .control],
                                      tip: "Show only rows with the selected value in this column")
    static let filterNotEquals = Command("Not Equal to Selection", #selector(AirSQLActions.quickFilterNotEquals(_:)), "2",
                                         [.command, .control], tip: "Hide rows with the selected value in this column")
    static let filterByValues = Command("Filter by Values…", #selector(AirSQLActions.filterByValues(_:)),
                                        tip: "Tick the values to show in this column, as in a spreadsheet")
    static let clearFilter = Command("Clear Filter", #selector(AirSQLActions.clearFilter(_:)), tip: "Show every row again")
    static let sortAscending = Command("Sort Ascending", #selector(AirSQLActions.sortAscending(_:)),
                                       tip: "Sort by this column, smallest first")
    static let sortDescending = Command("Sort Descending", #selector(AirSQLActions.sortDescending(_:)),
                                        tip: "Sort by this column, largest first")
    static let clearSort = Command("Clear Sort", #selector(AirSQLActions.clearSort(_:)), tip: "Show rows in the table's own order again")
    static let goToRow = Command("Go to Row…", #selector(AirSQLActions.goToRow(_:)), "l", tip: "Go to a row by its number, or to column:row")
    static let relatedRows = Command("Related Rows", #selector(AirSQLActions.showRelatedRows(_:)), down, [.command, .control],
                                     tip: "Show the rows this value refers to, or the rows that refer to it")
    static let columnSummary = Command("Column Summary…", #selector(AirSQLActions.showColumnSummary(_:)),
                                       tip: "Count the column's distinct values, NULLs, minimum and maximum on the server")
    static let loadMore = Command("Load More", #selector(AirSQLActions.loadMore(_:)), down, [.command, .option],
                                  tip: "Load the next page of rows")
    static let loadAll = Command("Load All", #selector(AirSQLActions.loadAll(_:)), down, [.command, .option, .shift],
                                 tip: "Load every row of the table or result; asks first when there are many")
    static let countRows = Command("Count Rows Exactly", #selector(AirSQLActions.countRows(_:)),
                                   tip: "Count the table's rows with COUNT(*) instead of the estimate")
    static let hideColumn = Command("Hide Column", #selector(AirSQLActions.hideColumn(_:)), tip: "Hide this column; Column List shows it again")
    static let freeze = Command("Freeze", #selector(AirSQLActions.freezeColumns(_:)),
                                tip: "Keep the columns up to this one in view while scrolling sideways")
    static let displayAs = Command("Display As", #selector(AirSQLActions.displayAs(_:)),
                                   tip: "Show this column's values another way: hex, UUID, date from a Unix time…")
    static let exportRows = Command("Export Rows…", #selector(AirSQLActions.exportRows(_:)),
                                    tip: "Save the selected or loaded rows, or all of them, to a file")

    // MARK: Database
    static let newDatabase = Command("New Database…", #selector(AirSQLActions.newDatabase(_:)),
                                     tip: "Create a database with a character set and collation")
    static let createTable = Command("Create Table…", #selector(AirSQLActions.createTable(_:)),
                                     tip: "Design a new table: its columns, keys and options")
    static let createObject = Command("New…", #selector(AirSQLActions.createObject(_:)),
                                      tip: "Create a new object of this kind: a table, view, routine, trigger or event")
    static let openData = Command("Open Data", #selector(AirSQLActions.openData(_:)), tip: "Open the table's rows in a tab of their own")
    static let openTable = Command("Open Table…", #selector(AirSQLActions.openTable(_:)), "O",
                                   tip: "Open a table's rows in a tab by typing its name")
    static let openStructure = Command("Open Structure", #selector(AirSQLActions.openStructure(_:)),
                                       tip: "Open the table's columns, indexes and keys in the table editor")
    static let openObject = Command("Open", #selector(AirSQLActions.openObject(_:)), tip: "Open the routine, trigger or event in its editor")
    static let runRoutine = Command("Run…", #selector(AirSQLActions.runRoutine(_:)), tip: "Run the procedure, asking for its parameters")
    static let generateSelect = Command("Generate SELECT", #selector(AirSQLActions.generateSelect(_:)),
                                        tip: "Put a SELECT of this table's columns in a console tab")
    static let generateInsert = Command("Generate INSERT", #selector(AirSQLActions.generateInsert(_:)),
                                        tip: "Put an INSERT for this table in a console tab")
    static let generateUpdate = Command("Generate UPDATE", #selector(AirSQLActions.generateUpdate(_:)),
                                        tip: "Put an UPDATE for this table in a console tab")
    static let copyTable = Command("Copy Table…", #selector(AirSQLActions.copyTable(_:)),
                                   tip: "Copy this table, with or without its rows, to another database")
    static let maintenance = Command("Maintenance", #selector(AirSQLActions.runMaintenance(_:)),
                                     tip: "Optimize, check, analyze, repair or checksum the selected tables")
    static let truncate = Command("Truncate…", #selector(AirSQLActions.truncateTable(_:)),
                                  tip: "Delete every row of the selected tables (asks first)")
    static let rename = Command("Rename…", #selector(AirSQLActions.renameObject(_:)),
                                tip: "Rename the selected table or view (shows the SQL first)")
    static let drop = Command("Drop…", #selector(AirSQLActions.dropObject(_:)),
                              tip: "Delete the selected objects from the server (asks first and shows the SQL)")
    static let expandAll = Command("Expand All", #selector(AirSQLActions.expandAll(_:)), tip: "Open every folder under this one")
    static let collapseAll = Command("Collapse All", #selector(AirSQLActions.collapseAll(_:)), tip: "Close every folder under this one")
    static let findOnServer = Command("Find Text on Server…", #selector(AirSQLActions.findOnServer(_:)),
                                      tip: "Search every table of the server for a text")
    static let processList = Command("Process List", #selector(AirSQLActions.showProcessList(_:)), "p", [.command, .option],
                                     tip: "Show what every connection to the server is running, with Kill")
    static let killQuery = Command("Kill Query…", #selector(AirSQLActions.killQuery(_:)),
                                   tip: "Stop the selected process's statement; its connection stays")
    static let killConnection = Command("Kill Connection…", #selector(AirSQLActions.killConnection(_:)),
                                        tip: "End the selected process's connection to the server")
    static let erDiagram = Command("ER Diagram", #selector(AirSQLActions.showERDiagram(_:)),
                                   tip: "Draw the database's tables and their foreign keys")
    static let newView = Command("View…", #selector(AirSQLActions.createObject(_:)), tag: 1,
                                 tip: "Write a new view as its CREATE statement")
    static let newProcedure = Command("Procedure…", #selector(AirSQLActions.createObject(_:)), tag: 2,
                                      tip: "Write a new stored procedure as its CREATE statement")
    static let newFunction = Command("Function…", #selector(AirSQLActions.createObject(_:)), tag: 3,
                                     tip: "Write a new stored function as its CREATE statement")
    static let newTrigger = Command("Trigger…", #selector(AirSQLActions.createObject(_:)), tag: 4,
                                    tip: "Write a new trigger as its CREATE statement")
    static let newEvent = Command("Event…", #selector(AirSQLActions.createObject(_:)), tag: 5,
                                  tip: "Write a new scheduled event as its CREATE statement")
    static let bulkEdit = Command("Bulk Table Editor…", #selector(AirSQLActions.bulkEditTables(_:)),
                                  tip: "Move tables to another database, or change their engine or collation")

    // MARK: Connection
    static let connect = Command("Connect", #selector(AirSQLActions.connect(_:)), "k",
                                 tip: "Connect to the selected connection, or show it if it is connected")
    static let disconnect = Command("Disconnect", #selector(AirSQLActions.disconnect(_:)), "K",
                                    tip: "Close the connection; asks first about open transactions and pending edits")
    static let editConnection = Command("Edit…", #selector(AirSQLActions.editConnection(_:)),
                                        tip: "Change the selected connection's address, login, route and options")
    static let duplicateConnection = Command("Duplicate", #selector(AirSQLActions.duplicateConnection(_:)),
                                             tip: "Make a copy of the selected connection, with its saved password")
    static let colour = Command("Colour", #selector(AirSQLActions.setConnectionColour(_:)),
                                tip: "Mark the connection with this colour; Production also turns on stricter safety")
    static let deleteConnection = Command("Delete…", #selector(AirSQLActions.deleteConnection(_:)),
                                          tip: "Forget the selected connections and their saved passwords (asks first)")
    static let openInTerminal = Command("Open in Terminal", #selector(AirSQLActions.openInTerminal(_:)),
                                        tip: "Open the mysql command line in Terminal on this connection, through its route")

    // MARK: Tools
    static let export = Command("Export…", #selector(AirSQLActions.exportDatabase(_:)),
                                tip: "Dump databases or tables to a .sql file with your mysqldump or mariadb-dump")
    static let restore = Command("Restore…", #selector(AirSQLActions.restoreDatabase(_:)),
                                 tip: "Run a dump file into a database with your mysql or mariadb client")
    static let copyToServer = Command("Copy to Another Server…", #selector(AirSQLActions.copyToServer(_:)),
                                      tip: "Copy databases or tables, with their rows, to another connection")
    static let compare = Command("Compare…", #selector(AirSQLActions.compareDatabases(_:)),
                                 tip: "Compare two databases' structure and data, and make a script that syncs them")
    static let syncScript = Command("Sync Script…", #selector(AirSQLActions.showSyncScript(_:)),
                                    tip: "Review the script that makes the target match the source, then run it if you want")
    static let exportReport = Command("Export Report…", #selector(AirSQLActions.exportReport(_:)),
                                      tip: "Save what the compare found as an HTML, CSV or Markdown file")
    static let copySyncScript = Command("Copy Sync Script", #selector(AirSQLActions.copySyncScript(_:)),
                                        tip: "Copy the sync statements of the selected objects")
    static let leaveOutOfCompare = Command("Leave Out of Next Compare", #selector(AirSQLActions.leaveOutOfCompare(_:)),
                                           tip: "Skip the selected tables when you compare again; Tables… brings them back")
    static let generateLiquibase = Command("Generate Liquibase Changelog…", #selector(AirSQLActions.generateLiquibase(_:)),
                                           tip: "Write a Liquibase changelog of a database's objects and rows")
    static let setUpAgents = Command("Set Up Agents…", #selector(AirSQLActions.setUpAgents(_:)),
                                     tip: "Let Claude Code, Gemini CLI or another MCP client use AirSQL, at the access you choose")
    static let agentActivity = Command("Agent Activity", #selector(AirSQLActions.showAgentActivity(_:)),
                                       tip: "Show what agents asked AirSQL to do, newest last")
    static let turnAgentsOff = Command("Turn Agents Off", #selector(AirSQLActions.turnAgentsOff(_:)),
                                       tip: "Stop every agent from using AirSQL until you turn agents on again")

    // MARK: Window
    static let minimize = Command("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", tip: "Put the window in the Dock")
    static let zoom = Command("Zoom", #selector(NSWindow.performZoom(_:)), tip: "Fit the window to the screen")
    static let previousTab = Command("Show Previous Tab", #selector(AirSQLActions.showPreviousTab(_:)), "{",
                                     tip: "Show the tab to the left of the one shown")
    static let nextTab = Command("Show Next Tab", #selector(AirSQLActions.showNextTab(_:)), "}",
                                 tip: "Show the tab to the right of the one shown")
    static let mainWindow = Command("AirSQL", #selector(AirSQLActions.showMainWindow(_:)), tip: "Bring AirSQL's main window back")
    static let bringAllToFront = Command("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)),
                                         tip: "Bring every AirSQL window in front of other apps")

    /// Window ▸ the tabs, ⌘1…⌘9 (the item's tag is the number; its title is the tab's).
    static func tab(_ number: Int) -> Command {
        Command("Tab \(number)", #selector(AirSQLActions.selectTabNumber(_:)), String(number), tag: number, tip: "Show this tab")
    }

    // MARK: Help
    static let help = Command("AirSQL Help", #selector(AirSQLActions.showHelpSite(_:)),
                              tip: "Open AirSQL Help on the web: every task step by step, with pictures")
    static let gettingStarted = Command("Getting Started", #selector(AirSQLActions.showGettingStarted(_:)),
                                        tip: "Open the first steps in AirSQL Help: add a connection, run a query, edit rows")
    static let reportProblem = Command("Report a Problem", #selector(AirSQLActions.reportProblem(_:)),
                                       tip: "Tell AirSQL's makers about a problem: a form on GitHub with your versions filled in")
    static let copyDiagnostics = Command("Copy Diagnostics", #selector(AirSQLActions.copyDiagnostics(_:)),
                                         tip: "Copy the versions of AirSQL, macOS and its client library, for a problem report")
    static let agentGuide = Command("AI Agents", #selector(AirSQLActions.showAgentGuide(_:)),
                                    tip: "Open the page of AirSQL Help about letting Claude Code or Gemini CLI use AirSQL")

    /// Every command above, for the checks (the tab commands once).
    static let all: [Command] = [
        about, settings, hide, hideOthers, showAll, quit,
        newConnection, newQuery, open, closeTab, closeOtherTabs, closeWindow, save, saveAs, duplicateTab, renameTab, revealInFinder,
        runSQLFile, importCSV, importSSHConfig,
        undo, redo, cut, copy, copyWithHeaders, copyAs, copySummary, paste, delete, selectAll, copyName, copyColumnName, copyCreate,
        copyQuery, find, findAndReplace, findNext, findPrevious, useSelectionForFind,
        toggleSidebar, filterSidebar, valuePanel, recordView, transpose, viewAs, chart, columnList, sqlLog, clearSQLLog, activity,
        cancelAll, bigger, smaller, actualSize, refresh, autoRefresh, fullScreen,
        runStatement, runSelection, runAll, runAllF9, runStatementF9, explain, cancelQuery, commit, rollback, autoCommit, manualCommit,
        isolation, formatSQL, history, changeConnection, profile, saveAsChangeset, editAsTable, pinResult, renameResult, closeResult,
        closeOtherResults, exportResult, compareResult, toggleComment, shiftRight, shiftLeft, helpers,
        addRow, duplicateRow, duplicateRowWithoutKeys, deleteRows, setNull, setDefault, insertValue, apply, previewChanges, revert,
        filter, searchAllColumns, quickFilter, filterEquals, filterNotEquals, filterByValues, clearFilter, sortAscending,
        sortDescending, clearSort, goToRow, relatedRows, columnSummary, loadMore, loadAll, countRows, hideColumn, freeze, displayAs,
        exportRows,
        newDatabase, createTable, createObject, openData, openTable, openStructure, openObject, runRoutine, generateSelect, generateInsert,
        generateUpdate, copyTable, maintenance, truncate, rename, drop, expandAll, collapseAll, findOnServer, processList, killQuery,
        killConnection, erDiagram, bulkEdit, newView, newProcedure, newFunction, newTrigger, newEvent,
        connect, disconnect, editConnection, duplicateConnection, colour, deleteConnection, openInTerminal,
        export, restore, copyToServer, compare, syncScript, exportReport, copySyncScript, leaveOutOfCompare, generateLiquibase,
        setUpAgents, agentActivity, turnAgentsOff,
        minimize, zoom, previousTab, nextTab, mainWindow, bringAllToFront, tab(1),
        help, gettingStarted, reportProblem, copyDiagnostics, agentGuide,
    ]

    /// The command with this action (and tag, for the actions several commands share).
    static func command(for action: Selector?, tag: Int = 0) -> Command? {
        guard let action else { return nil }
        let matches = all.filter { $0.action == action && !$0.hidden }
        return matches.first { $0.tag == tag } ?? matches.first
    }

    /// What `item` does: its command's tip, or a submenu's.
    static func tip(for item: NSMenuItem) -> String? {
        command(for: item.action, tag: item.tag)?.tip ?? (item.submenu != nil ? submenus[item.title] : nil)
    }

    /// Menu items that only open a submenu, by title.
    static let submenus: [String: String] = [
        "Services": "Other apps' commands for what is selected",
        "Find": "Find text in the editor, or values in the grid",
        "Copy As": "Copy the selected cells as TSV, CSV, Markdown, JSON, SQL and more",
        "View As": viewAs.tip,
        "Refresh Every": autoRefresh.tip,
        "Transaction Mode": autoCommit.tip,
        "Isolation Level": isolation.tip,
        "Insert Value": insertValue.tip,
        "Quick Filter": quickFilter.tip,
        "Sort": "Sort the rows by this column, or show them in the table's own order",
        "Display As": displayAs.tip,
        "Maintenance": maintenance.tip,
        "New Object": "Write a new view, procedure, function, trigger or event as its CREATE statement",
        "Colour": colour.tip,
        "Agents": "Let AI agents use AirSQL, see what they did, or turn them off",
    ]
}

extension NSMenuItem {
    /// Sets the tooltip for the item's state: why it is off (when that is known), else what it does.
    func explain(enabled: Bool, reason: String?) {
        toolTip = (enabled ? nil : reason) ?? Commands.tip(for: self) ?? toolTip
    }
}
