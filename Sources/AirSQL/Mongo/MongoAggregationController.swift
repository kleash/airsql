import AirSQLCore
import AppKit

/// A collection's aggregation in a tab (mongo-plan, Aggregation): the pipeline in shell form in the console's editor,
/// one fold per stage and a syntax error underlined where `MongoPipeline` finds it, over its documents in the grid
/// (`MongoDocumentSource` over the aggregate cursor, a byte-bounded batch at a time) or its plan (Explain, which runs it).
/// The tab has a data session of its own, closed with the tab, so its Cancel ends only its own work.
@MainActor
final class MongoAggregationController: NSViewController, TabContent, DataGridViewDelegate, NSMenuItemValidation {
    enum Page: Int { case documents, explain }

    let model: AppModel
    let connectionID: UUID
    let database: String
    let collection: String
    let editorScroll: NSScrollView
    let editor: SQLEditorView
    let viewer = GridViewer(source: nil)
    var grid: DataGridView { viewer.grid }
    private(set) var source = MongoDocumentSource()
    let notice = TableDataNotice()
    let maxTime = textField("", placeholder: "none", id: "aggregate.maxTime",
                            tip: "Milliseconds the server may spend on the pipeline before it stops it", width: 80)
    let collation = textField("", placeholder: "{ locale: \"en\", strength: 2 }", id: "aggregate.collation",
                              tip: "How strings compare and sort: { locale: \"en\", strength: 2 } ignores case")
    let spinner = NSProgressIndicator()
    let pageSwitch = NSSegmentedControl(labels: ["Documents", "Explain"], trackingMode: .selectOne, target: nil, action: nil)
    private let split = NSSplitView()
    private let planPage = NSView()
    private(set) var explainView: MongoExplainView?
    private(set) lazy var toolbar = GridToolbar(grid: grid, groups: [
        [.init(Commands.runStatement, "play"), .init(Commands.explain, "list.bullet.indent"), .init(Commands.cancelQuery, "stop.circle")],
        GridToolbar.Item.viewItems,
    ], trailing: [.init(Commands.loadMore, "arrow.down.to.line", stays: true)])
    private lazy var moreLink: NSButton = {
        let link = GridStatusView.link("Load More", id: "aggregate.loadMore", tip: "Read the next batch of documents (\(Commands.loadMore.shortcut))",
                                       action: Commands.loadMore.action)
        link.target = self
        return link
    }()
    private(set) var page = Page.documents
    /// The tab's own session, made on first use; `sessionOf` is the connection it belongs to (a reconnect makes another).
    private var session: MongoSession?
    private weak var sessionOf: MongoConnection?
    /// Its slot among the connection's sessions (`MongoConnection.session(_:slot:)`), so a disconnect closes it too.
    private let slot = UUID().uuidString
    private var cursor: MongoCursor?
    /// The read under way (one at a time), and its line in Activity.
    private(set) var loading: Task<Void, Never>?
    private var activity: Activity?
    private var reads = 0
    /// What went wrong last, until the next read works.
    private(set) var problem: String?

    /// Stage names offered at a stage's start.
    static let stageNames = ["$addFields", "$bucket", "$bucketAuto", "$count", "$densify", "$documents", "$facet", "$fill", "$geoNear",
                             "$graphLookup", "$group", "$indexStats", "$limit", "$lookup", "$match", "$merge", "$out", "$project",
                             "$redact", "$replaceRoot", "$replaceWith", "$sample", "$set", "$setWindowFields", "$skip", "$sort",
                             "$sortByCount", "$unionWith", "$unset", "$unwind"]

    init(model: AppModel, connection: UUID, database: String, collection: String) {
        self.model = model
        connectionID = connection
        self.database = database
        self.collection = collection
        (editorScroll, editor) = SQLEditorView.make(fontSize: CGFloat(model.data.settings.editorFontSize))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var connection: MongoConnection? { model.openMongo[connectionID]?.connection }

    /// A batch: Settings ▸ Grid's rows per page, and at most 4 MB of documents.
    private var batch: Int { max(1, model.data.settings.rowsPerPage) }

    override func loadView() {
        let view = NSView()
        view.setAccessibilityIdentifier("mongoAggregation")
        editor.setAccessibilityIdentifier("aggregate.editor")
        editor.setAccessibilityLabel("Pipeline of \(collection)")
        editor.toolTip = "The pipeline in shell form: [{ $match: {…} }, { $group: {…} }]; Run (⌘↩) runs it, Explain (⌥⌘E) shows its plan"
        editor.otherLanguage = (problems: { text in
            do {
                _ = try MongoPipeline.stages(in: text)
                return []
            } catch let error as MongoPipeline.ParseError {
                return [Self.problem(error, in: text)]
            } catch { return [] }
        }, folds: Self.folds)
        editor.completions = { [weak self] text, caret in self?.completions(text, caret) ?? (caret..<caret, []) }
        editor.string = "[\n  { $match: {} }\n]\n"
        editor.onChange = { [weak self] in self?.updateBars() }
        viewer.host = self
        viewer.viewKey = GridViewer.ViewKey(connection: connectionID, database: database, table: collection)
        viewer.copyTable = (database, collection)
        viewer.whyReadOnly = { _, _ in "a pipeline's documents can't be edited: open the collection to change them" }
        viewer.toolbar = toolbar
        viewer.didPresent = { [weak self] in self?.updateBars() }
        viewer.status.insertView(moreLink, at: 1, in: .trailing)
        grid.nullText = model.data.settings.nullText
        grid.fontSize = CGFloat(model.data.settings.gridFontSize)
        grid.setAccessibilityLabel("Documents the pipeline gave")
        notice.owner = self
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Running the pipeline")
        for field in [maxTime, collation] {
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.target = self
            field.action = #selector(runStatement(_:))
        }
        collation.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pageSwitch.controlSize = .small
        pageSwitch.selectedSegmentBezelColor = .selectedSegment
        pageSwitch.selectedSegment = 0
        pageSwitch.target = self
        pageSwitch.action = #selector(pageSwitched(_:))
        pageSwitch.setToolTip("Show the documents the pipeline gave", forSegment: 0)
        pageSwitch.setToolTip("Show the plan Explain (⌥⌘E) measured", forSegment: 1)
        pageSwitch.setAccessibilityIdentifier("aggregate.page")
        toolbar.leadingView = pageSwitch

        func named(_ field: NSTextField, _ text: String) -> [NSView] {
            let name = label(text, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
            field.setAccessibilityTitleUIElement(name)
            return [name, field]
        }
        let options = NSStackView(views: named(collation, "Collation") + named(maxTime, "Max Time")
                                  + [label("ms", font: .systemFont(ofSize: 12), color: .secondaryLabelColor), spinner])
        options.spacing = Spacing.unit
        options.edgeInsets = NSEdgeInsets(top: 6, left: Spacing.double, bottom: 6, right: Spacing.double)
        options.setHuggingPriority(.defaultHigh, for: .vertical)  // a bar keeps its height; the split gets the rest
        let optionsBar = SurfaceView(.bar)
        optionsBar.translatesAutoresizingMaskIntoConstraints = false
        optionsBar.addSubview(options)
        options.pin(to: optionsBar)

        let results = NSStackView(views: [toolbar, notice, viewer])
        results.orientation = .vertical
        results.spacing = 0
        for part in results.arrangedSubviews { part.widthAnchor.constraint(equalTo: results.widthAnchor).isActive = true }
        viewer.setContentHuggingPriority(.defaultLow, for: .vertical)
        planPage.translatesAutoresizingMaskIntoConstraints = false
        planPage.isHidden = true
        let empty = MongoExplainView.note("Explain (⌥⌘E) runs the pipeline and shows how the server ran it.")
        planPage.addSubview(empty)
        empty.pin(to: planPage)
        let lower = NSView()
        lower.addSubview(results)
        results.pin(to: lower)
        lower.addSubview(planPage)
        NSLayoutConstraint.activate([
            planPage.topAnchor.constraint(equalTo: toolbar.bottomAnchor), planPage.bottomAnchor.constraint(equalTo: lower.bottomAnchor),
            planPage.leadingAnchor.constraint(equalTo: lower.leadingAnchor), planPage.trailingAnchor.constraint(equalTo: lower.trailingAnchor),
        ])

        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(editorScroll)
        split.addArrangedSubview(lower)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        editorScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        lower.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        split.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(optionsBar)
        view.addSubview(split)
        NSLayoutConstraint.activate([
            optionsBar.topAnchor.constraint(equalTo: view.topAnchor), optionsBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            optionsBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.topAnchor.constraint(equalTo: optionsBar.bottomAnchor), split.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor), split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        self.view = view
        updateBars()
        run()
    }

    private var placedDivider = false
    /// About ten lines of pipeline the first time the tab has its size; the person's drags after that.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard !placedDivider, split.bounds.height > 240 else { return }
        placedDivider = true
        // After this pass: a split moved in the middle of its own layout puts the divider back.
        DispatchQueue.main.async { [self] in split.setPosition(min(200, split.bounds.height * 0.4), ofDividerAt: 0) }
    }

    // MARK: The pipeline

    /// The stages typed and the options, or nil after saying what's wrong (the editor's caret moves to it).
    private func parsed() -> (stages: [BSONDocument], options: MongoFind)? {
        let text = editor.string
        do {
            let stages = try MongoPipeline.stages(in: text).map(\.document)
            editor.runProblem = nil
            let options = try MongoQueryText(collation: collation.stringValue, maxTimeMS: maxTime.stringValue).find()
            return (stages, options)
        } catch let error as MongoPipeline.ParseError {
            let found = Self.problem(error, in: text)
            editor.runProblem = found
            editor.setSelectedRange(NSRange(location: found.range.lowerBound, length: 0))
            view.window?.makeFirstResponder(editor)
            fail(found.message)
        } catch let error as MongoQueryText.Problem {
            fail("\(error.field): \(error.message)")
            view.window?.makeFirstResponder(error.field == "Collation" ? collation : maxTime)
        } catch {
            fail(error.localizedDescription)
        }
        return nil
    }

    /// The parser's error as the editor underlines it: the character it points at, and which stage.
    static func problem(_ error: MongoPipeline.ParseError, in text: String) -> SQLProblem {
        let length = text.utf16.count
        let start = max(0, min(error.offset, length - 1))
        let words = (error.stage.map { "Stage \($0 + 1), line " } ?? "Line ") + "\(error.line), column \(error.column): \(error.message)"
        return SQLProblem(range: start..<min(length, start + 1), message: words)
    }

    /// One fold per stage of several lines: from its first line's end to just before its closing brace.
    static func folds(_ text: String) -> [Range<Int>] {
        guard let stages = try? MongoPipeline.stages(in: text) else { return [] }
        let units = Array(text.utf16)
        return stages.compactMap { stage in
            guard let lineEnd = units[stage.range].firstIndex(of: 0x0A), lineEnd < stage.range.upperBound - 1 else { return nil }
            return lineEnd..<(stage.range.upperBound - 1)
        }
    }

    /// Stage names at a stage's start, `$`-paths in a stage's value, field names elsewhere: from the documents loaded.
    func completions(_ text: String, _ caret: Int) -> (Range<Int>, [CompletionItem]) {
        let units = Array(text.utf16)
        var start = min(caret, units.count)
        while start > 0, SQLLexer.isNameChar(units[start - 1]) || units[start - 1] == 0x2E { start -= 1 }
        let typed = String(decoding: units[start..<min(caret, units.count)], as: UTF16.self)
        var depth = 0
        for unit in units[..<start] {
            if unit == 0x7B { depth += 1 } else if unit == 0x7D { depth -= 1 }
        }
        let paths = Array(NSOrderedSet(array: source.paths.map { $0.joined(separator: ".") })) as? [String] ?? []
        let items: [CompletionItem]
        if depth <= 1 {
            items = Self.stageNames.map { CompletionItem(kind: .keyword, text: $0, label: $0, detail: "stage") }
        } else if typed.hasPrefix("$") {
            items = paths.map { CompletionItem(kind: .column, text: "$" + $0, label: "$" + $0, detail: "field") }
        } else {
            items = paths.map { CompletionItem(kind: .column, text: $0, label: $0, detail: "field") }
        }
        return (start..<caret, items.filter { $0.text.hasPrefix(typed) && $0.text != typed })
    }

    // MARK: Reading

    /// Run (⌘↩): the pipeline from its first batch.
    func run() {
        guard let (stages, options) = parsed() else { return }
        whenWritesAllowed(stages) { [self] in run(stages, options) }
    }

    /// A pipeline ending in $out or $merge writes a collection: refused on a read-only connection, otherwise run only
    /// once the person has seen it in the preview sheet, as any other change.
    private func whenWritesAllowed(_ stages: [BSONDocument], then go: @escaping () -> Void) {
        let writes = stages.compactMap { $0.keys.first }.filter { $0 == "$out" || $0 == "$merge" }
        guard let stage = writes.first else { return go() }
        guard let open = model.openMongo[connectionID], let window = view.window else { return }
        if model.connection(connectionID)?.readOnly == true {
            return fail("\(stage) writes to a collection, and this connection is read-only.")
        }
        var request = SQLPreviewRequest(
            change: ChangeSQL(title: "Run a pipeline that writes", statements: [MongoPipeline.text(stages)], connection: connectionID),
            heading: "Run a pipeline that writes with \(stage)?",
            caption: "\(stage) writes the pipeline's documents into a collection"
                + (stage == "$out" ? ", replacing everything in it." : ", merging them into it."))
        request.actionTitle = "Run"
        request.destructive = true
        request.shellCommands = true
        SQLPreviewSheet.show(request, connection: open.saved, on: window) { result in
            if result.approved { go() }
        }
    }

    private func run(_ stages: [BSONDocument], _ options: MongoFind) {
        stopReading()
        let (database, collection, batch) = (self.database, self.collection, self.batch)
        read("Running a pipeline on \(collection)") { [self] session in
            let found = try await session.aggregate(database: database, collection: collection, pipeline: stages,
                                                    maxTimeMS: options.maxTimeMS, collation: options.collation)
            let first = try await found.next(maxCount: batch)
            if Task.isCancelled { await found.close() }
            try Task.checkCancellation()
            cursor = found
            source = MongoDocumentSource()
            source.append(first)
            viewer.show(source)
            show(.documents)
        } cancelled: { [self] in
            problem = "Cancelled, so these aren't the documents the pipeline gives. Run (⌘↩) runs it again."
        } failed: { [self] error in
            problem = "The pipeline didn't run: " + error.localizedDescription
        }
    }

    /// The next batch from the cursor (Load More, or the grid scrolled to its end).
    func loadMore() {
        guard loading == nil, let cursor, !cursor.isExhausted else { return }
        let batch = self.batch
        read("Reading more of the pipeline's documents") { [self] _ in
            let next = try await cursor.next(maxCount: batch)
            try Task.checkCancellation()
            let origin = grid.scrollView.contentView.bounds.origin, selection = grid.selection
            if source.append(next) {
                viewer.show(source)
                grid.selection = selection
                grid.scrollView.contentView.scroll(to: origin)
                grid.scrollView.reflectScrolledClipView(grid.scrollView.contentView)
            } else {
                viewer.reloadData()
            }
        } cancelled: { [self] in
            self.cursor = nil  // its getMore was ended on the server
            problem = "Cancelled: Run (⌘↩) runs the pipeline again to read past these."
        } failed: { [self] error in
            self.cursor = nil
            problem = "Not every document loaded: " + error.localizedDescription
        }
    }

    /// Explain (⌥⌘E): the pipeline run with executionStats, its plan shown.
    func explain() {
        guard let (stages, options) = parsed() else { return }
        // executionStats runs the pipeline, so a writing one is asked about as Run asks.
        whenWritesAllowed(stages) { [self] in explain(stages, options) }
    }

    private func explain(_ stages: [BSONDocument], _ options: MongoFind) {
        stopReading()
        let (database, collection) = (self.database, self.collection)
        read("Explaining a pipeline on \(collection)") { [self] session in
            let answer = try await session.explain(database: database, collection: collection, pipeline: stages,
                                                   maxTimeMS: options.maxTimeMS, collation: options.collation)
            try Task.checkCancellation()
            showPlan(answer)
        } cancelled: { [self] in
            problem = "Cancelled: Explain (⌥⌘E) runs the pipeline again to measure it."
        } failed: { [self] error in
            problem = "The pipeline wasn't explained: " + error.localizedDescription
        }
    }

    /// Runs `body` on the tab's session with the spinner, the tab's busy mark and a line in Activity whose Cancel ends
    /// it on the server; a newer read takes over from it.
    private func read(_ title: String, _ body: @escaping (MongoSession) async throws -> Void,
                      cancelled: @escaping () -> Void, failed: @escaping (Error) -> Void) {
        guard let connection else { return fail("Connect to the server again to run the pipeline.") }
        reads += 1
        let read = reads
        activity = model.activity.start(title, connection: connectionID) { [weak self] in self?.stop() }
        spinner.startAnimation(nil)
        problem = nil
        updateBars()
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
        loading = Task { [self] in
            do {
                try await body(try await ownSession(connection))
            } catch where Task.isCancelled {
                if read == reads { cancelled() }
            } catch {
                if read == reads { failed(error) }
            }
            guard read == reads else { return }
            activity?.end()
            activity = nil
            loading = nil
            spinner.stopAnimation(nil)
            updateBars()
            NotificationCenter.default.post(name: .tabContentDidChange, object: self)
        }
    }

    /// The tab's session on the connection as it is now: a reconnect made a new one, so the old session goes.
    private func ownSession(_ connection: MongoConnection) async throws -> MongoSession {
        if let session, sessionOf === connection { return session }
        if let old = session { Task { await old.close() } }
        session = nil
        let made = try await connection.session(.data, slot: slot)
        session = made
        sessionOf = connection
        return made
    }

    /// Cancel: the read stops waiting, and the server ends what runs on this tab's session.
    private func stop() {
        guard let task = loading else { return }
        task.cancel()
        if let session { Task { await session.cancel() } }
    }

    /// A new run replaces the old one: its read stops and its cursor ends on the server.
    private func stopReading() {
        stop()
        loading = nil
        activity?.end()
        activity = nil
        spinner.stopAnimation(nil)
        let old = cursor
        cursor = nil
        if let old { Task { await old.close() } }
    }

    private func fail(_ message: String) {
        problem = message
        updateBars()
    }

    /// Stops for good (the tab closed): the read, the cursor and the session.
    func close() {
        stopReading()
        session = nil
        if let connection = sessionOf { Task { [slot] in await connection.closeSession(.data, slot: slot) } }
    }

    // MARK: Showing

    private func showPlan(_ answer: BSONDocument) {
        planPage.subviews.forEach { $0.removeFromSuperview() }
        let shown = MongoExplainView(MongoExplain(answer), raw: answer.shellForm(pretty: true), settings: model.data.settings)
        planPage.addSubview(shown)
        shown.pin(to: planPage)
        explainView = shown
        show(.explain)
    }

    func show(_ page: Page) {
        self.page = page
        pageSwitch.selectedSegment = page.rawValue
        planPage.isHidden = page != .explain
        viewer.isHidden = page != .documents
        updateBars()
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
    }

    @objc private func pageSwitched(_ sender: NSSegmentedControl) { show(Page(rawValue: sender.selectedSegment) ?? .documents) }

    func updateBars() {
        notice.show(.problem, problem)
        let loaded = source.rowCount, more = cursor?.isExhausted == false
        viewer.status.rows.stringValue = loading != nil && loaded == 0 ? "Running…"
            : "\(loaded.formatted()) document\(loaded == 1 ? "" : "s")\(more ? " loaded" : "")" + (cursor?.secondary.map { " · from \($0)" } ?? "")
        viewer.status.rows.toolTip = cursor?.secondary.map {
            "Read from \($0), a secondary, as the connection's readPreference asks: it may lag the primary"
        }
        moreLink.isHidden = !more
        viewer.status.update()
        toolbar.setNeedsValidation()
    }

    // MARK: Commands

    @objc func runStatement(_ sender: Any?) { run() }
    @objc func explain(_ sender: Any?) { explain() }
    @objc func cancelQuery(_ sender: Any?) { activity?.cancel() }
    @objc func loadMore(_ sender: Any?) { loadMore() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let action = item.action, !Self.instancesRespond(to: action), viewer.responds(to: action) {
            return viewer.validateMenuItem(item)
        }
        var reason: String?
        switch item.action {
        case Commands.runStatement.action?:
            item.toolTip = "Run the pipeline and show the documents it gives"
        case Commands.explain.action?:
            item.toolTip = "Run the pipeline with executionStats and show how the server ran it (it runs the pipeline)"
        case Commands.loadMore.action?:
            reason = loading != nil ? "Wait for the read under way, or cancel it (⌘.)"
                : cursor?.isExhausted == false ? nil : "Every document the pipeline gives is loaded"
        case Commands.cancelQuery.action?:
            reason = activity?.canCancel == true ? nil : "Nothing is running now"
        default:
            break
        }
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }

    // MARK: DataGridViewDelegate

    func dataGridReachedLastRow(_ grid: DataGridView) { loadMore() }

    // MARK: TabContent

    var isBusy: Bool { loading != nil }
    var statusAccessory: NSView? { page == .documents ? viewer.status : nil }

    var reopen: ((MainWindowController) -> Void)? {
        let (database, collection, connection) = (database, collection, connectionID)
        return { main in main.openAggregation(collection, database: database, connection: connection) }
    }

    func shouldClose(_ answer: @escaping (Bool) -> Void) {
        close()
        answer(true)
    }
}

// MARK: Opening

extension MainWindowController {
    /// A new aggregation tab on a collection.
    func openAggregation(_ collection: String, database: String, connection: UUID) {
        let content = MongoAggregationController(model: model, connection: connection, database: database, collection: collection)
        open(content, title: collection + " pipeline", connection: connection)
        window?.makeFirstResponder(content.editor)
    }
}

// New Aggregation (⌥⌘A) answers in the responder chain: from the tree, for its selected collections; from a
// collection's tab or a pipeline's, for that collection.

extension SidebarController {
    @objc func newAggregation(_ sender: Any?) {
        guard let main, let open = mongoSelection?.open else { return NSSound.beep() }
        let collections = (mongoSelection?.items ?? []).filter { $0.collection != nil && $0.index == nil }
        if collections.isEmpty { NSSound.beep() }
        for item in collections {
            main.openAggregation(item.collection!, database: item.database, connection: open.saved.id)
        }
    }
}

extension MongoCollectionController {
    @objc func newAggregation(_ sender: Any?) {
        (view.window?.windowController as? MainWindowController)?.openAggregation(name, database: database, connection: connectionID)
    }
}

extension MongoAggregationController {
    @objc func newAggregation(_ sender: Any?) {
        (view.window?.windowController as? MainWindowController)?.openAggregation(collection, database: database, connection: connectionID)
    }
}
