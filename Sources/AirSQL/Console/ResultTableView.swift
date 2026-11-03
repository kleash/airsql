import AirSQLCore
import AppKit

/// A result set as a read-only table: the console's stand-in until the data grid (`DataGridView` with a
/// `ResultSetSource`) is on main; it takes a `ResultStore` and nothing else, so the grid can replace it in one place
/// (`ResultsView.content(for:)`). Numbers right-aligned in their colour, NULL in grey italics as Settings ▸ Grid shows
/// it, long values cut with an ellipsis (the whole value in the tooltip).
final class ResultTableView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    private let store: ResultStore
    private let nullText: String
    private let numeric: [Bool]
    private let font: NSFont

    init(store: ResultStore, nullText: String, fontSize: CGFloat) {
        self.store = store
        self.nullText = nullText
        font = .systemFont(ofSize: fontSize)
        numeric = store.columns.map(\.isNumeric)
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.style = .plain
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.rowHeight = ceil(fontSize * 1.7)
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.setAccessibilityIdentifier("console.resultTable")
        table.setAccessibilityLabel("Result rows")
        for (index, column) in store.columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
            tableColumn.title = column.name
            tableColumn.headerToolTip = column.name + (column.table.isEmpty ? "" : " (from \(column.table))")
            tableColumn.width = width(of: index)
            tableColumn.minWidth = 40
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        documentView = table
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Wide enough for the header and the first rows' values, at most 320 points.
    private func width(of column: Int) -> CGFloat {
        var widest = (store.columns[column].name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width
        for row in 0..<min(store.rowCount, 50) {
            let text = store.isNull(row, column) ? nullText : store.display(row, column) ?? nullText
            widest = max(widest, (text as NSString).size(withAttributes: [.font: font]).width)
        }
        return min(320, ceil(widest) + 18)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.rowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Int(tableColumn.identifier.rawValue) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier(numeric[column] ? "number" : "text")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? makeCell(identifier)
        let field = cell.textField!
        if store.isNull(row, column) {
            field.stringValue = nullText
            field.textColor = .dataNull
            field.font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) ?? font
            field.toolTip = nil
        } else {
            let text = store.display(row, column) ?? ""
            field.stringValue = text
            field.textColor = numeric[column] ? .dataNumber : store.columns[column].isBinary ? .dataBinary : .labelColor
            field.font = font
            field.toolTip = text.count > 40 ? String(text.prefix(2_000)) : nil
        }
        return cell
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.alignment = identifier.rawValue == "number" ? .right : .left
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// The selected rows as tab-separated text with a header line (⌘C).
    @objc func copy(_ sender: Any?) {
        let rows = table.selectedRowIndexes.isEmpty ? IndexSet(0..<store.rowCount) : table.selectedRowIndexes
        var lines = [store.columns.map(\.name).joined(separator: "\t")]
        for row in rows {
            lines.append((0..<store.columns.count).map { store.isNull(row, $0) ? nullText : store.display(row, $0) ?? "" }
                .joined(separator: "\t"))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
