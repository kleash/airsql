import AirSQLCore
import AppKit

private let f3 = String(UnicodeScalar(NSF3FunctionKey)!)

/// The workspace's commands: the Files panel, scratch files and the list of consoles.
extension Commands {
    static let filesPanel = Command("Files", #selector(MainWindowController.toggleFilesPanel(_:)), "4", [.command, .option],
                                    tip: "Show attached folders and scratch files in the sidebar, or the tree again")
    static let attachFolder = Command("Attach Folder…", #selector(MainWindowController.attachFolder(_:)),
                                      tip: "Add a folder of .sql files to the Files panel; nothing in it changes")
    static let detachFolder = Command("Detach Folder", #selector(FilesPanelController.detachFolder(_:)),
                                      tip: "Take the folder out of the Files panel; it stays on disk")
    static let newScratch = Command("New Scratch File", #selector(MainWindowController.newScratchFile(_:)), "n", [.command, .option, .shift],
                                    tip: "Open a throwaway .sql file that AirSQL keeps for you, with no name to choose")
    static let openFile = Command("Open", #selector(FilesPanelController.openChosen(_:)), tip: "Open the selected files in query tabs")
    static let runFileOn = Command("Run on Connection", #selector(FilesPanelController.runChosen(_:)),
                                   tip: "Show the file or the folder's .sql files in Run SQL File… on this connection")
    static let copyPath = Command("Copy Path", #selector(FilesPanelController.copyPath(_:)), tip: "Copy where the selected files are")
    static let trashScratch = Command("Move to Trash", #selector(FilesPanelController.trashChosen(_:)),
                                      tip: "Move the selected scratch files to the Trash")
    static let consoleList = Command("Consoles…", #selector(MainWindowController.showConsoleList(_:)), "j", [.command, .shift],
                                     tip: "List the connection's query tabs, jump to one or open a new one")
    static let defaultConsole = Command("Default Console", #selector(MainWindowController.openDefaultConsole(_:)),
                                        tip: "Open the query tab this connection keeps for good, as you left it")

    static let splitRight = Command("Split Right", #selector(MainWindowController.splitRight(_:)), "\\", [.command, .option],
                                    tip: "Show the next tab beside this one, or one tab again")
    static let showBeside = Command("Show Beside This Tab", #selector(MainWindowController.showBeside(_:)),
                                    tip: "Show this tab next to the tab that was on show, side by side")
    static let otherPane = Command("Go to Other Side", #selector(MainWindowController.goToOtherPane(_:)), "\\", [.command, .control],
                                   tip: "Move the focus to the other tab of a split")

    static let toggleBookmark = Command("Toggle Bookmark", #selector(SQLEditorView.toggleBookmark(_:)), f3, [],
                                        tip: "Mark the line at the cursor to come back to it, or take the mark off")
    static let nextBookmark = Command("Next Bookmark", #selector(SQLEditorView.nextBookmark(_:)), f3, .option,
                                      tip: "Go to the next line marked in this editor")
    static let previousBookmark = Command("Previous Bookmark", #selector(SQLEditorView.previousBookmark(_:)), f3, [.option, .shift],
                                          tip: "Go to the line marked before this one")

    static let askAgent = Command("Explain This", #selector(ConsoleViewController.askAgent(_:)), tag: AgentRequest.explain.rawValue,
                                  tip: "Copy a request for your agent to explain the selected SQL; the agent reads it through the gate")
    static let askAgentFix = Command("Fix the Last Error", #selector(ConsoleViewController.askAgent(_:)), tag: AgentRequest.fix.rawValue,
                                     tip: "Copy a request for your agent to say why the last run failed and how to fix it")
    static let askAgentOptimise = Command("Make This Faster", #selector(ConsoleViewController.askAgent(_:)), tag: AgentRequest.optimise.rawValue,
                                          tip: "Copy a request for your agent to suggest indexes or a rewrite")
    static let askAgentWrite = Command("Write SQL…", #selector(ConsoleViewController.askAgent(_:)), tag: AgentRequest.write.rawValue,
                                       tip: "Say what you want, and copy that as a request for your agent to write the SQL")

    static let newWindow = Command("New Window", #selector(MainWindowController.newWindow(_:)), "N", .command,
                                   tip: "Open another main window on the same connections, with its own tabs")
    static let moveTabToNewWindow = Command("Move Tab to New Window", #selector(MainWindowController.moveTabToNewWindow(_:)),
                                            tip: "Take the tab shown out to a window of its own, session and all")
    static let moveTabToNextWindow = Command("Move Tab to Next Window", #selector(MainWindowController.moveTabToNextWindow(_:)),
                                             tip: "Move the tab shown to the next main window, session and all")

    static let pinTab = Command("Pin Tab", #selector(MainWindowController.togglePinTab(_:)),
                                tip: "Keep this tab at the left of the strip, out of Close Others and Close All")

    static let workspaceCommands = [pinTab, newWindow, moveTabToNewWindow, moveTabToNextWindow, askAgent, askAgentFix, askAgentOptimise, askAgentWrite, toggleBookmark, nextBookmark, previousBookmark, splitRight, showBeside, otherPane, filesPanel, attachFolder, detachFolder, newScratch, openFile, runFileOn, copyPath, trashScratch, consoleList,
                                    defaultConsole]
}
