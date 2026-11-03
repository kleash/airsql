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
        guard let tab = selectedResult ?? resultTabs.last, case .rows = tab.content else { return nil }
        return (tab.view as? ResultGridView)?.viewer.status
    }

    func selectResult(_ tab: ResultTab) {
        selectedResult = tab
        showResults()
    }

    /// Takes away the result tabs that aren't pinned, as a new run starts.
    func dropUnpinnedResults() {
        resultTabs.removeAll { !$0.pinned }
        if let selected = selectedResult, !selected.pinned, selected !== messagesTab { selectedResult = nil }
    }

    /// A result set's tab, after the others.
    /// `query`: the statement it came from, under which its columns are kept.
    func addResult(_ store: ResultStore, title: String?, summary: String, query: String? = nil) {
        resultNumber += 1
        let tab = ResultTab(title: title ?? "Result \(resultNumber)", content: .rows(store), summary: summary)
        let settings = model.data.settings
        let key = connectionID.flatMap { id in query.map { GridViewer.ViewKey(connection: id, database: database ?? "", table: $0) } }
        tab.makeView = {
            ResultGridView(store: store, nullText: settings.nullText, fontSize: CGFloat(settings.gridFontSize), viewKey: key,
                           transposed: settings.transposeSingleRow && store.rowCount == 1 && store.columns.count > 1)
        }
        resultTabs.append(tab)
        if selectedResult == nil || selectedResult === messagesTab { selectedResult = tab }
    }

    /// An EXPLAIN's tab.
    func addPlan(table: ResultStore?, tree: String, title: String) {
        let tab = ResultTab(title: title, content: .plan(table: table, tree: tree), summary: "")
        let settings = model.data.settings
        tab.makeView = { PlanView(table: table, tree: tree, nullText: settings.nullText, fontSize: CGFloat(settings.gridFontSize)) }
        resultTabs.append(tab)
        selectedResult = tab
    }

    /// What the results show before anything has run.
    func emptyResults() -> NSView {
        let view = NSView()
        let connected = isConnected
        let name = connection?.displayName ?? "a connection"
        let text = connected ? "Run the statement at the cursor with ⌘↩, or every statement with ⇧⌘↩: the results show here."
            : "Connect to “\(name)” to run SQL: double-click it in the sidebar."
        let words = label(text, font: .systemFont(ofSize: 12.5), color: .secondaryLabelColor, wraps: true)
        words.alignment = .center
        words.setAccessibilityIdentifier("console.empty")
        view.addSubview(words)
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
        menu.add([Commands.pinResult, Commands.renameResult, Commands.closeResult, Commands.closeOtherResults, nil,
                  Commands.exportResult, Commands.compareResult])
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
        let index = resultTabs.firstIndex { $0 === tab } ?? 0
        resultTabs.removeAll { $0 === tab }
        selectedResult = resultTabs.isEmpty ? messagesTab : resultTabs[min(index, resultTabs.count - 1)]
        showResults()
    }

    @objc func closeOtherResults(_ sender: Any?) {
        guard let tab = currentResult else { return }
        resultTabs = [tab]
        selectedResult = tab
        showResults()
    }
}
