import AirSQLCore
import AppKit

// Filtering, searching and sorting a table's rows (grid-spec §4). The WHERE bar, quick filters, Filter by Values, Column
// Summary's values and Search All Columns run on the server over every row; "Loaded rows only" searches the rows loaded
// so far. The grid bar's chip always says which; the cells the search matches are tinted.
extension TableDataController {
    /// The condition the server gets: the WHERE bar's, and the search's when it runs on the server.
    var serverFilter: String { serverFilter(typed: bar.filterText) }

    private func serverFilter(typed text: String) -> String {
        let typed = GridFilter.condition(text)
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
        guard context.connection.readOnly, !source.filter.isEmpty || !source.orderText.isEmpty,
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

    /// The WHERE bar's suggestions at the caret. A column's values are read once, off the main thread; the next keystroke
    /// stops a read it no longer needs.
    func suggest(asked: Bool) {
        let field = bar.whereField, caret = field.selectedRange()
        guard let source, caret.length == 0, view.window?.firstResponder === field else { return field.closeSuggestions() }
        let text = field.string
        let (place, word) = WhereSuggestion.place(text, caret: caret.location, columns: source.columns.map(\.name),
                                                  noBackslashEscapes: noBackslashEscapes)
        var values: [String?]?
        if case .value(let column) = place {
            values = sampledValues[column]
            if values == nil { sample(column) }
        } else {
            sampling?.task.cancel()
            sampling = nil
        }
        let typed = String(decoding: Array(text.utf16)[word], as: UTF16.self)
        let items = WhereSuggestion.items(place, word: typed, columns: source.columns, values: values, noBackslashEscapes: noBackslashEscapes)
        // Between words only where something has to come next; nothing for a word already whole.
        let wanted = asked || !typed.isEmpty || !text.isEmpty && place != .joiners
        let whole = items.count == 1 && items[0].text.trimmingCharacters(in: .whitespaces).lowercased() == typed.lowercased()
        field.suggest(wanted && !whole ? items : [], replacing: word)
    }

    private func sample(_ column: Int) {
        guard let source, sampling?.column != column, source.columns[column].kind != .binary else { return }
        sampling?.task.cancel()
        let sql = source.sampleValuesSQL(column, limit: 200), open = openSession
        sampling = (column, Task { [weak self] in
            guard let session = try? await open(), let self,
                  let store = try? await stoppable(session, sql, { try await session.query(sql, rowCap: 200).first?.rows }) else { return }
            sampledValues[column] = (0..<store.rowCount).map { TableDataSource.text(store, $0, 0) }
            sampling = nil
            suggest(asked: false)
        })
    }

    func dataGridFiltersColumns(_ grid: DataGridView) -> Bool { source != nil }

    /// A header's funnel: Filter by Values in a popover. The list leaves out the column's own earlier choice, which comes
    /// ticked, so it can be widened; what is chosen replaces it.
    func dataGrid(_ grid: DataGridView, filterValuesOf column: Int, at rect: NSRect) {
        guard let source else { return }
        let info = source.columns[column], earlier = funnels[info.name]
        let others = earlier.flatMap { GridFilter.removing($0.sql(noBackslashEscapes: noBackslashEscapes), from: bar.filterText) }
        let sql = source.topValuesSQL(column, limit: FilterByValuesSheet.limit, filter: serverFilter(typed: others ?? bar.filterText))
        let open = openSession
        FilterByValuesSheet.pop(column: info, table: tableName, chosen: others == nil || earlier?.op != .isIn ? nil : earlier?.values, at: rect,
                                of: grid.header, read: { [weak self] in
            let session = try await open()
            guard let self, let store = try await self.stoppable(session, sql, {
                try await session.query(sql, rowCap: FilterByValuesSheet.limit).first?.rows
            }) else { return [] }
            return (0..<store.rowCount).map { [TableDataSource.text(store, $0, 0), store.string($0, 1)] }
        }, completion: { [weak self] condition in
            guard let self else { return }
            let rest = others ?? self.bar.filterText
            self.funnels[info.name] = condition
            self.applyFilter(condition.map { GridFilter.adding($0.sql(noBackslashEscapes: self.noBackslashEscapes), to: rest) } ?? rest)
        })
    }

    /// The columns the WHERE bar's condition names: their funnels stay on show.
    func updateFunnels() {
        guard let source else { return }
        let filter = GridFilter.condition(bar.filterText), text = Array(filter.utf16)
        let names = Set(SQLLexer.tokens(filter, noBackslashEscapes: noBackslashEscapes).compactMap { token -> String? in
            let word = String(decoding: text[token.range], as: UTF16.self)
            return token.kind == .word ? word.lowercased() : token.kind == .quotedName ? word.dropFirst().dropLast().lowercased() : nil
        })
        grid.filteredColumns = Set(source.columns.indices.filter { names.contains(source.columns[$0].name.lowercased()) })
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

    /// The sort control in a header: ascending, descending, then off; `adding`, the column joins the sort.
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
        alert.addButton(withTitle: "Sort").toolTip = "Sort the loaded rows on this Mac"
        alert.addButton(withTitle: "Cancel").toolTip = "Leave the rows as they are"
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { apply() }
        }
    }

    @objc func sortAscending(_ sender: Any?) { sortFocused(ascending: true) }
    @objc func sortDescending(_ sender: Any?) { sortFocused(ascending: false) }
    @objc func addToSort(_ sender: Any?) {
        guard let column = viewer.focusedColumn else { return NSSound.beep() }
        sort(by: column, adding: true)
    }
    @objc func clearSort(_ sender: Any?) {
        if source?.localSort.isEmpty == false { setLocalSort([]) } else { setSort([]) }
    }

    /// Order By…: any ORDER BY, expressions included; empty clears it. The header's sort replaces it.
    @objc func typeOrderBy(_ sender: Any?) {
        guard let source, let window = view.window else { return NSSound.beep() }
        askText("Order By", message: "Type what goes after ORDER BY: columns or any expression", placeholder: "LENGTH(name) DESC, id", value: source.orderText,
                action: "Sort", id: "tableData.orderBy", on: window) { [weak self] text in
            guard let self, let source = self.source else { return }
            var typed = text
            if typed.lowercased().hasPrefix("order by ") { typed = String(typed.dropFirst(9)) }
            let before = (source.orderText, source.sort)
            source.orderText = typed.trimmingCharacters(in: CharacterSet(charactersIn: "; \n\t"))
            source.sort = []
            grid.sortOrder = []
            if refusesOnReadOnly(source) {
                (source.orderText, source.sort) = before
                return updateBars()
            }
            reloadForFilter()
        }
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
    func setSort(_ keys: [TableViewSettings.SortKey]) {
        guard let source else { return }
        let indexed = Set(source.table.indexes.compactMap { $0.parts.first?.column })
        let unindexed = keys.map(\.column).filter { !indexed.contains($0) && !source.sort.map(\.column).contains($0) }
        let apply = { [weak self] in
            source.orderText = ""
            source.sort = keys
            self?.grid.sortOrder = keys.compactMap { key in
                source.columns.firstIndex { $0.name == key.column }.map { DataGridView.Sort(column: $0, ascending: key.ascending) }
            }
            self?.reloadForFilter()
        }
        // Under a filter nobody knows, and most filters leave few rows; a table's estimate can be wrong, so that asks.
        let known = knownTotal
        guard known.map({ $0.rows > 1_000_000 }) ?? source.filter.isEmpty, let column = unindexed.first, let window = view.window,
              model.data.safety(for: context.connection).askBeforeUnindexedSort else { return apply() }
        let alert = NSAlert()
        alert.messageText = "Sort " + (known.map { "\($0.exact ? "" : "about ")\($0.rows.formatted()) rows" } ?? "every row") + " by \(column)?"
        alert.informativeText = "\(column) has no index, so the server sorts every row before it sends the first page. That can "
            + "take a while and load the server."
        alert.addButton(withTitle: "Sort").toolTip = "Ask the server to sort every row"
        alert.addButton(withTitle: "Cancel").toolTip = "Leave the rows as they are"
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { apply() }
        }
    }
}
