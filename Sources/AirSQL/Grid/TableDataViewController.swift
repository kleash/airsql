import AirSQLCore
import AppKit

/// A table's rows in a tab of their own (plan §2.5, grid-spec §4 paging): the first page (Settings ▸ Grid ▸ Rows per
/// page) loads on the data session off the main thread under a spinner, then Load More (⌥⌘↓) adds the next with
/// `LIMIT … OFFSET …`. The status bar shows the rows loaded of the server's estimate until Count Rows Exactly counts
/// them. Read-only here: editing, the WHERE bar and sorting on the server come with lane L3a.
@MainActor
final class TableDataViewController: NSViewController, TabContent {
    let connectionID: UUID
    private let connection: Connection
    private let model: AppModel
    private(set) var query: TableQuery
    private let schema: SchemaTable?
    let viewer = GridViewer(source: nil)
    private(set) var source: TableDataSource?
    /// The server's estimate of the rows, or their exact count once counted; nil when unknown (a filter).
    private(set) var total: (rows: Int, exact: Bool)?
    /// The statement running now, if any (one at a time).
    private(set) var running: Activity?
    private var session: DBConnection?
    private let spinner = NSProgressIndicator()
    private let message = label("", font: .systemFont(ofSize: 13), color: .secondaryLabelColor, wraps: true)
    private let more = GridStatusView.link("Load more", id: "table.loadMore", tip: Commands.loadMore.tip + " (⌥⌘↓)",
                                           action: Commands.loadMore.action)
    private let count = GridStatusView.link("Count exactly", id: "table.countRows", tip: Commands.countRows.tip,
                                            action: Commands.countRows.action)

    /// `filter`: a WHERE condition the rows are limited to ("" for all); `schema`: the table's, for the header.
    init(connection: Connection, id: UUID, database: String, table: String, filter: String = "", schema: SchemaTable?,
         model: AppModel) {
        self.connection = connection
        connectionID = id
        self.model = model
        query = TableQuery(database: database, table: table, filter: filter)
        self.schema = schema
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var pageSize: Int { max(1, model.data.settings.rowsPerPage) }

    override func loadView() {
        view = NSView()
        view.setAccessibilityIdentifier("table")
        let settings = model.data.settings
        viewer.grid.nullText = settings.nullText
        viewer.grid.fontSize = CGFloat(settings.gridFontSize)
        viewer.grid.setAccessibilityLabel("Rows of \(query.table)")
        viewer.viewKey = GridViewer.ViewKey(connection: connectionID, database: query.database, table: query.table)
        view.addSubview(viewer)
        viewer.pin(to: view)
        viewer.status.insertView(more, at: 1, in: .leading)
        viewer.status.insertView(count, at: 2, in: .leading)
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false
        message.alignment = .center
        message.preferredMaxLayoutWidth = 420
        for part in [spinner, message] as [NSView] { view.addSubview(part) }
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -16),
            message.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 10),
            message.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
        ])
        updateStatus()
        reload()
    }

    var statusAccessory: NSView? { viewer.status }

    // MARK: Loading

    /// Reads the first page again (and the estimate), keeping the columns as they are.
    func reload() {
        let query = query, pageSize = pageSize, filtered = !query.filter.trimmingCharacters(in: .whitespaces).isEmpty
        let first = source == nil
        if first { showMessage("Loading the rows of \(query.table)…", spinning: true) }
        run("Loading the rows of \(query.table)", { session -> (Int?, ResultStore) in
            let estimate = filtered ? nil : try await Self.rows(query.estimate(noBackslashEscapes: session.noBackslashEscapes), on: session)
            return (estimate.flatMap(Self.number), try await Self.rows(query.page(limit: pageSize, offset: 0), on: session))
        }) { [weak self] estimate, page in
            guard let self else { return }
            let source = TableDataSource(page, table: schema, pageSize: pageSize)
            self.source = source
            total = estimate.map { ($0, false) }
            if first {
                viewer.show(source)
            } else {
                viewer.grid.source = source
                viewer.restoreColumns()
            }
            showMessage(source.rowCount == 0 ? "\(query.table) has no rows\(filtered ? " that match the filter" : "")." : nil)
        }
    }

    @objc func loadMore(_ sender: Any?) {
        guard let source, !source.isComplete, running == nil else { return NSSound.beep() }
        let sql = query.page(limit: pageSize, offset: source.rowCount), pageSize = pageSize
        run("Loading more rows of \(query.table)", { session in try await Self.rows(sql, on: session) }) { [weak self] page in
            guard let self, self.source === source else { return }
            source.append(page, pageSize: pageSize)
            viewer.grid.reloadData()
        }
    }

    @objc func countRows(_ sender: Any?) {
        guard running == nil else { return NSSound.beep() }
        let sql = query.count
        run("Counting the rows of \(query.table)", { session in Self.number(try await Self.rows(sql, on: session)) }) { [weak self] rows in
            self?.total = rows.map { ($0, true) }
        }
    }

    @objc func refresh(_ sender: Any?) {
        guard running == nil else { return NSSound.beep() }
        reload()
    }

    @objc func cancelQuery(_ sender: Any?) {
        running?.cancel()
    }

    /// The first result's rows, or none.
    private static func rows(_ sql: String, on session: DBConnection) async throws -> ResultStore {
        guard let rows = try await session.query(sql, rowCap: .max).first?.rows else { return ResultStore(columns: []) }
        return rows
    }

    /// The first cell as a whole number (a count, an estimate).
    private static func number(_ rows: ResultStore) -> Int? {
        rows.rowCount > 0 && !rows.columns.isEmpty ? rows.string(0, 0).flatMap { Int($0) } : nil
    }

    /// Runs `work` on the data session off the main thread as an activity (with Cancel), then `done` with what it
    /// returned on the main thread; an error shows in place of the rows, or in an alert once rows are shown.
    private func run<T>(_ title: String, _ work: @escaping (DBConnection) async throws -> T, done: @escaping (T) -> Void) {
        let name = model.connection(connectionID)?.displayName ?? "the server"
        let activity = model.activity.start("\(title) on \(name)", connection: connectionID) { [weak self] in
            guard let session = self?.session else { return }
            Task { _ = try? await session.cancel() }
        }
        running = activity
        updateStatus()
        let connection = connection
        Task { [weak self] in
            var result: Result<T, Error>
            do {
                let session = try await connection.session(.data)
                self?.session = session
                result = .success(try await work(session))
            } catch {
                result = .failure(error)
            }
            activity.end()
            guard let self else { return }
            running = nil
            switch result {
            case .success(let value): done(value)
            case .failure(let error):
                let text = (error as? AirSQLError)?.message ?? error.localizedDescription
                if source == nil { showMessage("Couldn't load the rows: \(text)") } else { showError(text, title: title + " failed", on: view.window) }
            }
            updateStatus()
        }
    }

    // MARK: Showing

    private func showMessage(_ text: String?, spinning: Bool = false) {
        message.stringValue = text ?? ""
        message.isHidden = text == nil
        spinner.isHidden = !spinning
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// "1,000 of ≈2,348,245 rows", "1,000+ rows" or "120 rows", and Load More and Count Exactly when they apply.
    private func updateStatus() {
        let loaded = source?.rowCount ?? 0
        var text = ""
        if let source {
            if source.isComplete {
                text = "\(loaded.formatted()) row\(loaded == 1 ? "" : "s")"
            } else if let total, total.rows > loaded {
                text = "\(loaded.formatted()) of \(total.exact ? "" : "≈")\(total.rows.formatted()) rows"
            } else {
                text = "\(loaded.formatted())+ rows"
            }
        }
        viewer.status.rows.stringValue = text
        viewer.status.rows.toolTip = total?.exact == false ? "The server's estimate: Count exactly counts them" : nil
        more.isHidden = source?.isComplete != false
        count.isHidden = source == nil || source?.isComplete == true || total?.exact == true
        more.isEnabled = running == nil
        count.isEnabled = running == nil
        viewer.status.update()
    }

    // The viewer's commands (Go to Row, Hide Column…) reach it from the menu bar while the focus is outside the grid.
    override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || viewer.responds(to: selector) }
    override func forwardingTarget(for selector: Selector!) -> Any? { viewer.responds(to: selector) ? viewer : nil }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        func explained(_ enabled: Bool, _ reason: String) -> Bool {
            item.explain(enabled: enabled, reason: reason)
            return enabled
        }
        let waiting = "Wait for the rows to load"
        switch item.action {
        case Commands.loadMore.action?:
            return explained(running == nil && source?.isComplete == false, source?.isComplete == true ? "Every row is loaded" : waiting)
        case Commands.countRows.action?: return explained(running == nil && source != nil, waiting)
        case Commands.refresh.action?: return explained(running == nil, waiting)
        case Commands.cancelQuery.action?: return explained(running != nil, "Nothing is loading")
        default: return viewer.validateMenuItem(item)
        }
    }
}
