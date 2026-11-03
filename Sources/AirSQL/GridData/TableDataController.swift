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

/// A table's or view's rows in a tab (plan §2.5, grid-spec §4–§6): the grid bar (where filtering runs, the WHERE
/// condition, Search All Columns), a notice for pending changes or why the table is read-only, and the grid. Rows load
/// a page at a time on the connection's data session; edits wait as pending changes until Apply, which runs them there
/// in one transaction. Nothing waits on the network on the main thread.
@MainActor
final class TableDataController: NSViewController, TabContent {
    let model: AppModel
    let context: EditorContext
    let database: String
    let tableName: String
    /// The data session; the tests give their own.
    var openSession: () async throws -> TableSession
    private(set) var source: TableDataSource?
    let grid = DataGridView()
    let bar = TableDataBar()
    let notice = TableDataNotice()
    let status = TableDataStatus()
    /// The rows' estimate (information_schema) or exact count (Count Rows Exactly), with the filter it was for.
    var total: (rows: Int, exact: Bool, filter: String)?
    /// A load under way (a page, Load All, Refresh, Apply): one at a time.
    var loading: Task<Void, Never>?
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
        grid.delegate = self
        grid.nullText = model.data.settings.nullText
        grid.fontSize = CGFloat(model.data.settings.gridFontSize)
        grid.setAccessibilityLabel("Rows of \(tableName)")
        bar.owner = self
        notice.owner = self
        status.owner = self
        let stack = NSStackView(views: [bar, notice, grid.containerView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        view.addSubview(stack)
        stack.pin(to: view)
        grid.containerView.setContentHuggingPriority(.defaultLow, for: .vertical)
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
                let keys = TableEditing.key(of: info).columns ?? []
                let (saved, left) = await Task.detached {
                    (TableViewSettingsStore.shared.settings(connection: connection, database: database, table: table),
                     PendingChangesStore.shared.changes(connection: connection, database: database, table: table, keyColumns: keys))
                }.value
                show(TableDataSource(database: database, table: info), settings: saved, changes: left)
            } catch {
                problem = (error as? AirSQLError)?.message ?? error.localizedDescription
                bar.busy = false
                updateBars()
            }
            loading = nil
            if source != nil { loadRows(more: false) }
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
        }
        self.source = source
        grid.source = source
        grid.sortOrder = source.sort.compactMap { key in
            source.columns.firstIndex { $0.name == key.column }.map { DataGridView.Sort(column: $0, ascending: key.ascending) }
        }
    }

    // MARK: Loading

    /// Loads the first page again (a new filter or sort, Refresh), or the next one (Load More).
    func loadRows(more: Bool, through rows: Int? = nil) {
        guard let source, loading == nil else { return }
        let limit = more ? rowsPerPage : max(rowsPerPage, rows ?? 0)
        let sql = source.pageSQL(offset: more ? source.loadedRows : 0, limit: limit)
        let filter = source.filter
        bar.busy = true
        loading = Task {
            do {
                let session = try await openSession()
                let page = try await session.query(sql, rowCap: limit).first?.rows
                if !more { source.reset() }
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
                        self.grid.reloadData()
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
        grid.reloadData()
        updateBars()
        if reloadWhenDone {
            reloadWhenDone = false
            loadRows(more: false)
        }
    }

    /// The table's estimated rows (information_schema), or the exact count when there is a filter that was counted.
    private func estimate(_ session: TableSession, filter: String) async throws -> (rows: Int, exact: Bool, filter: String)? {
        guard GridFilter.condition(filter).isEmpty else { return nil }
        let sql = "SELECT TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA = "
            + SQLQuote.string(database, noBackslashEscapes: session.noBackslashEscapes) + " AND TABLE_NAME = "
            + SQLQuote.string(tableName, noBackslashEscapes: session.noBackslashEscapes)
        guard let store = try await session.query(sql, rowCap: 1).first?.rows, store.rowCount > 0,
              let rows = store.string(0, 0).flatMap({ Int($0) }) else { return nil }
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

    /// Load All asks first above this many rows.
    static let loadAllAsksAbove = 100_000

    @objc func loadAll(_ sender: Any?) {
        guard let source, source.hasMore else { return }
        guard let total, total.rows > Self.loadAllAsksAbove, let window = view.window else { return loadAllRows() }
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
        guard let source else { return open() }
        total = nil
        loadRows(more: false, through: source.loadedRows)
    }

    /// Keeps the WHERE bar's filter and the sort for the next time the table opens, the filter among the recent ones.
    func remember() {
        guard let source else { return }
        settings.filter = GridFilter.condition(bar.filterText)
        settings.remember(settings.filter)
        settings.sort = source.sort
        TableViewSettingsStore.shared.set(settings, connection: context.connection.id, database: database, table: tableName)
    }

    // MARK: TabContent

    var isEdited: Bool { source?.changes.isEmpty == false }
    var statusAccessory: NSView? { status }

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
