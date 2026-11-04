import AirSQLCore
import AppKit

/// A foreign key column's drop-down (grid-spec §5): the referenced table's keys with a label beside them ("Ada (12)"),
/// the first 100 in the key's order, searched on the server as you type (never the whole table). Return or a double
/// click puts the chosen key in the selected rows as a pending edit; Esc or a click elsewhere closes it.
@MainActor
final class ForeignKeyLookup: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var popover = NSPopover()
    let search = NSSearchField()
    let table = ContentTable()
    let status = label("Loading…", font: .systemFont(ofSize: 11), color: .secondaryLabelColor, truncates: true)
    /// The rows shown: the referenced key's values, and the label.
    private(set) var rows: [(key: [String], label: String?)] = []
    private let keyCount: Int
    private let read: (String) async throws -> ResultStore?
    private let pick: ([String]) -> Void
    private var reading: Task<Void, Never>?

    /// `read` runs the lookup for a search text; `pick` gets the chosen key's values.
    init(title: String, keyCount: Int, read: @escaping (String) async throws -> ResultStore?, pick: @escaping ([String]) -> Void) {
        self.keyCount = keyCount
        self.read = read
        self.pick = pick
        super.init()
        search.placeholderString = "Search \(title)"
        search.toolTip = "Find a row of \(title) by its label or its key"
        search.delegate = self
        search.setAccessibilityIdentifier("grid.lookup.search")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        column.title = title
        table.addTableColumn(column)
        table.headerView = nil
        table.centreText(rowHeight: 24)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(choose(_:))
        table.toolTip = "Double-click a row to put its key in the cell (a pending edit)"
        table.setAccessibilityIdentifier("grid.lookup.rows")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [search, scroll, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.setAccessibilityIdentifier("grid.lookup")
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 300), scroll.heightAnchor.constraint(equalToConstant: 220),
            search.widthAnchor.constraint(equalTo: scroll.widthAnchor), status.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        popover = AirSQL.popover(around: stack, behavior: .transient)
        run("", after: 0)
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(search)
    }

    /// Reads the rows for `text` once typing pauses; a newer search replaces one still running.
    func run(_ text: String, after delay: UInt64 = 300_000_000) {
        reading?.cancel()
        reading = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let self, !Task.isCancelled else { return }
            status.stringValue = "Searching…"
            do {
                let store = try await read(text)
                guard !Task.isCancelled else { return }
                let count = store?.rowCount ?? 0, keys = keyCount
                rows = (0..<count).map { row in
                    ((0..<keys).map { TableDataSource.text(store!, row, $0) ?? "" },
                     store!.columns.count > keys ? TableDataSource.text(store!, row, keys) : nil)
                }
                status.stringValue = count == 0 ? "No rows match" : count >= 100 ? "The first 100 rows: type to find others" : "\(count) rows"
            } catch {
                rows = []
                status.stringValue = "The rows didn't load: " + ((error as? AirSQLError)?.message ?? error.localizedDescription)
            }
            status.toolTip = status.stringValue
            table.reloadData()
            if !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        }
    }

    func controlTextDidChange(_ obj: Notification) { run(search.stringValue) }

    /// ↑ and ↓ move through the rows while typing; Return chooses, Esc closes.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !rows.isEmpty else { return true }
            let step = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let next = min(max(0, table.selectedRow + step), rows.count - 1)
            table.selectRowIndexes([next], byExtendingSelection: false)
            table.scrollRowToVisible(next)
        case #selector(NSResponder.insertNewline(_:)): choose(nil)
        case #selector(NSResponder.cancelOperation(_:)): popover.close()
        default: return false
        }
        return true
    }

    @objc func choose(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(row) else { return NSSound.beep() }
        popover.close()
        pick(rows[row].key)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text = ForeignKeyQueries.display(label: rows[row].label, key: rows[row].key)
        let cell = label(text, truncates: true)
        cell.toolTip = text
        return cell
    }
}
