import AirSQLCore
import AppKit

/// Manual Commit in a table tab: the tab moves to a session of its own, each Apply writes into a transaction left open,
/// and the rows it reads see those changes, until Commit or Roll Back. Each Apply is still all or nothing, by a savepoint.
extension TableDataController {
    var inTransaction: Bool { transactionSession.map { $0.isConnected && $0.inTransaction } ?? false }

    var transactionBadge: String? { inTransaction ? "Transaction open" : nil }

    @objc func setTransactionMode(_ sender: Any?) {
        let manual = (sender as? NSMenuItem)?.tag == 1 || (sender as? NSPopUpButton)?.selectedTag() == 1
        guard manual != (transactionSession != nil) else { return }
        guard manual else { return endTransactionSession() }
        let sessions = context.sessions
        Task {
            do {
                let session = try await sessions.toolsSession(role: .query)
                transactionSession = session
                openSession = { session }
                loadRows(more: false, through: source?.loadedRows)
                NotificationCenter.default.post(name: .tabContentDidChange, object: self)
            } catch {
                showError(error.localizedDescription, title: "AirSQL couldn't open a session for \(tableName)", on: view.window)
            }
        }
    }

    /// Back to the shared data session; the server rolls back what wasn't committed.
    func endTransactionSession() {
        guard let session = transactionSession else { return }
        transactionSession = nil
        let sessions = context.sessions
        openSession = { try await sessions.session(.data) }
        Task.detached { await session.close() }
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
    }

    @objc func commit(_ sender: Any?) { endTransaction("COMMIT") }
    @objc func rollback(_ sender: Any?) { endTransaction("ROLLBACK") }

    func endTransaction(_ sql: String, then done: (() -> Void)? = nil) {
        guard let session = transactionSession, loading == nil else { return NSSound.beep() }
        bar.busy = true
        loading = Task {
            defer { bar.busy = false }
            do {
                _ = try await session.query(sql)
                source?.setSaved([])
                loading = nil
                loadRows(more: false, through: source?.loadedRows)
                NotificationCenter.default.post(name: .tabContentDidChange, object: self)
                done?()
            } catch {
                loading = nil
                showError(error.localizedDescription, title: "The transaction on \(tableName) is still open", on: view.window)
            }
        }
    }

    /// Whether `action` is a transaction's, and if so whether it can act now and why not.
    func transactionState(of action: Selector?) -> (Bool, String?)? {
        switch action {
        case Commands.commit.action, Commands.rollback.action:
            return (inTransaction && loading == nil, inTransaction ? "Wait until the rows have loaded" : "No transaction is open in this tab")
        case Commands.manualCommit.action:
            if inTransaction { return (false, "Commit or roll back first") }
            return (editingOff == nil, editingOff ?? "This table can't be edited")
        default:
            return nil
        }
    }

    /// Closing with a transaction open: Commit, Roll Back or stay. `proceed` runs once none is open.
    func askAboutTransaction(proceed: @escaping () -> Void, stay: @escaping () -> Void) {
        guard inTransaction, model.data.safety(for: context.connection).warnOnClose, let window = view.window else { return proceed() }
        ConsoleClosing.alert(window, "Close “\(tableName)” with a transaction open?",
                             "What you applied on \(context.connection.displayName) isn't committed. Commit keeps it; Roll Back undoes it.",
                             buttons: [("Commit", "Make the changes permanent, then close"), ("Roll Back", "Undo the changes, then close"),
                                       ("Cancel", "Keep the tab open")], destructive: 1) { [weak self] choice in
            guard let self, choice < 2 else { return stay() }
            self.endTransaction(choice == 0 ? "COMMIT" : "ROLLBACK", then: proceed)
        }
    }
}
