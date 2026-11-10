import AirSQLCore
import AppKit

/// A MongoDB collection's documents in a tab (mongo-plan, Collection tab): the query bar, then three pages — the
/// documents in the grid (`MongoDocumentSource` in a `GridViewer`: the status bar's figures, the value panel with a
/// document's tree, Record View, Column Summary, charts, copying), the loaded documents as Extended JSON, and the
/// Schema of a sample. Documents come from a cursor on the tab's own data session, a byte-bounded batch at a time: the
/// first with Run, the next as the grid scrolls to its end (or Load More). Every read runs off the main thread with a
/// spinner, and Cancel (⌘.) ends it on the server. Edits, new documents and deletes wait as pending changes
/// (`MongoChanges`) until Apply (`+Editing`).
@MainActor
final class MongoCollectionController: NSViewController, TabContent, DataGridViewDelegate, NSMenuItemValidation, NSMenuDelegate {
    enum Page: Int, CaseIterable {
        case documents, json, schema, indexes

        var command: Command {
            [Commands.collectionDocuments, Commands.collectionJSON, Commands.collectionSchema, Commands.collectionIndexes][rawValue]
        }
    }

    let model: AppModel
    let connectionID: UUID
    let database: String
    let info: MongoCollectionInfo
    var name: String { info.name }
    let viewer = GridViewer(source: nil)
    var grid: DataGridView { viewer.grid }
    var source = MongoDocumentSource()
    let bar = MongoQueryBar()
    let notice = TableDataNotice()
    let emptyNote = TableEmptyNote()
    let pageSwitch = NSSegmentedControl()
    private let pageBar = NSView()
    private var pageBarHeight: NSLayoutConstraint!
    private let dataPage = NSView()
    let jsonScroll = NSTextView.scrollableTextView()
    var jsonView: NSTextView { jsonScroll.documentView as! NSTextView }
    let schemaView = MongoSchemaView()
    let indexesView = MongoIndexesView()
    private(set) lazy var toolbar = GridToolbar(grid: grid, groups: [
        [.init(Commands.refresh, "arrow.clockwise"), .init(Commands.cancelQuery, "stop.circle")],
        [.init(Commands.expandField, "arrow.up.left.and.arrow.down.right"), .init(Commands.copyDocuments, "doc.on.doc")],
        GridToolbar.Item.viewItems,
    ], trailing: [.init(Commands.loadMore, "arrow.down.to.line", stays: true)])
    private lazy var countLink = link("Count Exactly", Commands.countRows, id: "mongo.count",
                                      tip: "Count the documents the filter finds, on the server")
    private lazy var moreLink = link("Load More", Commands.loadMore, id: "mongo.loadMore", tip: "Read the next batch of documents")
    private(set) var page = Page.documents
    /// The open find's cursor: what Load More reads from.
    var cursor: MongoCursor?
    /// The read under way (one at a time), and its line in Activity.
    var loading: Task<Void, Never>?
    private var activity: Activity?
    /// The reads started, which tells a read a newer one took over.
    private(set) var reads = 0
    private var jsonTask: Task<Void, Never>?
    /// What went wrong last, until the next read works.
    var problem: String?
    /// How many documents the find gives: the server's estimate (no filter), or counted.
    var total: (count: Int64, exact: Bool)?
    /// The query whose documents show.
    private(set) var shown = MongoQueryText()
    /// The collection's queries run and kept, newest first.
    private(set) var history: [MongoQueryHistory.Entry] = []
    /// The tab's own data session (`MongoConnection.session(_:slot:)`): its Cancel and Apply touch no other tab's work.
    let slot = UUID().uuidString
    /// The changes waiting for Apply, and the ones before each change for Undo (and after, for Redo).
    var changes: MongoChanges
    var undone: [MongoChanges] = [], redone: [MongoChanges] = []
    /// Apply is running: the changes stay as they are until it reports.
    var isApplying = false

    init(model: AppModel, connection: UUID, database: String, collection: MongoCollectionInfo) {
        self.model = model
        connectionID = connection
        self.database = database
        info = collection
        changes = MongoChanges(database: database, collection: collection.name, kind: collection.kind)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Text being typed undoes itself, and ⌘⌫ deletes in it: those go on past this tab while a field has the keyboard.
    override func responds(to selector: Selector!) -> Bool {
        if [Commands.undo.action, Commands.redo.action, Commands.deleteRows.action].contains(selector),
           isViewLoaded, view.window?.firstResponder is NSTextView { return false }
        return super.responds(to: selector)
    }

    func shows(_ connection: UUID, _ database: String, _ collection: String) -> Bool {
        connectionID == connection && self.database == database && name == collection
    }

    /// The connection's sessions now (a new connect makes new ones).
    var connection: MongoConnection? { model.openMongo[connectionID]?.connection }

    /// A batch: Settings ▸ Grid's rows per page, and at most 4 MB of documents.
    private var batch: Int { max(1, model.data.settings.rowsPerPage) }

    override func loadView() {
        let view = NSView()
        view.setAccessibilityIdentifier("mongoCollection")
        viewer.host = self
        viewer.viewKey = GridViewer.ViewKey(connection: connectionID, database: database, table: name)
        viewer.copyTable = (database, name)
        viewer.filterByValue = { [weak self] column, value in self?.filter(column, by: value) }
        viewer.whyReadOnly = { [weak self] row, column in self?.whyReadOnly(row, column) }
        viewer.keepValue = { [weak self] row, column, text in self?.keep(text, row: row, column: column) }
        notice.preview.title = "Preview Commands…"
        notice.preview.toolTip = "Show the commands Apply would run, without running them"
        notice.apply.toolTip = "Show the commands, then write the pending changes to the server"
        emptyNote.add.title = "Insert Document"
        emptyNote.add.toolTip = "Add a new document; it is written when you apply the changes"
        emptyNote.add.target = self
        viewer.toolbar = toolbar
        viewer.didPresent = { [weak self] in self?.updateBars() }
        for (index, link) in [countLink, moreLink].enumerated() { viewer.status.insertView(link, at: index + 1, in: .trailing) }
        grid.nullText = model.data.settings.nullText
        grid.fontSize = CGFloat(model.data.settings.gridFontSize)
        grid.setAccessibilityLabel("Documents of \(name)")
        bar.onRun = { [weak self] in self?.run() }
        bar.paths = { [weak self] in self?.knownPaths ?? [] }
        bar.history.menu?.delegate = self
        notice.owner = self
        emptyNote.add.isHidden = true
        emptyNote.clear.target = self
        emptyNote.place(in: viewer.body)
        jsonView.isEditable = false
        jsonView.backgroundColor = .content
        jsonView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        jsonView.textContainerInset = NSSize(width: 6, height: 6)
        jsonView.setAccessibilityIdentifier("mongo.json")
        jsonView.layoutManager?.allowsNonContiguousLayout = true
        schemaView.sample = { [weak self] size in self?.sample(size) }
        schemaView.choose = { [weak self] path in self?.findHaving(path) }
        for button in [indexesView.createButton, indexesView.dropButton, indexesView.hideButton] { button.target = self }
        indexesView.table.menu?.items.forEach { $0.target = self }
        indexesView.selectionChanged = { [weak self] in self?.updateIndexButtons() }
        pageSwitch.segmentCount = Page.allCases.count
        pageSwitch.trackingMode = .selectOne
        pageSwitch.controlSize = .small
        pageSwitch.segmentStyle = .rounded
        pageSwitch.selectedSegmentBezelColor = .selectedSegment
        pageSwitch.target = self
        pageSwitch.action = #selector(pageSwitched(_:))
        pageSwitch.setAccessibilityIdentifier("mongo.page")
        for page in Page.allCases {
            pageSwitch.setLabel(page.command.title, forSegment: page.rawValue)
            pageSwitch.setToolTip(page.command.tipWithShortcut, forSegment: page.rawValue)
        }
        let rows = NSStackView(views: [toolbar, viewer])
        rows.orientation = .vertical
        rows.spacing = 0
        for part in rows.arrangedSubviews { part.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true }
        viewer.setContentHuggingPriority(.defaultLow, for: .vertical)
        dataPage.addSubview(rows)
        rows.pin(to: dataPage)
        let top = NSStackView(views: [bar, notice])
        top.orientation = .vertical
        top.spacing = 0
        for part in top.arrangedSubviews { part.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true }
        for part in [top, pageBar, dataPage, jsonScroll, schemaView, indexesView] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(part)
        }
        pageBar.clipsToBounds = true
        pageBarHeight = pageBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.topAnchor), top.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageBar.topAnchor.constraint(equalTo: top.bottomAnchor), pageBarHeight,
            pageBar.leadingAnchor.constraint(equalTo: view.leadingAnchor), pageBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        for part in [dataPage, jsonScroll, schemaView, indexesView] as [NSView] {
            NSLayoutConstraint.activate([
                part.topAnchor.constraint(equalTo: pageBar.bottomAnchor), part.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                part.leadingAnchor.constraint(equalTo: view.leadingAnchor), part.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
        self.view = view
        show(.documents)
        updateBars()
        loadHistory()
        run()
    }

    // MARK: Reading

    /// Run (⌘↩, Return in a field): the find the query bar describes, from its first batch; a field it can't read says
    /// why under the fields, and nothing runs.
    func run() {
        guard changes.isEmpty else { return askToDiscard { [weak self] in self?.run() } }
        let text = bar.query
        let find: MongoFind
        do {
            find = try text.find()
        } catch {
            return bar.show(error as? MongoQueryText.Problem)  // the only error `find` throws
        }
        bar.show(nil)
        stopReading()
        guard let connection else { return fail("Connect to the server again to read its documents.") }
        let (database, name, batch, id) = (self.database, self.name, self.batch, connectionID)
        let read = begin("Finding documents in \(name)")
        loading = Task { [self] in
            do {
                let session = try await connection.session(.data, slot: slot)
                let found = try await session.find(database: database, collection: name, find)
                let first = try await found.next(maxCount: batch)
                if Task.isCancelled { await found.close() }
                try Task.checkCancellation()
                cursor = found
                source = MongoDocumentSource()
                source.append(first)
                shown = text
                problem = nil
                total = found.isExhausted ? (Int64(source.rowCount), true) : nil
                showSource()
                MongoQueryHistory.shared.add(text, connection: id, database: database, collection: name)
                loadHistory()
                if total == nil, find.filter.fields.isEmpty, find.skip == nil, find.limit == nil {
                    let estimate = try? await session.estimatedCount(database: database, collection: name)
                    if read == reads { total = estimate.map { ($0, false) } }
                }
            } catch where Task.isCancelled {
                if read == reads { problem = "Cancelled, so these aren't the documents you asked for. Run (⌘↩) finds them again." }
            } catch {
                problem = "The documents didn't load: " + error.localizedDescription
            }
            endRead(read)
        }
    }

    /// The next batch from the cursor, after the documents loaded (Load More, or the grid scrolled to its end).
    func loadMore() {
        guard loading == nil, let cursor, !cursor.isExhausted else { return }
        let batch = self.batch
        let read = begin("Reading more documents of \(name)")
        loading = Task { [self] in
            do {
                let next = try await cursor.next(maxCount: batch)
                try Task.checkCancellation()
                if source.append(next) { showSource(keepingPlace: true) } else { viewer.reloadData() }
                if cursor.isExhausted { total = (Int64(source.rowCount), true) }
                if page == .json { showJSON() }
            } catch where Task.isCancelled {
                if read == reads {
                    self.cursor = nil  // its getMore was ended on the server
                    problem = "Cancelled: Run (⌘↩) finds the documents again to read past these."
                }
            } catch {
                self.cursor = nil
                problem = "Not every document loaded: " + error.localizedDescription
            }
            endRead(read)
        }
    }

    /// Count Exactly: the documents the filter finds (within skip and limit), counted on the server.
    func count() {
        guard loading == nil, let connection, let find = try? shown.find() else { return }
        let (database, name) = (self.database, self.name)
        let read = begin("Counting the documents of \(name)")
        loading = Task { [self] in
            do {
                var counted = try await connection.session(.data, slot: slot).count(database: database, collection: name, filter: find.filter,
                                                                        maxTimeMS: find.maxTimeMS)
                if let skip = find.skip { counted = max(0, counted - skip) }
                if let limit = find.limit, limit > 0 { counted = min(counted, limit) }
                try Task.checkCancellation()
                total = (counted, true)
            } catch where Task.isCancelled {
            } catch {
                problem = "The documents weren't counted: " + error.localizedDescription
            }
            endRead(read)
        }
    }

    /// A `$sample` of the collection summed up for the Schema page.
    func sample(_ size: Int) {
        guard loading == nil, let connection else { return }
        let (database, name) = (self.database, self.name)
        let read = begin("Sampling \(size.formatted()) documents of \(name)")
        schemaView.busy = true
        loading = Task { [self] in
            do {
                let session = try await connection.session(.data, slot: slot)
                let cursor = try await session.aggregate(database: database, collection: name,
                                                         pipeline: [BSONDocument([("$sample", .document(BSONDocument([("size", .int32(Int32(size)))])))])])
                var documents: [[UInt8]] = []
                while !cursor.isExhausted {
                    documents += try await cursor.next(maxCount: size)
                    try Task.checkCancellation()
                }
                // Decoded and summed up off the main thread: 10,000 documents take a moment.
                let schema = await Task.detached { MongoSchema(sample: documents.compactMap { try? BSONDocument(bytes: $0) }) }.value
                try Task.checkCancellation()
                schemaView.show(schema, caption: "From a random sample of \(schema.documents.formatted()) document"
                                + (schema.documents == 1 ? "" : "s") + " · read " + GridStatusView.time(Date()))
                problem = nil
            } catch where Task.isCancelled {
                if read == reads { problem = "Cancelled: the sample wasn't taken." }
            } catch {
                problem = "The sample wasn't taken: " + error.localizedDescription
            }
            schemaView.busy = false
            endRead(read)
        }
    }

    /// The spinner, the tab's busy mark, and a line in Activity whose Cancel ends the read on the server.
    func begin(_ title: String) -> Int {
        reads += 1
        activity = model.activity.start(title, connection: connectionID) { [weak self] in self?.stop() }
        bar.busy = true
        updateBars()
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
        return reads
    }

    /// The end of read number `read`, unless a newer one took its place (a Run while it was reading).
    func endRead(_ read: Int) {
        guard read == reads else { return }
        activity?.end()
        activity = nil
        loading = nil
        bar.busy = false
        updateBars()
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
    }

    /// Cancel: the read stops waiting, and the server ends what the tab's data session runs.
    private func stop() {
        guard let task = loading else { return }
        task.cancel()
        if let connection { Task { [slot] in try? await connection.session(.data, slot: slot).cancel() } }
    }

    /// A new find replaces the old one: its read stops and its cursor ends on the server.
    private func stopReading() {
        stop()
        loading = nil
        activity?.end()
        activity = nil
        let old = cursor
        cursor = nil
        if let old { Task { await old.close() } }
    }

    private func fail(_ message: String) {
        problem = message
        updateBars()
    }

    /// Stops reading for good (the tab closed, or the preview moved on).
    func close() {
        let reading = loading != nil, old = cursor
        loading?.cancel()
        (loading, cursor) = (nil, nil)
        activity?.end()
        activity = nil
        jsonTask?.cancel()
        // In order: the server ends the read, then the tab's session closes (a cancel after it would open another).
        guard let connection else { return }
        Task { [slot] in
            if reading { await (try? await connection.session(.data, slot: slot))?.cancel() }
            await old?.close()
            await connection.closeSession(.data, slot: slot)
        }
    }

    // MARK: Showing

    /// The documents in the grid again, with the columns as they were left; `keepingPlace`: where it was scrolled and
    /// what was selected stay (a new batch brought new columns).
    func showSource(keepingPlace: Bool = false) {
        source.changes = changes
        let origin = grid.scrollView.contentView.bounds.origin, selection = grid.selection
        viewer.show(source)
        grid.sortOrder = sortShown
        if keepingPlace {
            grid.selection = selection
            grid.scrollView.contentView.scroll(to: origin)
            grid.scrollView.reflectScrolledClipView(grid.scrollView.contentView)
        }
        if page == .json { showJSON() }
    }

    /// The header's sort marks for the sort that ran.
    private var sortShown: [DataGridView.Sort] {
        guard let sort = try? BSONDocument(shellForm: shown.sort.isEmpty ? "{}" : shown.sort) else { return [] }
        let paths = source.paths.map { $0.joined(separator: ".") }
        return sort.fields.compactMap { key, value in
            paths.firstIndex(of: key).map { DataGridView.Sort(column: $0, ascending: (value.integer ?? 1) >= 0) }
        }
    }

    func updateBars() {
        if let problem {
            notice.show(.problem, problem)
        } else if !changes.isEmpty {
            notice.show(.pending, pendingSummary)
        } else {
            notice.show(.readOnly, editingOff.map { "Read-only. " + $0 + "." })
        }
        let loaded = source.loadedCount, more = cursor?.isExhausted == false
        let rows = viewer.status.rows
        let noun = { (count: Int64) in count == 1 ? "document" : "documents" }
        if shown.isEmpty && loaded == 0 && loading != nil {
            rows.stringValue = "Loading…"
        } else if !more {
            rows.stringValue = "\(loaded.formatted()) \(noun(Int64(loaded)))"
        } else if let total {
            rows.stringValue = "\(loaded.formatted()) of \(total.exact ? "" : "about ")\(total.count.formatted()) \(noun(total.count))"
        } else {
            rows.stringValue = "\(loaded.formatted()) \(noun(Int64(loaded))) loaded"
        }
        rows.toolTip = total?.exact == false ? "The collection's count from its metadata: Count Exactly counts the documents" : nil
        countLink.isHidden = !more || total?.exact == true
        moreLink.isHidden = !more
        let filtered = !shown.filter.trimmingCharacters(in: .whitespaces).isEmpty
        emptyNote.isHidden = loaded > 0 || loading != nil || problem != nil || viewer.presentation != .table
        emptyNote.text.stringValue = filtered ? "No documents match the filter." : "\(name) has no documents."
        emptyNote.clear.isHidden = !filtered
        emptyNote.add.isHidden = editingOff != nil
        viewer.status.update()
        toolbar.setNeedsValidation()
        updateIndexButtons()
    }

    /// The loaded documents as relaxed Extended JSON, laid out off the main thread.
    private func showJSON() {
        let documents = (0..<source.loadedCount).map(source.bytes)
        jsonTask?.cancel()
        jsonTask = Task { [weak self] in
            let text = await Task.detached { () -> String in
                var writer = ExtendedJSONWriter(.relaxed, layout: .array, pretty: true)
                var out = writer.header()
                for bytes in documents {
                    if let document = try? BSONDocument(bytes: bytes) { out += writer.document(document) }
                }
                return out + writer.footer()
            }.value
            guard !Task.isCancelled, let self else { return }
            jsonView.string = text
        }
    }

    /// Shows a page: the grid, the JSON or the schema (sampled the first time it shows).
    func show(_ page: Page) {
        self.page = page
        pageSwitch.selectedSegment = page.rawValue
        dataPage.isHidden = page != .documents
        jsonScroll.isHidden = page != .json
        schemaView.isHidden = page != .schema
        indexesView.isHidden = page != .indexes
        // On the grid's toolbar on Documents; on a bar of its own on the others.
        pageBar.subviews.forEach { $0.removeFromSuperview() }
        pageBarHeight.constant = page == .documents ? 0 : 31
        if page == .documents {
            toolbar.leadingView = pageSwitch
            view.window?.makeFirstResponder(grid)
        } else {
            toolbar.leadingView = nil
            let row = actionBar([pageSwitch, NSView()], spacing: Spacing.unit)
            pageBar.addSubview(row)
            row.pin(to: pageBar)
        }
        if page == .json { showJSON() }
        if page == .schema, schemaView.schema == nil, loading == nil { sample(schemaView.sampleSize) }
        if page == .indexes { loadIndexes() }
        updateBars()
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
    }

    @objc private func pageSwitched(_ sender: NSSegmentedControl) { show(Page(rawValue: sender.selectedSegment) ?? .documents) }

    /// Documents, JSON or Schema (the item's tag); the JSON's or Schema's own command again goes back to the documents.
    @objc func showCollectionPage(_ sender: Any?) {
        let chosen = Page(rawValue: (sender as? NSMenuItem)?.tag ?? 0) ?? .documents
        show(chosen == page && chosen != .documents ? .documents : chosen)
    }

    /// The field names the query bar completes: the loaded documents' and the sample's (an array's elements by the
    /// array's name, as a query names them).
    var knownPaths: [String] {
        let sampled = (schemaView.schema?.fields ?? []).map { $0.path.replacingOccurrences(of: ".[]", with: "") }
        return source.paths.map { $0.joined(separator: ".") } + sampled
    }

    // MARK: Filtering from the grid and the schema

    /// Column Summary's value clicked: the documents whose field holds it.
    private func filter(_ column: Int, by value: String?) {
        let path = source.paths[column].joined(separator: ".")
        let literal = value.flatMap { try? BSONValue(shellForm: $0) } ?? .null
        bar.filter.stringValue = BSONDocument([(path, literal)]).shellForm()
        show(.documents)
        run()
    }

    /// A schema path double-clicked: the documents that have that field.
    private func findHaving(_ path: String) {
        let field = path.replacingOccurrences(of: ".[]", with: "")
        bar.filter.stringValue = BSONDocument([(field, .document(BSONDocument([("$exists", .bool(true))])))]).shellForm()
        show(.documents)
        run()
    }

    // MARK: Commands

    @objc func runStatement(_ sender: Any?) { run() }
    /// Query ▸ Explain (⌥⌘E): the find's plan, measured, in a window of its own.
    @objc func explain(_ sender: Any?) { _ = MongoExplainWindow.explain(self) }
    /// Refresh (⌘R): the find again, or on the Schema page a new sample, on the Indexes page the indexes.
    @objc func refresh(_ sender: Any?) {
        guard loading == nil else { return }
        if page == .schema { sample(schemaView.sampleSize) } else if page == .indexes { loadIndexes() } else { run() }
    }
    @objc func cancelQuery(_ sender: Any?) { activity?.cancel() }
    @objc func loadMore(_ sender: Any?) { loadMore() }
    @objc func countRows(_ sender: Any?) { count() }

    @objc func clearFilter(_ sender: Any?) {
        bar.filter.stringValue = ""
        run()
    }

    /// Query History (⌘Y): the history's menu, under its button.
    @objc func showHistory(_ sender: Any?) { bar.history.performClick(sender) }

    /// Expand Field on a sub-document's column, or Collapse Field on a column of a sub-document's fields.
    @objc func toggleField(_ sender: Any?) {
        guard let column = ((sender as? NSMenuItem)?.representedObject as? Int) ?? viewer.focusedColumn,
              let (path, on) = fieldToggle(column) else { return NSSound.beep() }
        source.setExpanded(path, on)
        showSource()
    }

    /// What Expand Field does to a column: expands it (a sub-document) or collapses its parent (a sub-document's field).
    private func fieldToggle(_ column: Int) -> (path: [String], on: Bool)? {
        guard source.paths.indices.contains(column) else { return nil }
        if source.canExpand(column) { return (source.paths[column], true) }
        let path = source.paths[column]
        return path.count > 1 ? (Array(path.dropLast()), false) : nil
    }

    /// Copy Documents: the selected rows' documents as relaxed Extended JSON, a line each.
    @objc func copyDocuments(_ sender: Any?) {
        let rows = viewer.selectedRows()
        guard !rows.isEmpty else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rows.compactMap { source.document($0)?.extendedJSON(.relaxed) }.joined(separator: "\n"),
                                       forType: .string)
    }

    /// A link in the status bar that sends `command` to this tab.
    private func link(_ title: String, _ command: Command, id: String, tip: String) -> NSButton {
        let link = GridStatusView.link(title, id: id, tip: tip + (command.shortcut.isEmpty ? "" : " (\(command.shortcut))"),
                                       action: command.action)
        link.target = self
        return link
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let action = item.action, !Self.instancesRespond(to: action), viewer.responds(to: action) {
            return viewer.validateMenuItem(item)
        }
        let more = cursor?.isExhausted == false
        var reason: String?
        switch item.action {
        case Commands.runStatement.action?:
            item.explain(enabled: true, reason: nil)
            item.toolTip = "Find the documents the query bar describes"
            return true
        case Commands.refresh.action?, Commands.countRows.action?, Commands.loadMore.action?:
            if loading != nil {
                reason = "Wait for the read under way, or cancel it (⌘.)"
            } else if item.action == Commands.countRows.action, !more || total?.exact == true {
                reason = "Every document is counted already"
            } else if item.action == Commands.loadMore.action, !more {
                reason = "Every document the find gives is loaded"
            }
        case Commands.cancelQuery.action?:
            reason = activity?.canCancel == true ? nil : "Nothing is being read now"
        case Commands.explain.action?:
            item.explain(enabled: true, reason: nil)
            item.toolTip = "Run the query bar's find with executionStats and show how the server ran it"
            return true
        case Commands.clearFilter.action?:
            reason = bar.filter.stringValue.isEmpty ? "There is no filter to clear" : nil
        case Commands.collectionDocuments.action?:
            item.state = item.tag == page.rawValue ? .on : .off
        case Commands.expandField.action?:
            let column = (item.representedObject as? Int) ?? viewer.focusedColumn
            let toggle = column.flatMap(fieldToggle)
            item.title = toggle?.on == false ? "Collapse Field" : "Expand Field"
            reason = toggle == nil ? "Select a column that holds sub-documents, or one of their fields" : nil
        case Commands.copyDocuments.action?:
            reason = viewer.selectedRows().isEmpty ? "Select rows first" : nil
        case Commands.createIndex.action?, Commands.dropIndex.action?, Commands.hideIndex.action?:
            var title = Commands.hideIndex.title
            reason = indexReason(item.action, title: &title)
            if item.action == Commands.hideIndex.action { item.title = title }
        default:
            reason = editingReason(item)
        }
        item.explain(enabled: reason == nil, reason: reason)
        if reason == nil, let action = item.action, let tip = Self.editingTips[action] { item.toolTip = tip }
        return reason == nil
    }

    // MARK: History (the bar's clock button)

    private func loadHistory() {
        let (id, database, name) = (connectionID, database, self.name)
        Task { [weak self] in
            let found = await MongoQueryHistory.shared.entries(id, database: database, collection: name)
            self?.history = found
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "")  // the pull-down's own title
        menu.items[0].image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Query History")
        func add(_ title: String, _ action: Selector?, tip: String, object: Any? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.toolTip = tip
            item.representedObject = object
            menu.addItem(item)
        }
        func section(_ title: String, _ entries: [MongoQueryHistory.Entry]) {
            guard !entries.isEmpty else { return }
            menu.addItem(.separator())
            add(title, nil, tip: title == "Favourites" ? "The queries kept for this collection" : "The queries run here last, newest first")
            for entry in entries {
                let summary = entry.query.summary
                add(summary.count > 90 ? String(summary.prefix(89)) + "…" : summary, #selector(useHistory(_:)),
                    tip: "Put this query in the bar and run it: " + summary, object: entry.query)
            }
        }
        let favourite = history.contains { $0.favourite && $0.query == bar.query }
        add(favourite ? "Remove from Favourites" : "Add to Favourites", #selector(toggleFavouriteQuery(_:)),
            tip: favourite ? "Take the query in the bar out of this collection's favourites" : "Keep the query in the bar among this collection's favourites")
        section("Favourites", history.filter(\.favourite))
        section("Recent", Array(history.filter { !$0.favourite }.prefix(20)))
        if history.isEmpty {
            menu.addItem(.separator())
            add("No queries run here yet", nil, tip: "Queries you run in this collection appear here")
        } else {
            menu.addItem(.separator())
            add("Clear History", #selector(clearQueryHistory(_:)), tip: "Forget this collection's recent queries; the favourites stay")
        }
    }

    @objc private func useHistory(_ sender: NSMenuItem) {
        guard let query = sender.representedObject as? MongoQueryText else { return }
        bar.query = query
        run()
    }

    @objc private func toggleFavouriteQuery(_ sender: Any?) {
        let query = bar.query, favourite = !history.contains { $0.favourite && $0.query == query }
        MongoQueryHistory.shared.setFavourite(favourite, query, connection: connectionID, database: database, collection: name)
        loadHistory()
    }

    @objc private func clearQueryHistory(_ sender: Any?) {
        MongoQueryHistory.shared.clear(connectionID, database: database, collection: name)
        loadHistory()
    }

    // MARK: DataGridViewDelegate

    func dataGridReachedLastRow(_ grid: DataGridView) { loadMore() }

    /// A header click sorts by that field on the server: ascending, then descending; with ⇧ after the sort there is.
    func dataGrid(_ grid: DataGridView, sortBy column: Int, adding: Bool) {
        let path = source.paths[column].joined(separator: ".")
        var sort = (try? BSONDocument(shellForm: shown.sort.isEmpty ? "{}" : shown.sort)) ?? BSONDocument()
        let old = sort.fields.firstIndex { $0.key == path }
        let ascending = old.map { (sort.fields[$0].value.integer ?? 1) < 0 } ?? true
        if !adding { sort = BSONDocument() } else if let old { sort.fields.remove(at: old) }
        sort.fields.append((path, .int32(ascending ? 1 : -1)))
        bar.sort.stringValue = sort.shellForm()
        run()
    }

    func dataGrid(_ grid: DataGridView, menuFor target: DataGridView.Target) -> NSMenu? {
        let menu = NSMenu(title: "Documents")
        if case .column(let column) = target {
            guard fieldToggle(column) != nil else { return nil }
            let item = Commands.expandField.item()
            item.representedObject = column
            menu.addItem(item)
        } else {
            menu.add([Commands.copyDocuments])
            addEditingItems(to: menu)
        }
        return menu
    }

    // MARK: TabContent

    var isBusy: Bool { loading != nil }
    var isEdited: Bool { !changes.isEmpty }
    var statusAccessory: NSView? { page == .documents ? viewer.status : nil }

    var reopen: ((MainWindowController) -> Void)? {
        let (info, database, connection) = (info, database, connectionID)
        return { main in main.openCollection(info, database: database, connection: connection) }
    }

    func shouldClose(_ answer: @escaping (Bool) -> Void) {
        guard !isApplying else {
            NSSound.beep()  // Apply's report must reach the person: the tab stays until it has run
            return answer(false)
        }
        let closes = { [weak self] in
            self?.close()
            answer(true)
        }
        changes.isEmpty ? closes() : askToDiscard(closes, staying: { answer(false) })
    }
}
