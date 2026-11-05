import AppKit

private let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
private let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
private let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
private let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)

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

    static let selectNextOccurrence = Command("Select Next Occurrence", #selector(SQLEditorView.selectNextOccurrence(_:)), "g", [.command, .option],
                                              tip: "Select the word at the cursor, then add a caret where its text appears next")
    static let selectAllOccurrences = Command("Select All Occurrences", #selector(SQLEditorView.selectAllOccurrences(_:)), "g", [.command, .control],
                                              tip: "Put a caret on every place the selection or word at the cursor appears")
    static let caretPerLine = Command("Add Caret to Each Line", #selector(SQLEditorView.caretPerLine(_:)), "G", .option,
                                      tip: "Put a caret at the end of each selected line")
    static let addCaretAbove = Command("Add Caret Above", #selector(SQLEditorView.addCaretAbove(_:)), up, [.control, .option, .shift],
                                       tip: "Add a caret on the line above, at the same column")
    static let addCaretBelow = Command("Add Caret Below", #selector(SQLEditorView.addCaretBelow(_:)), down, [.control, .option, .shift],
                                       tip: "Add a caret on the line below, at the same column")
    static let columnSelection = Command("Column Selection Mode", #selector(SQLEditorView.toggleColumnSelection(_:)), "*", .command,
                                         tip: "Select a block with a drag, and add carets with ⇧↑ and ⇧↓")

    static let foldHere = Command("Fold", #selector(SQLEditorView.foldHere(_:)), left, [.control, .option],
                                  tip: "Hide the statement, brackets or comment at the cursor, down to its first line")
    static let unfoldHere = Command("Unfold", #selector(SQLEditorView.unfoldHere(_:)), right, [.control, .option],
                                    tip: "Show again what's folded on the cursor's line")
    static let foldAll = Command("Fold All", #selector(SQLEditorView.foldAll(_:)), left, [.control, .option, .shift],
                                 tip: "Fold every statement and comment of several lines")
    static let unfoldAll = Command("Unfold All", #selector(SQLEditorView.unfoldAll(_:)), right, [.control, .option, .shift],
                                   tip: "Show everything that's folded")

    static let editorCommands = [foldHere, unfoldHere, foldAll, unfoldAll,
                                 selectNextOccurrence, selectAllOccurrences, caretPerLine, addCaretAbove, addCaretBelow, columnSelection,
                                 nextStatement, previousStatement, selectStatement, moveStatementUp, moveStatementDown,
                                 duplicateLine, deleteLine, moveLineUp, moveLineDown, joinLines, sortLines, reverseLines, toggleCase, blockComment,
                                 completeStatement]
}
