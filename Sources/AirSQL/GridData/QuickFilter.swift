import AirSQLCore
import AppKit

/// Quick filters (grid-spec §4), shared by the table tab (it filters on the server) and console results (they filter
/// their own rows): the conditions a cell's value offers, Quick Filter ▸ showing each as its SQL, and Type a Value….
@MainActor
enum QuickFilter {
    /// The focused cell's column and value, and the distinct values selected in its column (for IN and NOT IN).
    typealias Focus = (column: GridColumn, value: String?, values: [String?])

    /// The focused cell of `viewer`, its value and the distinct values selected in its column (the first 1,000 cells, as
    /// a menu opens with them), `value` reading the host's rows.
    static func focus(_ viewer: GridViewer, columns: [GridColumn], value: (Int, Int) -> String?) -> Focus? {
        guard let (row, column) = viewer.focusedCell else { return nil }
        var values: [String?] = []
        for cell in viewer.selectedCells(limit: 1_000) where cell.column == column {
            let value = value(cell.row, column)
            if !values.contains(value) { values.append(value) }
        }
        return (columns[column], value(row, column), values)
    }

    /// The operators a value offers: NULL only IS [NOT] NULL, and binary values compare whole (LIKE would read their hex
    /// as text); IN and NOT IN when several values are selected.
    static func operators(_ focus: Focus) -> [GridCondition.Operator] {
        var ops: [GridCondition.Operator] = focus.value == nil ? [.isNull, .isNotNull] : focus.column.kind == .binary
            ? [.equals, .notEquals, .isNull, .isNotNull]
            : [.equals, .notEquals, .less, .greater, .startsWith, .endsWith, .contains, .isNull, .isNotNull]
        if focus.values.count > 1 { ops.insert(contentsOf: [.isIn, .notIn], at: focus.value == nil ? 0 : 2) }
        return ops
    }

    static func condition(_ op: GridCondition.Operator, _ focus: Focus) -> GridCondition {
        GridCondition(focus.column, op, op == .isIn || op == .notIn ? focus.values : [focus.value])
    }

    /// Why Data ▸ Quick Filter's item for `op` is off for `focus`, nil when it can filter (= and <> always can: NULL
    /// gives IS NULL and IS NOT NULL).
    static func reason(_ op: GridCondition.Operator, _ focus: Focus?) -> String? {
        guard let focus else { return "Select a cell first" }
        if op == .equals || op == .notEquals || operators(focus).contains(op) { return nil }
        if op == .isIn || op == .notIn { return "Select several values of this column first" }
        return focus.value == nil ? "The selected value is NULL: use Is NULL or Is Not NULL" : "Binary values only compare whole: use = or <>"
    }

    /// Data ▸ Quick Filter ▸'s items, in `GridCondition.Operator.allCases`' order (as their tags are).
    static let commands = [Commands.filterEquals, Commands.filterNotEquals, Commands.filterLess, Commands.filterGreater,
                           Commands.filterStartsWith, Commands.filterEndsWith, Commands.filterContains, Commands.filterIn,
                           Commands.filterNotIn, Commands.filterNull, Commands.filterNotNull]

    /// Quick Filter ▸ for a cell: each condition as its SQL (⌥ shows the same adding it with AND: tag 1), the clipboard's
    /// text, then Type a Value…. Each item carries its `GridCondition`. An agent's has the Data menu's items instead: the
    /// value may be of rows it may not read (plan §2.8), and the clipboard is the person's.
    static func menuItem(_ focus: Focus?, noBackslashEscapes: Bool, target: AnyObject, action: Selector) -> NSMenuItem {
        var items: [NSMenuItem] = []
        if let focus {
            for op in operators(focus) {
                if AgentGate.agent != nil, let index = GridCondition.Operator.allCases.firstIndex(of: op) {
                    items.append(commands[index].item())
                } else {
                    items += pair(condition(op, focus), noBackslashEscapes: noBackslashEscapes, target: target, action: action)
                }
            }
            if AgentGate.agent == nil, let clipboard = NSPasteboard.general.string(forType: .string), !clipboard.isEmpty,
               !clipboard.contains(where: \.isNewline), clipboard.count <= 1_000 {
                items.append(.separator())
                for op in [GridCondition.Operator.equals, .notEquals, .contains] {
                    items += pair(GridCondition(focus.column, op, [clipboard]), noBackslashEscapes: noBackslashEscapes, target: target,
                                  action: action, clipboard: true)
                }
            }
            items.append(.separator())
            items.append(Commands.filterPrompt.item())
        }
        let item = MainMenu.submenu("Quick Filter", items)
        item.isEnabled = !items.isEmpty
        return item
    }

    private static func pair(_ condition: GridCondition, noBackslashEscapes: Bool, target: AnyObject, action: Selector,
                             clipboard: Bool = false) -> [NSMenuItem] {
        let sql = condition.sql(noBackslashEscapes: noBackslashEscapes)
        let shown = sql.count > 70 ? String(sql.prefix(70)) + "…" : sql
        func item(_ title: String, adding: Bool) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.representedObject = condition
            item.tag = adding ? 1 : 0
            item.target = target
            item.toolTip = (adding ? "Add this condition to the current filter: " : "Show only the rows where ") + shown
            return item
        }
        let adding = item("AND " + shown, adding: true)
        adding.isAlternate = true
        adding.keyEquivalentModifierMask = .option
        return [item((clipboard ? "Clipboard: " : "") + shown, adding: false), adding]
    }

    /// The operators Type a Value… offers, as its pop-up names them (binary columns: = and <> only).
    static let typed: [(op: GridCondition.Operator, title: String)] = [
        (.equals, "Equal to (=)"), (.notEquals, "Not equal to (<>)"), (.less, "Less than (<)"), (.greater, "Greater than (>)"),
        (.startsWith, "Starts with (LIKE x%)"), (.contains, "Contains (LIKE %x%)"), (.endsWith, "Ends with (LIKE %x)"),
    ]

    /// Type a Value… (grid-spec §4: =, <>, LIKE from a prompt): how to compare and the value, starting from the focused
    /// cell's. `canAdd` offers adding it to the current filter; `reply` gets the condition and whether to add it.
    static func ask(_ focus: Focus, canAdd: Bool, on window: NSWindow, reply: @escaping (GridCondition, Bool) -> Void) {
        let choices = focus.column.kind == .binary ? Array(typed.prefix(2)) : typed
        let alert = NSAlert()
        alert.messageText = "Filter by \(focus.column.name)"
        alert.informativeText = "Choose how \(focus.column.name) compares with the value, type the value, and press Filter."
        let pick = popup(choices.map(\.title), selected: 0, id: "quickFilter.operator",
                         tip: "Choose how the column's values compare with the value", target: nil, action: nil)
        let field = textField(focus.value ?? "", placeholder: focus.column.kind == .binary ? "0x00FF" : "Value",
                              id: "quickFilter.value", tip: "Type the value to compare with", width: 300)
        let add = checkbox("Add to the current filter (AND)", id: "quickFilter.add",
                           tip: "Keep the rows' current filter and add this condition to it", on: false, target: nil, action: nil)
        add.isHidden = !canAdd
        let stack = NSStackView(views: [pick, field, add])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.unit
        // NSAlert places its accessory by frame.
        stack.translatesAutoresizingMaskIntoConstraints = true
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: canAdd ? 82 : 56)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Filter").toolTip = "Show only the rows that meet the condition"
        alert.addButton(withTitle: "Cancel").toolTip = "Close without filtering"
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let op = choices[max(0, pick.indexOfSelectedItem)].op
            reply(GridCondition(focus.column, op, [field.stringValue]), add.state == .on)
        }
    }
}
