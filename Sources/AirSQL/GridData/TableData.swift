import AirSQLCore
import AppKit

extension MainWindowController {
    /// Shows a table's rows in a tab of their own, the one already open on it if there is one; `condition` filters them
    /// (Find Text on Server's matches) in a new tab.
    @discardableResult
    func openTableData(_ table: String, database: String, context: EditorContext, condition: String? = nil) -> Tab {
        if condition == nil, let tab = tabs.first(where: {
            ($0.content as? TableDataController)?.shows(context.connection.id, database, table) == true
        }) {
            select(tab)
            return tab
        }
        let content = TableDataController(model: model, context: context, database: database, table: table, filter: condition)
        return open(content, title: table, connection: context.connection.id)
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
        autoRefresh?.invalidate()
        autoRefresh = nil
        let seconds = (sender as? NSMenuItem)?.tag ?? 0
        autoRefreshSeconds = seconds
        guard seconds > 0 else { return }
        autoRefresh = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.loading == nil, self.grid.editor == nil, self.view.window != nil else { return }
                self.refresh(nil)
            }
        }
    }

    /// The Refresh Every items, Off first.
    static func autoRefreshItems() -> [NSMenuItem] {
        [0, 5, 10, 30, 60].map { seconds in
            let item = Commands.autoRefresh.item()
            item.title = seconds == 0 ? "Off" : "\(seconds) Seconds"
            item.tag = seconds
            item.toolTip = seconds == 0 ? "Stop refreshing the grid by itself" : "Refresh the grid by itself every \(seconds) seconds"
            return item
        }
    }
}
