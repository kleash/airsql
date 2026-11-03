import AirSQLCore
import AppKit

/// Opening a table's rows in a tab. The navigator (lane L5a) opens them from its tree through `NavigatorHooks.tableData`,
/// which the integrator points at `openTableData`'s controller; until then, and for a table whose name you know,
/// Data ▸ Open Table… (⇧⌘O) asks for the name.
extension MainWindowController {
    @objc func openTable(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        guard let saved = activeConnection, let connection = ConsoleViewController.openConnection(saved.id) else {
            return showError("Connect to a server first: double-click it in the sidebar.", title: "AirSQL can't open a table yet",
                             on: window)
        }
        let current = (selectedTab?.content as? ConsoleViewController)?.database ?? connection.options.database
        askText("Open a Table", message: "Type the table's name, or database.table" + (current.map { " (it's in \($0) when you leave the database out)" } ?? ""),
                placeholder: current.map { "\($0).table" } ?? "database.table", action: "Open", id: "openTable.name", on: window) {
            [weak self] text in
            guard let self else { return }
            guard let query = TableQuery(name: text, database: current) else {
                return showError("Type a table's name, as database.table when no database is chosen.", title: "AirSQL can't open “\(text)”",
                                 on: window)
            }
            openTableData(connection: connection, id: saved.id, database: query.database, table: query.table)
        }
    }

    /// A tab with a table's rows, limited by `filter` (a WHERE condition) when one is given; `schema` adds the header's
    /// types, keys and comments.
    @discardableResult
    func openTableData(connection: Connection, id: UUID, database: String, table: String, filter: String = "",
                       schema: SchemaTable? = nil) -> Tab {
        let content = TableDataViewController(connection: connection, id: id, database: database, table: table, filter: filter,
                                              schema: schema, model: model)
        let tab = open(content, title: table, connection: id)
        window?.makeFirstResponder(content.viewer.grid)
        return tab
    }
}

/// A sheet asking for one line of text (Open Table, Go to Row); `reply` gets it, trimmed, when `action` is pressed.
@MainActor
func askText(_ title: String, message: String, placeholder: String, value: String = "", action: String, id: String,
             on window: NSWindow, reply: @escaping (String) -> Void) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    let field = textField(value, placeholder: placeholder, id: id, tip: message)
    // NSAlert places its accessory by frame.
    field.translatesAutoresizingMaskIntoConstraints = true
    field.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
    alert.accessoryView = field
    alert.addButton(withTitle: action).toolTip = message
    alert.addButton(withTitle: "Cancel").toolTip = "Close without doing anything"
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { response in
        guard response == .alertFirstButtonReturn else { return }
        reply(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
