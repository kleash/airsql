import AirSQLCore
import AppKit

extension MainWindowController {
    /// Shows a table's rows in a tab of their own, the one already open on it if there is one; `condition` filters them
    /// (Find Text on Server's matches) in a new tab.
    @discardableResult
    func openTableData(_ table: String, database: String, context: EditorContext, condition: String? = nil) -> Tab {
        // A preview with pending changes counts: a second tab on the table would edit the same changes. A plain one doesn't.
        if condition == nil, let tab = model.allTabs.first(where: { tab in
            (tab.shown as? TableDataController).map {
                $0.shows(context.connection.id, database, table) && ($0 === tab.content || $0.isEdited)
            } == true
        }) {
            show(tab)
            return tab
        }
        let content = TableDataController(model: model, context: context, database: database, table: table, filter: condition)
        let tab = open(content, title: table, connection: context.connection.id)
        // The keyboard goes to the rows: arrows, Return to edit, ⇧↩ for the value panel.
        if content.page == .data { window?.makeFirstResponder(content.grid) }
        return tab
    }

    /// The navigator's double-click and Open Data, and Find Text on Server's matches (filtered by `condition`).
    func openTableData(_ table: DatabaseObject, of open: OpenConnection, condition: String? = nil) {
        guard let context = Editors.context(model.connection(open.id), in: model) else { return NSSound.beep() }
        openTableData(table.name, database: table.database, context: context, condition: condition)
    }
}

extension TableDataController {
    /// Whether this tab shows that table.
    func shows(_ connection: UUID, _ database: String, _ table: String) -> Bool {
        context.connection.id == connection && self.database == database && tableName == table
    }

    /// Refresh Every ▸ Off, 5, 10, 30 or 60 seconds (the item's tag): reloads the rows loaded so far while nothing else
    /// loads and no cell is being edited.
    @objc func setAutoRefresh(_ sender: Any?) {
        let seconds = (sender as? NSMenuItem)?.tag ?? 0
        guard seconds >= 0 else {
            guard let window = view.window else { return }
            return askText("Refresh Every", message: "Type how many seconds between refreshes, from 1 to 86,400", placeholder: "120", action: "Refresh",
                           id: "autoRefresh.seconds", on: window) { [weak self] text in
                guard let seconds = Int(text), (1...86_400).contains(seconds) else { return NSSound.beep() }
                self?.startAutoRefresh(seconds)
            }
        }
        startAutoRefresh(seconds)
    }

    func startAutoRefresh(_ seconds: Int) {
        autoRefresh?.invalidate()
        autoRefresh = nil
        autoRefreshSeconds = seconds
        guard seconds > 0 else { return }
        autoRefresh = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.loading == nil, self.grid.editor == nil, self.view.window != nil else { return }
                self.reloadRows()
            }
        }
    }

    /// Export Rows…: the selected or loaded rows (with their pending changes), or every row of the table with the
    /// filter and sort, streamed on a session of its own.
    @objc func exportRows(_ sender: Any?) {
        guard let source, let window = view.window else { return NSSound.beep() }
        let order = viewer.shownColumns, rows = viewer.selectedRows(), sessions = context.sessions
        let readWhole = { [weak self] (loaded: Bool, then: @escaping () -> Void) -> Void in
            self?.readWhole(loaded ? Array(0..<source.rowCount) : rows, columns: order, then: then)
        }
        let sql = source.pageSQL(offset: 0, limit: nil)
        let request = ExportRowsRequest(
            title: tableName, columns: order.map { source.columns[$0] }, database: database, table: tableName,
            noBackslashEscapes: noBackslashEscapes, hiddenColumns: source.columns.count - order.count, readWhole: readWhole,
            preview: { selected in (selected ? Array(rows.prefix(ExportRowsSheet.previewRows)) : Array(0..<min(ExportRowsSheet.previewRows, source.rowCount))).map { row in
                order.map { source.value(row, $0) }
            } }, selectedCount: rows.count,
            selected: { rows.map { row in order.map { source.value(row, $0) } } },
            loadedCount: source.rowCount, loaded: { (0..<source.rowCount).map { row in order.map { source.value(row, $0) } } },
            all: { write in
                let session = try await sessions.toolsSession()
                do {
                    try await session.stream(sql, batchRows: 5_000) { store in
                        try write((0..<store.rowCount).map { row in order.map { TableDataSource.text(store, row, $0) } })
                    }
                } catch {
                    await session.close()
                    throw error
                }
                await session.close()
            })
        ExportRowsSheet.show(request, activity: model.activity, on: window)
    }

    /// The Refresh Every items, Off first, Custom… last (its tag: -1).
    static func autoRefreshItems() -> [NSMenuItem] {
        [0, 5, 10, 30, 60, -1].map { seconds in
            let item = Commands.autoRefresh.item()
            item.title = seconds == 0 ? "Off" : seconds < 0 ? "Custom…" : "\(seconds) Seconds"
            item.tag = seconds
            item.toolTip = seconds == 0 ? "Stop refreshing the grid by itself" : seconds < 0 ? "Type how many seconds between refreshes"
                : "Refresh the grid by itself every \(seconds) seconds"
            return item
        }
    }
}

/// Asks for an SQL expression for the selected cells (Set Expression…).
@MainActor
func askExpression(on window: NSWindow, then keep: @escaping (String) -> Void) {
    askText("Set Expression", message: "Type an SQL expression or function: it's sent as you type it when you apply", placeholder: "UPPER(name) or NOW()",
            action: "Set", id: "cell.expression", on: window) { text in
        let sql = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sql.isEmpty { keep(sql) }
    }
}
