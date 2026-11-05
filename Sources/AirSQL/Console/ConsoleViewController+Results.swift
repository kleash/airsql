import AirSQLCore
import AppKit

/// The result tabs (plan §2.6): one per result set, named from the comment above its query, replaced by the next run
/// unless pinned; Messages always last; an EXPLAIN's plan in a tab of its own.
extension ConsoleViewController {
    /// The tabs on the bar: the result tabs, then Messages.
    var allResultTabs: [ResultTab] { resultTabs + [messagesTab] }

    func showResults() {
        if let selected = selectedResult, !allResultTabs.contains(where: { $0 === selected }) { selectedResult = nil }
        let shown = selectedResult ?? resultTabs.last ?? (messagesView.messages.isEmpty ? nil : messagesTab)
        results.show(allResultTabs, selected: shown, empty: emptyResults())
        // The status bar shows the shown result's figures.
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
    }

    /// The grid's part of the status bar, for the result shown.
    var statusAccessory: NSView? {
        guard let tab = selectedResult ?? resultTabs.last else { return nil }
        switch tab.content {
        case .rows, .diff: return (tab.view as? ResultGridView)?.viewer.status
        case .plan, .messages: return nil
        }
    }

    func selectResult(_ tab: ResultTab) {
        selectedResult = tab
        showResults()
    }

    /// Takes away the result tabs that aren't pinned, as a new run starts; those with edits not applied stay, as if pinned
    /// (grid-spec rule 1).
    func dropUnpinnedResults() {
        resultTabs.removeAll { !$0.pinned && $0.pendingRows == 0 }
        if let selected = selectedResult, !selected.pinned, selected !== messagesTab { selectedResult = nil }
    }

    /// The rows edited in the results and not applied.
    var pendingResultRows: Int { resultTabs.reduce(0) { $0 + $1.pendingRows } }

    /// Asks before `tabs` close with edits not applied (unless Settings ▸ Safety doesn't warn on close), then answers
    /// whether they may.
    func askBeforeClosing(_ tabs: [ResultTab], answer: @escaping (Bool) -> Void) {
        let rows = tabs.reduce(0) { $0 + $1.pendingRows }
        guard rows > 0, connection.map({ model.data.safety(for: $0).warnOnClose }) ?? true, let window = view.window else {
            return answer(true)
        }
        ConsoleClosing.alert(window, "Discard the edits to \(rows == 1 ? "a row" : "\(rows.formatted()) rows")?",
                             "They aren't applied yet: only Apply (⌘S with the result's rows focused) writes them, and closing "
                                + "loses them.",
                             buttons: [("Discard", "Close and lose the edits"), ("Cancel", "Keep it open to apply the edits")],
                             destructive: 0) { answer($0 == 0) }
    }

    /// A result set's tab, after the others.
    /// `query`: the statement it came from, under which its columns are kept.
    func addResult(_ store: ResultStore, title: String?, summary: String, query: String? = nil) {
        resultNumber += 1
        let tab = ResultTab(title: title ?? "Result \(resultNumber)", content: .rows(store), summary: summary)
        let settings = model.data.settings
        let key = connectionID.flatMap { id in query.map { GridViewer.ViewKey(connection: id, database: database ?? "", table: $0) } }
        // A query's rows may be edited (ResultGridView+Editing) on the connection it ran on.
        let context = query == nil ? nil : Editors.context(connection, in: model)
        let (current, noBackslashEscapes) = (database, editor.noBackslashEscapes)
        tab.makeView = { [weak self] in
            let view = ResultGridView(store: store, nullText: settings.nullText, fontSize: CGFloat(settings.gridFontSize), viewKey: key,
                                      transposed: settings.transposeSingleRow && store.rowCount == 1 && store.columns.count > 1,
                                      editable: query != nil)
            view.viewer.noBackslashEscapes = noBackslashEscapes
            if let query, let self {
                view.editingContext = context
                view.model = model
                view.transactionOpen = { [weak self] in self?.session?.inTransaction == true }
                view.prepareEditing(sql: query, database: current, noBackslashEscapes: noBackslashEscapes)
            }
            return view
        }
        resultTabs.append(tab)
        if selectedResult == nil || selectedResult === messagesTab { selectedResult = tab }
    }

    /// Run Again's rows, the last `count` tabs, in the place of `old`, under its name; none (an error) leaves it as it was.
    func replace(_ old: ResultTab, withLast count: Int) {
        guard count > 0, let index = resultTabs.firstIndex(where: { $0 === old }) else { return }
        let added = Array(resultTabs.suffix(count))
        resultTabs.removeLast(count)
        resultTabs.replaceSubrange(index...index, with: added)
        added[0].title = old.title
        added[0].pinned = old.pinned
        selectedResult = added[0]
    }

    /// An EXPLAIN's tab.
    func addPlan(table: ResultStore?, tree: String, nodes: [PlanNode], raw: String, title: String) {
        let tab = ResultTab(title: title, content: .plan(table: table, tree: tree), summary: "")
        let settings = model.data.settings
        tab.makeView = {
            PlanView(table: table, tree: tree, nodes: nodes, raw: raw, nullText: settings.nullText, fontSize: CGFloat(settings.gridFontSize))
        }
        resultTabs.append(tab)
        selectedResult = tab
    }

    /// What the results show before anything has run.
    func emptyResults() -> NSView {
        let view = NSView()
        let text: String
        var next: Command?
        if isConnected {
            text = "Run the statement at the cursor with ⌘↩, or every statement with ⇧⌘↩: the results show here."
        } else if let connection {
            text = "Connect to “\(connection.displayName)” to run SQL: double-click it in the sidebar."
        } else if model.data.connections.isEmpty {
            text = "Add a connection with File ▸ New Connection… (⌘N) to run SQL."
            next = Commands.newConnection
        } else {
            text = "Choose a connection for this tab with Query ▸ Change Connection… to run SQL."
            next = Commands.changeConnection
        }
        let words = label(text, font: .systemFont(ofSize: 12.5), color: .secondaryLabelColor, wraps: true)
        words.alignment = .center
        words.setAccessibilityIdentifier("console.empty")
        view.addSubview(words)
        if let next {
            let action = button(next.title, id: "console.emptyAction", tip: next.tip, target: nil, action: next.action)
            view.addSubview(action)
            NSLayoutConstraint.activate([action.topAnchor.constraint(equalTo: words.bottomAnchor, constant: Spacing.unit),
                                         action.centerXAnchor.constraint(equalTo: view.centerXAnchor)])
        }
        NSLayoutConstraint.activate([
            words.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            words.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            words.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -2 * Spacing.triple),
            words.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
        return view
    }

    /// Selects a message's statement in the editor.
    func reveal(_ message: ConsoleMessage) {
        guard let range = message.range, NSMaxRange(range) <= (text as NSString).length else { return }
        view.window?.makeFirstResponder(editor)
        editor.setSelectedRange(range)
        editor.scrollRangeToVisible(range)
    }

    // MARK: Result tab commands

    /// The result tab's menu (plan §2.12): Pin, Rename, Close, Close Others, Export…, Compare With….
    func resultMenu() -> NSMenu {
        let menu = NSMenu(title: "Result")
        menu.add([Commands.rerunResult, Commands.copyResultQuery, nil, Commands.pinResult, Commands.renameResult, Commands.closeResult,
                  Commands.closeOtherResults, nil, Commands.exportResult, Commands.compareResult])
        // The console's own commands go to it wherever the focus is; Export and Compare to whatever handles them.
        for item in menu.items where item.action.map(responds(to:)) == true { item.target = self }
        return menu
    }

    /// The result tab the commands act on: the one shown, unless that is Messages.
    var currentResult: ResultTab? {
        guard let selected = selectedResult ?? resultTabs.last, selected !== messagesTab else { return nil }
        return selected
    }

    @objc func pinResult(_ sender: Any?) {
        guard let tab = currentResult else { return }
        tab.pinned.toggle()
        showResults()
    }

    @objc func renameResult(_ sender: Any?) {
        guard let tab = currentResult else { return }
        results.tabButton(for: tab)?.beginRename()
    }

    @objc func closeResult(_ sender: Any?) {
        guard let tab = currentResult else { return }
        askBeforeClosing([tab]) { [weak self] close in
            guard close, let self, let index = self.resultTabs.firstIndex(where: { $0 === tab }) else { return }
            self.resultTabs.remove(at: index)
            self.selectedResult = self.resultTabs.isEmpty ? self.messagesTab : self.resultTabs[min(index, self.resultTabs.count - 1)]
            self.showResults()
        }
    }

    /// The shown result's statement on the clipboard.
    @objc func copyResultQuery(_ sender: Any?) {
        guard let sql = currentResult?.sql else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sql, forType: .string)
    }

    @objc func showNextResult(_ sender: Any?) { stepResult(1) }
    @objc func showPreviousResult(_ sender: Any?) { stepResult(-1) }

    /// Shows the tab `offset` along the bar, Messages included, going round at the ends.
    private func stepResult(_ offset: Int) {
        let tabs = allResultTabs
        guard let shown = selectedResult ?? resultTabs.last, let index = tabs.firstIndex(where: { $0 === shown }) else { return }
        selectResult(tabs[(index + offset + tabs.count) % tabs.count])
    }

    /// Export Result…: the shown result's Export Rows…, wherever the focus is.
    @objc func exportResult(_ sender: Any?) {
        guard let grid = currentResult?.view as? ResultGridView else { return NSSound.beep() }
        grid.exportRows(sender)
    }

    @objc func closeOtherResults(_ sender: Any?) {
        guard let tab = currentResult else { return }
        askBeforeClosing(resultTabs.filter { $0 !== tab }) { [weak self] close in
            guard close, let self, self.resultTabs.contains(where: { $0 === tab }) else { return }
            self.resultTabs = [tab]
            self.selectedResult = tab
            self.showResults()
        }
    }
}
