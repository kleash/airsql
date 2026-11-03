import AirSQLCore
import AppKit

/// What closing a console asks first (plan §2.6, §2.10): a statement still running (it is cancelled), the open
/// transaction when this is the connection's last console (Commit or Roll Back), and unsaved text (Save, Don't Save).
@MainActor
enum ConsoleClosing {
    static func ask(_ console: ConsoleViewController, answer: @escaping (Bool) -> Void) {
        guard let window = console.view.window else { return answer(true) }
        if console.running != nil {
            return alert(window, "Stop the statement that is running and close “\(console.tab?.title ?? "this tab")”?",
                         "The server stops it; what it changed in an open transaction stays until Commit or Rollback.",
                         buttons: [("Stop and Close", "Cancel the statement, then close the tab"), ("Cancel", "Keep the tab open")],
                         destructive: 0) { choice in
                guard choice == 0 else { return answer(false) }
                console.cancelQuery(nil)
                whenIdle(console) { transaction(console, window, answer: answer) }
            }
        }
        transaction(console, window, answer: answer)
    }

    /// Once the console's run has ended.
    private static func whenIdle(_ console: ConsoleViewController, _ then: @escaping () -> Void) {
        guard console.running != nil else { return then() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { whenIdle(console, then) }
    }

    /// The open transaction, when no other console of the connection stays open to show it.
    private static func transaction(_ console: ConsoleViewController, _ window: NSWindow, answer: @escaping (Bool) -> Void) {
        let others = console.mainWindow?.tabs.contains { tab in
            tab.content !== console && (tab.content as? ConsoleViewController)?.connectionID == console.connectionID
        } ?? false
        guard let saved = console.connection, console.model.data.safety(for: saved).warnOnClose, !others,
              let session = console.session, session.inTransaction else { return unsaved(console, window, answer: answer) }
        let changes = console.shared.changes
        alert(window, "Close “\(console.tab?.title ?? "this tab")” with a transaction open?",
              "\(changes > 0 ? "\(changes.formatted()) change\(changes == 1 ? "" : "s") on" : "Changes on") \(saved.displayName) "
                + "aren't committed. Commit keeps them; Roll Back undoes them.",
              buttons: [("Commit", "Make the changes permanent, then close"), ("Roll Back", "Undo the changes, then close"),
                        ("Cancel", "Keep the tab open")], destructive: 1) { choice in
            guard choice < 2 else { return answer(false) }
            console.runCommand([choice == 0 ? "COMMIT" : "ROLLBACK"]) {
                if console.session?.inTransaction == true { return answer(false) }  // it failed: Messages says why
                unsaved(console, window, answer: answer)
            }
        }
    }

    private static func unsaved(_ console: ConsoleViewController, _ window: NSWindow, answer: @escaping (Bool) -> Void) {
        guard console.isEdited else { return finish(console, answer: answer, true) }
        let name = console.tab?.title ?? "this console"
        alert(window, "Save the changes to “\(name)”?",
              console.fileURL == nil ? "The text isn't saved in a file; it's lost if you don't save it."
                : "Your changes since it was last saved are lost if you don't save them.",
              buttons: [("Save…", "Save the text in a .sql file, then close"), ("Don't Save", "Close and lose the unsaved text"),
                        ("Cancel", "Keep the tab open")], destructive: 1) { choice in
            switch choice {
            case 0: console.save(as: console.fileURL == nil) { saved in finish(console, answer: answer, saved) }
            case 1: finish(console, answer: answer, true)
            default: answer(false)
            }
        }
    }

    private static func finish(_ console: ConsoleViewController, answer: (Bool) -> Void, _ close: Bool) {
        if close { ConsoleDocuments.shared.closed(console) }
        answer(close)
    }

    /// A sheet with `buttons` (title, tooltip); `destructive`: the index of the one drawn as destructive.
    static func alert(_ window: NSWindow, _ message: String, _ information: String, buttons: [(String, String)],
                      destructive: Int?, accessory: NSView? = nil, choice: @escaping (Int) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        alert.accessoryView = accessory
        for (index, (title, tip)) in buttons.enumerated() {
            let button = alert.addButton(withTitle: title)
            button.toolTip = tip
            if index == destructive { button.hasDestructiveAction = true }
            if title == "Cancel" { button.keyEquivalent = "\u{1b}" }
        }
        alert.beginSheetModal(for: window) { response in
            choice(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
        }
    }
}
