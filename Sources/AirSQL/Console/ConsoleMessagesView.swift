import AirSQLCore
import AppKit

/// What one statement of a run did, as the Messages tab lists it.
struct ConsoleMessage {
    enum Level { case ok, warning, error, info }

    var level: Level
    /// The statement in the editor (nil for notes like "Stopped"); its first line's number.
    var range: NSRange?
    var line: Int?
    /// The statement's first line.
    var statement: String
    /// "200 rows · 38 ms", "3 rows affected · 12 ms", or the error and the server's own words.
    var text: String
}

/// The Messages tab (plan §2.6): each statement of the runs with its rows or rows affected, time, warnings, or the
/// error and the line it points to, wrapped so the whole of it shows. A click selects a message, a double-click selects
/// its statement in the editor, a click on the selected one's text starts selecting that text, a right-click copies it.
@MainActor
final class ConsoleMessagesView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let table = MessagesTable()
    private(set) var messages: [ConsoleMessage] = []
    /// A double-click on a message: show its statement.
    var onOpen: ((ConsoleMessage) -> Void)?
    /// Row heights measured at the text column's width: a run's every message is asked for at each new one.
    private var heights: [Int: CGFloat] = [:]
    private static let textFont = NSFont.systemFont(ofSize: 12)

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        table.headerView = nil
        table.style = .plain
        table.centreText(rowHeight: 24)
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = true
        table.setAccessibilityIdentifier("console.messages")
        table.setAccessibilityLabel("Messages")
        for (identifier, width) in [("icon", 22.0), ("line", 64.0), ("statement", 200.0), ("text", 360.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.width = width
            column.resizingMask = identifier == "text" ? .autoresizingMask : .userResizingMask
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(open(_:))
        table.menu = NSMenu(title: "Message")
        table.menu?.delegate = self
        documentView = table
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func append(_ message: ConsoleMessage) {
        messages.append(message)
        table.reloadData()
        table.scrollRowToVisible(messages.count - 1)
    }

    func clear() {
        messages = []
        heights = [:]
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { messages.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if let height = heights[row] { return height }
        let cell = NSTextFieldCell(textCell: messages[row].text)
        cell.font = Self.textFont
        cell.wraps = true
        let width = table.tableColumns.last?.width ?? 420
        let height = max(table.rowHeight, ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1_000_000)).height))
        heights[row] = height
        return height
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        heights = [:]
        table.noteHeightOfRows(withIndexesChanged: IndexSet(messages.indices))
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        let message = messages[row]
        if identifier.rawValue == "icon" {
            let image = NSImageView()
            let (symbol, color, name): (String, NSColor, String) = switch message.level {
            case .ok: ("checkmark.circle.fill", .statusOK, "Done")
            case .warning: ("exclamationmark.triangle.fill", .statusWarning, "Warning")
            case .error: ("xmark.octagon.fill", .statusBad, "Error")
            case .info: ("info.circle", .secondaryLabelColor, "Note")
            }
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
            image.contentTintColor = color
            image.imageAlignment = .alignTop
            return image
        }
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.font = Self.textFont
        switch identifier.rawValue {
        case "line":
            field.stringValue = message.line.map { "Line \($0)" } ?? ""
            field.textColor = .secondaryLabelColor
        case "statement":
            field.stringValue = message.statement
            field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            field.toolTip = message.statement
        default:
            field.stringValue = message.text
            field.textColor = message.level == .error ? .statusBad : .labelColor
            field.lineBreakMode = .byWordWrapping
            field.isSelectable = true
        }
        return field
    }

    @objc private func open(_ sender: Any?) {
        guard table.clickedRow >= 0 || table.selectedRow >= 0 else { return }
        onOpen?(messages[table.clickedRow >= 0 ? table.clickedRow : table.selectedRow])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        if row >= 0, !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
        let copy = Commands.copy.item()
        copy.target = self
        menu.addItem(copy)
    }

    /// The selected messages as text, one per line.
    @objc func copy(_ sender: Any?) {
        let rows = table.selectedRowIndexes.isEmpty ? IndexSet(messages.indices) : table.selectedRowIndexes
        let text = rows.map { row -> String in
            let message = messages[row]
            return [message.line.map { "Line \($0)" }, message.statement, message.text].compactMap { $0 }.joined(separator: "\t")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Messages' table: a first click selects the row, and a double-click stays the table's; only a single click on the
/// selected row's text reaches the text, to select some of it.
final class MessagesTable: ContentTable {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        guard responder is NSTextField, let event else { return super.validateProposedFirstResponder(responder, for: event) }
        return event.clickCount == 1 && isRowSelected(row(at: convert(event.locationInWindow, from: nil)))
    }
}
