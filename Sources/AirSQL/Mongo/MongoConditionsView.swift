import AirSQLCore
import AppKit

/// The query builder's conditions (mongo-plan, Phase 5 A): "Find documents where all/any of these are true" (SQL's
/// WHERE … AND/OR), a row per condition (field, operator, value), `+ Condition`, `+ Group` (one level), `+ Item` (one item
/// of an array meeting its conditions together, `$elemMatch`). A plain view: set
/// `group`, read it back after `onChange`; `schema` and `paths` give the fields, their types and values. The query bar
/// and the stage builder's Filter card both use it. It grows downward, and scrolls past `maxHeight`.
@MainActor
final class MongoConditionsView: NSView {
    /// After any edit; `group` and `problem` say what the rows hold now.
    var onChange: (() -> Void)?
    /// The sample the rows take their fields' types, shares and values from; nil: any typed field.
    var schema: MongoSchema? { didSet { fieldsChanged() } }
    /// Fields besides the sample's (the columns a tab loaded).
    var paths: [String] = [] { didSet { if paths != oldValue { fieldsChanged() } } }
    var maxHeight: CGFloat = 220 { didSet { resize() } }

    private let top: ConditionGroupView
    private let scroll = NSScrollView()
    private var height: NSLayoutConstraint!

    override init(frame: NSRect) {
        top = ConditionGroupView(level: 0)
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("mongo.conditions")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Conditions")
        top.owner = self
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(top)
        top.pin(to: document)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.pin(to: self)
        height = heightAnchor.constraint(equalToConstant: 30)
        NSLayoutConstraint.activate([height, document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                                     document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)])
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        resize()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The rows as conditions; rows without a field yet are left out.
    var group: MongoBuilder.Group {
        get { top.group }
        set {
            top.set(newValue)
            fieldsChanged()
        }
    }

    /// The first bad row's message ("age: ‘x’ isn't a number"), else a bad item's; nil when all make conditions.
    var problem: String? { allRows.lazy.compactMap(\.error).first ?? top.items.lazy.compactMap(\.error).first }

    var allRows: [ConditionRowView] { top.rows }

    /// `+ Condition`: a new empty row at the end of the top group, with the keyboard in its field.
    @discardableResult
    func addCondition() -> ConditionRowView { top.newRow() }

    /// `+ Item`: a new item at the end of the top group.
    @discardableResult
    func addItem() -> ConditionGroupView { top.newItem() }

    /// The field box's list for a row in the item(s) of `array` (`items`: their fields, `sku`), or of the whole document.
    func fieldItems(under array: String?) -> [String] {
        let paths = array.map { a in fieldPaths.compactMap { $0.hasPrefix(a + ".") ? String($0.dropFirst(a.count + 1)) : nil } } ?? fieldPaths
        return paths.map { p in shares(array.map { $0 + "." + p } ?? p).map { p + Self.sharesMark + $0 } ?? p }
    }

    /// The sample's array fields, named from inside the item(s) of `array` when there is one.
    func arrayPaths(under array: String?) -> [String] {
        var seen = Set<String>()
        let all = (schema?.fields ?? []).filter { $0.path.hasSuffix(".[]") }.map { MongoBuilder.queryPath(String($0.path.dropLast(3))) }
        let paths = array.map { a in all.compactMap { $0.hasPrefix(a + ".") ? String($0.dropFirst(a.count + 1)) : nil } } ?? all
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Every path the field boxes offer: the sample's as a query names them, then `paths`.
    var fieldPaths: [String] {
        var seen = Set<String>()
        let sampled = (schema?.fields ?? []).filter { !$0.path.hasSuffix(".[]") }.map { MongoBuilder.queryPath($0.path) }
        return (sampled + paths).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The sample's field for a query path (an array: the array's own).
    func field(_ path: String) -> MongoSchema.Field? {
        schema?.fields.first { MongoBuilder.queryPath($0.path) == path && !$0.path.hasSuffix(".[]") }
    }

    /// "text 80%, number 20%" for a path in the sample.
    func shares(_ path: String) -> String? {
        guard let schema, let field = field(path) else { return nil }
        return MongoSchemaView.text(field, "types", of: schema.documents)
    }

    /// The sample's most common values of a path, as its boxes take them (text without its quotes).
    func topValues(_ path: String) -> [String] {
        guard let field = field(path) else { return [] }
        let values = field.types.first?.name == "array" ? schema?[field.path + ".[]"]?.top ?? [] : field.top
        return values.map { top in
            if case .string(let s)? = try? BSONValue(shellForm: top.value) { return s }
            return top.value
        }
    }

    /// The type a path's values have in the sample; text when it isn't there.
    func sampleType(_ path: String) -> MongoBuilder.ValueType {
        schema.map { MongoBuilder.valueType(of: path, in: $0) } ?? .text
    }

    private func fieldsChanged() {
        for row in allRows { row.offer(fieldItems(under: row.itemPrefix)) }
        for item in top.items { item.offerArrays() }
        changed(notify: false)
    }

    /// Between a field's path and its shares in the field box's list.
    static let sharesMark = "  —  "

    /// After an edit: the notes and messages under the rows and items, the height, then `onChange`.
    func changed(notify: Bool = true) {
        let rows = allRows
        let arrays = (schema?.fields ?? []).map(\.path)
        // Rows in an item match one item together already.
        let shared = MongoBuilder.sharedArrays(paths: rows.map { $0.itemPrefix == nil ? $0.rule?.path ?? "" : "" }, arrayPaths: arrays)
        for (row, array) in zip(rows, shared) { row.updateMessage(sharedArray: row.rule == nil ? nil : array) }
        for item in top.items.reversed() { item.updateMessage() }
        resize()
        if notify { onChange?() }
    }

    func resize() {
        top.layoutSubtreeIfNeeded()
        height?.constant = min(top.fittingSize.height, maxHeight)
    }
}

// MARK: A group

/// The top group (level 0: "Find documents where …", `+ Condition`, `+ Group`, `+ Item`), a group inside it ("all/any
/// of these:", its rows, `+ Condition`, remove), or an item ("An item of <array> where all/any of these:", `$elemMatch`).
@MainActor
final class ConditionGroupView: NSStackView, NSComboBoxDelegate {
    let level: Int
    /// An item of an array field (`MongoBuilder.Item`) rather than a group.
    let isItem: Bool
    weak var owner: MongoConditionsView?
    let anyPopup: NSPopUpButton
    /// An item's array field.
    let arrayField = NSComboBox()
    /// Under an item: what makes it no condition.
    let message = label("", font: .systemFont(ofSize: 11), color: .statusBad, wraps: true)
    private(set) var error: String?
    private let tail = label("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private let body = NSStackView()
    private let addRule: NSButton
    private var addGroup: NSButton?

    init(level: Int, item: Bool = false) {
        self.level = level
        isItem = item
        let kind = level == 0 ? "" : item ? ".item" : ".group", ids = "mongo.conditions" + kind
        anyPopup = popup(["all", "any"], selected: 0, id: "mongo.conditions.anyAll" + kind,
                         tip: "Choose whether every condition must hold (all: AND) or one is enough (any: OR)", target: nil, action: nil)
        anyPopup.item(at: 0)?.toolTip = "Every condition must hold, as SQL's AND"
        anyPopup.item(at: 1)?.toolTip = "One condition is enough, as SQL's OR"
        anyPopup.controlSize = .small
        anyPopup.font = .systemFont(ofSize: 12)
        anyPopup.setAccessibilityLabel(level == 0 ? "Find documents where all or any of the conditions are true"
                                       : item ? "Item: all or any" : "Group: all or any")
        addRule = button("+ Condition", id: ids + ".add",
                         tip: level == 0 ? "Add a condition: a field, how it compares and a value"
                             : item ? "Add a condition on this item: one of its fields, or leave the field empty for the item itself"
                             : "Add a condition to this group",
                         target: nil, action: nil)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        translatesAutoresizingMaskIntoConstraints = false
        anyPopup.target = self
        anyPopup.action = #selector(anyChanged(_:))
        let addItem = button("+ Item", id: ids + ".addItem",
                             tip: "Add conditions that one item of an array must meet together ($elemMatch)", target: self, action: #selector(addItem(_:)))
        addRule.target = self
        addRule.action = #selector(addRule(_:))
        var header: [NSView] = []
        if level == 0 || item {
            addGroup = button("+ Group", id: ids + ".addGroup",
                              tip: "Add a group of conditions with its own all or any, as parentheses in SQL", target: self, action: #selector(addGroup(_:)))
        }
        for b in [addRule, addItem] + (addGroup.map { [$0] } ?? []) {
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11.5)
            b.bezelStyle = .recessed
        }
        if level == 0 {
            header = [label("Find documents where", font: .systemFont(ofSize: 12), color: .secondaryLabelColor), anyPopup, tail]
        } else {
            let remove = removeButton(tip: item ? "Remove this item and its conditions" : "Remove this group and its conditions", id: ids + ".remove")
            remove.target = self
            remove.action = #selector(removeSelf(_:))
            header = [anyPopup, tail, remove]
        }
        if item {
            arrayField.placeholderString = "array field"
            arrayField.toolTip = "Type or choose the array field whose items the conditions are on (items, or tags for plain values)"
            arrayField.setAccessibilityLabel("Array field")
            arrayField.setAccessibilityIdentifier("mongo.conditions.item.array")
            arrayField.completes = false
            arrayField.delegate = self
            arrayField.controlSize = .small
            arrayField.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            arrayField.translatesAutoresizingMaskIntoConstraints = false
            arrayField.widthAnchor.constraint(equalToConstant: 150).isActive = true
            header = [label("An item of", font: .systemFont(ofSize: 12), color: .secondaryLabelColor), arrayField,
                      label("where", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)] + header
        }
        let head = NSStackView(views: header)
        head.spacing = Spacing.half
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 4
        let foot = NSStackView(views: [addRule] + (addGroup.map { [$0] } ?? []) + [addItem])
        foot.spacing = Spacing.half
        addArrangedSubview(head)
        addArrangedSubview(body)
        addArrangedSubview(foot)
        if level > 0 {
            edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 4)
            wantsLayer = true
            layer?.cornerRadius = 5
            layer?.borderWidth = 1
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            setAccessibilityLabel(item ? "Item of an array" : "Group of conditions")
            setAccessibilityIdentifier(item ? "mongo.conditions.item" : "mongo.conditions.group")
        }
        if item {
            message.isSelectable = true
            message.preferredMaxLayoutWidth = 640
            message.isHidden = true
            message.setAccessibilityIdentifier("mongo.conditions.item.message")
            addArrangedSubview(message)
        }
        updateTail()
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() {
        super.updateLayer()
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    private var isAny: Bool { anyPopup.indexOfSelectedItem == 1 }

    private func updateTail() {
        tail.stringValue = level == 0 ? (isAny ? "of these are true   (SQL: WHERE … OR …)" : "of these are true   (SQL: WHERE … AND …)")
            : isItem ? (isAny ? "of these hold for that one item   (OR)" : "of these hold for that one item   (AND)")
            : (isAny ? "of these   (OR)" : "of these   (AND)")
    }

    var arrayPath: String { arrayField.stringValue.trimmingCharacters(in: .whitespaces) }

    /// Its rows, a group's rows after it in order.
    var rows: [ConditionRowView] {
        body.arrangedSubviews.flatMap { view -> [ConditionRowView] in
            if let row = view as? ConditionRowView { return [row] }
            return (view as? ConditionGroupView)?.rows ?? []
        }
    }

    /// The items inside it, each before the items inside that one.
    var items: [ConditionGroupView] {
        body.arrangedSubviews.compactMap { $0 as? ConditionGroupView }.flatMap { ($0.isItem ? [$0] : []) + $0.items }
    }

    var group: MongoBuilder.Group {
        MongoBuilder.Group(any: isAny, body.arrangedSubviews.compactMap { view in
            if let row = view as? ConditionRowView { return row.rule.map(MongoBuilder.Condition.rule) }
            return (view as? ConditionGroupView)?.condition
        })
    }

    var condition: MongoBuilder.Condition { isItem ? .item(MongoBuilder.Item(arrayPath, group)) : .group(group) }

    func set(_ group: MongoBuilder.Group) {
        anyPopup.selectItem(at: group.any ? 1 : 0)
        updateTail()
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for child in group.children {
            switch child {
            case .rule(let rule): append(row(rule))
            case .group(let inner): append(nested(inner))
            case .item(let item):
                let view = nested(item.group, item: true)
                view.arrayField.stringValue = item.path
                append(view)
            }
        }
    }

    private func nested(_ group: MongoBuilder.Group, item: Bool = false) -> ConditionGroupView {
        let view = ConditionGroupView(level: level + 1, item: item)
        view.owner = owner
        view.set(group)
        return view
    }

    private func row(_ rule: MongoBuilder.Rule?) -> ConditionRowView {
        let row = ConditionRowView(owner: owner)
        if let rule { row.set(rule) }
        return row
    }

    private func append(_ view: NSView) {
        body.addArrangedSubview(view)
        if view is ConditionGroupView { view.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true }
    }

    /// An item's conditions: what it says under it when its rows are good but it makes no condition.
    func updateMessage() {
        error = nil
        if rows.allSatisfy({ $0.error == nil }), items.allSatisfy({ $0.error == nil }) {
            do { _ = try MongoBuilder.Item(arrayPath, group).clause() } catch { self.error = (error as? BSONError)?.message ?? "\(error)" }
        }
        message.stringValue = error ?? ""
        message.isHidden = error == nil
    }

    @objc private func anyChanged(_ sender: Any?) {
        updateTail()
        owner?.changed()
    }

    @objc func addRule(_ sender: Any?) { newRow() }

    @discardableResult
    func newRow() -> ConditionRowView {
        let row = row(nil)
        append(row)
        owner.map { row.offer($0.fieldItems(under: row.itemPrefix)) }
        row.followSample()
        owner?.changed(notify: false)
        window?.makeFirstResponder(row.field)
        return row
    }

    @objc func addGroup(_ sender: Any?) {
        let view = nested(MongoBuilder.Group(any: !isAny))
        append(view)
        view.addRule(nil)
    }

    @objc func addItem(_ sender: Any?) { newItem() }

    /// `+ Item`: an item with one empty row, the keyboard in its array field.
    @discardableResult
    func newItem() -> ConditionGroupView {
        let view = nested(MongoBuilder.Group(), item: true)
        append(view)
        view.offerArrays()
        view.newRow()
        window?.makeFirstResponder(view.arrayField)
        return view
    }

    /// An item's array box: the sample's arrays, named from the item it is in.
    func offerArrays() {
        guard isItem, let owner else { return }
        arrayField.removeAllItems()
        arrayField.addItems(withObjectValues: owner.arrayPaths(under: ConditionRowView.prefix(above: superview)))
    }

    @objc private func removeSelf(_ sender: Any?) {
        let owner = owner
        removeFromSuperview()
        owner?.changed()
    }

    // MARK: The array field

    private func arrayChanged() {
        for row in rows {
            owner.map { row.offer($0.fieldItems(under: row.itemPrefix)) }
            row.followSample()
        }
        owner?.changed()
    }

    func controlTextDidChange(_ notification: Notification) { arrayChanged() }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // The box takes the chosen item's text after this.
        DispatchQueue.main.async { [weak self] in self?.arrayChanged() }
    }
}

/// The small "remove" button of a row or group.
@MainActor
func removeButton(tip: String, id: String) -> NSButton {
    let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: tip)!, target: nil, action: nil)
    remove.isBordered = false
    remove.toolTip = tip
    remove.setAccessibilityLabel(tip)
    remove.setAccessibilityIdentifier(id)
    remove.translatesAutoresizingMaskIntoConstraints = false
    return remove
}

// MARK: A row

/// One condition: field (the sample's paths with their types' shares; any path can be typed), the type its value is read
/// as, the operator (titles with SQL's beside them), the value box(es) for the operator, Ignore case on the text operators,
/// date presets on dates, remove; under it what's wrong or worth knowing.
@MainActor
final class ConditionRowView: NSStackView, NSComboBoxDelegate {
    weak var owner: MongoConditionsView?
    let field = NSComboBox()
    let typePopup: NSPopUpButton
    let opPopup: NSPopUpButton
    private let values = NSStackView()
    let presets = NSPopUpButton(frame: .zero, pullsDown: true)
    let ignoreCase: NSButton
    let message = label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor, wraps: true)
    /// The value boxes now: combo boxes, a list's field, or true/false.
    private(set) var boxes: [NSControl] = []
    private var ops: [MongoBuilder.Operator] = []
    private(set) var type = MongoBuilder.ValueType.text
    /// What makes no condition; nil when the row is good or has no field yet.
    private(set) var error: String?

    init(owner: MongoConditionsView?) {
        self.owner = owner
        typePopup = popup(MongoBuilder.ValueType.allCases.map(\.title), selected: 0, id: "mongo.condition.type",
                          tip: "Choose what the value is read as; the sample's main type is chosen for you", target: nil, action: nil)
        opPopup = popup([], selected: 0, id: "mongo.condition.operator",
                        tip: "Choose how the field compares with the value; SQL's way of writing it is beside each", target: nil, action: nil)
        ignoreCase = checkbox("Ignore case", id: "mongo.condition.ignoreCase", tip: "Match capitals and small letters alike (the i option)",
                              on: false, target: nil, action: nil)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 2
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Condition")
        setAccessibilityIdentifier("mongo.condition")
        field.placeholderString = "field"
        field.toolTip = "Type or choose the field: dotted for a sub-document's (address.city) or an array's items (items.sku)"
        field.setAccessibilityLabel("Field")
        field.setAccessibilityIdentifier("mongo.condition.field")
        field.completes = false
        field.numberOfVisibleItems = 14
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 170).isActive = true
        for control in [field, typePopup, opPopup, ignoreCase] as [NSControl] {
            control.controlSize = .small
            control.font = .systemFont(ofSize: 12)
        }
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        typePopup.setAccessibilityLabel("Value type")
        opPopup.setAccessibilityLabel("Operator")
        typePopup.target = self
        typePopup.action = #selector(typeChosen(_:))
        opPopup.target = self
        opPopup.action = #selector(opChosen(_:))
        ignoreCase.target = self
        ignoreCase.action = #selector(edited(_:))
        presets.addItem(withTitle: "")
        presets.item(at: 0)?.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Date presets")
        for preset in MongoBuilder.DatePreset.allCases {
            presets.addItem(withTitle: preset.title)
            presets.lastItem?.representedObject = preset.rawValue
            presets.lastItem?.toolTip = "Find documents whose date is in this range (UTC days)"
        }
        (presets.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        presets.isBordered = false
        presets.toolTip = "Choose a range of days: today, the last 7 days or this month"
        presets.setAccessibilityLabel("Date presets")
        presets.setAccessibilityIdentifier("mongo.condition.presets")
        presets.target = self
        presets.action = #selector(presetChosen(_:))
        values.spacing = Spacing.half
        let remove = removeButton(tip: "Remove this condition", id: "mongo.condition.remove")
        remove.target = self
        remove.action = #selector(removeSelf(_:))
        let line = NSStackView(views: [field, typePopup, opPopup, values, presets, ignoreCase, remove])
        line.spacing = Spacing.half
        message.isSelectable = true
        message.preferredMaxLayoutWidth = 640
        message.setAccessibilityIdentifier("mongo.condition.message")
        addArrangedSubview(line)
        addArrangedSubview(message)
        offer(owner.map { o in o.fieldPaths.map { p in o.shares(p).map { p + MongoConditionsView.sharesMark + $0 } ?? p } } ?? [])
        setType(.text, keeping: .is)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    private var path: String { field.stringValue.trimmingCharacters(in: .whitespaces) }

    /// The array paths of the items the row is in, outermost first (`orders.items`); nil outside any item.
    var itemPrefix: String? { Self.prefix(above: superview) }

    static func prefix(above view: NSView?) -> String? {
        var paths: [String] = [], view = view
        while let each = view, !(each is MongoConditionsView) {
            if let item = each as? ConditionGroupView, item.isItem { paths.insert(item.arrayPath, at: 0) }
            view = each.superview
        }
        return paths.isEmpty ? nil : paths.filter { !$0.isEmpty }.joined(separator: ".")
    }

    /// The path as the sample names it: in an item, under its array (no field: the array's items themselves).
    private var fullPath: String { [itemPrefix ?? "", path].filter { !$0.isEmpty }.joined(separator: ".") }

    /// The row's condition; nil while it has no field (in an item, no field is the item's own value).
    var rule: MongoBuilder.Rule? {
        guard !path.isEmpty || itemPrefix != nil, ops.indices.contains(opPopup.indexOfSelectedItem) else { return nil }
        let op = ops[opPopup.indexOfSelectedItem]
        let texts: [String]
        switch op.arity {
        case .none: texts = []
        case .list: texts = MongoBuilder.listItems(boxes.first?.stringValue ?? "")
        case .one, .two:
            texts = boxes.map { ($0 as? NSPopUpButton)?.titleOfSelectedItem ?? $0.stringValue }
        }
        return MongoBuilder.Rule(path, op, texts, type: type, ignoreCase: op.isPattern && ignoreCase.state == .on)
    }

    func set(_ rule: MongoBuilder.Rule) {
        field.stringValue = rule.path
        ignoreCase.state = rule.ignoreCase ? .on : .off
        setType(rule.type, keeping: rule.op)
        switch rule.op.arity {
        case .none: break
        case .list: boxes.first?.stringValue = MongoBuilder.listText(rule.values)
        case .one, .two:
            for (box, text) in zip(boxes, rule.values) {
                if let popup = box as? NSPopUpButton { popup.selectItem(withTitle: text) } else { box.stringValue = text }
            }
        }
        updateFieldTip()
    }

    /// The field box's list: paths, each with its shares.
    func offer(_ items: [String]) {
        field.placeholderString = itemPrefix == nil ? "field" : "the item itself"
        updateFieldTip()
        field.removeAllItems()
        field.addItems(withObjectValues: items)
        for box in boxes { (box as? NSComboBox).map(fillValues) }
    }

    // MARK: Type, operator, values

    private func setType(_ type: MongoBuilder.ValueType, keeping op: MongoBuilder.Operator?) {
        self.type = type
        typePopup.selectItem(at: MongoBuilder.ValueType.allCases.firstIndex(of: type) ?? 0)
        let old = op ?? (ops.indices.contains(opPopup.indexOfSelectedItem) ? ops[opPopup.indexOfSelectedItem] : .is)
        ops = MongoBuilder.Operator.fitting(type)
        if !ops.contains(old) { ops.append(old) }  // read back from text: kept even if the type wouldn't offer it
        opPopup.removeAllItems()
        for op in ops {
            opPopup.addItem(withTitle: op.label)
            opPopup.lastItem?.toolTip = "\(op.title): in SQL, \(op.sqlHint)"
        }
        opPopup.selectItem(at: ops.firstIndex(of: old) ?? 0)
        makeBoxes()
    }

    private var op: MongoBuilder.Operator { ops.indices.contains(opPopup.indexOfSelectedItem) ? ops[opPopup.indexOfSelectedItem] : .is }

    /// The value boxes the operator takes, keeping what was typed where it still fits.
    private func makeBoxes() {
        let old = boxes.map { ($0 as? NSPopUpButton)?.titleOfSelectedItem ?? $0.stringValue }
        values.arrangedSubviews.forEach { $0.removeFromSuperview() }
        boxes = []
        let op = self.op
        func box(_ name: String) -> NSControl {
            if type == .bool {
                let pick = popup(["true", "false"], selected: 0, id: "mongo.condition.value", tip: "Choose true or false",
                                 target: self, action: #selector(edited(_:)))
                pick.controlSize = .small
                pick.font = .systemFont(ofSize: 12)
                pick.setAccessibilityLabel(name)
                return pick
            }
            let combo = NSComboBox()
            combo.translatesAutoresizingMaskIntoConstraints = false
            combo.controlSize = .small
            combo.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            combo.completes = false
            combo.delegate = self
            combo.placeholderString = placeholder
            combo.toolTip = valueTip
            combo.setAccessibilityLabel(name)
            combo.setAccessibilityIdentifier("mongo.condition.value")
            combo.widthAnchor.constraint(equalToConstant: op.arity == .two ? 120 : 170).isActive = true
            fillValues(combo)
            return combo
        }
        switch op.arity {
        case .none: break
        case .one: boxes = [box("Value")]
        case .two: boxes = [box("From"), box("To")]
        case .list:
            let list = AirSQL.textField("", placeholder: "DE, FR, \"a, b\"", id: "mongo.condition.list",
                                 tip: "Type the values, separated by commas; quote one that has a comma", width: 200)
            list.controlSize = .small
            list.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            list.delegate = self
            list.setAccessibilityLabel("Values")
            boxes = [list]
        }
        for (index, box) in boxes.enumerated() {
            if index == 1 { values.addArrangedSubview(label("and", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)) }
            values.addArrangedSubview(box)
        }
        // What was typed stays: a list keeps its items as one box's text, and the other way round.
        if op.arity == .list, !old.isEmpty { boxes.first?.stringValue = old.count == 1 ? old[0] : MongoBuilder.listText(old) }
        else if op.arity != .list, op.arity != .none {
            for (box, text) in zip(boxes, old) where !(box is NSPopUpButton) { box.stringValue = text }
        }
        presets.isHidden = type != .date
        ignoreCase.isHidden = !op.isPattern
    }

    private var placeholder: String {
        switch type {
        case .text: return "text"
        case .number: return "number"
        case .date: return "2026-11-12 (UTC)"
        case .objectId: return "24 hex digits"
        case .bool: return ""
        case .shell: return "UUID(\"…\")"
        }
    }

    private var valueTip: String {
        switch type {
        case .date: return "Type a day (2026-11-12: the whole day), a time (2026-11-12 10:30) or ISO 8601, all in UTC"
        case .shell: return "Type the value in shell form: UUID(\"…\"), NumberDecimal(\"1.5\"), ISODate(\"…\")"
        default: return "Type the value or choose one of the sample's most common; ObjectId(\"…\") and other shell values are taken as written"
        }
    }

    private func fillValues(_ combo: NSComboBox) {
        combo.removeAllItems()
        combo.addItems(withObjectValues: Array((owner?.topValues(fullPath) ?? []).prefix(15)))
    }

    private func updateFieldTip() {
        if path.isEmpty, itemPrefix != nil {
            field.toolTip = "Type or choose a field of the item (sku), or leave it empty for the item's own value (an array of plain values)"
            return
        }
        guard let shares = owner?.shares(fullPath) else {
            field.toolTip = path.isEmpty ? "Type or choose the field: dotted for a sub-document's (address.city) or an array's items (items.sku)"
                : "\(fullPath) isn't in the sample: choose the type its value is read as"
            return
        }
        field.toolTip = "\(fullPath) in the sample: \(shares)"
    }

    // MARK: Messages

    /// Under the row: what is wrong (it makes no condition), else that a date goes to a text field, or that rules on the
    /// same array may match different items.
    func updateMessage(sharedArray: String?) {
        error = nil
        var notes: [String] = []
        if let rule {
            do { _ = try rule.path.isEmpty ? rule.itemCondition() : rule.clause() } catch { self.error = (error as? BSONError)?.message ?? "\(error)" }
            if type == .text, owner?.sampleType(fullPath) == .text, owner?.field(fullPath) != nil,
               rule.values.contains(where: { $0.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil }) {
                notes.append("\(fullPath) holds text in the sample, so this compares the date as text, not as a date")
            }
            if let sharedArray {
                notes.append("Conditions on fields of the array \(sharedArray) may each match a different item of it: "
                             + "+ Item makes one item meet them all")
            }
        }
        message.stringValue = error ?? notes.joined(separator: " · ")
        message.textColor = error == nil ? .secondaryLabelColor : .statusBad
        message.isHidden = message.stringValue.isEmpty
        setAccessibilityHelp(message.isHidden ? nil : message.stringValue)
    }

    // MARK: Edits

    @objc private func typeChosen(_ sender: Any?) {
        setType(MongoBuilder.ValueType.allCases[max(0, typePopup.indexOfSelectedItem)], keeping: nil)
        edited(nil)
    }

    @objc private func opChosen(_ sender: Any?) {
        makeBoxes()
        edited(nil)
    }

    @objc private func presetChosen(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let preset = MongoBuilder.DatePreset(rawValue: raw),
              let between = ops.firstIndex(of: .between) else { return }
        opPopup.selectItem(at: between)
        makeBoxes()
        for (box, text) in zip(boxes, preset.values(now: Date(), calendar: .current)) { box.stringValue = text }
        edited(nil)
    }

    @objc private func edited(_ sender: Any?) { owner?.changed() }

    @objc private func removeSelf(_ sender: Any?) {
        let owner = owner
        removeFromSuperview()
        owner?.changed()
    }

    /// The field typed or chosen: its shares cut off, then the type and operators of the sample's field.
    private func fieldChanged() {
        if let mark = field.stringValue.range(of: MongoConditionsView.sharesMark) {
            field.stringValue = String(field.stringValue[..<mark.lowerBound])
        }
        followSample()
        updateFieldTip()
        edited(nil)
    }

    /// The type and values of the sample's field (in an item with no field: its array's items).
    func followSample() {
        let type = owner?.sampleType(fullPath) ?? .text
        if type != self.type, owner?.field(fullPath) != nil { setType(type, keeping: nil) }
        for box in boxes { (box as? NSComboBox).map(fillValues) }
    }

    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSControl) === field { fieldChanged() } else { edited(nil) }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox else { return }
        // The box takes the chosen item's text after this.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if combo === field { fieldChanged() } else { edited(nil) }
        }
    }
}
