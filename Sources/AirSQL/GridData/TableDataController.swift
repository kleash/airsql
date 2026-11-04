import AirSQLCore
import AppKit

/// What the table tab sends its statements to: the connection's data session (plan §2.2), or the tests' own.
protocol TableSession: AnyObject {
    var noBackslashEscapes: Bool { get }
    func query(_ sql: String, rowCap: Int) async throws -> [StatementResult]
    func stream(_ sql: String, batchRows: Int, batch: @escaping (ResultStore) throws -> Void) async throws
}

extension DBConnection: TableSession {}

/// Set from any thread to stop a stream between batches (Cancel on Load All's activity).
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// A table's or view's rows in a tab (plan §2.5, grid-spec §3–§6): the grid bar (where filtering runs, the WHERE
/// condition, Search All Columns), a notice for pending changes or why the table is read-only, and the grid in a
/// `GridViewer` (the status bar's figures, the value panel, Record View, Column Summary, copying), which this tab hosts.
/// Rows load a page at a time on the connection's data session; edits wait as pending changes until Apply, which runs
/// them there in one transaction. Nothing waits on the network on the main thread.
@MainActor
final class TableDataController: NSViewController, TabContent {
    let model: AppModel
    let context: EditorContext
    let database: String
    let tableName: String
    /// The data session; the tests give their own.
    var openSession: () async throws -> TableSession
    private(set) var source: TableDataSource?
    let viewer = GridViewer(source: nil)
    var grid: DataGridView { viewer.grid }
    let bar = TableDataBar()
    let findBar = TableFindBar()
    let notice = TableDataNotice()
    /// The status bar's links, after the rows' count (`viewer.status.rows`).
    lazy var countLink = link("Count Exactly", Commands.countRows, id: "tableData.count")
    lazy var moreLink = link("Load More", Commands.loadMore, id: "tableData.loadMore")
    lazy var allLink = link("Load All", Commands.loadAll, id: "tableData.loadAll")
    /// The rows' estimate (information_schema) or exact count (Count Rows Exactly), with the filter it was for.
    var total: (rows: Int, exact: Bool, filter: String)?
    /// The table's size on the server in bytes, from the estimate (Column Summary asks first above 2 GB).
    var dataLength: Int?
    /// A load under way (a page, Load All, Refresh, Apply): one at a time.
    var loading: Task<Void, Never>?
    /// The preview tab moved on while this was opening: its rows aren't read.
    var abandoned = false
    /// The data session's NO_BACKSLASH_ESCAPES, as filters quote their values for it (read at each load).
    var noBackslashEscapes = false
    /// The data session's sql_mode and time zone, which decide what a value may be (read with the first page).
    var editContext: EditContext?
    /// A SET column's checklist, or a foreign key's drop-down, while it shows.
    var checklist: SetChecklist?
    var lookup: ForeignKeyLookup?
    /// Foreign keys' labels shown after their values (by column, value → label; "" for none), the values on screen
    /// still to read, and the read under way.
    var labels: [Int: [String: String]] = [:]
    var wantedLabels: [Int: Set<String>] = [:]
    var readingLabels: Task<Void, Never>?
    /// Each column's one-column foreign key, for its labels (nil until worked out; again after a key is added).
    var labelKeys: [SchemaForeignKey?]?
    /// Edit as Table's rows, added once the table is read; and Apply shows the SQL first for them.
    var waitingInserts: InsertRows?
    var previewsApply = false
    /// A new filter or sort came while rows were loading: load again once they are in.
    var reloadWhenDone = false
    /// What went wrong last (a filter the server refused), until the next load works.
    var problem: String?
    /// The changes were left from before AirSQL quit.
    var restored = false
    var settings = TableViewSettings()
    /// Refresh Every's timer and its interval (0: off).
    var autoRefresh: Timer?
    var autoRefreshSeconds = 0
    private let initialFilter: String?

    init(model: AppModel, context: EditorContext, database: String, table: String, filter: String? = nil) {
        self.model = model
        self.context = context
        self.database = database
        tableName = table
        initialFilter = filter
        let sessions = context.sessions
        openSession = { try await sessions.session(.data) }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { autoRefresh?.invalidate() }

    var rowsPerPage: Int { max(1, model.data.settings.rowsPerPage) }

    override func loadView() {
        let view = NSView()
        view.setAccessibilityIdentifier("tableData")
        viewer.host = self
        viewer.viewKey = GridViewer.ViewKey(connection: context.connection.id, database: database, table: tableName)
        viewer.copyTable = (database, tableName)
        viewer.serverSummary = { [weak self] column, done in self?.summarize(column, done: done) }
        viewer.filterByValue = { [weak self] column, value in self?.filter(column, by: value) }
        viewer.keepValue = { [weak self] row, column, text in self?.keep(.text(text), row: row, column: column) }
        grid.cellSuffix = { [weak self] row, column in
            guard let self, let cell = viewer.hostCell(row, column) else { return nil }
            return label(cell.row, cell.column)
        }
        for (index, link) in [countLink, moreLink, allLink].enumerated() { viewer.status.insertView(link, at: index + 1, in: .trailing) }
        grid.nullText = model.data.settings.nullText
        grid.fontSize = CGFloat(model.data.settings.gridFontSize)
        grid.setAccessibilityLabel("Rows of \(tableName)")
        bar.owner = self
        findBar.owner = self
        notice.owner = self
        let bars = NSStackView(views: [bar, findBar, notice])
        bars.orientation = .vertical
        bars.spacing = 0
        bars.alignment = .leading
        for child in bars.arrangedSubviews { child.widthAnchor.constraint(equalTo: bars.widthAnchor).isActive = true }
        // The rows take all the height the bars leave, whatever the viewer shows beside them (the value panel).
        for part in [bars, viewer] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(part)
        }
        NSLayoutConstraint.activate([
            bars.topAnchor.constraint(equalTo: view.topAnchor), bars.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bars.trailingAnchor.constraint(equalTo: view.trailingAnchor), viewer.topAnchor.constraint(equalTo: bars.bottomAnchor),
            viewer.leadingAnchor.constraint(equalTo: view.leadingAnchor), viewer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            viewer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.view = view
        updateBars()
        open()
    }

    /// Reads the table's columns and keys, its saved filter and sort and any changes left from before, then the first
    /// page.
    private func open() {
        bar.busy = true
        let (connection, database, table, schema) = (context.connection.id, self.database, tableName, context.schema)
        loading = Task {
            do {
                try await schema.loadDetails([database])
                if schema.snapshot.table(database, table) == nil {
                    try await schema.refresh([.table(database: database, name: table)])
                }
                guard let info = schema.snapshot.table(database, table) else {
                    throw AirSQLError(.notFound, "The table “\(table)” isn't in “\(database)” any more.")
                }
                let keys = info.editingKey ?? []
                let (saved, left) = await Task.detached {
                    (TableViewSettingsStore.shared.settings(connection: connection, database: database, table: table),
                     PendingChangesStore.shared.changes(connection: connection, database: database, table: table, keyColumns: keys))
                }.value
                // A read-only connection checks the saved filter as the data session reads it.
                if context.connection.readOnly { noBackslashEscapes = try await openSession().noBackslashEscapes }
                show(TableDataSource(database: database, table: info), settings: saved, changes: left)
            } catch {
                problem = (error as? AirSQLError)?.message ?? error.localizedDescription
                bar.busy = false
                updateBars()
            }
            loading = nil
            guard let source, !abandoned else { return }
            // A saved filter the read-only check refuses stays in the bar, unused, and no rows load until it changes.
            if refusesOnReadOnly(source) {
                source.filter = ""
                finishLoading()
            } else {
                loadRows(more: false)
            }
        }
    }

    private func show(_ source: TableDataSource, settings saved: TableViewSettings, changes: PendingChanges?) {
        settings = saved
        let names = Set(source.columns.map(\.name))
        source.sort = saved.sort.filter { names.contains($0.column) }
        bar.filterText = initialFilter ?? saved.filter
        source.filter = GridFilter.condition(bar.filterText)
        if let changes, source.key != nil {
            source.changes = changes
            restored = true
            NotificationCenter.default.post(name: .tabContentDidChange, object: self)  // the tab's dot
        }
        self.source = source
        grid.sortOrder = source.sort.compactMap { key in
            source.columns.firstIndex { $0.name == key.column }.map { DataGridView.Sort(column: $0, ascending: key.ascending) }
        }

    }

    // MARK: Loading

    /// Loads the first page again (a new filter or sort, Refresh), or the next one (Load More). `keepingSaved`: the new
    /// rows read back after Apply stay after the loaded ones (unless the pages bring them).
    func loadRows(more: Bool, through rows: Int? = nil, keepingSaved: Bool = false) {
        guard let source, loading == nil else { return }
        let limit = more ? rowsPerPage : max(rowsPerPage, rows ?? 0)
        let sql = source.pageSQL(offset: more ? source.loadedRows : 0, limit: limit)
        let filter = source.filter
        bar.busy = true
        loading = Task {
            do {
                let session = try await openSession()
                noBackslashEscapes = session.noBackslashEscapes
                bar.whereField.noBackslashEscapes = noBackslashEscapes
                if editContext == nil { editContext = try await readEditContext(session) }
                let page = try await session.query(sql, rowCap: limit).first?.rows
                if !more {
                    source.reset(keepingSaved: keepingSaved)
                    labels = [:]
                }
                if let page { source.append(page, requested: limit) }
                problem = nil
                if !more { remember() }
                if total?.filter != filter { total = try? await estimate(session, filter: filter) }
            } catch {
                problem = "The rows didn't load: " + ((error as? AirSQLError)?.message ?? error.localizedDescription)
            }
            finishLoading()
        }
    }

    /// Loads every row that's left, in batches as they arrive (Load All).
    func loadAllRows() {
        guard let source, loading == nil, source.hasMore else { return }
        let sql = source.pageSQL(offset: source.loadedRows, limit: nil)
        bar.busy = true
        let stop = StopFlag()
        let activity = model.activity.start("Loading every row of \(tableName)", connection: context.connection.id) { stop.set() }
        loading = Task {
            do {
                let session = try await openSession()
                try await session.stream(sql, batchRows: 10_000) { page in
                    // Throwing here stops the statement on the server, as Cancel does.
                    if stop.isSet { throw CancellationError() }
                    DispatchQueue.main.async {
                        source.append(page, requested: nil)
                        self.viewer.reloadData()
                        self.updateBars()
                    }
                }
                await MainActor.run { source.finishLoading() }
            } catch is CancellationError {
            } catch {
                problem = "Not every row loaded: " + ((error as? AirSQLError)?.message ?? error.localizedDescription)
            }
            activity.end()
            finishLoading()
        }
    }

    private func finishLoading() {
        loading = nil
        bar.busy = false
        if !wantedLabels.isEmpty { readLabels() }
        // The grid gets the source with its first rows, so it sizes the columns to their values, not only their names.
        if let source, viewer.source !== source, source.loadedRows > 0 || !source.hasMore { viewer.show(source) }
        viewer.reloadData()
        updateBars()
        // Edit as Table's rows, after the loaded ones.
        if let inserts = waitingInserts, source != nil {
            waitingInserts = nil
            add(inserts)
        }
        if reloadWhenDone {
            reloadWhenDone = false
            loadRows(more: false)
        }
    }

    /// The table's estimated rows and its size (information_schema); none under a filter, which they say nothing about.
    private func estimate(_ session: TableSession, filter: String) async throws -> (rows: Int, exact: Bool, filter: String)? {
        guard let source, GridFilter.condition(filter).isEmpty else { return nil }
        let sql = source.estimateSQL(noBackslashEscapes: session.noBackslashEscapes)
        guard let store = try await session.query(sql, rowCap: 1).first?.rows, store.rowCount > 0,
              let rows = store.string(0, 0).flatMap({ Int($0) }) else { return nil }
        dataLength = store.columns.count > 1 ? store.string(0, 1).flatMap { Int($0) } : nil
        return (rows, false, filter)
    }

    /// Count Rows Exactly: COUNT(*) with the filter.
    @objc func countRows(_ sender: Any?) {
        guard let source, loading == nil else { return }
        let sql = source.countSQL, filter = source.filter
        bar.busy = true
        loading = Task {
            do {
                let session = try await openSession()
                if let store = try await session.query(sql, rowCap: 1).first?.rows, let count = store.string(0, 0).flatMap({ Int($0) }) {
                    total = (count, true, filter)
                }
            } catch {
                problem = "The rows weren't counted: " + ((error as? AirSQLError)?.message ?? error.localizedDescription)
            }
            loading = nil
            bar.busy = false
            updateBars()
        }
    }

    @objc func loadMore(_ sender: Any?) { loadRows(more: true) }

    /// Column Summary on the server: every row within the filter, on the data session; a table over 2 GB asks first.
    private func summarize(_ column: Int, done: @escaping (Result<ColumnSummary, Error>) -> Void) {
        guard let source, loading == nil else { return done(.failure(AirSQLError(.other, "Wait for the rows to load, then ask again."))) }
        let name = source.columns[column].name, open = openSession
        let summary = source.summarySQL(column), top = source.topValuesSQL(column, limit: ColumnSummary.topLimit)
        let start = { [weak self] in
            guard let self, loading == nil else { return done(.failure(AirSQLError(.other, "Wait for the rows to load, then ask again."))) }
            bar.busy = true
            let activity = model.activity.start("Summing up \(name) in \(tableName)", connection: context.connection.id)
            loading = Task {
                do {
                    let session = try await open()
                    guard let counts = try await session.query(summary, rowCap: 1).first?.rows, counts.rowCount > 0, counts.columns.count == 5,
                          let values = try await session.query(top, rowCap: ColumnSummary.topLimit).first?.rows else {
                        throw AirSQLError(.other, "The server sent no counts.")
                    }
                    func number(_ index: Int) -> Int { counts.string(0, index).flatMap { Int($0) } ?? 0 }
                    let most = (0..<values.rowCount).map { (TableDataSource.text(values, $0, 0), values.string($0, 1).flatMap { Int($0) } ?? 0) }
                    done(.success(ColumnSummary(distinct: number(0), nulls: number(1), rows: number(4), minimum: TableDataSource.text(counts, 0, 2),
                                                maximum: TableDataSource.text(counts, 0, 3), top: most)))
                } catch {
                    done(.failure(error))
                }
                activity.end()
                self.loading = nil
                self.bar.busy = false
                self.updateBars()
            }
        }
        guard let bytes = dataLength, bytes > 2 << 30, let window = view.window else { return start() }
        let alert = NSAlert()
        alert.messageText = "Sum up \(name) on the server?"
        alert.informativeText = "\(tableName) holds \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)): "
            + "Column Summary reads every row, which can take a while and load the server."
        alert.addButton(withTitle: "Sum Up").toolTip = "Count the column's values on the server"
        alert.addButton(withTitle: "Cancel").toolTip = "Close without counting"
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { start() } else { done(.failure(AirSQLError(.cancelled, "Not counted."))) }
        }
    }

    /// A link in the status bar that sends `command` to this tab, wherever the focus is.
    private func link(_ title: String, _ command: Command, id: String) -> NSButton {
        let link = GridStatusView.link(title, id: id, tip: command.tip + (command.shortcut.isEmpty ? "" : " (\(command.shortcut))"),
                                       action: command.action)
        link.target = self
        return link
    }

    /// Load All: asks first above Settings ▸ Grid's number of rows.
    @objc func loadAll(_ sender: Any?) {
        guard let source, source.hasMore else { return }
        guard let total, total.rows > model.data.settings.loadAllAsksAbove, let window = view.window else { return loadAllRows() }
        let alert = NSAlert()
        alert.messageText = "Load all \(total.exact ? "" : "about ")\(total.rows.formatted()) rows?"
        alert.informativeText = "They are held in memory while the tab is open. A filter shows fewer rows."
        alert.addButton(withTitle: "Load All")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.loadAllRows() }
        }
    }

    /// Refresh (⌘R): the rows loaded so far again, from the server.
    @objc func refresh(_ sender: Any?) {
        guard loading == nil else { return }
        guard let source else { return open() }
        total = nil
        loadRows(more: false, through: source.loadedRows, keepingSaved: true)
    }

    /// Keeps the WHERE bar's filter and the sort for the next time the table opens, the filter among the recent ones.
    func remember() {
        guard let source else { return }
        // Read again first: the viewer keeps the columns' widths, order and display types there.
        settings = TableViewSettingsStore.shared.settings(connection: context.connection.id, database: database, table: tableName)
        settings.filter = GridFilter.condition(bar.filterText)
        settings.remember(settings.filter)
        settings.sort = source.sort
        TableViewSettingsStore.shared.set(settings, connection: context.connection.id, database: database, table: tableName)
    }

    // MARK: TabContent

    var isEdited: Bool { source?.changes.isEmpty == false }
    var statusAccessory: NSView? { viewer.status }

    func shouldClose(_ answer: @escaping (Bool) -> Void) {
        guard let source, !source.changes.isEmpty, model.data.safety(for: context.connection).warnOnClose,
              let window = view.window else { return answer(true) }
        let alert = NSAlert()
        alert.messageText = "Apply the changes to \(tableName) before closing?"
        alert.informativeText = "\(source.changes.rowCount.formatted()) rows have pending changes. Kept, they come back the next "
            + "time you open the table."
        alert.addButton(withTitle: "Keep for Later")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Throw Away")
        alert.buttons[2].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: answer(true)
            case .alertThirdButtonReturn:
                self?.source?.changes.revertAll()
                self?.changesDidChange()
                answer(true)
            default: answer(false)
            }
        }
    }
}
