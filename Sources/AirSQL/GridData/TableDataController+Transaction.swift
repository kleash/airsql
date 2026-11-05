import AirSQLCore
import AppKit

/// Manual Commit in a table tab: the tab moves to a session of its own, each Apply writes into a transaction left open,
/// and the rows it reads see those changes, until Commit or Roll Back. Each Apply is still all or nothing, by a savepoint.
extension TableDataController {
    var inTransaction: Bool { transactionSession.map { $0.isConnected && $0.inTransaction } ?? false }

    var transactionBadge: String? {
        lostTransaction?.transaction == true ? "Transaction rolled back: the connection ended" : inTransaction ? "Transaction open" : nil
    }

    @objc func setTransactionMode(_ sender: Any?) {
        let manual = (sender as? NSMenuItem)?.tag == 1 || (sender as? NSPopUpButton)?.selectedTag() == 1
        guard manual != (transactionSession != nil), !inTransaction, editingOff == nil else { return }
        guard manual else { return endTransactionSession() }
        let sessions = context.sessions
        Task {
            do {
                useTransactionSession(try await sessions.toolsSession(role: .query))
            } catch {
                showError(error.localizedDescription, title: "AirSQL couldn't open a session for \(tableName)", on: view.window)
            }
        }
    }

    private func useTransactionSession(_ session: DBConnection) {
        transactionSession = session
        transactionRows = 0
        openSession = { session }
        let states = model.$states.sink { [weak self] _ in DispatchQueue.main.async { self?.noticeLostTransaction() } }
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.noticeLostTransaction() }
        }
        transactionWatch?.1.invalidate()
        transactionWatch = (states, timer)
        loadRows(more: false, through: source?.loadedRows)
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
    }

    /// Reports, on the tab, a transaction whose session ended unasked. Until the person answers (`lostTransactionBlocks`)
    /// nothing is applied.
    func noticeLostTransaction() {
        guard lostTransaction == nil, let session = transactionSession else { return }
        var dropped = session.wasLost
        if case .failed? = model.states[context.connection.id] { dropped = true }
        guard dropped || !session.isConnected else { return }
        let lost = LostSession(transaction: session.inTransaction, changes: transactionRows, manual: true, isolation: nil, dropped: dropped,
                               server: context.connection.displayName)
        lostTransaction = lost
        problem = lost.message.replacingOccurrences(of: "this tab's", with: "the tab's")
        updateBars()
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
    }

    /// Whether a lost transaction stands in the way: the sheet says what went, and only its button goes on, on a new
    /// session, still in Manual Commit, with the rows read again.
    func lostTransactionBlocks() -> Bool {
        noticeLostTransaction()
        guard let lost = lostTransaction else { return false }
        guard let window = view.window, window.attachedSheet == nil else { NSSound.beep(); return true }
        ConsoleClosing.alert(window, lost.heading, lost.message + " Nothing was applied now.",
                             buttons: [("Open New Session", "Leave what was lost behind and read the rows again"),
                                       ("Cancel", "Open no session and apply nothing")], destructive: nil) { [weak self] choice in
            guard choice == 0, let self, !AgentGuard.refuses("Only the person at the Mac can leave a lost transaction behind.") else { return }
            let sessions = self.context.sessions
            Task {
                do {
                    let session = try await sessions.toolsSession(role: .query)
                    self.lostTransaction = nil
                    self.problem = nil
                    self.source?.setSaved([])
                    self.useTransactionSession(session)
                } catch {
                    showError(error.localizedDescription, title: "AirSQL couldn't open a session: connect again first", on: self.view.window)
                }
            }
        }
        return true
    }

    /// Back to the shared data session; the server rolls back what wasn't committed.
    func endTransactionSession() {
        guard let session = transactionSession else { return }
        transactionSession = nil
        transactionWatch?.1.invalidate()
        transactionWatch = nil
        if lostTransaction != nil {
            lostTransaction = nil
            problem = nil
            updateBars()
        }
        let sessions = context.sessions
        openSession = { try await sessions.session(.data) }
        Task.detached { await session.close() }
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
    }

    @objc func commit(_ sender: Any?) { endTransaction("COMMIT") }
    @objc func rollback(_ sender: Any?) { endTransaction("ROLLBACK") }

    func endTransaction(_ sql: String, then done: (() -> Void)? = nil) {
        guard !lostTransactionBlocks() else { return }
        guard let session = transactionSession, loading == nil else { return NSSound.beep() }
        bar.busy = true
        loading = Task {
            defer { bar.busy = false }
            do {
                _ = try await session.query(sql)
                transactionRows = 0
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
            if lostTransaction?.transaction == true { return (false, "The server rolled this tab's transaction back when the connection ended") }
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
