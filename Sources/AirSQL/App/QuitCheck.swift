import AirSQLCore
import AppKit

// Quit asks first about what it would leave unfinished, as its menu item promises (plan §2.10): tables with pending
// changes, console transactions still open, console results' edits not applied and client tools running, in one sheet.
extension MainWindowController {
    /// A line for each thing Quit leaves unfinished: a table's pending changes (kept for the next time it opens), a
    /// connection's open console transaction (rolled back as AirSQL disconnects) and a console's results' edits not
    /// applied (thrown away). Connections whose Safety settings don't warn on close are left out.
    func unfinishedWork() -> [String] {
        var lines: [String] = [], transactions: Set<UUID> = []
        for tab in tabs {
            if let table = tab.content as? TableDataController, let changes = table.source?.changes, !changes.isEmpty,
               model.data.safety(for: table.context.connection).warnOnClose {
                let count = changes.rowCount
                lines.append("\(table.tableName) on \(table.context.connection.displayName): \(count.formatted()) pending "
                             + "change\(count == 1 ? "" : "s"), kept for the next time you open the table")
            } else if let console = tab.content as? ConsoleViewController, let saved = console.connection,
                      model.data.safety(for: saved).warnOnClose {
                if console.session?.inTransaction == true, transactions.insert(saved.id).inserted {
                    let count = console.shared.changes
                    lines.append("A transaction on \(saved.displayName)"
                                 + (count > 0 ? " with \(count.formatted()) change\(count == 1 ? "" : "s")" : "")
                                 + ", not committed: it is rolled back")
                }
                let rows = console.pendingResultRows
                if rows > 0 {
                    lines.append("Edits to \(rows.formatted()) row\(rows == 1 ? "" : "s") in the results of “\(tab.title)”, not "
                                 + "applied: they are thrown away")
                }
            }
        }
        return lines + ToolSheet.open.filter(\.running).map { "“\($0.window?.title ?? "")”, still running: it is stopped" }
    }
}

extension AppDelegate {
    /// Asks before quitting with pending table changes, a console transaction open or results' edits not applied,
    /// listing them in one sheet.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let main else { return .terminateNow }
        let lines = main.unfinishedWork()
        guard !lines.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit AirSQL with work that isn't finished?"
        alert.informativeText = lines.map { "• " + $0 }.joined(separator: "\n")
        alert.addButton(withTitle: "Quit").toolTip = "Quit now: open transactions are rolled back, results' edits thrown away and "
            + "running tools stopped; tables' pending changes are kept"
        alert.addButton(withTitle: "Cancel").toolTip = "Keep AirSQL open to apply, commit or roll back first"
        alert.buttons[0].hasDestructiveAction = lines.contains { $0.hasSuffix("rolled back") || $0.hasSuffix("thrown away") || $0.hasSuffix("stopped") }
        guard let window = main.window, window.isVisible, window.attachedSheet == nil else {
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
        alert.beginSheetModal(for: window) { NSApp.reply(toApplicationShouldTerminate: $0 == .alertFirstButtonReturn) }
        return .terminateLater
    }
}
