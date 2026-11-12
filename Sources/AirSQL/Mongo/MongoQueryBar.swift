import AirSQLCore
import AppKit

/// A collection tab's query bar (mongo-plan, Query bar): the find's filter, projection, sort, skip, limit, collation,
/// hint and max time, each typed in shell form; Run (⌘↩ or Return in a field), a spinner while it reads, the history and
/// favourites, and what's wrong with a field said under them. The filter, projection, sort, collation and hint autofill
/// (`MongoAutofill`) with what the collection tab's `complete` offers.
@MainActor
final class MongoQueryBar: NSView, NSTextFieldDelegate {
    let filter = AirSQL.textField("", placeholder: "{ field: \"value\" }   every document when empty", id: "mongo.filter",
                           tip: "Which documents to find, in shell form: { age: { $gt: 30 } }; Esc lists what fits here")
    let projection = AirSQL.textField("", placeholder: "{ field: 1 }", id: "mongo.projection",
                               tip: "Which fields to show: { name: 1 } keeps name, { notes: 0 } leaves notes out")
    let sort = AirSQL.textField("", placeholder: "{ field: -1 }", id: "mongo.sort", tip: "The order: { age: -1 } is oldest first")
    let skip = AirSQL.textField("", placeholder: "0", id: "mongo.skip", tip: "How many documents to pass over first", width: 64)
    let limit = AirSQL.textField("", placeholder: "none", id: "mongo.limit", tip: "The most documents to find", width: 64)
    let collation = AirSQL.textField("", placeholder: "{ locale: \"en\", strength: 2 }", id: "mongo.collation",
                              tip: "How strings compare: { locale: \"en\", strength: 2 } ignores case")
    let hint = AirSQL.textField("", placeholder: "index name or { field: 1 }", id: "mongo.hint", tip: "The index the server must use")
    let maxTime = AirSQL.textField("", placeholder: "none", id: "mongo.maxTime",
                            tip: "Milliseconds the server may spend on the find before it stops it", width: 80)
    let run = button("Run", id: "mongo.run", tip: Commands.runStatement.tip, target: nil, action: Commands.runStatement.action, primary: true)
    let history = NSPopUpButton(frame: .zero, pullsDown: true)
    let spinner = NSProgressIndicator()
    let problem = label("", font: .systemFont(ofSize: 11.5), color: .statusBad, wraps: true)
    /// Autofill's suggestions for a field's text at a caret.
    var complete: ((MongoCaret.Root, String, Int) -> (Range<Int>, [CompletionItem]))?
    let autofill = MongoAutofill()
    /// Return in a field.
    var onRun: (() -> Void)?

    // The builder (mongo-plan, Phase 5 A): the conditions, Show fields, Sort rows, Skip and Limit (the shell's own fields),
    // Ignore case, and the query in shell form. It edits the fields' text, which stays what Run, the history and Explain read.
    enum Mode: Int { case builder, shell }
    let modeSwitch = NSSegmentedControl()
    private(set) var mode = Mode.builder
    let conditions = MongoConditionsView()
    let showFields = NSPopUpButton(frame: .zero, pullsDown: true)
    let sortRows = NSStackView()
    lazy var addSort = button("+ Sort", id: "mongo.sort.add", tip: "Add a field to sort by, as SQL's ORDER BY", target: self,
                              action: #selector(addSortRow(_:)))
    lazy var ignoreCase = checkbox("Ignore case in comparisons and sorting", id: "mongo.ignoreCase",
                                   tip: "Compare and sort text with capitals and small letters alike (a collation; patterns use their own Ignore case)",
                                   on: false, target: self, action: #selector(ignoreCaseChanged(_:)))
    let shellLine = label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor, truncates: true)
    let textNote = label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor, wraps: true)
    let aggregate = button("Aggregate…", id: "mongo.aggregate", tip: "Group, join and reshape these documents in steps",
                           target: nil, action: Commands.aggregateQuery.action)
    /// The collection, for the shell line.
    var collection = ""
    /// The text the builder last read or wrote: a part whose text differs is read again.
    private var read = MongoQueryText()
    private var shown = Projection()
    /// The parts the builder can't show, which show their text field in its place.
    private(set) var asText: Set<String> = []
    private typealias Projection = MongoBuilder.Projection
    private var fields: [(name: String, field: NSTextField)] {
        [("Filter", filter), ("Project", projection), ("Sort", sort), ("Skip", skip), ("Limit", limit), ("Collation", collation),
         ("Hint", hint), ("Max Time", maxTime)]
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("mongo.queryBar")
        run.toolTip = "Find the documents the fields describe (⌘↩)"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Reading documents")
        history.addItem(withTitle: "")
        history.item(at: 0)?.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Query History")
        (history.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        history.isBordered = false
        history.toolTip = "Run a query again, or keep this one among the favourites (⌘Y)"
        history.setAccessibilityIdentifier("mongo.history")
        problem.setAccessibilityIdentifier("mongo.problem")
        problem.isSelectable = true
        problem.isHidden = true
        for (_, field) in fields {
            field.delegate = self
            field.target = self
            field.action = #selector(returnPressed(_:))
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        conditions.onChange = { [weak self] in self?.conditionsChanged() }
        modeSwitch.segmentCount = 2
        modeSwitch.setLabel("Builder", forSegment: 0)
        modeSwitch.setLabel("Shell", forSegment: 1)
        modeSwitch.trackingMode = .selectOne
        modeSwitch.controlSize = .small
        modeSwitch.selectedSegmentBezelColor = .selectedSegment
        modeSwitch.setToolTip("Build the query from fields, operators and values, as a SQL WHERE, SELECT and ORDER BY", forSegment: 0)
        modeSwitch.setToolTip("Type each part of the query in shell form", forSegment: 1)
        modeSwitch.setAccessibilityIdentifier("mongo.mode")
        modeSwitch.setAccessibilityLabel("Query builder or shell fields")
        modeSwitch.target = self
        modeSwitch.action = #selector(modeSwitched(_:))
        modeSwitch.selectedSegment = 0
        showFields.addItem(withTitle: "All fields")
        showFields.menu?.delegate = self
        showFields.toolTip = "Tick the fields to show, as SQL's SELECT; every field shows when none is ticked"
        showFields.setAccessibilityIdentifier("mongo.showFields")
        showFields.setAccessibilityLabel("Show fields")
        showFields.controlSize = .small
        showFields.font = .systemFont(ofSize: 12)
        for control in [addSort, ignoreCase] { control.controlSize = .small; control.font = .systemFont(ofSize: 12) }
        addSort.bezelStyle = .recessed
        sortRows.spacing = Spacing.half
        shellLine.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        shellLine.isSelectable = true
        shellLine.setAccessibilityIdentifier("mongo.shellLine")
        shellLine.setAccessibilityLabel("The query in shell form")
        textNote.setAccessibilityIdentifier("mongo.textNote")
        let ground = SurfaceView(.bar)
        addSubview(ground)
        ground.pin(to: self)
        layoutParts()
        readText(force: true)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The fields as typed. Setting them puts the builder in step.
    var query: MongoQueryText {
        get {
            MongoQueryText(filter: filter.stringValue, projection: projection.stringValue, sort: sort.stringValue, limit: limit.stringValue,
                           skip: skip.stringValue, collation: collation.stringValue, hint: hint.stringValue, maxTimeMS: maxTime.stringValue)
        }
        set {
            filter.stringValue = newValue.filter
            projection.stringValue = newValue.projection
            sort.stringValue = newValue.sort
            limit.stringValue = newValue.limit
            skip.stringValue = newValue.skip
            collation.stringValue = newValue.collation
            hint.stringValue = newValue.hint
            maxTime.stringValue = newValue.maxTimeMS
            readText()
        }
    }

    var busy = false {
        didSet { if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) } }
    }

    /// Says what's wrong with a field under the fields, and puts the keyboard there; nil clears it.
    func show(_ problem: MongoQueryText.Problem?) {
        guard let problem else {
            self.problem.stringValue = ""
            self.problem.isHidden = true
            return
        }
        show(field: problem.field, problem.message)
    }

    func show(field name: String, _ message: String) {
        problem.stringValue = "\(name): \(message)"
        problem.isHidden = false
        guard let field = fields.first(where: { $0.name == name })?.field, field.superview != nil else { return }
        window?.makeFirstResponder(field)
    }

    @objc private func returnPressed(_ sender: Any?) { onRun?() }

    // MARK: Autofill

    /// What a field's text is; nil: a number, without autofill.
    func root(of control: NSControl) -> MongoCaret.Root? {
        [(filter, MongoCaret.Root.filter), (projection, .projection), (sort, .sort), (collation, .collation), (hint, .hint)]
            .first { $0.0 === control }?.1
    }

    private func completer(_ control: NSControl) -> MongoAutofill.Complete? {
        guard let root = root(of: control), let complete else { return nil }
        return { complete(root, $0, $1) }
    }

    func controlTextDidChange(_ notification: Notification) {
        if let control = notification.object as? NSControl { textEdited(control) }
        guard let control = notification.object as? NSControl, let complete = completer(control),
              let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
        autofill.textChanged(editor, complete)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let complete = completer(control) else { return false }
        return autofill.command(selector, in: textView, complete)
    }

    func textEdited(_ control: NSControl) {
        if mode == .builder, fields.contains(where: { $0.field === control }) { updateShellLine() }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        autofill.close()
        // A part shown as text, fixed or cleared, can go back to the builder.
        if mode == .builder { readText() }
    }
}

// MARK: Builder (lane P5-query)

extension MongoQueryBar: NSMenuDelegate {
    /// Builder or Shell; switching never changes the text, the builder only reads it again.
    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        modeSwitch.selectedSegment = mode.rawValue
        if mode == .builder { readText(force: true) } else { layoutParts() }
    }

    @objc private func modeSwitched(_ sender: NSSegmentedControl) { setMode(Mode(rawValue: sender.selectedSegment) ?? .builder) }

    /// The sample (and the loaded columns) the builder offers fields, types and values from.
    func use(_ schema: MongoSchema?, paths: [String]) {
        if let schema { conditions.schema = schema }
        conditions.paths = paths
        for case let row as SortRowView in sortRows.arrangedSubviews { row.offer(conditions.fieldPaths) }
    }

    /// Why Run can't run what the builder shows: a condition that is wrong.
    var builderProblem: String? {
        mode == .builder && !asText.contains("Filter") ? conditions.problem : nil
    }

    /// Reads the text into the builder: each part whose text changed since (all, `force`); a part it can't read shows
    /// its text field instead.
    func readText(force: Bool = false) {
        let now = query
        var text = asText
        func document(_ s: String) -> BSONDocument?? {
            let s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return .some(nil) }
            return (try? BSONDocument(shellForm: s)).map { .some($0) }
        }
        func mark(_ part: String, _ readable: Bool) { if readable { text.remove(part) } else { text.insert(part) } }
        if force || now.filter != read.filter {
            let group: MongoBuilder.Group?
            switch document(now.filter) {
            case nil: group = nil
            case .some(nil): group = MongoBuilder.Group()
            case .some(let filter?): group = MongoBuilder.Group(filter: filter)
            }
            if let group { conditions.group = group }
            mark("Filter", group != nil)
        }
        if force || now.projection != read.projection {
            let projection = document(now.projection).flatMap { Projection(document: $0) }
            if let projection { shown = projection }
            mark("Project", projection != nil)
            updateShowTitle()
        }
        if force || now.sort != read.sort {
            let keys = document(now.sort).flatMap { MongoBuilder.sortKeys($0) }
            if let keys { setSortRows(keys) }
            mark("Sort", keys != nil)
        }
        if force || now.collation != read.collation {
            let on = document(now.collation).flatMap { MongoBuilder.ignoresCase($0) }
            if let on { ignoreCase.state = on ? .on : .off }
            mark("Collation", on != nil)
        }
        read = now
        if force || text != asText {
            asText = text
            if mode == .builder || force { layoutParts() }
        }
        updateShellLine()
    }

    /// The rows for the mode: Shell's three as they always were; the builder's conditions, then Show, Sort, Skip, Limit
    /// and Ignore case, then the query in shell form. A part the builder can't read shows its own text field.
    func layoutParts() {
        func named(_ field: NSTextField, _ text: String) -> [NSView] {
            let name = label(text, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
            field.setAccessibilityTitleUIElement(name)
            return [name, field]
        }
        func row(_ views: [NSView]) -> NSStackView {
            let row = NSStackView(views: views)
            row.spacing = Spacing.unit
            return row
        }
        subviews.filter { $0 is NSStackView }.forEach { $0.removeFromSuperview() }
        var rows: [NSView]
        var equalWidths: [(NSView, NSView)] = []
        if mode == .shell {
            rows = [row([modeSwitch] + named(filter, "Filter") + [run, spinner, history, aggregate]),
                    row(named(projection, "Project") + named(sort, "Sort") + named(skip, "Skip") + named(limit, "Limit")),
                    row(named(collation, "Collation") + named(hint, "Hint") + named(maxTime, "Max Time")
                        + [label("ms", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)])]
            equalWidths = [(projection, sort), (collation, hint)]
        } else {
            let where_: [NSView] = asText.contains("Filter") ? named(filter, "Filter") : [conditions]
            let first = row([modeSwitch] + where_ + [run, spinner, history, aggregate])
            first.alignment = .top
            let show: [NSView] = asText.contains("Project") ? named(projection, "Show") : named2(showFields, "Show")
            let order: [NSView] = asText.contains("Sort") ? named(sort, "Sort by") : [label("Sort by", font: .systemFont(ofSize: 12), color: .secondaryLabelColor), sortRows, addSort]
            let caseControl: [NSView] = asText.contains("Collation") ? named(collation, "Collation") : [ignoreCase]
            let second = row(show + order + named(skip, "Skip") + named(limit, "Limit") + caseControl + [NSView()])
            textNote.stringValue = asText.isEmpty ? "" : "Shown as text, as the builder can't show it: "
                + ["Filter", "Project", "Sort", "Collation"].filter(asText.contains).joined(separator: ", ")
                + ". Fix or clear the text to build it here, or switch to Shell."
            textNote.isHidden = asText.isEmpty
            rows = [first, second, shellLine, textNote]
        }
        let stack = NSStackView(views: rows + [problem])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: Spacing.double, bottom: 8, right: Spacing.double)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Spacing.double).isActive = true
        }
        for (a, b) in equalWidths { a.widthAnchor.constraint(equalTo: b.widthAnchor).isActive = true }
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        addSubview(stack)
        stack.pin(to: self)
        conditions.resize()
    }

    private func named2(_ control: NSControl, _ text: String) -> [NSView] {
        let name = label(text, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        control.setAccessibilityTitleUIElement(name)
        return [name, control]
    }

    // MARK: Writing the text

    /// A part's text from the builder; only that field changes.
    private func write(_ field: NSTextField, _ document: BSONDocument?) {
        field.stringValue = document.map { $0.fields.isEmpty ? "" : $0.shellForm() } ?? ""
        read = query
        updateShellLine()
    }

    private func conditionsChanged() {
        // A wrong row leaves the text as it was; Run then says what's wrong.
        guard conditions.problem == nil, let filter = try? conditions.group.filter() else { return updateShellLine() }
        write(self.filter, filter)
    }

    @objc private func ignoreCaseChanged(_ sender: Any?) {
        write(collation, ignoreCase.state == .on ? MongoBuilder.ignoreCaseCollation : nil)
    }

    // MARK: Show fields

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: showTitle, action: nil, keyEquivalent: "")
        func add(_ title: String, _ on: Bool, tip: String, object: String?) {
            let item = NSMenuItem(title: title, action: #selector(showFieldChosen(_:)), keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            item.toolTip = tip
            item.representedObject = object
            menu.addItem(item)
        }
        add("All Fields", shown.paths.isEmpty && shown.includeId, tip: "Show every field (SELECT *)", object: nil)
        menu.addItem(.separator())
        add("_id", shown.includeId, tip: "Show or leave out each document's _id", object: "_id")
        for path in conditions.fieldPaths where path != "_id" {
            add(path, shown.paths.contains(path), tip: "Show or leave out \(path)", object: path)
        }
        for path in shown.paths where !conditions.fieldPaths.contains(path) {
            add(path, true, tip: "Leave out \(path)", object: path)
        }
    }

    @objc private func showFieldChosen(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case nil: shown = Projection()
        case "_id"?: shown.includeId.toggle()
        case let path?:
            if let index = shown.paths.firstIndex(of: path) { shown.paths.remove(at: index) } else { shown.paths.append(path) }
        }
        if shown.paths.isEmpty, !shown.includeId { shown.includeId = true }  // `{ _id: 0 }` alone shows the rest: not a tick
        updateShowTitle()
        write(projection, shown.document)
    }

    private var showTitle: String {
        if shown.paths.isEmpty { return shown.includeId ? "All fields" : "All but _id" }
        let names = (shown.includeId ? ["_id"] : []) + shown.paths
        return names.count > 3 ? names.prefix(3).joined(separator: ", ") + " +\(names.count - 3)" : names.joined(separator: ", ")
    }

    private func updateShowTitle() {
        showFields.item(at: 0)?.title = showTitle
        showFields.synchronizeTitleAndSelectedItem()
    }

    // MARK: Sort rows

    private func setSortRows(_ keys: [MongoBuilder.SortKey]) {
        sortRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for key in keys { sortRows.addArrangedSubview(sortRow(key)) }
    }

    private func sortRow(_ key: MongoBuilder.SortKey?) -> SortRowView {
        let row = SortRowView(key, paths: conditions.fieldPaths)
        row.onChange = { [weak self] in self?.sortChanged() }
        return row
    }

    @objc private func addSortRow(_ sender: Any?) {
        let row = sortRow(nil)
        sortRows.addArrangedSubview(row)
        window?.makeFirstResponder(row.field)
    }

    private func sortChanged() {
        let keys = sortRows.arrangedSubviews.compactMap { ($0 as? SortRowView)?.key }
        write(sort, MongoBuilder.sortDocument(keys))
    }

    // MARK: The shell line

    func updateShellLine() {
        let line = Self.shellLine(query, collection: collection)
        shellLine.stringValue = line
        shellLine.toolTip = line
    }

    /// `db.coll.find({…}, {…}).sort({…}).skip(n).limit(n).collation({…}).hint(…).maxTimeMS(n)`, the parts set only.
    static func shellLine(_ query: MongoQueryText, collection: String) -> String {
        func flat(_ s: String) -> String {
            s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        let plain = collection.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil
        var line = "db." + (plain ? collection : "getCollection(\(BSONValue.string(collection).shellForm()))")
        line += ".find(" + (flat(query.filter).isEmpty ? "{}" : flat(query.filter))
            + (flat(query.projection).isEmpty ? "" : ", " + flat(query.projection)) + ")"
        let hint = flat(query.hint)
        let quotedHint = hint.isEmpty || hint.hasPrefix("{") || hint.hasPrefix("\"") || hint.hasPrefix("'") ? hint
            : BSONValue.string(hint).shellForm()
        for (name, value) in [("sort", flat(query.sort)), ("skip", flat(query.skip)), ("limit", flat(query.limit)),
                              ("collation", flat(query.collation)), ("hint", quotedHint), ("maxTimeMS", flat(query.maxTimeMS))]
        where !value.isEmpty {
            line += ".\(name)(\(value))"
        }
        return line
    }
}

/// A Sort row: the field, Ascending or Descending, remove.
@MainActor
final class SortRowView: NSStackView, NSComboBoxDelegate {
    let field = NSComboBox()
    let direction = popup(["Ascending — ASC", "Descending — DESC"], selected: 0, id: "mongo.sort.direction",
                          tip: "Choose smallest first (ASC) or largest first (DESC)", target: nil, action: nil)
    var onChange: (() -> Void)?

    init(_ key: MongoBuilder.SortKey?, paths: [String]) {
        super.init(frame: .zero)
        spacing = 2
        translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.controlSize = .small
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.completes = false
        field.placeholderString = "field"
        field.toolTip = "Type or choose the field to sort by"
        field.setAccessibilityLabel("Sort field")
        field.setAccessibilityIdentifier("mongo.sort.field")
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 120).isActive = true
        direction.controlSize = .small
        direction.font = .systemFont(ofSize: 12)
        direction.setAccessibilityLabel("Sort direction")
        direction.target = self
        direction.action = #selector(edited(_:))
        let remove = removeButton(tip: "Stop sorting by this field", id: "mongo.sort.remove")
        remove.target = self
        remove.action = #selector(removeSelf(_:))
        for view in [field, direction, remove] as [NSView] { addArrangedSubview(view) }
        offer(paths)
        if let key {
            field.stringValue = key.path
            direction.selectItem(at: key.ascending ? 0 : 1)
        }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    var key: MongoBuilder.SortKey? {
        let path = field.stringValue.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : MongoBuilder.SortKey(path, ascending: direction.indexOfSelectedItem == 0)
    }

    func offer(_ paths: [String]) {
        field.removeAllItems()
        field.addItems(withObjectValues: paths)
    }

    @objc private func edited(_ sender: Any?) { onChange?() }

    @objc private func removeSelf(_ sender: Any?) {
        let changed = onChange
        removeFromSuperview()
        changed?()
    }

    func controlTextDidChange(_ notification: Notification) { onChange?() }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }
}
