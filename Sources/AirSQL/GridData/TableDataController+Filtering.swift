import AirSQLCore
import AppKit

// Filtering, searching, sorting and copying a table's rows (grid-spec §4, §6). The WHERE bar, quick filters, Filter by
// Values and Search All Columns run on the server over every row; "Loaded rows only" searches the rows loaded so far.
// The grid bar's chip always says which.
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
        source.filter = serverFilter
        if loading == nil { loadRows(more: false) } else { reloadWhenDone = true }
    }

    // MARK: Quick filters

    /// Quick Filter ▸ for the focused cell (and every selected value of its column, for IN): each item shows its SQL;
    /// with ⌥ it is added to the current filter instead.
    func quickFilterItem() -> NSMenuItem {
        var items: [NSMenuItem] = []
        if let (column, value, values) = focusedValues() {
            // Binary values compare whole (LIKE would read their hex as text).
            var ops: [GridCondition.Operator] = value == nil ? [.isNull, .isNotNull] : column.kind == .binary
                ? [.equals, .notEquals, .isNull, .isNotNull]
                : [.equals, .notEquals, .less, .greater, .startsWith, .endsWith, .contains, .isNull, .isNotNull]
            if values.count > 1 { ops.insert(contentsOf: [.isIn, .notIn], at: value == nil ? 0 : 2) }
            for op in ops {
                let condition = GridCondition(column, op, op == .isIn || op == .notIn ? values : [value])
                items += quickFilterItems(condition)
            }
            if let clipboard = NSPasteboard.general.string(forType: .string), !clipboard.isEmpty, !clipboard.contains(where: \.isNewline),
               clipboard.count <= 1_000 {
                items.append(.separator())
                for op in [GridCondition.Operator.equals, .notEquals, .contains] {
                    items += quickFilterItems(GridCondition(column, op, [clipboard]), clipboard: true)
                }
            }
        }
        let item = MainMenu.submenu("Quick Filter", items)
        item.isEnabled = !items.isEmpty
        return item
    }

    private func quickFilterItems(_ condition: GridCondition, clipboard: Bool = false) -> [NSMenuItem] {
        let sql = condition.sql(noBackslashEscapes: noBackslashEscapes)
        let shown = sql.count > 70 ? String(sql.prefix(70)) + "…" : sql
        func item(_ title: String, adding: Bool) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(applyQuickFilter(_:)), keyEquivalent: "")
            item.representedObject = sql
            item.tag = adding ? 1 : 0
            item.target = self
            item.toolTip = (adding ? "Add this condition to the current filter: " : "Filter every row by ") + shown
            return item
        }
        let plain = item((clipboard ? "Clipboard: " : "") + shown, adding: false)
        let adding = item("AND " + shown, adding: true)
        adding.isAlternate = true
        adding.keyEquivalentModifierMask = .option
        return [plain, adding]
    }

    @objc func applyQuickFilter(_ sender: NSMenuItem) {
        guard let sql = sender.representedObject as? String else { return }
        applyFilter(sender.tag == 1 ? GridFilter.adding(sql, to: bar.filterText) : sql)
    }

    /// ⌃⌘1 and ⌃⌘2: the focused cell's column equal or not equal to its value.
    @objc func quickFilterEquals(_ sender: Any?) { quickFilter(.equals) }
    @objc func quickFilterNotEquals(_ sender: Any?) { quickFilter(.notEquals) }

    private func quickFilter(_ op: GridCondition.Operator) {
        guard let (column, value, _) = focusedValues() else { return NSSound.beep() }
        applyFilter(GridCondition(column, op, [value]).sql(noBackslashEscapes: noBackslashEscapes))
    }

    /// The focused cell's column and value, and the distinct values selected in that column.
    func focusedValues() -> (GridColumn, String?, [String?])? {
        guard let source, let cursor = grid.selection.cursor, cursor.row < grid.rowCount, cursor.column < grid.columnCount else { return nil }
        let column = grid.sourceColumn(cursor.column)
        var values: [String?] = []
        for cell in selectedCells() where cell.column == column {
            let value = source.value(cell.row, column)
            if !values.contains(value) { values.append(value) }
        }
        return (source.columns[column], source.value(cursor.row, column), values)
    }

    /// Filter by Values…: the focused column's values with their counts, from the server within the current filter.
    @objc func filterByValues(_ sender: Any?) {
        guard let source, let column = focusedColumn(), let window = view.window else { return NSSound.beep() }
        let info = source.columns[column], name = SQLQuote.identifier(info.name), condition = GridFilter.condition(source.filter)
        let sql = "SELECT \(name), COUNT(*) FROM " + SQLQuote.identifier(database, tableName) + (condition.isEmpty ? "" : " WHERE " + condition)
            + " GROUP BY \(name) ORDER BY COUNT(*) DESC LIMIT \(FilterByValuesSheet.limit)"
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
        let apply = { [weak self] in
            source.localSort = keys
            self?.grid.sortOrder = keys.map { DataGridView.Sort(column: $0.column, ascending: $0.ascending) }
            self?.grid.reloadData()
            self?.updateBars()
        }
        guard source.loadedRows > 100_000, let window = view.window else { return apply() }
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
    @objc func clearSort(_ sender: Any?) { setSort([]) }

    private func sortFocused(ascending: Bool) {
        guard let source, let column = focusedColumn() else { return NSSound.beep() }
        setSort([TableViewSettings.SortKey(column: source.columns[column].name, ascending: ascending)])
    }

    /// The column of the focused cell or of the selected header.
    func focusedColumn() -> Int? {
        if let cursor = grid.selection.cursor, cursor.column < grid.columnCount { return grid.sourceColumn(cursor.column) }
        for case .columns(let columns) in grid.selection.areas where columns.lowerBound < grid.columnCount {
            return grid.sourceColumn(columns.lowerBound)
        }
        return nil
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

    // MARK: Copy

    @objc func copy(_ sender: Any?) { copySelection(GridCopy.format, headers: false) }
    @objc func copyWithHeaders(_ sender: Any?) { copySelection(GridCopy.format, headers: true) }

    @objc func copyAs(_ sender: Any?) {
        guard let format = GridCopy.format(of: sender) else { return }
        GridCopy.format = format
        copySelection(format, headers: false)
    }

    @objc func copyColumnNames(_ sender: Any?) {
        guard let source else { return }
        let names = GridCopy.covered(grid).columns.map { source.columns[$0].name }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\t"), forType: .string)
    }

    private func copySelection(_ format: CopyFormat, headers: Bool) {
        guard let source else { return NSSound.beep() }
        GridCopy.copy(grid, format: format, headers: headers, value: { source.value($0, $1) },
                      database: database, table: tableName)
    }
}
