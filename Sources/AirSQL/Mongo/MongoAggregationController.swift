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
        [.init(Commands.runToStage, "forward.end", menu: { [weak self] in self?.stageItems() ?? [] }),
         .init(Commands.savePipeline, "bookmark", menu: { [weak self] in self?.savedItems() ?? [] }),
         .init(Commands.exportDocuments, "square.and.arrow.up")],
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
    /// What the grid shows when it isn't the whole pipeline's documents (Run to Here), or each stage's count.
    private(set) var info: String?
    /// How many stages gave the documents shown (Run to Here: fewer than the pipeline's), and the text they came from.
    private var shownStages: (count: Int, key: String)?
    /// The documents each stage gives (by its number from 1), for the text and collation in `countsOf`.
    private(set) var counts: [Int: Int64] = [:]
    private var countsOf = ""
    /// The collection's saved pipelines, and the one open in the tab.
    private(set) var saved: [MongoSavedPipelines.Entry] = []
    private(set) var savedName: String?

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
        loadSaved()
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
            items = MongoWords.stages.map(\.name).sorted().map { CompletionItem(kind: .keyword, text: $0, label: $0, detail: "stage") }
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

    /// Run to Here: the stages up to the one at the caret (or `stage`), that stage's documents in the grid.
    func run(through stage: Int? = nil) {
        guard let (stages, options) = parsed(), let found = try? MongoPipeline.stages(in: editor.string), !found.isEmpty else { return }
        let last = min(stage ?? Self.stage(at: editor.selectedRange().location, in: found), found.count - 1)
        let prefix = Array(stages.prefix(last + 1))
        whenWritesAllowed(prefix) { [self] in run(prefix, options) }
    }

    /// The stage the caret is in, or the last that starts before it (the first when it is before them all).
    static func stage(at caret: Int, in stages: [MongoPipeline.Stage]) -> Int {
        stages.lastIndex { $0.range.lowerBound <= caret } ?? 0
    }

    /// A pipeline ending in $out or $merge writes a collection: refused on a read-only connection, otherwise run only
    /// once the person has seen it in the preview sheet, as any other change.
    private func whenWritesAllowed(_ stages: [BSONDocument], then go: @escaping () -> Void) {
        guard let stage = MongoPipeline.writingStage(stages) else { return go() }
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
        let shown = (count: stages.count, key: countsKey)
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
            shownStages = shown
            info = nil
            noteCount()
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
            noteCount()
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
        notice.show(problem == nil ? .readOnly : .problem, problem ?? info ?? partInfo)
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
            reason = pipelineReason(item.action)
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

// MARK: Run to Here, each stage's count, saved pipelines, Save as View and Export (lane P2-aggregate)

extension MongoAggregationController {
    /// What counts and Run to Here's note belong to: the pipeline's text and its collation.
    private var countsKey: String { editor.string + "\u{0}" + collation.stringValue }

    /// Once every document the grid shows is loaded, their number is the count of its last stage.
    private func noteCount() {
        guard let shownStages, cursor?.isExhausted != false else { return }
        if countsOf != shownStages.key { (counts, countsOf) = ([:], shownStages.key) }
        counts[shownStages.count] = Int64(source.rowCount)
    }

    /// How many documents stage `number` (from 1) gives, while the pipeline is the one counted.
    func count(ofStage number: Int) -> Int64? { countsOf == countsKey ? counts[number] : nil }

    /// Run to Here's note: which stage the grid shows, when it isn't the last.
    private var partInfo: String? {
        guard let shownStages, shownStages.key == countsKey, let stages = try? MongoPipeline.stages(in: editor.string),
              shownStages.count < stages.count else { return nil }
        return "These are the documents stage \(shownStages.count) of \(stages.count) (\(stages[shownStages.count - 1].name)) gives. "
            + "Run (⌘↩) runs the whole pipeline."
    }

    /// Count Each Stage: a $count after each stage in turn (the stages before a $out or $merge), on the tab's session.
    func countStages() {
        guard loading == nil, let (stages, options) = parsed() else { return }
        let counted = Array(stages.prefix { MongoPipeline.writingStage([$0]) == nil })
        guard !counted.isEmpty else { return fail("There's no stage to count before \(MongoPipeline.writingStage(stages) ?? "")") }
        let (database, collection, key) = (self.database, self.collection, countsKey)
        read("Counting each stage's documents on \(collection)") { [self] session in
            for number in 1...counted.count {
                let found = try await session.aggregate(database: database, collection: collection,
                                                        pipeline: counted.prefix(number) + [BSONDocument([("$count", .string("n"))])],
                                                        maxTimeMS: options.maxTimeMS, collation: options.collation)
                let first = try await found.next(maxCount: 1)
                await found.close()
                try Task.checkCancellation()
                if countsOf != key { (counts, countsOf) = ([:], key) }
                counts[number] = try first.first.map { try BSONDocument(bytes: $0)["n"]?.integer ?? 0 } ?? 0
            }
            info = "Documents after each stage: " + counted.indices.map { "\($0 + 1) \(counted[$0].keys.first ?? "") "
                + (counts[$0 + 1] ?? 0).formatted() }.joined(separator: "  →  ")
        } cancelled: { [self] in
            problem = "Cancelled: not every stage was counted."
        } failed: { [self] error in
            problem = "The stages weren't counted: " + error.localizedDescription
        }
    }

    /// The Run to Here button's menu: each stage with its count when known, to run up to it.
    func stageItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let stages = (try? MongoPipeline.stages(in: editor.string)) ?? []
        for (index, stage) in stages.enumerated() {
            let count = count(ofStage: index + 1).map { "  —  \($0.formatted()) document\($0 == 1 ? "" : "s")" } ?? ""
            let item = NSMenuItem(title: "\(index + 1)  \(stage.name)\(count)", action: #selector(runStageItem(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            item.toolTip = "Run the stages up to this \(stage.name) and show the documents it gives"
            items.append(item)
        }
        return items + [.separator(), Commands.runToStage.item(), Commands.countStages.item()]
    }

    @objc private func runStageItem(_ sender: NSMenuItem) { run(through: sender.tag) }

    // MARK: Saved pipelines

    func loadSaved() {
        let (id, database, collection) = (connectionID, database, collection)
        Task { [weak self] in self?.saved = await MongoSavedPipelines.shared.entries(id, database: database, collection: collection) }
    }

    /// The Save Pipeline button's menu: Save, the collection's saved pipelines to open, then Rename, Delete and Save as View.
    func savedItems() -> [NSMenuItem] {
        var items = [Commands.savePipeline.item(), .separator()]
        for entry in saved {
            let item = NSMenuItem(title: entry.name, action: #selector(openSaved(_:)), keyEquivalent: "")
            item.representedObject = entry.name
            item.target = self
            item.state = entry.name == savedName ? .on : .off
            item.toolTip = "Put this saved pipeline in the editor and run it"
            items.append(item)
        }
        if saved.isEmpty {
            let none = NSMenuItem(title: "No saved pipelines for \(collection) yet", action: nil, keyEquivalent: "")
            none.toolTip = "Save Pipeline… keeps the pipeline in the editor under a name"
            items.append(none)
        }
        return items + [.separator(), Commands.renamePipeline.item(), Commands.deletePipeline.item(), .separator(), Commands.saveAsView.item()]
    }

    @objc private func openSaved(_ sender: NSMenuItem) {
        guard let entry = saved.first(where: { $0.name == sender.representedObject as? String }) else { return }
        open(entry)
    }

    /// A saved pipeline in the editor, run.
    func open(_ entry: MongoSavedPipelines.Entry) {
        editor.string = entry.text
        savedName = entry.name
        run()
    }

    @objc func savePipeline(_ sender: Any?) {
        guard let window = view.window else { return }
        askText("Save Pipeline", message: "Name this pipeline of \(collection); one saved under the same name is replaced",
                placeholder: "Name", value: savedName ?? "", action: "Save", id: "aggregate.pipelineName", on: window) { [weak self] name in
            if !name.isEmpty { self?.save(as: name) }
        }
    }

    func save(as name: String) {
        MongoSavedPipelines.shared.save(name, text: editor.string, connection: connectionID, database: database, collection: collection)
        savedName = name
        loadSaved()
    }

    @objc func renamePipeline(_ sender: Any?) {
        guard let window = view.window, let old = savedName else { return }
        askText("Rename Saved Pipeline", message: "A new name for “\(old)”; a pipeline saved under that name is replaced",
                placeholder: "Name", value: old, action: "Rename", id: "aggregate.pipelineName", on: window) { [weak self] name in
            if !name.isEmpty { self?.rename(old, to: name) }
        }
    }

    func rename(_ old: String, to name: String) {
        MongoSavedPipelines.shared.rename(old, to: name, connection: connectionID, database: database, collection: collection)
        savedName = name
        loadSaved()
    }

    @objc func deletePipeline(_ sender: Any?) {
        guard let window = view.window, let name = savedName else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the saved pipeline “\(name)”?"
        alert.informativeText = "The editor keeps its text: Save Pipeline… keeps it again."
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        delete.toolTip = "Forget this saved pipeline"
        alert.addButton(withTitle: "Cancel").toolTip = "Keep the saved pipeline"
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.deleteSaved(name) }
        }
    }

    func deleteSaved(_ name: String) {
        MongoSavedPipelines.shared.delete(name, connection: connectionID, database: database, collection: collection)
        savedName = nil
        loadSaved()
    }

    // MARK: Save as View

    /// Save as View…: a name, then the `create` command in the preview sheet, then the view made on the tab's session.
    @objc func saveAsView(_ sender: Any?) {
        guard let (stages, options) = parsed(), let window = view.window, let open = model.openMongo[connectionID] else { return }
        if let reason = viewRefusal(stages) { return fail(reason) }
        askText("Save as View", message: "Name the view of \(collection) that gives what this pipeline gives", placeholder: "View name",
                action: "Continue", id: "aggregate.viewName", on: window) { [weak self] name in
            guard let self, !name.isEmpty else { return }
            // The admin builder: the same name checks as Create View… (no system.*, no admin, local or config).
            let made: MongoAdminCommand
            do {
                made = try MongoAdmin.createView(database: database, name: name, on: collection, pipeline: stages,
                                                 collation: options.collation)
            } catch { return fail("\(error)") }
            let command = made.command
            var request = SQLPreviewRequest(
                change: ChangeSQL(title: "Save a pipeline as a view", statements: [made.shellForm],
                                  connection: connectionID),
                heading: "Make the view \(name) in \(database)?",
                caption: "A view runs this pipeline on \(collection) each time it is read; it keeps no documents of its own.")
            request.actionTitle = "Create"
            request.shellCommands = true
            SQLPreviewSheet.show(request, connection: open.saved, on: window) { [weak self] result in
                if result.approved { self?.createView(command, name: name) }
            }
        }
    }

    /// Why the pipeline can't be saved as a view now.
    func viewRefusal(_ stages: [BSONDocument]) -> String? {
        if model.connection(connectionID)?.readOnly == true {
            return "This connection is read-only: turn that off in the connection's settings to make a view."
        }
        if let stage = MongoPipeline.writingStage(stages) { return "\(stage) writes to a collection, so a view can't run it: remove that stage first." }
        return nil
    }

    private func createView(_ command: BSONDocument, name: String) {
        let database = self.database
        read("Making the view \(name)") { [self] session in
            try await session.saveView(command, database: database)
            info = "Made the view \(name) in \(database)."
            model.openMongo[connectionID]?.loadDatabase(database, again: true)
        } cancelled: { [self] in
            problem = "Cancelled: refresh the tree to see whether the view was made."
        } failed: { [self] error in
            problem = "The view wasn't made: " + error.localizedDescription
        }
    }

    // MARK: Export and the commands' state

    @objc func runToStage(_ sender: Any?) { run(through: nil) }
    @objc func countStages(_ sender: Any?) { countStages() }
    /// Export Documents… from the tab's toolbar: for this tab's window, whichever is in front.
    @objc func exportDocuments(_ sender: Any?) {
        guard let window = view.window, let main = window.windowController as? MainWindowController,
              let ref = MongoTransferMenu.shared.target(in: main), ref.refusal == nil else { return NSSound.beep() }
        MongoExportSheet.show(ref, activity: model.activity, on: window)
    }

    /// The pipeline Export Documents… writes the documents of, or why it can't.
    func exportPipeline() -> (stages: [BSONDocument], collation: BSONDocument?, refusal: String?) {
        guard let stages = try? MongoPipeline.stages(in: editor.string).map(\.document),
              let options = try? MongoQueryText(collation: collation.stringValue).find() else {
            return ([], nil, "Fix the pipeline first: Run (⌘↩) shows what's wrong")
        }
        if let stage = MongoPipeline.writingStage(stages) {
            return (stages, nil, "The pipeline writes with \(stage), and Export only reads: remove that stage first")
        }
        return (stages, options.collation, nil)
    }

    func pipelineReason(_ action: Selector?) -> String? {
        let wait = loading != nil ? "Wait for the read under way, or cancel it (⌘.)" : nil
        switch action {
        case Commands.runToStage.action?:
            guard let stages = try? MongoPipeline.stages(in: editor.string) else { return "Fix the pipeline first: Run (⌘↩) shows what's wrong" }
            return stages.isEmpty ? "Type a stage first" : nil
        case Commands.countStages.action?:
            return wait ?? pipelineReason(Commands.runToStage.action)
        case Commands.renamePipeline.action?, Commands.deletePipeline.action?:
            return savedName == nil ? "Open a saved pipeline first, from the Save Pipeline button's menu" : nil
        case Commands.saveAsView.action?:
            return wait ?? (model.connection(connectionID)?.readOnly == true ? "This connection is read-only" : nil)
        case Commands.exportDocuments.action?:
            return exportPipeline().refusal
        default:
            return nil
        }
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
