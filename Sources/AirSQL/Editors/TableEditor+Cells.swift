import AirSQLCore
import AppKit

// The list's cells: text fields, check boxes, pop-ups and combo boxes, each writing its edit back into the design.
extension TableEditorController: NSComboBoxDataSource {
    static let extras = ["", "AUTO_INCREMENT", "ON UPDATE CURRENT_TIMESTAMP", "VIRTUAL GENERATED", "STORED GENERATED"]

    func makeCell(_ id: String, row: Int) -> NSView {
        let nbe = server.noBackslashEscapes
        if id == "mark" {
            let state = rowState(row)
            let mark = label(state == .new ? "+" : state == .changed ? "•" : "\(row + 1)", font: .monospacedDigitSystemFont(ofSize: 11,
                                                                                                                         weight: .regular),
                             color: state == .new ? .pendingInsertLine : state == .changed ? .pendingEditLine : .secondaryLabelColor)
            mark.toolTip = state == .new ? "New: added when you apply" : state == .changed ? "Changed: altered when you apply" : nil
            return mark
        }
        switch section {
        case .columns:
            let column = design.columns[row]
            let type = column.columnType
            switch id {
            case "name": return text(column.name, placeholder: "name")
            case "type":
                var names = ColumnTypes.all(for: server).map { $0.name.uppercased() }
                if !names.contains(column.type.name.uppercased()) { names.append(column.type.name.uppercased()) }
                return choice(names, column.type.name.uppercased())
            case "length":
                return because(text(column.type.length, placeholder: type?.hint ?? "", enabled: type?.length != EditorColumnType.Length.none),
                               "\(column.type.name.uppercased()) takes no length or values")
            case "unsigned": return because(check(column.type.unsigned, enabled: type?.numeric ?? false), "Only number columns can be unsigned")
            case "null": return check(column.nullable)
            case "default":
                if let generated = column.generated { return text(generated.expression, placeholder: "expression") }
                return because(text(EditorText.defaultValue(column.defaultValue, numeric: type?.numeric ?? false, noBackslashEscapes: nbe),
                                    placeholder: column.autoIncrement ? "counts up" : "none", enabled: !column.autoIncrement),
                               "An AUTO_INCREMENT column counts up by itself: it has no default")
            case "extra": return choice(Self.extras, extra(column), enabled: Self.extras.map { extraAllowed($0, column) })
            case "collation":
                return because(combo(column.collation ?? "", placeholder: "table's", enabled: type?.text ?? false),
                               "Only text columns have a collation")
            default: return text(column.comment, placeholder: "")
            }
        case .indexes:
            let index = design.indexes[row]
            switch id {
            case "name": return text(index.name, placeholder: "name", enabled: index.kind != .primary)
            case "kind": return choice(IndexDesign.Kind.allCases.map(\.title), index.kind.title)
            case "columns": return text(EditorText.parts(index.parts), placeholder: "columns")
            default: return text(index.comment, placeholder: "")
            }
        case .foreignKeys:
            let key = design.foreignKeys[row]
            switch id {
            case "name": return text(key.name, placeholder: "name")
            case "columns": return text(EditorText.names(key.columns), placeholder: "columns")
            case "references": return combo(referenceText(key), placeholder: "table")
            case "referencedColumns": return text(EditorText.names(key.referencedColumns), placeholder: "columns")
            case "onUpdate": return choice(ForeignKeyDesign.rules, key.onUpdate)
            default: return choice(ForeignKeyDesign.rules, key.onDelete)
            }
        case .checks, .options:
            if row >= design.checks.count {
                let column = design.columns[columnCheckRows[row - design.checks.count]]
                switch id {
                case "name":
                    let name = text(column.name + " (column)", placeholder: "", enabled: false)
                    name.toolTip = "MariaDB keeps this check with the column \(column.name); empty its condition to remove it"
                    return name
                case "clause": return text(column.check ?? "", placeholder: "condition")
                default: return check(true, enabled: false)
                }
            }
            let item = design.checks[row]
            switch id {
            case "name": return text(item.name, placeholder: "name")
            case "clause": return text(item.clause, placeholder: "condition, such as `total` >= 0")
            default:
                let box = check(item.enforced, enabled: server.flavour == .mysql)
                box.toolTip = server.flavour == .mysql ? "MySQL checks the condition on every write" : "MariaDB always enforces checks"
                return box
            }
        }
    }

    /// The Extra pop-up's choice for a column.
    func extra(_ column: ColumnDesign) -> String {
        if let generated = column.generated { return generated.stored ? "STORED GENERATED" : "VIRTUAL GENERATED" }
        if column.autoIncrement { return "AUTO_INCREMENT" }
        return column.onUpdate == nil ? "" : "ON UPDATE CURRENT_TIMESTAMP"
    }

    func extraAllowed(_ extra: String, _ column: ColumnDesign) -> Bool {
        switch extra {
        case "AUTO_INCREMENT": return column.columnType?.integer ?? false
        case "ON UPDATE CURRENT_TIMESTAMP": return ["timestamp", "datetime"].contains(column.type.name)
        default: return true
        }
    }

    func referenceText(_ key: ForeignKeyDesign) -> String {
        key.referencedDatabase.isEmpty || key.referencedDatabase == database ? key.referencedTable
            : EditorText.name(key.referencedDatabase) + "." + EditorText.name(key.referencedTable)
    }

    // MARK: Controls

    /// `control`, saying `reason` when its column's type turns it off (busy cells are covered by the editor's spinner).
    private func because<Control: NSControl>(_ control: Control, _ reason: String) -> Control {
        if !control.isEnabled && !isBusy { control.toolTip = reason }
        return control
    }

    private func text(_ value: String, placeholder: String, enabled: Bool = true) -> NSTextField {
        let field = ListTextField(string: value)
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = enabled && !isBusy
        field.isEnabled = enabled
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.sendsActionOnEndEditing = true
        field.font = .systemFont(ofSize: 12.5)
        field.target = self
        field.action = #selector(cellEdited(_:))
        field.toolTip = value.isEmpty ? nil : value
        return field
    }

    private func check(_ on: Bool, enabled: Bool = true) -> NSButton {
        let box = ListCheckbox(checkboxWithTitle: "", target: self, action: #selector(cellEdited(_:)))
        box.state = on ? .on : .off
        box.isEnabled = enabled && !isBusy
        return box
    }

    private func choice(_ titles: [String], _ selected: String, enabled: [Bool]? = nil) -> NSPopUpButton {
        let popup = ListPopUp(frame: .zero, pullsDown: false)
        popup.isBordered = false
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 12)
        popup.autoenablesItems = false
        popup.addItems(withTitles: titles)
        for (index, item) in popup.itemArray.enumerated() {
            if item.title.isEmpty { item.title = "—" }
            item.isEnabled = enabled?[index] ?? true
        }
        popup.selectItem(at: titles.firstIndex(of: selected) ?? 0)
        popup.isEnabled = !isBusy
        popup.target = self
        popup.action = #selector(cellEdited(_:))
        return popup
    }

    private func combo(_ value: String, placeholder: String, enabled: Bool = true) -> NSComboBox {
        let box = ListComboBox()
        box.usesDataSource = true
        box.dataSource = self
        box.completes = true
        box.stringValue = value
        box.toolTip = value.isEmpty ? nil : value  // whole, when the column is too narrow for it
        box.placeholderString = placeholder
        box.isBordered = false
        box.drawsBackground = false
        box.controlSize = .small
        box.font = .systemFont(ofSize: 12)
        box.isEnabled = enabled && !isBusy
        box.numberOfVisibleItems = 14
        box.target = self
        box.action = #selector(cellEdited(_:))
        box.cell?.sendsActionOnEndEditing = true
        return box
    }

    /// What a combo box offers: collations, or the tables a key can point at.
    func comboItems(_ box: NSComboBox) -> [String] {
        if box.identifier?.rawValue == "references" {
            return context.schema.snapshot.database(database ?? "")?.tables.filter { $0.kind == .table }.map(\.name) ?? []
        }
        return collations.map(\.name)
    }

    func numberOfItems(in comboBox: NSComboBox) -> Int { comboItems(comboBox).count }

    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        let items = comboItems(comboBox)
        return items.indices.contains(index) ? items[index] : nil
    }

    func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
        comboItems(comboBox).first { $0.lowercased().hasPrefix(string.lowercased()) }
    }

    func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int {
        comboItems(comboBox).firstIndex(of: string) ?? NSNotFound
    }
}
