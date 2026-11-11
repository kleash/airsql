import AirSQLCore
import AppKit

/// Watch Changes (mongo-plan, Phase 4 "watch"): a collection's or a database's change stream in a tab, its events in
/// the grid (`MongoDocumentSource`: events are documents), newest first and capped (`MongoWatch.Events`). One filter on
/// the events, `$match`; Look Up Full Document adds an update's whole document. Start/Stop: Stop ends the stream, and
/// Start continues after the last event it saw, so nothing written meanwhile is missed. The stream reads on a session of
/// its own (the tab's slot), closed with the tab; a connection that drops or an error the driver can't resume from stops
/// it and says so. It never starts by itself after a relaunch.
@MainActor
final class MongoWatchController: NSViewController, TabContent, DataGridViewDelegate, NSMenuItemValidation {
    let model: AppModel
    let connectionID: UUID
    let database: String
    /// nil: the whole database.
    let collection: String?
    let viewer = GridViewer(source: nil)
    var grid: DataGridView { viewer.grid }
    private(set) var source = MongoDocumentSource()
    let notice = TableDataNotice()
    private static let filterTip = "Show only the changes that match, as a filter on the change events; Return starts"
    private static let lookUpTip = "Show an update's whole document as it is now, read again for each update"
    private static let stopFirst = "Stop first to change what the watch shows"
    let filter = textField("", placeholder: "{ operationType: \"insert\" }", id: "watch.filter", tip: filterTip)
    let lookUp = checkbox("Look Up Full Document", id: "watch.lookUp", tip: lookUpTip, on: false, target: nil, action: nil)
    private(set) lazy var startStop = button("Start", id: "watch.startStop", tip: "", target: self, action: #selector(toggle(_:)),
                                             primary: true)
    let spinner = NSProgressIndicator()
    /// Set before the view loads: false for a tab back after a relaunch, which waits for Start.
    var startsOnOpen = true
    private(set) var events = MongoWatch.Events()
    /// Where the stream got to: Start continues after it.
    private(set) var token: BSONDocument?
    private(set) var watching: Task<Void, Never>?
    private(set) var problem: String?
    private(set) var info: String?
    private var session: MongoSession?
    private weak var sessionOf: MongoConnection?
    private let slot = UUID().uuidString
    private var showing = false

    init(model: AppModel, connection: UUID, database: String, collection: String?) {
        self.model = model
        connectionID = connection
        self.database = database
        self.collection = collection
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var connection: MongoConnection? { model.openMongo[connectionID]?.connection }
    private var scope: String { collection.map { "\($0) in \(database)" } ?? "the database \(database)" }

    override func loadView() {
        let view = NSView()
        view.setAccessibilityIdentifier("mongoWatch")
        filter.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        filter.target = self
        filter.action = #selector(toggle(_:))
        filter.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Watching for changes")
        let name = label("Filter", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        filter.setAccessibilityTitleUIElement(name)
        let options = NSStackView(views: [name, filter, lookUp, spinner, startStop])
        options.spacing = Spacing.unit
        options.edgeInsets = NSEdgeInsets(top: 6, left: Spacing.double, bottom: 6, right: Spacing.double)
        options.setHuggingPriority(.defaultHigh, for: .vertical)
        let bar = SurfaceView(.bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(options)
        options.pin(to: bar)

        viewer.host = self
        viewer.viewKey = GridViewer.ViewKey(connection: connectionID, database: database, table: (collection ?? "") + " changes")
        viewer.copyTable = (database, collection ?? "changes")
        viewer.whyReadOnly = { _, _ in "a change event can't be edited: open the collection to change its documents" }
        grid.nullText = model.data.settings.nullText
        grid.fontSize = CGFloat(model.data.settings.gridFontSize)
        grid.setAccessibilityLabel("Changes to \(scope), newest first")
        notice.owner = self
        let stack = NSStackView(views: [bar, notice, viewer])
        stack.orientation = .vertical
        stack.spacing = 0
        for part in stack.arrangedSubviews { part.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        viewer.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.addSubview(stack)
        stack.pin(to: view)
        self.view = view
        updateBars()
        if startsOnOpen { start() }
    }

    // MARK: Watching

    /// Start: a change stream from now, or after the last event seen; the events it gives go to the top of the grid.
    func start() {
        guard watching == nil else { return }
        guard let connection, let open = model.openMongo[connectionID] else {
            return fail("Connect to the server again to watch its changes.")
        }
        let kind = collection.flatMap { name in open.collections[database]?.first { $0.name == name }?.kind }
        if let reason = open.watchRefusal(database, collection == nil ? nil : kind) {
            return fail(reason)
        }
        let pipeline: [BSONDocument]
        do {
            pipeline = try MongoWatch.pipeline(filter: filter.stringValue)
        } catch {
            view.window?.makeFirstResponder(filter)
            return fail("\(error)")
        }
        let (database, collection, lookUp) = (database, collection, lookUp.state == .on)
        problem = nil
        info = nil
        watching = Task { [self] in
            var stream: MongoChangeStream?
            do {
                let session = try await ownSession(connection)
                // Stop cancels the task: seen here between reads, each at most about a second.
                while !Task.isCancelled {
                    do {
                        if stream == nil {
                            stream = try await session.watch(database: database, collection: collection, pipeline: pipeline,
                                                             lookUp: lookUp, resumeAfter: token)
                        }
                        let batch = try await stream!.next()
                        token = stream?.token ?? token
                        if !batch.isEmpty {
                            events.add(batch)
                            showSoon()
                        }
                    } catch where token != nil && MongoWatch.historyLost(error) {
                        await stream?.close()
                        (stream, token) = (nil, nil)
                        info = "The server no longer has every change since this tab stopped, so it watches from now: "
                            + "changes made in between aren't shown."
                        updateBars()
                    }
                }
            } catch {
                problem = "The watch stopped: \(error.localizedDescription) Start continues after the last change shown."
            }
            await stream?.close()
            watching = nil
            updateBars()
            NotificationCenter.default.post(name: .tabContentDidChange, object: self)
        }
        updateBars()
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
    }

    /// Stop: the stream ends after the read under way (at most about a second); the place it got to is kept.
    func stop() { watching?.cancel() }

    @objc func toggle(_ sender: Any?) {
        if watching == nil { start() } else if sender as? NSButton === startStop { stop() }
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

    /// Stops for good (the tab closed): the stream and the session.
    func close() {
        stop()
        session = nil
        if let connection = sessionOf { Task { [slot] in await connection.closeSession(.data, slot: slot) } }
    }

    private func fail(_ message: String) {
        problem = message
        updateBars()
    }

    // MARK: Showing

    /// Events come in bursts: the grid is made again at most five times a second.
    private func showSoon() {
        guard !showing else { return }
        showing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.showEvents() }
    }

    private func showEvents() {
        showing = false
        let origin = grid.scrollView.contentView.bounds.origin
        source = MongoDocumentSource()
        source.append(events.events)
        viewer.show(source)
        grid.scrollView.contentView.scroll(to: origin)
        grid.scrollView.reflectScrolledClipView(grid.scrollView.contentView)
        updateBars()
    }

    func updateBars() {
        let on = watching != nil
        startStop.title = on ? "Stop" : "Start"
        startStop.toolTip = on ? "Stop watching; Start continues after the last change shown, with those made meanwhile"
            : token == nil ? "Watch the changes made from now on" : "Watch again from the last change shown, with those made meanwhile"
        filter.isEnabled = !on
        lookUp.isEnabled = !on
        filter.toolTip = on ? Self.stopFirst : Self.filterTip
        lookUp.toolTip = on ? Self.stopFirst : Self.lookUpTip
        if on { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let state = on ? "Watching \(scope): new changes show at the top within about a second."
            : token == nil ? "Start watches \(scope) for changes made from now on."
            : "Stopped: Start continues after the last change shown, with those made meanwhile."
        notice.show(problem == nil ? .readOnly : .problem, problem ?? info ?? state)
        let count = events.events.count
        viewer.status.rows.stringValue = "\(count.formatted()) change\(count == 1 ? "" : "s")"
            + (events.dropped > 0 ? " · the oldest \(events.dropped.formatted()) dropped" : "")
        viewer.status.rows.toolTip = "A tab keeps the newest \(MongoWatch.Events.maxCount.formatted()) changes, and at most "
            + "\(MongoWatch.Events.maxBytes >> 20) MB of them"
        viewer.status.update()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let action = item.action, !Self.instancesRespond(to: action), viewer.responds(to: action) {
            return viewer.validateMenuItem(item)
        }
        return true
    }

    // MARK: TabContent

    var isBusy: Bool { watching != nil }
    var statusAccessory: NSView? { viewer.status }

    var reopen: ((MainWindowController) -> Void)? {
        let (database, collection, connection) = (database, collection, connectionID)
        return { main in main.openWatch(database: database, collection: collection, connection: connection) }
    }

    func shouldClose(_ answer: @escaping (Bool) -> Void) {
        close()
        answer(true)
    }
}

extension OpenMongoConnection {
    /// Why Watch Changes can't watch `database`, or a collection of it of `kind` (nil: the database); nil when it can.
    func watchRefusal(_ database: String, _ kind: MongoCollectionInfo.Kind?) -> String? {
        if server.setName == nil && !server.isMongos {
            return "Watching changes needs a replica set or a sharded cluster, and this server is a standalone"
        }
        if Self.isInternal(database) { return "MongoDB doesn't watch its own databases (admin, local and config)" }
        switch kind {
        case .view?: return "A view has no changes of its own: watch the collection it reads"
        case .timeseries?: return "MongoDB can't watch a time-series collection"
        default: return nil
        }
    }
}

// MARK: Opening

extension MainWindowController {
    /// A watch tab on a collection, or on a database (nil): the one it has already, or a new one.
    func openWatch(database: String, collection: String?, connection: UUID) {
        if let tab = tabs.first(where: {
            guard let watch = $0.content as? MongoWatchController else { return false }
            return watch.connectionID == connection && watch.database == database && watch.collection == collection
        }) {
            return select(tab)
        }
        let content = MongoWatchController(model: model, connection: connection, database: database, collection: collection)
        _ = open(content, title: (collection ?? database) + " changes", connection: connection)
        window?.makeFirstResponder(content.grid)
    }
}

// Watch Changes answers in the responder chain: from the tree, for its selected collection or database; from a
// collection's tab, for that collection.

extension SidebarController {
    /// The tree's one database or collection to watch, or why there's none.
    var watchTarget: (open: OpenMongoConnection, database: String, collection: String?, refusal: String?)? {
        guard let (open, items) = mongoSelection, items.count == 1, items[0].index == nil else { return nil }
        let item = items[0]
        let kind = item.collection.map { _ in mongoInfo(open.saved.id, item)?.kind ?? .collection }
        return (open, item.database, item.collection, open.watchRefusal(item.database, kind))
    }

    @objc func watchChanges(_ sender: Any?) {
        guard let main, let target = watchTarget, target.refusal == nil else { return NSSound.beep() }
        main.openWatch(database: target.database, collection: target.collection, connection: target.open.saved.id)
    }

    var watchReason: String? {
        guard let target = watchTarget else { return "Select one database or collection of a connected MongoDB server in the tree first" }
        return target.refusal
    }
}

extension MongoCollectionController {
    @objc func watchChanges(_ sender: Any?) {
        (view.window?.windowController as? MainWindowController)?.openWatch(database: database, collection: name, connection: connectionID)
    }

    var watchReason: String? {
        model.openMongo[connectionID].map { $0.watchRefusal(database, info.kind) } ?? "Connect to the server again first"
    }
}
