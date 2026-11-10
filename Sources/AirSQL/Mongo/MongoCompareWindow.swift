import AirSQLCore
import AppKit

/// The MongoDB compare window (mongo-plan, Phase 2 compare), in the compare window's look: two collections, on one
/// connection or two, compared by `_id` (`MongoCompare`); the differences listed with status chips, one pair of
/// documents side by side with what differs marked, the indexes and options apart; Reconcile makes the target match
/// through the Apply sheet and `MongoApply`, never on its own.
@MainActor
final class MongoCompareWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation,
    NSTableViewDataSource, NSTableViewDelegate {
    nonisolated static let defaultSize = NSSize(width: 1240, height: 780)
    private static var open: [MongoCompareWindowController] = []

    let model: AppModel
    let source = MongoCompareSidePicker("Source"), target = MongoCompareSidePicker("Target")
    private(set) var result: MongoCompareResult?
    /// The target's connection and collection as compared: Reconcile writes there, whatever the pickers say by then.
    private(set) var compared: (saved: SavedConnection, database: String, collection: String)?
    private var task: Task<Void, Never>?
    /// Reconcile's run, while it lasts.
    var reconciling: Task<Void, Never>?
    private var activity: Activity?
    /// Each side's session of its own, closed with the window.
    private var sessions: [(MongoConnection, String)] = []
    let slot = "compare-" + UUID().uuidString.prefix(8)

    let ignoreKeyOrder = checkbox("Ignore Key Order", id: "mongoCompare.keyOrder",
                                  tip: "Count documents with the same fields in another order as the same", on: false, target: nil, action: nil)
    let ignoredFields = textField("", placeholder: "Ignore fields, such as updatedAt", id: "mongoCompare.ignore",
                                  tip: "Leave these fields (dotted paths, separated by commas) out of the compare", width: 260)
    private(set) lazy var compareButton = button("Compare", id: "mongoCompare.run", tip: "Compare the two collections (⌘R)",
                                                 target: self, action: #selector(refresh(_:)), primary: true)
    let inserts = checkbox("Insert Missing", id: "mongoCompare.inserts", tip: "Reconcile inserts the documents only in the source",
                           on: true, target: nil, action: nil)
    let replaces = checkbox("Replace Different", id: "mongoCompare.replaces",
                            tip: "Reconcile puts the source's document in place of each that differs", on: true, target: nil, action: nil)
    let deletes = checkbox("Delete Extra", id: "mongoCompare.deletes",
                           tip: "Destructive: Reconcile deletes the documents only in the target", on: false, target: nil, action: nil)
    private(set) lazy var reconcileButton = button("Reconcile…", id: "mongoCompare.reconcile", tip: Commands.reconcileCollection.tip,
                                                   target: self, action: #selector(reconcile(_:)))
    let progress = NSProgressIndicator()
    let progressLabel = label("", color: .secondaryLabelColor, truncates: true)
    private(set) lazy var cancelButton = button("Cancel", id: "mongoCompare.cancel", tip: "Stop the compare (⌘.)", target: self,
                                                action: #selector(cancelQuery(_:)))
    /// Which statuses the list shows: only in source, only in target, different, same (off at first).
    let chips = NSSegmentedControl(labels: ["Only in Source", "Only in Target", "Different", "Same"], trackingMode: .selectAny,
                                   target: nil, action: nil)
    /// Holds the two pages, one shown at a time.
    let tabs = NSView()
    /// Documents, or Indexes and Options: the page `tabs` shows.
    let pages = NSSegmentedControl(labels: ["Documents", "Indexes and Options"], trackingMode: .selectOne, target: nil, action: nil)
    let list = NSTableView(), indexList = NSTableView()
    let summary = label("Choose two collections, then Compare", color: .secondaryLabelColor, truncates: true)
    let pathsLabel = label("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor, truncates: true)
    let sourceText = NSTextView(), targetText = NSTextView(), optionsText = NSTextView()
    /// The listed items, as the chips filter them.
    private(set) var shown: [MongoCompareResult.Item] = []

    @discardableResult
    static func show(model: AppModel, source: (SavedConnection, String, String)? = nil) -> MongoCompareWindowController {
        let controller = MongoCompareWindowController(model: model)
        if let (saved, database, collection) = source {
            controller.source.choose(saved, database: database, collection: collection)
            controller.target.choose(saved, database: database, collection: "")
            controller.window?.makeFirstResponder(controller.target.collection)
        }
        controller.showWindow(nil)
        return controller
    }

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 1200, height: 600)
        window.isReleasedWhenClosed = false
        window.title = "Compare Collections"
        window.backgroundColor = .ground
        window.tabbingMode = .disallowed
        window.autorecalculatesKeyViewLoop = true
        super.init(window: window)
        window.delegate = self
        let connections = model.data.connections.filter { $0.engine == .mongodb }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        for picker in [source, target] {
            picker.model = model
            picker.connections = connections
            picker.changed = { [weak self] in self?.update() }
        }
        window.contentView = makeContent()
        window.initialFirstResponder = source.popup
        window.open(size: Self.defaultSize, autosave: layoutName("Mongo Compare"))
        Self.open.append(self)
        show(nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeContent() -> NSView {
        let swap = button("Swap", id: "mongoCompare.swap", tip: "Swap source and target", target: self, action: #selector(swapSides(_:)))
        let arrow = label("→", font: .systemFont(ofSize: 15, weight: .medium), color: .secondaryLabelColor)
        arrow.toolTip = "Reconcile makes the target (right) match the source (left)"
        let sides = NSStackView(views: [source.view, arrow, target.view, swap])
        sides.spacing = Spacing.double
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        cancelButton.controlSize = .small
        cancelButton.isHidden = true
        deletes.contentTintColor = .statusBad
        for box in [ignoreKeyOrder, inserts, replaces, deletes] {
            box.target = self
            box.action = #selector(optionChanged(_:))
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let options = NSStackView(views: [compareButton, ignoreKeyOrder, ignoredFields, progress, progressLabel, cancelButton, spacer,
                                          inserts, replaces, deletes, reconcileButton])
        options.spacing = Spacing.unit + 4
        let top = NSStackView(views: [sides, options])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = Spacing.unit
        top.edgeInsets = NSEdgeInsets(top: Spacing.unit, left: Spacing.double, bottom: Spacing.unit, right: Spacing.double)
        options.widthAnchor.constraint(equalTo: top.widthAnchor, constant: -2 * Spacing.double).isActive = true
        let bar = SurfaceView(.bar)
        bar.addSubview(top)
        top.pin(to: bar)

        chips.target = self
        chips.action = #selector(chipsChanged(_:))
        chips.setAccessibilityIdentifier("mongoCompare.chips")
        chips.toolTip = "Show or hide the documents of each status"
        for segment in 0..<3 { chips.setSelected(true, forSegment: segment) }
        pages.selectedSegment = 0
        pages.target = self
        pages.action = #selector(pageChosen(_:))
        pages.setAccessibilityIdentifier("mongoCompare.pages")
        pages.toolTip = "Show the documents that differ, or the two collections' indexes and options"
        pages.setContentCompressionResistancePriority(.required, for: .horizontal)
        chips.setContentCompressionResistancePriority(.required, for: .horizontal)
        let chipBar = NSStackView(views: [chips, summary, pages])
        chipBar.spacing = Spacing.double
        chipBar.alignment = .centerY
        chipBar.edgeInsets = NSEdgeInsets(top: Spacing.unit, left: Spacing.double, bottom: Spacing.unit, right: Spacing.double)

        setUp(list, id: "mongoCompare.list", columns: [("status", "Status", 110), ("id", "_id", 220), ("paths", "Differs At", 200)])
        setUp(indexList, id: "mongoCompare.indexes",
              columns: [("status", "Status", 110), ("keys", "Keys", 220), ("source", "Source", 260), ("target", "Target", 260), ("paths", "Differs At", 160)])
        let documents = NSSplitView()
        documents.isVertical = true
        documents.dividerStyle = .thin
        documents.addArrangedSubview(scrolled(list))
        let texts = NSStackView(views: [column("Source", sourceText), column("Target", targetText)])
        texts.distribution = .fillEqually
        texts.spacing = Spacing.unit
        let detail = NSStackView(views: [pathsLabel, texts])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = Spacing.unit
        detail.edgeInsets = NSEdgeInsets(top: Spacing.unit, left: Spacing.unit, bottom: Spacing.unit, right: Spacing.unit)
        texts.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -2 * Spacing.unit).isActive = true
        documents.addArrangedSubview(detail)
        documents.arrangedSubviews[0].widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
        let optionsColumn = column("Options (validator, collation…)", optionsText)
        let structure = NSStackView(views: [scrolled(indexList), optionsColumn])
        structure.orientation = .vertical
        structure.spacing = Spacing.unit
        structure.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: Spacing.unit, right: 0)
        optionsColumn.heightAnchor.constraint(equalToConstant: 200).isActive = true
        for view in structure.arrangedSubviews { view.widthAnchor.constraint(equalTo: structure.widthAnchor).isActive = true }
        (optionsColumn as? NSStackView)?.edgeInsets = NSEdgeInsets(top: 0, left: Spacing.unit, bottom: 0, right: Spacing.unit)
        for page in [documents, structure] as [NSView] {
            tabs.addSubview(page)
            page.pin(to: tabs)
        }
        structure.isHidden = true

        let stack = NSStackView(views: [bar, ReconWindowController.line(), chipBar, tabs])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        // The bars keep their height; the page takes the rest.
        top.setHuggingPriority(.required, for: .vertical)
        chipBar.setHuggingPriority(.required, for: .vertical)
        tabs.setContentHuggingPriority(.init(1), for: .vertical)
        let root = SurfaceView(.ground)
        root.addSubview(stack)
        stack.pin(to: root)
        return root
    }

    private func setUp(_ table: NSTableView, id: String, columns: [(String, String, CGFloat)]) {
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.rowHeight = 22
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier(id)
    }

    private func scrolled(_ view: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = view is NSTextView ? false : true
        scroll.borderType = view is NSTextView ? .bezelBorder : .noBorder
        return scroll
    }

    /// A text view under its title, for a document or the options.
    private func column(_ title: String, _ text: NSTextView) -> NSView {
        text.isEditable = false
        text.isRichText = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.setAccessibilityLabel(title)
        let stack = NSStackView(views: [label(title, font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor), scrolled(text)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.half
        stack.arrangedSubviews[1].widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    // MARK: Comparing

    var isRunning: Bool { task != nil || reconciling != nil }

    /// Why Compare can't start, or nil when it can.
    var compareBlocked: String? {
        if isRunning { return "A compare is running: wait for it, or Cancel it" }
        guard let left = source.connection, let right = target.connection else { return "Choose a MongoDB connection on each side first" }
        if source.databaseName.isEmpty || target.databaseName.isEmpty { return "Choose a database on each side first" }
        if source.collectionName.isEmpty || target.collectionName.isEmpty { return "Choose a collection on each side first" }
        if left.id == right.id, source.databaseName == target.databaseName, source.collectionName == target.collectionName {
            return "Choose two different collections: these are the same one"
        }
        return nil
    }

    var options: MongoCompareOptions {
        MongoCompareOptions(ignoreKeyOrder: ignoreKeyOrder.state == .on, ignoredPaths: MongoCompareOptions.paths(ignoredFields.stringValue))
    }

    /// Compare (⌘R): both sides connected first when they aren't, then read on sessions of the window's own.
    @objc func refresh(_ sender: Any?) {
        guard compareBlocked == nil, let left = source.connection, let right = target.connection else { return NSSound.beep() }
        let (a, b) = ((left, source.databaseName, source.collectionName), (right, target.databaseName, target.collectionName))
        let options = self.options, window = self.window, model = self.model, slot = self.slot
        activity = model.activity.start("Comparing \(a.1).\(a.2) with \(b.1).\(b.2)", connection: right.id) { [weak self] in self?.cancelQuery(nil) }
        progressLabel.stringValue = "Connecting…"
        progress.startAnimation(nil)
        cancelButton.isHidden = false
        task = Task { [weak self] in
            let outcome: Result<MongoCompareResult, Error>
            do {
                let first = try await MongoCompareSidePicker.connect(a.0, model: model, on: window)
                let second = try await MongoCompareSidePicker.connect(b.0, model: model, on: window)
                let sides = try await (first.connection.session(.data, slot: slot + "-source"), second.connection.session(.data, slot: slot + "-target"))
                self?.remember(first.connection, slot + "-source")
                self?.remember(second.connection, slot + "-target")
                self?.running = [sides.0, sides.1]
                outcome = .success(try await MongoCompare.run(source: MongoCompareSide(session: sides.0, database: a.1, collection: a.2),
                                                              target: MongoCompareSide(session: sides.1, database: b.1, collection: b.2),
                                                              options: options) { step in
                    DispatchQueue.main.async { self?.show(step) }
                })
            } catch {
                outcome = .failure(error)
            }
            self?.finished(outcome, target: (b.0, b.1, b.2))
        }
        update()
    }

    /// The sessions a compare reads on, for Cancel.
    private var running: [MongoSession] = []

    private func remember(_ connection: MongoConnection, _ slot: String) {
        if !sessions.contains(where: { $0.0 === connection && $0.1 == slot }) { sessions.append((connection, slot)) }
    }

    /// Stops the compare (⌘.): the command on the wire ends on the server too.
    @objc func cancelQuery(_ sender: Any?) {
        guard isRunning else { return }
        task?.cancel()
        for session in running { Task { await session.cancel() } }
        progressLabel.stringValue = "Stopping…"
    }

    private func show(_ step: MongoCompare.Progress) {
        guard isRunning else { return }
        let text = step.total > 0 ? "\(step.step) · \(step.read.formatted()) of about \(step.total.formatted()) read" : step.step
        progressLabel.stringValue = text
        progressLabel.toolTip = text
        activity?.detail = text
        activity?.progress = step.total > 0 ? Double(step.read) / Double(step.total) : nil
    }

    private func finished(_ outcome: Result<MongoCompareResult, Error>, target: (SavedConnection, String, String)) {
        task = nil
        running = []
        activity?.end()
        activity = nil
        progress.stopAnimation(nil)
        progressLabel.stringValue = ""
        cancelButton.isHidden = true
        switch outcome {
        case .success(let result):
            compared = (target.0, target.1, target.2)
            show(result)
        case .failure(let error) where error is CancellationError || (error as? AirSQLError)?.kind == .cancelled:
            break
        case .failure(let error):
            showError(error.localizedDescription, title: "The compare stopped with an error", on: window)
        }
        update()
    }

    /// Shows a result (tests and screenshots give one directly).
    func show(_ result: MongoCompareResult?) {
        self.result = result
        if let result {
            let names: [(MongoCompareResult.Status, String)] = [(.onlyInSource, "Only in Source"), (.onlyInTarget, "Only in Target"),
                                                                (.different, "Different"), (.same, "Same")]
            for (segment, (status, name)) in names.enumerated() {
                chips.setLabel("\(name) \(result.count(status).formatted())", forSegment: segment)
            }
            let structure = result.indexes.filter { $0.status != .same }.count + (result.optionPaths.isEmpty ? 0 : 1)
            summary.stringValue = (result.differs ? "" : "The two match. ")
                + (result.merged ? "Merged in _id order" : "Looked up by _id (the _ids are of several types)")
                + " in \(ActivityPopover.elapsed(result.duration))"
                + (structure > 0 ? " · indexes or options differ: see Indexes and Options" : "")
                + (result.truncated ? " · the first \(MongoCompare.keep.formatted()) differences are listed: reconcile them, then compare again" : "")
            summary.textColor = result.truncated ? .statusWarning : .secondaryLabelColor
        }
        chips.sizeToFit()
        arrange()
        indexList.reloadData()
        optionsText.textStorage?.setAttributedString(optionsDescription(result))
        update()
    }

    @objc private func chipsChanged(_ sender: Any?) { arrange() }

    @objc private func pageChosen(_ sender: Any?) { showPage(pages.selectedSegment) }

    /// Shows Documents (0) or Indexes and Options (1).
    func showPage(_ page: Int) {
        pages.selectedSegment = page
        for (index, view) in tabs.subviews.enumerated() { view.isHidden = index != page }
    }

    @objc private func optionChanged(_ sender: Any?) { update() }

    /// The items the chips keep; the first is shown.
    private func arrange() {
        let wanted = MongoCompareResult.Status.allCases.enumerated().filter { chips.isSelected(forSegment: $0.offset) }.map(\.element)
        let items = result?.items ?? []
        shown = items.filter { wanted.contains($0.status) }
        if wanted.contains(.same) { shown += (result?.same ?? []).map { MongoCompareResult.Item(id: $0, status: .same) } }
        list.reloadData()
        if !shown.isEmpty { list.selectRowIndexes([0], byExtendingSelection: false) }
        showDetail()
    }

    @objc func swapSides(_ sender: Any?) {
        let (connection, database, collection) = (source.connection, source.databaseName, source.collectionName)
        source.choose(target.connection, database: target.databaseName, collection: target.collectionName)
        target.choose(connection, database: database, collection: collection)
        update()
    }

    func update() {
        compareButton.isEnabled = compareBlocked == nil
        compareButton.toolTip = compareBlocked ?? "Compare the two collections (⌘R)"
        let blocked = reconcileBlocked
        reconcileButton.isEnabled = blocked == nil
        reconcileButton.toolTip = blocked ?? Commands.reconcileCollection.tip
        let text = [source, target].allSatisfy { !$0.summary.isEmpty } ? "Compare \(source.summary) with \(target.summary)" : "Compare Collections"
        window?.title = text
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        let sessions = self.sessions
        Task { for (connection, slot) in sessions { await connection.closeSession(.data, slot: slot) } }
        Self.open.removeAll { $0 === self }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let reason: String?
        switch item.action {
        case #selector(refresh(_:)): reason = compareBlocked
        case #selector(cancelQuery(_:)): reason = isRunning ? nil : "No compare is running"
        case #selector(reconcile(_:)): reason = reconcileBlocked
        default: return true
        }
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }

    // MARK: The lists

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === list ? shown.count : result?.indexes.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let column = tableColumn?.identifier.rawValue ?? ""
        let status: MongoCompareResult.Status, text: String
        if tableView === list {
            let item = shown[row]
            status = item.status
            text = column == "id" ? item.id.shellForm(maxLength: 200) : item.paths.map(Self.pathName).joined(separator: ", ")
        } else {
            guard let index = result?.indexes[row] else { return nil }
            status = index.status
            func spec(_ spec: BSONDocument?) -> String {
                guard let spec else { return "—" }
                let name = spec["name"].map { if case .string(let s) = $0 { return s } else { return $0.shellForm() } } ?? ""
                return ([name] + MongoIndex(spec: spec).options).joined(separator: ", ")
            }
            switch column {
            case "keys": text = index.keys.shellForm()
            case "source": text = spec(index.source)
            case "target": text = spec(index.target)
            default: text = index.paths.joined(separator: ", ")
            }
        }
        if column == "status" {
            let (words, style) = Self.chip(status)
            let chip = ChipView(words, style: style)
            let cell = NSView()
            cell.addSubview(chip)
            NSLayoutConstraint.activate([chip.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                                         chip.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            cell.setAccessibilityElement(true)
            cell.setAccessibilityLabel(words)
            return cell
        }
        let cell = NSTableCellView()
        let field = label(text, font: column == "paths" ? .systemFont(ofSize: 12) : .monospacedSystemFont(ofSize: 11.5, weight: .regular),
                          truncates: true)
        field.toolTip = text
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                                     field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                                     field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === list { showDetail() }
    }

    static func chip(_ status: MongoCompareResult.Status) -> (String, ChipView.Style) {
        switch status {
        case .onlyInSource: return ("only source", .tinted(.statusBad))
        case .onlyInTarget: return ("only target", .tinted(.statusBad))
        case .different: return ("different", .tinted(.statusWarning))
        case .same: return ("same", .tinted(.statusOK))
        }
    }

    /// A differing path as the list says it: "" is the document's own field order.
    static func pathName(_ path: String) -> String { path.isEmpty ? "(field order)" : path }

    /// The selected pair side by side, the lines of what differs marked.
    private func showDetail() {
        let row = list.selectedRow
        guard row >= 0, row < shown.count else {
            pathsLabel.stringValue = result == nil ? "Choose two collections, then Compare: what differs lists here" : "Select a document in the list"
            for text in [sourceText, targetText] { text.string = "" }
            return
        }
        let item = shown[row]
        switch item.status {
        case .different: pathsLabel.stringValue = "Differs at " + item.paths.map(Self.pathName).joined(separator: ", ")
        case .onlyInSource: pathsLabel.stringValue = "Only in the source: Reconcile inserts it"
        case .onlyInTarget: pathsLabel.stringValue = "Only in the target: Reconcile deletes it when Delete Extra is ticked"
        case .same: pathsLabel.stringValue = "The same in both" + (options.ignoredPaths.isEmpty && !options.ignoreKeyOrder ? "" : ", as the compare's options see them")
        }
        pathsLabel.toolTip = pathsLabel.stringValue
        sourceText.textStorage?.setAttributedString(Self.render(item.source, marking: item.paths, missing: item.status == .same ? "Not kept: the same as the target's" : "Not in the source"))
        targetText.textStorage?.setAttributedString(Self.render(item.target, marking: item.paths, missing: item.status == .same ? "Not kept: the same as the source's" : "Not in the target"))
    }

    /// A document, one field per line, the lines at or under a differing path on a warning tint.
    static func render(_ document: BSONDocument?, marking paths: [String], missing: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        guard let document else {
            return NSAttributedString(string: missing, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        }
        func line(_ text: String, _ path: [BSONPathSegment]) {
            let dotted = path.dotted
            let marked = paths.contains { $0 == dotted || (!$0.isEmpty && dotted.hasPrefix($0 + ".")) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if marked { attributes[.backgroundColor] = NSColor.statusWarning.withAlphaComponent(0.22) }
            out.append(NSAttributedString(string: text + "\n", attributes: attributes))
        }
        func key(_ key: String) -> String { String(BSONDocument([(key, .int32(0))]).shellForm().dropFirst(2).dropLast(5)) + ": " }
        func emit(_ prefix: String, _ item: BSONValue, _ path: [BSONPathSegment], _ indent: String, _ comma: String) {
            switch item {
            case .document(let inner) where !inner.fields.isEmpty:
                line(indent + prefix + "{", path)
                for (n, field) in inner.fields.enumerated() {
                    emit(key(field.key), field.value, path + [.key(field.key)], indent + "  ", n < inner.fields.count - 1 ? "," : "")
                }
                line(indent + "}" + comma, path)
            case .array(let values) where !values.isEmpty:
                line(indent + prefix + "[", path)
                for (n, element) in values.enumerated() {
                    emit("", element, path + [.index(n)], indent + "  ", n < values.count - 1 ? "," : "")
                }
                line(indent + "]" + comma, path)
            default:
                line(indent + prefix + item.shellForm(maxLength: 2_000) + comma, path)
            }
        }
        // The top level's own path is "": marked only when its field order differs.
        line("{", [])
        for (n, field) in document.fields.enumerated() {
            emit(key(field.key), field.value, [.key(field.key)], "  ", n < document.fields.count - 1 ? "," : "")
        }
        out.append(NSAttributedString(string: "}", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        return out
    }

    private func optionsDescription(_ result: MongoCompareResult?) -> NSAttributedString {
        guard let result else { return NSAttributedString() }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let out = NSMutableAttributedString()
        func add(_ text: String, color: NSColor = .labelColor) {
            out.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        guard let targetOptions = result.targetOptions else {
            add("The target collection doesn't exist yet: Reconcile's inserts make it, without the source's options and indexes.", color: .statusWarning)
            return out
        }
        if result.optionPaths.isEmpty { add("The options are the same.", color: .secondaryLabelColor) }
        // Each option that differs whole on each side, with where inside it.
        var options: [String] = []
        for path in result.optionPaths {
            let option = String(path.prefix { $0 != "." })
            if !options.contains(option) { options.append(option) }
        }
        for option in options {
            let inside = result.optionPaths.filter { $0.hasPrefix(option + ".") }
            add(option.isEmpty ? "(field order)" : option + (inside.isEmpty ? "" : " (differs at \(inside.joined(separator: ", ")))"), color: .statusWarning)
            guard !option.isEmpty else { continue }
            add("  source: " + (result.sourceOptions?[option]?.shellForm(maxLength: 2_000) ?? "not set"))
            add("  target: " + (targetOptions[option]?.shellForm(maxLength: 2_000) ?? "not set"))
        }
        return out
    }
}
