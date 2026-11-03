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

    /// Gives every selected cell that can take it `value`: each checked by its own column (a beep when one couldn't).
    func setSelected(_ value: (Int) -> PendingChanges.Value?) {
        guard let source, editingOff == nil else { return NSSound.beep() }
        var refused = false
        let depth = source.changes.undoDepth
        for cell in selectedCells() where source.canEdit(cell.row, cell.column) {
            guard let value = value(cell.column), refusal(value, column: cell.column) == nil else {
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
            switch typed?.lowercased() {
            case nil, " ":
                let value = source.value(row, column) ?? "0"
                let on = value.contains { $0 != "0" }
                setSelected { _ in .text(on ? "0" : "1") }
            case "t", "1": setSelected { _ in .text("1") }
            case "f", "0": setSelected { _ in .text("0") }
            case "n": setSelected { _ in .null }
            default: return false
            }
            return true
        }
        guard typed == nil else { return false }
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
    private var editedRect: NSRect {
        grid.selection.cursor.map { grid.cellRect($0) } ?? .zero
    }

    /// An ENUM's members (and NULL where allowed) as a menu over the cell, the cell's value ticked.
    func pickList(_ members: [String], row: Int, column: Int) -> NSMenu {
        let menu = NSMenu(title: source?.columns[column].name ?? "")
        let current = source?.value(row, column)
        let nullable = source?.table.columns[column].nullable == true
        for member in members.map(Optional.some) + (nullable ? [nil] : []) {
            let item = NSMenuItem(title: member ?? grid.nullText, action: #selector(pickMember(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = member
            item.state = member == current ? .on : .off
            item.toolTip = member == nil ? "Set the selected cells to NULL (a pending edit)"
                : "Set the selected cells to \(member ?? "") (a pending edit)"
            menu.addItem(item)
        }
        return menu
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

    // MARK: Insert Value

    /// Insert Value's items for the focused column: values the server works out when Apply runs.
    func insertValueItems() -> [NSMenuItem] {
        guard let source, let column = viewer.focusedCell?.column else { return [] }
        let info = source.table.columns[column], type = ColumnType(info)
        return info.insertValues.map { value in
            let item = NSMenuItem(title: value.title(for: type, values), action: Commands.insertValue.action, keyEquivalent: "")
            item.representedObject = value.rawValue
            item.toolTip = value.help
            return item
        }
    }

    /// Insert Value ▸ an item: each selected cell gets it, as SQL for its own column's type.
    @objc func insertCellValue(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let chosen = InsertValue(rawValue: raw),
              let source else { return NSSound.beep() }
        setSelected { column in
            let info = source.table.columns[column]
            guard info.insertValues.contains(chosen) else { return nil }
            switch chosen {
            case .null: return .null
            case .default: return .default
            default: return .sql(chosen.sql(for: ColumnType(info), self.values))
            }
        }
    }
}

/// A SET column's members as checkboxes in a popover under the cell (grid-spec §5): Set keeps the ticked ones as the
/// selected cells' pending value, Esc or a click elsewhere leaves them as they were.
@MainActor
final class SetChecklist: NSObject {
    let popover = NSPopover()
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
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.setAccessibilityIdentifier("grid.set")
        let content = NSViewController()
        content.view = stack
        popover.contentViewController = content
        popover.behavior = .transient
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
