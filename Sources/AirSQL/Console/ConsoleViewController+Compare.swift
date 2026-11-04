import AirSQLCore
import AppKit

/// Compare With… (the result tab's menu and Query ▸ Compare With…): the shown result against another result of this
/// window, or a table of its connection, matched on a key. The rows that differ open in a result tab of their own, in the
/// grid as the compare window shows a table's (a `DiffSource`): the shown result is the first side.
extension ConsoleViewController {
    /// What a result can be compared with.
    enum CompareTarget {
        /// Another result tab with rows, its name here ("Result 1", or "Query 2 › Result 1" from another tab) and its
        /// console's connection.
        case result(ResultTab, name: String, connection: UUID?)
        case table(database: String, name: String)
    }

    /// Every result tab with rows in this window but `tab` (this console's nearest first), then the tables and views of
    /// the console's database.
    func compareTargets(for tab: ResultTab) -> [CompareTarget] {
        var targets = resultTabs.reversed().filter { $0 !== tab && $0.content.store != nil }
            .map { CompareTarget.result($0, name: $0.title, connection: connectionID) }
        for other in (view.window?.windowController as? MainWindowController)?.tabs ?? [] {
            guard let console = other.content as? ConsoleViewController, console !== self else { continue }
            targets += console.resultTabs.filter { $0.content.store != nil }
                .map { .result($0, name: "\(other.title) › \($0.title)", connection: console.connectionID) }
        }
        if let database, let tables = model.openConnection(connectionID)?.snapshot.database(database)?.tables {
            targets += tables.map { .table(database: database, name: $0.name) }
        }
        return targets
    }

    @objc func compareResult(_ sender: Any?) {
        guard let tab = currentResult, let store = tab.content.store, let window = view.window, window.attachedSheet == nil else {
            return NSSound.beep()
        }
        let targets = compareTargets(for: tab)
        guard !targets.isEmpty else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = "Compare “\(tab.title)” with"
        alert.informativeText = "The rows that differ open in a tab of their own: those only in this result in green, those only in "
            + "the other in red, and the cells that changed in amber."
        let with = popup([], selected: 0, id: "compare.with", tip: "Choose the result or the table to compare this result with",
                         target: nil, action: nil)
        with.autoenablesItems = false
        func heading(_ title: String, _ tip: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.toolTip = tip
            with.menu?.addItem(item)
        }
        var tables = false
        for (index, target) in targets.enumerated() {
            let item: NSMenuItem
            switch target {
            case .result(let other, let name, _):
                if index == 0 { heading("Results", "The result tabs with rows in this window") }
                item = NSMenuItem(title: name + other.label.dropFirst(other.title.count), action: nil, keyEquivalent: "")
                item.toolTip = "Compare with the rows of \(name)"
            case .table(let database, let name):
                if !tables { heading("Tables", "The tables and views of \(database), read when you compare") }
                tables = true
                item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                item.toolTip = "Compare with the rows of \(database).\(name) (up to \(ReconTableData.tableRows.formatted()))"
            }
            item.representedObject = target
            item.indentationLevel = 1
            with.menu?.addItem(item)
        }
        with.selectItem(at: 1)
        // The result's key (the primary key's columns the result has), each column alone, or every column.
        let columns = store.columns.map(\.name), key = store.columns.filter { $0.gridColumn.isKey }.map(\.name)
        let keys = popup([], selected: 0, id: "compare.key", tip: "Choose the columns that tell which row is which on both sides",
                         target: nil, action: nil)
        for (title, names) in (key.isEmpty ? [] : [(key.joined(separator: ", ") + " (the key)", key)]) + columns.map({ ($0, [$0]) })
            + [("Every column", [])] {
            keys.addItem(withTitle: title)
            keys.lastItem?.representedObject = names
            keys.lastItem?.toolTip = names.isEmpty ? "Match rows on all their values: rows that differ show as only on one side"
                : "Match the rows whose \(names.joined(separator: " and ")) are the same, and show which of their cells differ"
        }
        keys.selectItem(at: key.isEmpty ? keys.numberOfItems - 1 : 0)
        for popup in [with, keys] { popup.widthAnchor.constraint(equalToConstant: 320).isActive = true }
        let form = NSGridView(views: [[label("Compare with:"), with], [label("Match rows on:"), keys]])
        form.rowSpacing = 10
        form.rowAlignment = .firstBaseline
        form.column(at: 0).xPlacement = .trailing
        form.frame.size = form.fittingSize
        alert.accessoryView = form
        alert.addButton(withTitle: "Compare").toolTip = "Compare the two, row by row: this changes nothing"
        alert.addButton(withTitle: "Cancel").toolTip = "Close without comparing"
        addHelp(to: alert, .compareResults)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let target = with.selectedItem?.representedObject as? CompareTarget else { return }
            self?.compare(tab, store, with: target, key: keys.selectedItem?.representedObject as? [String] ?? [])
        }
    }

    /// Compares off the main thread (reading the table on the data session), listed in the activity with Cancel.
    private func compare(_ tab: ResultTab, _ store: ResultStore, with target: CompareTarget, key: [String]) {
        let other: String, work: Task<ReconTableData, Error>
        var otherConnection: UUID?, capped = store.capped
        switch target {
        case .result(let result, let name, let connection):
            guard let second = result.content.store else { return }
            other = name
            otherConnection = connection == connectionID ? nil : connection
            capped = capped || second.capped
            work = Task.detached {
                try Task.checkCancellation()
                return ReconTableData.compare(store, second, key: key)
            }
        case .table(let database, let table):
            guard let connection = model.openConnection(connectionID)?.connection else { return NSSound.beep() }
            other = table
            work = Task {
                try await ReconTableData.compare(store, table: table, database: database, on: connection.session(.data), key: key)
            }
        }
        let activity = model.activity.start("Comparing \(tab.title) with \(other)", connection: connectionID) { work.cancel() }
        Task { [weak self, capped] in
            let outcome = await work.result
            activity.end()
            self?.showComparison(outcome, of: tab, store, with: other, on: otherConnection, capped: capped)
        }
    }

    private func showComparison(_ outcome: Result<ReconTableData, Error>, of tab: ResultTab, _ store: ResultStore, with other: String,
                                on otherConnection: UUID?, capped: Bool) {
        guard let window = view.window else { return }
        let title = "Can't compare \(tab.title) with \(other)"
        let data: ReconTableData
        switch outcome {
        case .failure(let error) where error is CancellationError || (error as? AirSQLError)?.kind == .cancelled: return
        case .failure(let error): return showError(error.localizedDescription, title: title, on: window)
        case .success(let result): data = result
        }
        let key = data.key.isEmpty ? "every column" : data.key.joined(separator: ", ")
        switch data.outcome {
        case .notCompared(let why): return showError(why, title: title, on: window)
        case .same:
            let alert = NSAlert()
            alert.messageText = capped ? "\(tab.title) and \(other) match as far as they go" : "\(tab.title) and \(other) have the same rows"
            alert.informativeText = "Their \(data.sourceRows.formatted()) rows match in the \(data.columns.count) columns both have, "
                + "matched on \(key)." + (capped ? " A result was cut at the row limit, so rows past it weren't compared." : "")
            alert.addOK()
            return alert.beginSheetModal(for: window)
        case .different, .differentWithoutKey, .tooManyDifferences: break
        }
        let diff = DiffSource(data, names: (tab.title, other), columns: data.columns.map { column in
            store.columns.first { $0.name == column.name }?.gridColumn ?? GridColumn(name: column.name)
        })
        let same = data.sourceRows - data.missing.count - data.changed.count
        // Named after the other side: it opens next to the result compared.
        let comparison = ResultTab(title: "vs \(other)", content: .diff(diff),
                                   summary: "\(same.formatted()) row\(same == 1 ? "" : "s") the same · matched on \(key)")
        comparison.otherConnection = otherConnection
        let settings = model.data.settings, table = ResultGridView.table(of: store.columns)
        comparison.makeView = {
            ResultGridView(source: diff, table: table, legend: diff.legend, nullText: settings.nullText,
                           fontSize: CGFloat(settings.gridFontSize))
        }
        resultTabs.insert(comparison, at: (resultTabs.firstIndex { $0 === tab } ?? resultTabs.count - 1) + 1)
        selectResult(comparison)
    }
}
