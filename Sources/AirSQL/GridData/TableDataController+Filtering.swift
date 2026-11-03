import AirSQLCore
import AppKit

// Filtering, searching and sorting a table's rows (grid-spec §4). The WHERE bar, quick filters, Filter by Values, Column
// Summary's values and Search All Columns run on the server over every row; "Loaded rows only" searches the rows loaded
// so far. The grid bar's chip always says which; the cells the search matches are tinted.
extension TableDataController {
    /// The condition the server gets: the WHERE bar's, and the search's when it runs on the server.
    var serverFilter: String {
        let typed = GridFilter.condition(bar.filterText)
        // A search of the loaded rows only stays here.
        let search = bar.loadedOnly.state == .on ? nil
            : source.flatMap { GridFilter.search(bar.searchField.stringValue, in: $0.columns, noBackslashEscapes: noBackslashEscapes) }
        guard let search else { return typed }
        return typed.isEmpty ? search : "(\(typed)) AND (\(search))"
    }

    func applyFilter(_ text: String) {
        bar.filterText = GridFilter.condition(text)
        reloadForFilter()
    }

    func search(_ text: String, loadedOnly: Bool) {
        guard let source else { return }
        bar.searchField.stringValue = text
        bar.loadedOnly.state = loadedOnly ? .on : .off
        updateLocalFilter()
        updateHighlight()
        if !loadedOnly, !source.localSort.isEmpty {
            source.localSort = []
            grid.sortOrder = source.sort.compactMap { key in
                source.columns.firstIndex { $0.name == key.column }.map { DataGridView.Sort(column: $0, ascending: key.ascending) }
            }
        }
        if source.filter != serverFilter { reloadForFilter() }
    }

    private func reloadForFilter() {
        guard let source else { return }
        let before = source.filter
        source.filter = serverFilter
        guard !refusesOnReadOnly(source) else {
            source.filter = before
            updateBars()
            return
        }
        if loading == nil { loadRows(more: false) } else { reloadWhenDone = true }
    }

    /// On a read-only connection, whether the read-only check refuses the rows' SELECT with its filter, as the console
    /// refuses what it can't prove only reads: a typed condition can hold a subquery that locks or a function with side
    /// effects. It checks the whole SELECT as the data session reads it (its NO_BACKSLASH_ESCAPES); the ORDER BY is built
    /// from column names. The notice says why (`problem`) until rows load again. A refused filter never stays the
    /// source's, so no statement of the tab (count, summary, export) sends it.
    func refusesOnReadOnly(_ source: TableDataSource) -> Bool {
        guard context.connection.readOnly, !source.filter.isEmpty,
              let refusal = StatementCheck.readOnlyRefusal(source.pageSQL(offset: 0, limit: rowsPerPage),
                                                            on: context.connection.displayName,
                                                            noBackslashEscapes: noBackslashEscapes) else { return false }
        problem = refusal
        return true
    }

    // MARK: Quick filters

    /// Quick Filter ▸ for the focused cell (and every selected value of its column, for IN): each item shows its SQL;
    /// with ⌥ it is added to the current filter instead.
    func quickFilterItem() -> NSMenuItem {
        QuickFilter.menuItem(focusedValues(), noBackslashEscapes: noBackslashEscapes, target: self,
                             action: #selector(applyQuickFilter(_:)))
    }

    @objc func applyQuickFilter(_ sender: NSMenuItem) {
        guard let condition = sender.representedObject as? GridCondition else { return }
        filter(by: condition, adding: sender.tag == 1)
    }

    /// The rows meeting `condition`, alone or added to the current filter.
    func filter(by condition: GridCondition, adding: Bool) {
        let sql = condition.sql(noBackslashEscapes: noBackslashEscapes)
        applyFilter(adding ? GridFilter.adding(sql, to: bar.filterText) : sql)
    }

    /// ⌃⌘1 and ⌃⌘2: the focused cell's column equal or not equal to its value.
    @objc func quickFilterEquals(_ sender: Any?) { quickFilter(.equals) }
    @objc func quickFilterNotEquals(_ sender: Any?) { quickFilter(.notEquals) }

    /// Data ▸ Quick Filter ▸'s other operators (the item's tag is the operator's index).
    @objc func quickFilter(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, GridCondition.Operator.allCases.indices.contains(tag) else { return }
        quickFilter(GridCondition.Operator.allCases[tag])
    }

    private func quickFilter(_ op: GridCondition.Operator) {
        guard let focus = focusedValues(), QuickFilter.reason(op, focus) == nil else { return NSSound.beep() }
        filter(by: QuickFilter.condition(op, focus), adding: false)
    }

    /// Type a Value…: a condition on the focused cell's column with a value typed in.
    @objc func quickFilterPrompt(_ sender: Any?) {
        guard let focus = focusedValues(), let window = view.window else { return NSSound.beep() }
        QuickFilter.ask(focus, canAdd: !bar.filterText.isEmpty, on: window) { [weak self] condition, adding in
            self?.filter(by: condition, adding: adding)
        }
    }

    func focusedValues() -> QuickFilter.Focus? {
        guard let source else { return nil }
        return QuickFilter.focus(viewer, columns: source.columns) { source.value($0, $1) }
    }

    /// Column Summary's value clicked: the rows with that value, added to the filter.
    func filter(_ column: Int, by value: String?) {
        guard let source else { return }
        applyFilter(GridFilter.adding(GridCondition(source.columns[column], .equals, [value]).sql(noBackslashEscapes: noBackslashEscapes),
                                      to: bar.filterText))
    }

    /// Filter by Values…: the focused column's values with their counts, from the server within the current filter.
    @objc func filterByValues(_ sender: Any?) {
        guard let source, let column = viewer.focusedColumn, let window = view.window else { return NSSound.beep() }
        let info = source.columns[column], sql = source.topValuesSQL(column, limit: FilterByValuesSheet.limit)
        let open = openSession
        FilterByValuesSheet.show(column: info, table: tableName, on: window, read: {
            guard let store = try await open().query(sql, rowCap: FilterByValuesSheet.limit).first?.rows else { return [] }
            return (0..<store.rowCount).map { [TableDataSource.text(store, $0, 0), store.string($0, 1)] }
        }, completion: { [weak self] condition in
            guard let self, let condition else { return }
            self.applyFilter(GridFilter.adding(condition.sql(noBackslashEscapes: self.noBackslashEscapes), to: self.bar.filterText))
        })
    }

    @objc func clearFilter(_ sender: Any?) {
        bar.searchField.stringValue = ""
        updateLocalFilter()
        updateHighlight()
        applyFilter("")
    }

    @objc func focusFilter(_ sender: Any?) { view.window?.makeFirstResponder(bar.whereField) }
    @objc func searchAllColumns(_ sender: Any?) { view.window?.makeFirstResponder(bar.searchField) }

    // MARK: Sort

    /// The sort control in a header: ascending, descending, then off; with ⌥ the column joins the sort.
    func sort(by column: Int, adding: Bool) {
        guard let source else { return }
        if bar.loadedOnly.state == .on { return sortLocally(by: column, adding: adding) }
        let name = source.columns[column].name
        var keys = source.sort
        if let index = keys.firstIndex(where: { $0.column == name }) {
            if keys[index].ascending { keys[index].ascending = false } else { keys.remove(at: index) }
            if !adding { keys = keys.filter { $0.column == name } }
        } else {
            keys = (adding ? keys : []) + [TableViewSettings.SortKey(column: name, ascending: true)]
        }
        setSort(keys)
    }

    /// With "Loaded rows only" the header sorts the loaded rows here, at once (asking first above 100,000 rows).
    private func sortLocally(by column: Int, adding: Bool) {
        guard let source else { return }
        var keys = source.localSort
        if let index = keys.firstIndex(where: { $0.column == column }) {
            if keys[index].ascending { keys[index].ascending = false } else { keys.remove(at: index) }
            if !adding { keys = keys.filter { $0.column == column } }
        } else {
            keys = (adding ? keys : []) + [(column: column, ascending: true)]
        }
        setLocalSort(keys)
    }

    private func setLocalSort(_ keys: [(column: Int, ascending: Bool)]) {
        guard let source else { return }
        let apply = { [weak self] in
            source.localSort = keys
            self?.grid.sortOrder = keys.map { DataGridView.Sort(column: $0.column, ascending: $0.ascending) }
            self?.viewer.reloadData()
            self?.updateBars()
        }
        guard !keys.isEmpty, source.loadedRows > 100_000, let window = view.window else { return apply() }
        let alert = NSAlert()
        alert.messageText = "Sort \(source.loadedRows.formatted()) loaded rows here?"
        alert.informativeText = "Sorting this many rows takes a moment. Untick Loaded rows only to sort every row on the server."
        alert.addButton(withTitle: "Sort")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { apply() }
        }
    }

    @objc func sortAscending(_ sender: Any?) { sortFocused(ascending: true) }
    @objc func sortDescending(_ sender: Any?) { sortFocused(ascending: false) }
    @objc func clearSort(_ sender: Any?) {
        if source?.localSort.isEmpty == false { setLocalSort([]) } else { setSort([]) }
    }

    /// Sort by Columns…: the columns, their directions and their order in a sheet; on the server, or with "Loaded rows
    /// only" here.
    @objc func sortColumns(_ sender: Any?) {
        guard let source, let window = view.window else { return NSSound.beep() }
        let local = bar.loadedOnly.state == .on
        let keys = local ? source.localSort : source.sort.compactMap { key in
            source.columns.firstIndex { $0.name == key.column }.map { (column: $0, ascending: key.ascending) }
        }
        SortSheet.show(columns: source.columns, keys: keys, title: tableName, on: window) { [weak self] keys in
            if local { return self?.setLocalSort(keys) ?? () }
            self?.setSort(keys.map { TableViewSettings.SortKey(column: source.columns[$0.column].name, ascending: $0.ascending) })
        }
    }

    private func sortFocused(ascending: Bool) {
        guard let source, let column = viewer.focusedColumn else { return NSSound.beep() }
        setSort([TableViewSettings.SortKey(column: source.columns[column].name, ascending: ascending)])
    }

    /// Sorts on the server; a table of over a million rows asks first when a new column has no index (R17).
    private func setSort(_ keys: [TableViewSettings.SortKey]) {
        guard let source else { return }
        let indexed = Set(source.table.indexes.compactMap { $0.parts.first?.column })
        let unindexed = keys.map(\.column).filter { !indexed.contains($0) && !source.sort.map(\.column).contains($0) }
        let apply = { [weak self] in
            source.sort = keys
            self?.grid.sortOrder = keys.compactMap { key in
                source.columns.firstIndex { $0.name == key.column }.map { DataGridView.Sort(column: $0, ascending: key.ascending) }
            }
            self?.reloadForFilter()
        }
        guard let total, total.rows > 1_000_000, let column = unindexed.first, let window = view.window,
              model.data.safety(for: context.connection).askBeforeUnindexedSort else { return apply() }
        let alert = NSAlert()
        alert.messageText = "Sort \(total.exact ? "" : "about ")\(total.rows.formatted()) rows by \(column)?"
        alert.informativeText = "\(column) has no index, so the server sorts every row before it sends the first page. That can "
            + "take a while and load the server."
        alert.addButton(withTitle: "Sort")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { apply() }
        }
    }
}
