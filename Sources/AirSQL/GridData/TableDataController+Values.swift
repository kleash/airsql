import AirSQLCore
import AppKit

// Values by their column's type (grid-spec §5): an edit is checked as Apply will write it (`ColumnType.literal`, for
// the data session's sql_mode), booleans toggle, ENUM and SET columns pick from their members, ↑ and ↓ step a date's
// part, a long value opens in the value panel, and Insert Value puts in what the server works out (NOW(), UUID()…).
extension TableDataController {
    /// The data session's sql_mode and time zone (they decide zero dates, backslashes, TIMESTAMP's zone).
    func readEditContext(_ session: TableSession) async throws -> EditContext {
        let store = try await session.query("SELECT @@SESSION.sql_mode, @@SESSION.time_zone", rowCap: 1).first?.rows
        let row = store.flatMap { $0.rowCount > 0 && $0.columns.count == 2 ? $0 : nil }
        return EditContext(server: server, sqlMode: row?.string(0, 0) ?? "", timeZone: row?.string(0, 1) ?? "SYSTEM")
    }

    /// The server as the schema cache read it (its flavour and version decide JSON depth and TIMESTAMP's range).
    private var server: SchemaServer { context.schema.snapshot.server ?? SchemaServer(version: "") }

    /// What decides the values: the session's, or the server's alone until the first page has been read.
    var values: EditContext {
        editContext ?? EditContext(server: server, sqlMode: noBackslashEscapes ? "NO_BACKSLASH_ESCAPES" : "")
    }

    func type(_ column: Int) -> ColumnType? { source.map { ColumnType($0.table.columns[column]) } }

    /// Why `value` can't go in a cell of `column`, nil when it can.
    func refusal(_ value: PendingChanges.Value, column: Int) -> String? {
        guard case .text(let text) = value, let type = type(column) else {
            if value == .null, let source, !source.table.columns[column].nullable { return "\(source.columns[column].name) can't be NULL" }
            return nil
        }
        do {
            _ = try type.literal(text, values)
            return nil
        } catch {
            return (error as? EditError)?.message ?? error.localizedDescription
        }
    }

    /// Keeps one cell's value as a pending change (the value panel, a pick-list), if its column takes it.
    func keep(_ value: PendingChanges.Value, row: Int, column: Int) {
        guard let source, editingOff == nil, source.canEdit(row, column), refusal(value, column: column) == nil else {
            return NSSound.beep()
        }
        source.set(value, row: row, column: column)
        changesDidChange()
    }

    /// Gives every selected cell its column's `value` (nil: leave the cell), each checked by its column: a beep when
    /// one refuses it.
    func setSelected(_ value: (Int) -> PendingChanges.Value?) {
        guard let source, editingOff == nil else { return NSSound.beep() }
        var refused = false
        let depth = source.changes.undoDepth
        for cell in selectedCells() where source.canEdit(cell.row, cell.column) {
            guard let value = value(cell.column) else { continue }
            guard refusal(value, column: cell.column) == nil else {
                refused = true
                continue
            }
            source.set(value, row: cell.row, column: cell.column)
        }
        source.changes.squashUndo(to: depth)  // one ⌘Z takes them all back
        if refused { NSSound.beep() }
        changesDidChange()
    }

    // MARK: Editors

    func dataGrid(_ grid: DataGridView, check text: String, row: Int, column: Int) -> String? {
        refusal(.text(text), column: column)
    }

    func dataGrid(_ grid: DataGridView, step text: String, at offset: Int, by amount: Int, row: Int, column: Int)
        -> (text: String, part: NSRange)? {
        type(column)?.step(text, at: offset, by: amount)
    }

    /// A boolean toggles (Space, Return, a double click; t, f and n type true, false and NULL), ENUM and SET pick from
    /// their members, and a long or multi-line value opens in the value panel. Typing anything else edits as text.
    func dataGrid(_ grid: DataGridView, edit row: Int, column: Int, typed: String?) -> Bool {
        guard let source, let type = type(column) else { return false }
        if type.isBoolean {
            guard let value = booleanValue(typed: typed, current: source.value(row, column)) else { return false }
            // The selected booleans all take the focused one's new state; other selected cells stay as they are.
            setSelected { self.type($0)?.isBoolean == true ? value : nil }
            return true
        }
        guard typed == nil else { return false }
        if source.isCut(row, column) {
            readWhole([row], columns: [column]) { [weak self] in self?.viewer.editInValuePanel() }
            return true
        }
        if foreignKey(column) != nil {
            showLookup(row: row, column: column)
            return true
        }
        switch type.kind {
        case .enumeration(let members):
            showPickList(members, row: row, column: column)
        case .set(let members):
            showChecklist(members, type: type, row: row, column: column)
        default:
            let value = source.value(row, column) ?? ""
            guard value.utf16.count > 256 || value.contains(where: \.isNewline) else { return false }
            viewer.editInValuePanel()
        }
        return true
    }

    /// The cell being edited, on screen.
    var editedRect: NSRect {
        grid.selection.cursor.map { grid.cellRect($0) } ?? .zero
    }

    /// An ENUM's members (and NULL where allowed) as a menu over the cell, the cell's value ticked.
    func pickList(_ members: [String], row: Int, column: Int) -> NSMenu {
        pickListMenu(members, title: source?.columns[column].name ?? "", current: source?.value(row, column),
                     nullable: source?.table.columns[column].nullable == true, nullText: grid.nullText, target: self)
    }

    private func showPickList(_ members: [String], row: Int, column: Int) {
        let menu = pickList(members, row: row, column: column)
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: editedRect.origin, in: grid)
    }

    @objc func pickMember(_ sender: NSMenuItem) {
        let member = sender.representedObject as? String
        setSelected { _ in member.map(PendingChanges.Value.text) ?? .null }
    }

    /// A SET's members as checkboxes under the cell; Set keeps the ticked ones.
    private func showChecklist(_ members: [String], type: ColumnType, row: Int, column: Int) {
        let chosen = Set((source?.value(row, column) ?? "").split(separator: ",").map(String.init))
        checklist = SetChecklist(members: members, chosen: chosen) { [weak self] picked in
            self?.setSelected { _ in .text(type.setText(picked)) }
        }
        checklist?.show(relativeTo: editedRect, of: grid)
    }

    // MARK: Foreign keys

    /// The foreign key a column is part of: the table's own, or one the person defined.
    func foreignKey(_ column: Int) -> SchemaForeignKey? {
        guard let source else { return nil }
        var table = source.table
        table.foreignKeys += settings.virtualKeys
        return ForeignKeyQueries.foreignKey(of: source.columns[column].name, in: table)
    }

    /// Choose Referenced Row…: the focused foreign key column's drop-down.
    @objc func chooseReferencedRow(_ sender: Any?) {
        guard let cell = viewer.focusedCell else { return NSSound.beep() }
        showLookup(row: cell.row, column: cell.column)
    }

    /// The referenced table's rows under the cell, searched on the data session; the one chosen gives the selected rows
    /// its key. Another database's table is read into the schema cache first.
    func showLookup(row: Int, column: Int) {
        guard editingOff == nil, let key = foreignKey(column) else { return NSSound.beep() }
        let schema = context.schema
        guard let referenced = schema.snapshot.table(key.referencedDatabase, key.referencedTable) else {
            Task {
                try? await schema.loadDetails([key.referencedDatabase])
                if schema.snapshot.table(key.referencedDatabase, key.referencedTable) != nil { showLookup(row: row, column: column) } else { NSSound.beep() }
            }
            return
        }
        let label = labelColumn(of: referenced, database: key.referencedDatabase, key: key.referencedColumns)
        let values = self.values, open = openSession
        lookup = ForeignKeyLookup(title: key.referencedTable, keyCount: key.referencedColumns.count, read: { text in
            let sql = ForeignKeyQueries.lookup(key, referenced: referenced, label: label, search: text, context: values)
            return try await open().query(sql, rowCap: 100).first?.rows
        }, pick: { [weak self] picked in self?.setForeignKey(key, to: picked) })
        lookup?.show(relativeTo: editedRect, of: grid)
    }

    /// The selected rows' foreign key columns take the chosen row's key (all of a composite key's), one step for undo.
    private func setForeignKey(_ key: SchemaForeignKey, to picked: [String]) {
        guard let source else { return }
        let depth = source.changes.undoDepth
        for row in Set(selectedCells().map(\.row)).sorted() {
            for (name, value) in zip(key.columns, picked) {
                guard let column = source.columns.firstIndex(where: { $0.name == name }), source.canEdit(row, column),
                      refusal(.text(value), column: column) == nil else { continue }
                source.set(.text(value), row: row, column: column)
            }
        }
        source.changes.squashUndo(to: depth)
        changesDidChange()
    }

    /// Related Rows (⌃⌘↓): the row the focused cell's foreign key points to, and the rows of other tables that point at
    /// this row, as a menu; each opens in a table tab filtered to them.
    @objc func showRelatedRows(_ sender: Any?) {
        guard let source, let cell = viewer.focusedCell, case .loaded = source.row(cell.row) else { return NSSound.beep() }
        let row = Dictionary(source.columns.indices.map { column in
            (source.columns[column].name, source.bytes(cell.row, column) ?? source.value(cell.row, column).map { Array($0.utf8) })
        }, uniquingKeysWith: { first, _ in first })
        let up = foreignKey(cell.column).flatMap { try? ForeignKeyQueries.referenced(by: $0, from: source.table, row: row, context: values) }
            .map { [$0] } ?? []
        let snapshot = context.schema.snapshot.adding(TableViewSettingsStore.shared.virtualKeys(connection: context.connection.id))
        let related = up + ForeignKeyQueries.referencing(database: database, table: source.table, row: row, snapshot: snapshot,
                                                         context: values)
        let menu = NSMenu(title: "Related Rows")
        for (index, item) in related.enumerated() {
            let pointsHere = index >= up.count
            let entry = NSMenuItem(title: "\(item.table): " + (pointsHere ? "rows pointing to this one (\(item.foreignKey))" : "the row it points to"),
                                   action: #selector(openRelated(_:)), keyEquivalent: "")
            entry.representedObject = [item.database, item.table, item.condition]
            entry.target = self
            entry.toolTip = "Open \(item.table) filtered to \(item.condition)"
            menu.addItem(entry)
        }
        if related.isEmpty {
            menu.addItem(withTitle: "No foreign key leads to or from this row", action: nil, keyEquivalent: "").toolTip =
                "Related Rows follows the table's foreign keys and those of tables that refer to it"
        }
        menu.popUp(positioning: nil, at: NSPoint(x: editedRect.minX, y: editedRect.maxY), in: grid)
    }

    @objc func openRelated(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [String], parts.count == 3,
              let main = view.window?.windowController as? MainWindowController else { return }
        _ = main.openTableData(parts[1], database: parts[0], context: context, condition: parts[2])
    }

    // MARK: Insert Value

    /// Insert Value's items for the focused column: values the server works out when Apply runs.
    func insertValueItems() -> [NSMenuItem] {
        guard let source, let column = viewer.focusedCell?.column else { return [] }
        return AirSQL.insertValueItems(source.table.columns[column], values)
    }

    /// Insert Value ▸ an item: each selected cell gets it, as SQL for its own column's type.
    @objc func insertCellValue(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let chosen = InsertValue(rawValue: raw),
              let source else { return NSSound.beep() }
        setSelected { insertedValue(chosen, source.table.columns[$0], self.values) }
    }
}

// Shared with a console result's cells (`ResultGridView+Values`).

/// What a boolean cell becomes: toggled (nil `typed`, Space), or as t, f, 1, 0 and n say; nil: anything else, typed as text.
func booleanValue(typed: String?, current: String?) -> PendingChanges.Value? {
    switch typed?.lowercased() {
    case nil, " ": return .text(current?.contains { $0 != "0" } == true ? "0" : "1")
    case "t", "1": return .text("1")
    case "f", "0": return .text("0")
    case "n": return .null
    default: return nil
    }
}

/// An ENUM's members (and NULL where allowed) as a menu, `current` ticked; `target` has `pickMember(_:)`.
@MainActor func pickListMenu(_ members: [String], title: String, current: String?, nullable: Bool, nullText: String, target: AnyObject) -> NSMenu {
    let menu = NSMenu(title: title)
    for member in members.map(Optional.some) + (nullable ? [nil] : []) {
        let item = NSMenuItem(title: member ?? nullText, action: #selector(TableDataController.pickMember(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = member
        item.state = member == current ? .on : .off
        item.toolTip = member == nil ? "Set the selected cells to NULL (a pending edit)"
            : "Set the selected cells to \(member ?? "") (a pending edit)"
        menu.addItem(item)
    }
    return menu
}

/// Insert Value's items for a column: values the server works out when Apply runs.
@MainActor func insertValueItems(_ info: SchemaColumn, _ values: EditContext) -> [NSMenuItem] {
    let type = ColumnType(info)
    return info.insertValues.map { value in
        let item = NSMenuItem(title: value.title(for: type, values), action: Commands.insertValue.action, keyEquivalent: "")
        item.representedObject = value.rawValue
        item.toolTip = value.help
        return item
    }
}

/// `chosen` as a pending value for a column; nil where the column doesn't take it.
func insertedValue(_ chosen: InsertValue, _ info: SchemaColumn, _ values: EditContext) -> PendingChanges.Value? {
    guard info.insertValues.contains(chosen) else { return nil }
    switch chosen {
    case .null: return .null
    case .default: return .default
    default: return .sql(chosen.sql(for: ColumnType(info), values))
    }
}

/// A SET column's members as checkboxes in a popover under the cell (grid-spec §5): Set keeps the ticked ones as the
/// selected cells' pending value, Esc or a click elsewhere leaves them as they were.
@MainActor
final class SetChecklist: NSObject {
    private(set) var popover = NSPopover()
    let boxes: [NSButton]
    private let done: ([String]) -> Void

    init(members: [String], chosen: Set<String>, done: @escaping ([String]) -> Void) {
        self.done = done
        boxes = members.map { member in
            checkbox(member, id: "grid.set.member", tip: "Include \(member) in the value",
                     on: chosen.contains { $0.caseInsensitiveCompare(member) == .orderedSame }, target: nil, action: nil)
        }
        super.init()
        let set = button("Set", id: "grid.set.done", tip: "Keep the ticked members as the cells' value (a pending edit)",
                         target: self, action: #selector(keep(_:)), primary: true)
        set.keyEquivalent = "\r"
        let cancel = button("Cancel", id: "grid.set.cancel", tip: "Leave the cells as they were", target: self,
                            action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: boxes + [NSStackView(views: [cancel, set])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.setAccessibilityIdentifier("grid.set")
        popover = AirSQL.popover(around: stack, behavior: .transient)
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    @objc func keep(_ sender: Any?) {
        popover.close()
        done(boxes.filter { $0.state == .on }.map(\.title))
    }

    @objc func cancel(_ sender: Any?) { popover.close() }
}
