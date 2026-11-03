import AirSQLCore
import AppKit

/// The table editor's Options: the table's name (and, for a new table, its database), engine, default collation, row
/// format, next AUTO_INCREMENT value and comment.
@MainActor
final class TableOptionsView: NSView {
    weak var editor: TableEditorController?
    let name = textField("", placeholder: "table name", id: "tableEditor.options.name", tip: "The table's name; changing it renames the table")
    let database = popup([], selected: 0, id: "tableEditor.options.database", tip: "The database the new table goes in", target: nil,
                         action: nil)
    let engine = popup([], selected: 0, id: "tableEditor.options.engine", tip: "How the server stores the table: InnoDB has transactions "
                       + "and foreign keys", target: nil, action: nil)
    let collation = NSComboBox()
    let rowFormat = popup([], selected: 0, id: "tableEditor.options.rowFormat", tip: "How rows are laid out on disk; Default leaves "
                          + "it to the engine", target: nil, action: nil)
    let next = textField("", placeholder: "as it is", id: "tableEditor.options.autoIncrement",
                         tip: "The number the next AUTO_INCREMENT row gets; it can't go below the largest one there")
    let comment = textField("", placeholder: "", id: "tableEditor.options.comment", tip: "A note kept with the table")

    init() {
        super.init(frame: .zero)
        collation.completes = true
        collation.numberOfVisibleItems = 16
        collation.placeholderString = "the database's"
        collation.toolTip = "How the table's new text columns compare and sort; existing columns keep theirs"
        collation.setAccessibilityIdentifier("tableEditor.options.collation")
        collation.translatesAutoresizingMaskIntoConstraints = false
        collation.widthAnchor.constraint(equalToConstant: 280).isActive = true
        for field in [name, next, comment] { field.cell?.sendsActionOnEndEditing = true }
        name.widthAnchor.constraint(equalToConstant: 280).isActive = true
        next.widthAnchor.constraint(equalToConstant: 140).isActive = true
        comment.widthAnchor.constraint(equalToConstant: 420).isActive = true
        for control in [name, database, engine, collation, rowFormat, next, comment] as [NSControl] {
            control.target = self
            control.action = #selector(edited(_:))
        }
        collation.cell?.sendsActionOnEndEditing = true
        let form = Form()
        form.row("Name", [name])
        form.row("Database", [database], caption: "Only a new table chooses its database; move a table with the bulk table editor.")
        form.row("Engine", [engine])
        form.row("Collation", [collation])
        form.row("Row format", [rowFormat])
        form.row("Next number", [next])
        form.row("Comment", [comment])
        let grid = form.finish()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = FlippedView()
        document.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: Spacing.double + 4),
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Spacing.triple),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -Spacing.triple),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -Spacing.double),
        ])
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        document.heightAnchor.constraint(greaterThanOrEqualTo: grid.heightAnchor, constant: 2 * Spacing.double + 4).isActive = true
        addSubview(scroll)
        scroll.pin(to: self)
        setAccessibilityIdentifier("tableEditor.options")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the editor's design (leaving alone a field being typed in).
    func show(_ editor: TableEditorController) {
        let options = editor.design.options
        func set(_ field: NSTextField, _ value: String) { if field.currentEditor() == nil { field.stringValue = value } }
        set(name, editor.design.name)
        set(next, options.autoIncrement.map(String.init) ?? "")
        set(comment, options.comment)
        if collation.currentEditor() == nil { collation.stringValue = options.collation ?? "" }
        if collation.numberOfItems != editor.collations.count {
            collation.removeAllItems()
            collation.addItems(withObjectValues: editor.collations.map(\.name))
        }
        let databases = editor.context.schema.snapshot.databases.map(\.name)
        database.removeAllItems()
        database.addItems(withTitles: databases.isEmpty ? [editor.database ?? ""] : databases)
        database.selectItem(withTitle: editor.database ?? "")
        database.isEnabled = editor.before == nil && !editor.isBusy
        database.toolTip = database.isEnabled ? "The database the new table goes in" : "Only a new table chooses its database"
        var engines = editor.engines
        if let current = options.engine, !engines.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            engines.append(current)
        }
        engine.removeAllItems()
        engine.addItems(withTitles: [Self.serverDefault] + engines)
        engine.selectItem(withTitle: engines.first { $0.caseInsensitiveCompare(options.engine ?? "") == .orderedSame } ?? Self.serverDefault)
        rowFormat.removeAllItems()
        rowFormat.addItems(withTitles: [Self.serverDefault] + TableOptions.rowFormats.map { $0.capitalized })
        rowFormat.selectItem(withTitle: options.rowFormat.map { $0.capitalized } ?? Self.serverDefault)
        for control in [name, engine, collation, rowFormat, next, comment] as [NSControl] { control.isEnabled = !editor.isBusy }
    }

    static let serverDefault = "Server's default"

    @objc private func edited(_ sender: NSControl) {
        guard let editor else { return }
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if sender === database, let title = database.titleOfSelectedItem {
            editor.database = title
            editor.designChanged()
            return
        }
        if sender === next, !text.isEmpty, UInt64(text) == nil {
            showError("Type a whole number, such as 1000, or leave it empty.", title: "That isn't a number", on: window)
            next.stringValue = editor.design.options.autoIncrement.map(String.init) ?? ""
            return
        }
        editor.update { table in
            switch sender {
            case name: table.name = sender.stringValue
            case engine: table.options.engine = engine.indexOfSelectedItem == 0 ? nil : engine.titleOfSelectedItem
            case collation: table.options.collation = text.isEmpty ? nil : text
            case rowFormat: table.options.rowFormat = rowFormat.indexOfSelectedItem == 0 ? nil : rowFormat.titleOfSelectedItem?.uppercased()
            case next: table.options.autoIncrement = UInt64(text)
            default: table.options.comment = sender.stringValue
            }
        }
    }
}
