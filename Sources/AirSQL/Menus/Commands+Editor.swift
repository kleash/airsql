import AppKit

private let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
private let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

/// The SQL editor's commands. They live on `SQLEditorView`, which sees them only while it has the focus.
extension Commands {
    static let duplicateLine = Command("Duplicate Line", #selector(SQLEditorView.duplicateLine(_:)), "d", .control,
                                       tip: "Copy the selected lines of SQL to just below them")
    static let deleteLine = Command("Delete Line", #selector(SQLEditorView.deleteLine(_:)), "K", .control,
                                    tip: "Delete the selected lines of SQL, whole")
    static let moveLineUp = Command("Move Line Up", #selector(SQLEditorView.moveLineUp(_:)), up, [.option, .shift],
                                    tip: "Move the selected lines of SQL above the line before them")
    static let moveLineDown = Command("Move Line Down", #selector(SQLEditorView.moveLineDown(_:)), down, [.option, .shift],
                                      tip: "Move the selected lines of SQL below the line after them")
    static let joinLines = Command("Join Lines", #selector(SQLEditorView.joinLines(_:)), "J", .control,
                                   tip: "Put the selected lines, or this line and the next, on one line")
    static let sortLines = Command("Sort Lines", #selector(SQLEditorView.sortLines(_:)), tip: "Sort the selected lines of SQL, A to Z")
    static let reverseLines = Command("Reverse Lines", #selector(SQLEditorView.reverseLines(_:)),
                                      tip: "Put the selected lines of SQL in the opposite order")
    static let toggleCase = Command("Toggle Case", #selector(SQLEditorView.toggleCase(_:)), "U", .control,
                                    tip: "Put the selection or the word at the cursor in capitals, or in small letters")
    static let blockComment = Command("Comment Selection", #selector(SQLEditorView.toggleBlockComment(_:)), "/", [.command, .option],
                                      tip: "Put /* */ around the selection, or take it away")
    static let completeStatement = Command("Complete Statement", #selector(SQLEditorView.completeStatement(_:)), "\r", [.control, .shift],
                                           tip: "Close the statement's brackets, add its ; and start a new line")

    static let nextStatement = Command("Next Statement", #selector(SQLEditorView.nextStatement(_:)), down, [.control, .option],
                                       tip: "Move the cursor to the start of the next statement")
    static let previousStatement = Command("Previous Statement", #selector(SQLEditorView.previousStatement(_:)), up, [.control, .option],
                                           tip: "Move the cursor to the start of this statement, or the one before")
    static let selectStatement = Command("Select Statement", #selector(SQLEditorView.selectStatement(_:)), "a", [.command, .control],
                                         tip: "Select the statement at the cursor")
    static let moveStatementUp = Command("Move Statement Up", #selector(SQLEditorView.moveStatementUp(_:)), up, [.control, .shift],
                                         tip: "Swap the statement at the cursor with the one before it")
    static let moveStatementDown = Command("Move Statement Down", #selector(SQLEditorView.moveStatementDown(_:)), down, [.control, .shift],
                                           tip: "Swap the statement at the cursor with the one after it")

    static let editorCommands = [nextStatement, previousStatement, selectStatement, moveStatementUp, moveStatementDown,
                                 duplicateLine, deleteLine, moveLineUp, moveLineDown, joinLines, sortLines, reverseLines, toggleCase, blockComment,
                                 completeStatement]
}
