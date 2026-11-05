import AirSQLCore
import AppKit

/// The fields above an object editor's code: a routine's parameters and characteristics, a trigger's timing, an event's
/// schedule, a view's options. The code stays the object: the fields show what it says (`show`) and write back to it
/// (`onChange`). Code the form can't read turns the fields off, and is edited as text.
@MainActor
final class ObjectFormView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// The code as the fields now say.
    var onChange: ((String) -> Void)?
    /// The tables a trigger can be on.
    var tables: [String] = []

    private let kind: ObjectKind
    private var noBackslashEscapes = false
    private var routine: RoutineForm?
    private var trigger: TriggerForm?
    private var event: EventForm?
    private var viewForm: ViewForm?
    /// A field is writing to the code: what it wrote may not read back yet (a bracket still open).
    private var writing = false

    let name = AirSQL.textField("", placeholder: "name", id: "objectForm.name", tip: "Type the object's name; changing it renames it when you apply", width: 150)
    let hint = label("This code doesn't start the usual way, so the fields are off: edit it as text below", font: .systemFont(ofSize: 11.5),
                     color: .secondaryLabelColor, truncates: true)
    let comment = AirSQL.textField("", placeholder: "none", id: "objectForm.comment", tip: "Type a note to keep with the object", width: 200)
    // Routines
    let returns = AirSQL.textField("", placeholder: "INT", id: "objectForm.returns", tip: "Type the type the function returns", width: 100)
    let access = popup(RoutineForm.dataAccess, selected: 0, id: "objectForm.access", tip: "Choose what the routine says it does with data", target: nil, action: nil)
    let security = popup(["DEFINER", "INVOKER"], selected: 0, id: "objectForm.security", tip: "Choose whose rights it runs with", target: nil, action: nil)
    let deterministic = checkbox("Deterministic", id: "objectForm.deterministic", tip: "Say that the same input always gives the same result", on: false,
                                 target: nil, action: nil)
    let parameters = ContentTable(frame: .zero)
    private(set) lazy var addParameter = symbolButton("plus", "objectForm.add", "Add a parameter", #selector(add(_:)))
    private(set) lazy var removeParameter = symbolButton("minus", "objectForm.remove", "Remove the selected parameter", #selector(remove(_:)))
    private(set) lazy var upButton = symbolButton("chevron.up", "objectForm.up", "Move the selected parameter up", #selector(moveParameterUp(_:)))
    private(set) lazy var downButton = symbolButton("chevron.down", "objectForm.down", "Move the selected parameter down", #selector(moveParameterDown(_:)))
    // Triggers
    let timing = popup(["BEFORE", "AFTER"], selected: 0, id: "objectForm.timing", tip: "Choose whether it fires before or after the change", target: nil, action: nil)
    let happening = popup(["INSERT", "UPDATE", "DELETE"], selected: 0, id: "objectForm.event", tip: "Choose the change it fires on", target: nil, action: nil)
    let table = NSComboBox()
    // Events
    let schedule = popup(["Every", "Once at"], selected: 0, id: "objectForm.schedule", tip: "Choose whether it repeats or runs once", target: nil, action: nil)
    let at = AirSQL.textField("", placeholder: "2030-01-31 09:00:00", id: "objectForm.at", tip: "Type when it runs: a date and time, or an expression", width: 180)
    let every = AirSQL.textField("", placeholder: "1", id: "objectForm.every", tip: "Type how many units between runs", width: 60)
    let unit = popup(EventForm.units, selected: 4, id: "objectForm.unit", tip: "Choose the unit of time", target: nil, action: nil)
    let starts = AirSQL.textField("", placeholder: "now", id: "objectForm.starts", tip: "Type when it starts: a date and time, or an expression; empty for now", width: 140)
    let ends = AirSQL.textField("", placeholder: "never", id: "objectForm.ends", tip: "Type when it stops: a date and time, or an expression; empty for never", width: 140)
    private let startsLabel = label("Starts:"), endsLabel = label("Ends:")
    let state = popup(["Enabled", "Disabled", "Disabled on replicas"], selected: 0, id: "objectForm.state", tip: "Choose whether it runs", target: nil, action: nil)
    let preserve = checkbox("Keep after last run", id: "objectForm.preserve", tip: "Keep the event once it has finished; off drops it", on: false, target: nil, action: nil)
    // Views
    let algorithm = popup(ViewForm.algorithms, selected: 0, id: "objectForm.algorithm", tip: "Choose how the server runs the view", target: nil, action: nil)
    let check = popup(["No check", "CASCADED", "LOCAL"], selected: 0, id: "objectForm.check", tip: "Choose whether writes through the view must stay visible in it",
                      target: nil, action: nil)

    private var fields: [NSControl] {
        [name, comment, returns, access, security, deterministic, timing, happening, table, schedule, at, every, unit, starts, ends, state, preserve,
         algorithm, check]
    }

    init(kind: ObjectKind) {
        self.kind = kind
        super.init(frame: .zero)
        for field in fields {
            field.target = self
            field.action = #selector(edited(_:))
            (field as? NSTextField)?.delegate = self
        }
        table.toolTip = "Choose the table it fires on"
        table.placeholderString = "table"
        table.completes = true
        table.setAccessibilityIdentifier("objectForm.table")
        table.translatesAutoresizingMaskIntoConstraints = false
        table.widthAnchor.constraint(equalToConstant: 190).isActive = true
        var rows: [NSView] = []
        func row(_ views: [NSView]) { rows.append(line(views)) }
        switch kind {
        case .procedure, .function:
            var first: [NSView] = [label("Name:"), name]
            if kind == .function { first += [label("Returns:"), returns] }
            row(first + [label("Security:"), security, deterministic])
            row([label("Data:"), access, label("Comment:"), comment])
            rows.append(parameterList())
        case .trigger:
            row([label("Name:"), name, timing, happening, label("on"), table])
        case .event:
            row([label("Name:"), name, state, preserve])
            row([schedule, at, every, unit])
            row([startsLabel, starts, endsLabel, ends, label("Comment:"), comment])
        case .view:
            row([label("Name:"), name, label("Algorithm:"), algorithm])
            row([label("Security:"), security, label("Check:"), check])
        }
        rows.append(hint)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = Spacing.half + 2
        stack.edgeInsets = NSEdgeInsets(top: Spacing.unit, left: Spacing.double, bottom: Spacing.unit, right: Spacing.double)
        addSubview(stack)
        stack.pin(to: self)
        setAccessibilityIdentifier("objectForm")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func line(_ views: [NSView]) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = NSStackView(views: views + [spacer])
        line.spacing = Spacing.unit
        line.alignment = .centerY
        return line
    }

    private func symbolButton(_ symbol: String, _ id: String, _ tip: String, _ action: Selector) -> NSButton {
        let control = NSButton()
        control.bezelStyle = .rounded
        control.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        control.target = self
        control.action = action
        control.toolTip = tip
        control.setAccessibilityIdentifier(id)
        return control
    }

    private func parameterList() -> NSView {
        var columns = [("name", "Parameter", CGFloat(170), "Name the parameter"), ("type", "Type", CGFloat(220), "Type its type, such as VARCHAR(100)")]
        if kind == .procedure { columns.insert(("mode", "Mode", 80, "Choose whether it goes in, out or both"), at: 0) }
        for (id, title, width, tip) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.headerToolTip = tip
            parameters.addTableColumn(column)
        }
        parameters.dataSource = self
        parameters.delegate = self
        parameters.stripes = true
        parameters.style = .plain
        parameters.rowHeight = 22
        parameters.setAccessibilityIdentifier("objectForm.parameters")
        let scroll = NSScrollView()
        scroll.documentView = parameters
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.heightAnchor.constraint(equalToConstant: 92),
                                     scroll.widthAnchor.constraint(equalToConstant: columns.map(\.2).reduce(24, +))])
        let buttons = NSStackView(views: [addParameter, removeParameter, upButton, downButton])
        buttons.orientation = .vertical
        buttons.spacing = 2
        return line([scroll, buttons])
    }

    // MARK: Reading the code

    /// Shows what `code` says; the field being typed in stays as it is.
    func show(_ code: String, noBackslashEscapes: Bool, enabled: Bool) {
        guard !writing else { return }
        self.noBackslashEscapes = noBackslashEscapes
        routine = RoutineForm(code, noBackslashEscapes: noBackslashEscapes)
        trigger = TriggerForm(code, noBackslashEscapes: noBackslashEscapes)
        event = EventForm(code, noBackslashEscapes: noBackslashEscapes)
        viewForm = ViewForm(code, noBackslashEscapes: noBackslashEscapes)
        func set(_ field: NSTextField, _ value: String) { if field.currentEditor() == nil { field.stringValue = value } }
        var readable = false
        switch kind {
        case .procedure, .function:
            if let routine {
                readable = routine.kind == kind
                set(name, routine.name)
                set(comment, routine.comment)
                set(returns, routine.returns ?? "")
                access.selectItem(withTitle: routine.dataAccess)
                security.selectItem(withTitle: routine.security)
                deterministic.state = routine.deterministic ? .on : .off
            }
            parameters.reloadData()
        case .trigger:
            if let trigger {
                readable = true
                set(name, trigger.name)
                set(table, trigger.table)
                timing.selectItem(withTitle: trigger.timing)
                happening.selectItem(withTitle: trigger.event)
            }
            if table.numberOfItems != tables.count {
                table.removeAllItems()
                table.addItems(withObjectValues: tables)
            }
        case .event:
            if let event {
                readable = true
                set(name, event.name)
                set(comment, event.comment)
                set(at, event.at)
                set(every, event.every)
                set(starts, event.starts)
                set(ends, event.ends)
                unit.selectItem(withTitle: event.unit)
                schedule.selectItem(at: event.once ? 1 : 0)
                state.selectItem(at: EventForm.states.firstIndex(of: event.state) ?? 0)
                preserve.state = event.preserve ? .on : .off
                at.isHidden = !event.once
                for control in [every, unit, starts, ends] as [NSView] { control.isHidden = event.once }
                for mark in [startsLabel, endsLabel] { mark.isHidden = event.once }
            }
        case .view:
            if let viewForm {
                readable = true
                set(name, viewForm.name)
                algorithm.selectItem(withTitle: viewForm.algorithm)
                security.selectItem(withTitle: viewForm.security)
                check.selectItem(at: ViewForm.checkOptions.firstIndex(of: viewForm.checkOption) ?? 0)
            }
        }
        for field in fields { field.isEnabled = readable && enabled }
        parameters.isEnabled = readable && enabled
        for control in [addParameter, removeParameter, upButton, downButton] { control.isEnabled = readable && enabled }
        updateMoves()
        hint.isHidden = readable
    }

    // MARK: Writing to the code

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSControl else { return }
        if parameters.row(for: field) >= 0 { parameterEdited(field) } else { edited(field) }
    }

    /// Takes every field into the form, and the form's code to the editor.
    @objc func edited(_ sender: Any?) {
        let text = { (field: NSTextField) in field.stringValue.trimmingCharacters(in: .whitespaces) }
        var code: String?
        switch kind {
        case .procedure, .function:
            guard var form = routine else { return }
            form.name = text(name)
            form.comment = comment.stringValue
            if kind == .function { form.returns = text(returns) }
            form.dataAccess = access.titleOfSelectedItem ?? form.dataAccess
            form.security = security.titleOfSelectedItem ?? form.security
            form.deterministic = deterministic.state == .on
            routine = form
            code = form.code(noBackslashEscapes: noBackslashEscapes)
        case .trigger:
            guard var form = trigger else { return }
            form.name = text(name)
            form.table = text(table)
            form.timing = timing.titleOfSelectedItem ?? form.timing
            form.event = happening.titleOfSelectedItem ?? form.event
            trigger = form
            code = form.code()
        case .event:
            guard var form = event else { return }
            form.name = text(name)
            form.comment = comment.stringValue
            form.once = schedule.indexOfSelectedItem == 1
            form.at = text(at)
            form.every = text(every)
            form.unit = unit.titleOfSelectedItem ?? form.unit
            form.starts = text(starts)
            form.ends = text(ends)
            form.preserve = preserve.state == .on
            form.state = EventForm.states[max(state.indexOfSelectedItem, 0)]
            event = form
            code = form.code(noBackslashEscapes: noBackslashEscapes)
        case .view:
            guard var form = viewForm else { return }
            form.name = text(name)
            form.algorithm = algorithm.titleOfSelectedItem ?? form.algorithm
            form.security = security.titleOfSelectedItem ?? form.security
            form.checkOption = ViewForm.checkOptions[max(check.indexOfSelectedItem, 0)]
            viewForm = form
            code = form.code()
        }
        write(code)
        // The schedule's fields follow Every and Once at.
        if sender as AnyObject === schedule, let code { show(code, noBackslashEscapes: noBackslashEscapes, enabled: true) }
    }

    private func write(_ code: String?) {
        guard let code else { return }
        writing = true
        onChange?(code)
        writing = false
    }

    // MARK: Parameters

    private func changeParameters(select row: Int? = nil, _ change: (inout [RoutineForm.Parameter]) -> Void) {
        guard var form = routine else { return }
        change(&form.parameters)
        routine = form
        write(form.code(noBackslashEscapes: noBackslashEscapes))
        guard let row else { return }
        parameters.reloadData()
        parameters.selectRowIndexes([row], byExtendingSelection: false)
        updateMoves()
    }

    @objc func add(_ sender: Any?) {
        let count = routine?.parameters.count ?? 0
        changeParameters(select: count) {
            $0.append(RoutineForm.Parameter(mode: kind == .procedure ? "IN" : "", name: "p_\(count + 1)", type: "INT"))
        }
    }

    @objc func remove(_ sender: Any?) {
        let row = parameters.selectedRow
        guard row >= 0, row < routine?.parameters.count ?? 0 else { return }
        changeParameters(select: max(0, row - 1)) { $0.remove(at: row) }
    }

    @objc func moveParameterUp(_ sender: Any?) { move(by: -1) }
    @objc func moveParameterDown(_ sender: Any?) { move(by: 1) }

    private func move(by offset: Int) {
        let row = parameters.selectedRow
        guard row >= 0, (routine?.parameters ?? []).indices.contains(row + offset) else { return }
        changeParameters(select: row + offset) { $0.swapAt(row, row + offset) }
    }

    /// Up and Down follow the selection; − needs one.
    private func updateMoves() {
        let row = parameters.selectedRow, count = routine?.parameters.count ?? 0
        removeParameter.isEnabled = routine != nil && row >= 0
        upButton.isEnabled = routine != nil && row > 0
        downButton.isEnabled = routine != nil && row >= 0 && row + 1 < count
    }

    func numberOfRows(in tableView: NSTableView) -> Int { routine?.parameters.count ?? 0 }

    func tableViewSelectionDidChange(_ notification: Notification) { updateMoves() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let parameter = routine?.parameters[row], let id = tableColumn?.identifier.rawValue else { return nil }
        if id == "mode" {
            let modes = ["IN", "OUT", "INOUT"]
            let control = popup(modes, selected: modes.firstIndex(of: parameter.mode) ?? 0, id: "objectForm.mode", tip: tableColumn?.headerToolTip ?? "",
                                target: self, action: #selector(parameterEdited(_:)))
            control.identifier = NSUserInterfaceItemIdentifier(id)
            control.isBordered = false
            control.controlSize = .small
            return control
        }
        let field = NSTextField(string: id == "name" ? parameter.name : parameter.type)
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 12.5)
        field.toolTip = tableColumn?.headerToolTip
        field.setAccessibilityIdentifier("objectForm.parameter." + id)
        field.delegate = self
        field.target = self
        field.action = #selector(parameterEdited(_:))
        field.cell?.sendsActionOnEndEditing = true
        return field
    }

    @objc func parameterEdited(_ sender: NSControl) {
        let row = parameters.row(for: sender)
        guard row >= 0, let id = sender.identifier?.rawValue else { return }
        changeParameters { list in
            guard list.indices.contains(row) else { return }
            switch id {
            case "mode": list[row].mode = (sender as? NSPopUpButton)?.titleOfSelectedItem ?? "IN"
            case "name": list[row].name = sender.stringValue.trimmingCharacters(in: .whitespaces)
            default: list[row].type = sender.stringValue.trimmingCharacters(in: .whitespaces)
            }
        }
    }
}
