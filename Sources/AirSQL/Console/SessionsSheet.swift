import AirSQLCore
import AppKit

/// Query ▸ Sessions…: every session AirSQL has open on the connection, what it is for, and what it is doing.
@MainActor
final class SessionsList: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    struct Row {
        var job, thread, database, state: String
    }

    private let rows: [Row]
    private static let columns: [(id: String, title: String, width: CGFloat)] = [("job", "Used by", 220), ("thread", "Thread", 70),
                                                                                  ("database", "Database", 130), ("state", "State", 150)]

    init(rows: [Row]) {
        self.rows = rows
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 220))
        let table = ContentTable()
        for column in Self.columns {
            let added = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            added.title = column.title
            added.width = column.width
            table.addTableColumn(added)
        }
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("sessions.list")
        documentView = table
        hasVerticalScroller = true
        borderType = .bezelBorder
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "job": text = item.job
        case "thread": text = item.thread
        case "database": text = item.database
        default: text = item.state
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = text
        return field
    }
}

extension MainWindowController {
    /// What each session of the connection is for, as the tabs know it.
    func sessionRows(_ sessions: [DBConnection]) -> [SessionsList.Row] {
        sessions.map { session in
            let console = model.allTabs.lazy.compactMap { tab -> (Tab, ConsoleViewController)? in
                (tab.content as? ConsoleViewController).flatMap { $0.session === session ? (tab, $0) : nil }
            }
            let table = model.allTabs.first { ($0.shown as? TableDataController)?.transactionSession === session }
            let job: String
            if let (tab, _) = console.first {
                job = session.role == .main ? "Query tabs sharing it" : "“\(tab.title)”"
            } else if let table {
                job = "“\(table.title)”"
            } else {
                job = ["main": "The connection", "data": "Table tabs", "schema": "The schema", "agent": "Agents", "tools": "A tool",
                       "query": "A query tab"][session.role.rawValue] ?? session.role.rawValue
            }
            let state = (session.isBusy ? "Running" : "Idle") + (session.inTransaction ? " · transaction open" : "")
            return .init(job: job, thread: session.server.map { String($0.threadID) } ?? "", database: console.first?.1.database ?? "",
                         state: state)
        }
    }

    @objc func showSessions(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, let saved = activeConnection, let open = model.openConnection(saved.id) else { return }
        Task {
            let sessions = await open.connection.sessions()
            let count = sessions.count
            ConsoleClosing.alert(window, "\(count) session\(count == 1 ? "" : "s") open on \(saved.displayName)",
                                 "Each query tab has its own once it has run something, and it closes with the tab. AirSQL leaves room "
                                    + "under the server's max_connections.",
                                 buttons: [("OK", "Close this list")], destructive: nil, accessory: SessionsList(rows: sessionRows(sessions))) { _ in }
        }
    }
}
