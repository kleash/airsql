import AirSQLCore
import AppKit

/// The table editor's Partitions: the partitions the server has, and the PARTITION BY clause as text. The clause changes the
/// design as it is typed, as a table's SQL shows it, and only Apply writes it.
@MainActor
final class PartitionsView: NSView, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    weak var editor: TableEditorController?
    let (codeScroll, code) = SQLEditorView.make(fontSize: 12.5)
    let list = ContentTable(frame: .zero)
    private let empty = label("This table has no partitions", color: .secondaryLabelColor)
    private let columns = [("name", "Name", 140.0, "The partition's name"), ("method", "Method", 90, "How rows are shared out"),
                           ("expression", "Expression", 180, "What the partition is chosen by"),
                           ("values", "Values", 180, "The values this partition holds"),
                           ("rows", "Rows", 80, "About how many rows it has"), ("size", "Size", 80, "Its data and indexes on disk")]

    init() {
        super.init(frame: .zero)
        for (id, title, width, tip) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 50
            column.headerToolTip = tip
            list.addTableColumn(column)
        }
        list.dataSource = self
        list.delegate = self
        list.stripes = true
        list.style = .plain
        list.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        list.setAccessibilityIdentifier("tableEditor.partitions")
        let listScroll = NSScrollView()
        listScroll.documentView = list
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.borderType = .noBorder
        code.delegate = self
        code.setAccessibilityIdentifier("tableEditor.partitionClause")
        code.toolTip = "Type the PARTITION BY clause; leave it empty for a table without partitions"
        let caption = label("PARTITION BY clause, such as PARTITION BY HASH (id) PARTITIONS 4. Edit it to add, change or remove partitions; "
                            + "empty it to remove them and keep the rows.", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, wraps: true)
        for view in [listScroll, empty, caption, codeScroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            listScroll.topAnchor.constraint(equalTo: topAnchor), listScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            listScroll.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.45),
            empty.centerXAnchor.constraint(equalTo: listScroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: listScroll.centerYAnchor),
            caption.topAnchor.constraint(equalTo: listScroll.bottomAnchor, constant: Spacing.unit),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.double),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.double),
            codeScroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: Spacing.unit),
            codeScroll.leadingAnchor.constraint(equalTo: leadingAnchor), codeScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the editor's design, unless the person is typing it.
    func show(_ editor: TableEditorController) {
        let clause = editor.design.options.partitioning ?? ""
        if code.string != clause { code.setText(clause) }
        code.isEditable = !editor.isBusy
        list.reloadData()
        empty.isHidden = !editor.partitionList.isEmpty
    }

    func textDidChange(_ notification: Notification) {
        guard let editor else { return }
        let clause = code.string.trimmingCharacters(in: .whitespacesAndNewlines)
        editor.design.options.partitioning = clause.isEmpty ? nil : code.string
        editor.designChanged()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { editor?.partitionList.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let partition = editor?.partitionList[row] else { return nil }
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "name": text = partition.name
        case "method": text = partition.method
        case "expression": text = partition.expression
        case "values": text = partition.values
        case "rows": text = partition.rows
        default: text = DiskUsage.size(partition.size)
        }
        let cell = label(text, font: .systemFont(ofSize: 12.5), truncates: true)
        cell.toolTip = text.isEmpty ? tableColumn?.headerToolTip : text
        return cell
    }
}
