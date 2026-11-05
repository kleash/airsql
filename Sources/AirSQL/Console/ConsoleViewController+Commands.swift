import AirSQLCore
import AppKit

/// The console's commands that aren't running: transactions (Auto-commit or Manual, the isolation level, Commit and
/// Rollback), Format SQL, the text size, and each command's state and the reason it is off.
extension ConsoleViewController: NSMenuItemValidation {
    /// Auto-commit (true) or Manual, as the session says; Auto-commit before it is used.
    var autocommit: Bool { session?.autocommit ?? true }

    @objc func setTransactionMode(_ sender: Any?) {
        let manual = (sender as? NSMenuItem)?.tag == 1 || (sender as? NSPopUpButton)?.selectedTag() == 1
        guard manual == autocommit else { return syncToolbar() }
        if manual { return runCommand(["SET autocommit = 0"]) { [weak self] in self?.syncToolbar() } }
        guard let window = view.window, let session, session.inTransaction else {
            return runCommand(["SET autocommit = 1"]) { [weak self] in self?.syncToolbar() }
        }
        // Auto-commit would commit the open transaction: the person says what becomes of it.
        ConsoleClosing.alert(window, "Commit the open transaction?",
                             "Auto-commit commits each statement by itself. The changes made so far are committed or rolled back first.",
                             buttons: [("Commit", "Make the changes permanent, then commit each statement by itself"),
                                       ("Roll Back", "Undo the changes, then commit each statement by itself"),
                                       ("Cancel", "Stay in Manual mode")], destructive: 1) { [weak self] choice in
            guard let self, choice < 2 else { self?.syncToolbar(); return }
            self.runCommand([choice == 0 ? "COMMIT" : "ROLLBACK", "SET autocommit = 1"]) { [weak self] in self?.syncToolbar() }
        }
    }

    @objc func setIsolationLevel(_ sender: Any?) {
        // The menu bar's item, or the toolbar's Tx pop-up with its item chosen.
        guard let item = sender as? NSMenuItem ?? (sender as? NSPopUpButton)?.selectedItem,
              IsolationLevel.allCases.indices.contains(item.tag) else { return }
        let level = IsolationLevel.allCases[item.tag]
        runCommand([level.sql]) { [weak self] in
            guard let self, self.messagesView.messages.last?.level != .error else { return }
            self.changeShared { $0.isolation = level }
        }
    }

    @objc func commit(_ sender: Any?) { runCommand(["COMMIT"]) }
    @objc func rollback(_ sender: Any?) { runCommand(["ROLLBACK"]) }

    /// Shows this console's state in the toolbar (its buttons and Tx pop-up ask it), when it is the tab shown.
    func syncToolbar() {
        guard let main = mainWindow, main.selectedTab?.content === self else { return }
        main.window?.toolbar?.validateVisibleItems()
    }

    // MARK: Format, text size

    @objc func formatSQL(_ sender: Any?) {
        let selection = editor.selectedRange()
        let range = selection.length > 0 ? selection : NSRange(location: 0, length: (text as NSString).length)
        let original = (text as NSString).substring(with: range)
        guard let formatted = SQLFormatter.format(original, noBackslashEscapes: editor.noBackslashEscapes) else {
            return note(.info, "AirSQL couldn't tidy this SQL without changing what it says, so it left it as it was.")
        }
        guard formatted != original else { return }
        editor.replace(range, with: formatted, select: selection.length > 0
                       ? NSRange(location: range.location, length: (formatted as NSString).length) : NSRange(location: 0, length: 0))
    }

    @objc func toggleWordWrap(_ sender: Any?) { model.data.settings.editorWordWrap.toggle() }

    @objc func zoomIn(_ sender: Any?) { zoom(by: 1) }
    @objc func zoomOut(_ sender: Any?) { zoom(by: -1) }

    @objc func zoomReset(_ sender: Any?) {
        zoomedSize = nil
        editor.setFontSize(CGFloat(model.data.settings.editorFontSize))
    }

    private func zoom(by step: CGFloat) {
        zoomedSize = min(36, max(9, (zoomedSize ?? CGFloat(model.data.settings.editorFontSize)) + step))
        editor.setFontSize(zoomedSize!)
    }

    // MARK: Validation

    /// ⌘R: the schema again, for completion and the helpers.
    @objc func refresh(_ sender: Any?) { model.openConnection(connectionID)?.load() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let (enabled, reason) = verdict(for: item)
        item.explain(enabled: enabled, reason: enabled ? nil : reason)
        return enabled
    }

    /// Whether `item` can act now and, when it can't, why.
    private func verdict(for item: NSMenuItem) -> (Bool, String) {
        let busy = running != nil ? "A statement is running in this tab: wait for it, or Cancel it"
            : shared.runner != nil && shared.runner != documentID ? "Another console tab of this connection is running a statement"
            : nil
        let offline = isConnected ? nil : "Connect first: double-click “\(connection?.displayName ?? "the connection")” in the sidebar"
        // The toolbar asks at every event: the first character that isn't a space answers.
        let hasText = text.contains { !$0.isWhitespace }
        switch item.action {
        case Commands.refresh.action:
            return (isConnected, offline ?? "")
        case #selector(runStatement(_:)), #selector(runAll(_:)), #selector(explain(_:)), #selector(explainAnalyze(_:)), #selector(profileQuery(_:)):
            if let reason = offline ?? busy { return (false, reason) }
            return (hasText, "Type a statement first")
        case #selector(runSelection(_:)):
            if let reason = offline ?? busy { return (false, reason) }
            return (editor.selectedRange().length > 0, "Select the SQL to run first")
        case #selector(cancelQuery(_:)):
            return (running.map { !$0.cancelled } ?? false, "Nothing is running in this tab")
        case #selector(commit(_:)), #selector(rollback(_:)):
            if let reason = busy { return (false, reason) }
            return (session?.inTransaction == true, "No transaction is open in this tab")
        case #selector(setTransactionMode(_:)):
            item.state = (item.tag == 1) == !autocommit ? .on : .off
            if let reason = offline ?? busy { return (false, reason) }
            return (true, "")
        case #selector(setIsolationLevel(_:)):
            item.state = IsolationLevel.allCases.indices.contains(item.tag) && shared.isolation == IsolationLevel.allCases[item.tag]
                ? .on : .off
            if let reason = offline ?? busy { return (false, reason) }
            return (true, "")
        case #selector(formatSQL(_:)):
            return (hasText, "Type some SQL first")
        case #selector(toggleWordWrap(_:)):
            item.state = model.data.settings.editorWordWrap ? .on : .off
            return (true, "")
        case #selector(editAsTable(_:)):
            if let reason = offline { return (false, reason) }
            return (hasText, "Type or select INSERT statements first")
        case #selector(pinResult(_:)), #selector(renameResult(_:)), #selector(closeResult(_:)), #selector(closeOtherResults(_:)):
            if item.action == #selector(pinResult(_:)) { item.title = currentResult?.pinned == true ? "Unpin Result" : "Pin Result" }
            if item.action == #selector(closeOtherResults(_:)), currentResult != nil, resultTabs.count < 2 {
                return (false, "This is the only result tab")
            }
            return (currentResult != nil, "Run a query first: there is no result tab yet")
        case #selector(rerunResult(_:)), #selector(copyResultQuery(_:)):
            guard currentResult?.sql != nil else {
                return (false, currentResult == nil ? "Run a query first: there is no result tab yet" : "This tab didn't come from a statement")
            }
            if item.action == #selector(copyResultQuery(_:)) { return (true, "") }
            if let reason = offline ?? busy { return (false, reason) }
            return (true, "")
        case #selector(showNextResult(_:)), #selector(showPreviousResult(_:)):
            return (!resultTabs.isEmpty, "Run a query first: there is no result tab yet")
        case #selector(exportResult(_:)):
            if currentResult?.view is ResultGridView { return (true, "") }
            return (false, currentResult == nil ? "Run a query first: there is no result tab yet" : "This result has no rows to export")
        case #selector(compareResult(_:)):
            guard let tab = currentResult else { return (false, "Run a query first: there is no result tab yet") }
            if case .diff = tab.content { return (false, "This tab is a comparison already: show one of the results to compare it") }
            guard tab.content.store != nil else { return (false, "An EXPLAIN's plan can't be compared: show a result with rows") }
            return (!compareTargets(for: tab).isEmpty, "Run another query first, or connect: there is no other result or table to compare with")
        case #selector(changeConnection(_:)):
            if let reason = busy { return (false, reason) }
            if !sharesSession, session?.inTransaction == true { return (false, "Commit or roll back first: the transaction is this tab's") }
            return (model.data.connections.count > 1 || connectionID == nil, "There is no other connection to choose")
        case #selector(toggleHelpers(_:)):
            item.state = helpersShown ? .on : .off
            return (true, "")
        case #selector(showHistory(_:)):
            return (connectionID != nil, "Choose a connection for this console first")
        default:
            return (true, "")
        }
    }
}
