import AirSQLCore
import AppKit

/// The compare window (plan §2.9, mockups screen 8): two servers, databases or objects, on the same or different
/// connections, compared in structure and data; the differences listed with what makes them; a sync script reviewed in a
/// console tab and the SQL preview, and run only when the person says so, on a session of its own.
@MainActor
final class ReconWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// Reaches a saved connection's sessions, connecting it first when it isn't, its prompts on the window given
    /// (`AppDelegate` sets it; tests reach the lab). Each compare and each sync opens tools sessions of its own on it and
    /// closes them when done.
    static var connect: ((SavedConnection, NSWindow?) async throws -> Connection)?

    nonisolated static let minimumSize = NSSize(width: 960, height: 600)
    nonisolated static let defaultSize = NSSize(width: 1240, height: 780)

    /// Open compare windows (nothing else holds them).
    private static var open: [ReconWindowController] = []

    let model: AppModel
    /// The main window that opened it: the sync script opens in a console tab there.
    weak var main: MainWindowController?
    var options = ReconOptions()
    private(set) var result: ReconResult?
    /// The server compare a database pair was opened from, for Back to All Databases.
    private(set) var serverResult: ReconResult?
    /// The connection the shown result's target is on: the sync script runs there, whatever the picker says by then.
    private var comparedTarget: SavedConnection?
    private var task: Task<Void, Never>?
    private var activity: Activity?

    let source = ReconSidePicker(side: "source"), target = ReconSidePicker(side: "target")
    let toolbarItems = ReconToolbar()
    let progressBar = NSProgressIndicator()
    let progressLabel = label("", color: .secondaryLabelColor, truncates: true)
    let progressStrip = NSStackView()
    /// The two objects, under the sides, at the Objects level.
    let objectBar = SurfaceView(.bar)
    let results = ReconResultsView()

    /// Opens a compare window, with `source` chosen as the source when given.
    @discardableResult
    static func show(model: AppModel, source: SavedConnection?) -> ReconWindowController {
        let controller = ReconWindowController(model: model)
        if let source { controller.source.choose(source) }
        controller.showWindow(nil)
        return controller
    }

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.title = "Compare"
        window.backgroundColor = .ground
        window.autorecalculatesKeyViewLoop = true  // Tab goes through the list and views a compare shows
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "Compare")
        toolbar.delegate = toolbarItems
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.contentView = makeContent()
        window.initialFirstResponder = source.popup
        for picker in [source, target] {
            picker.connections = model.data.connections.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            picker.changed = { [weak self] in
                self?.serverResult = nil
                self?.update()
            }
        }
        toolbarItems.window = self
        results.window = self
        window.open(size: Self.defaultSize, autosave: layoutName("Compare"))
        window.layoutIfNeeded()
        results.placeDivider()
        Self.open.append(self)
        update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeContent() -> NSView {
        let root = SurfaceView(.ground)
        let arrow = label("→", font: .systemFont(ofSize: 15, weight: .medium), color: .secondaryLabelColor)
        arrow.toolTip = "The script makes the target (right) match the source (left)"
        let swap = button("Swap", id: "recon.swap", tip: "Swap source and target", target: self, action: #selector(swapSides(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let setup = NSStackView(views: [toolbarItems.level, source.view, arrow, target.view, swap, spacer, helpButton(.compare)])
        setup.spacing = Spacing.double
        setup.edgeInsets = NSEdgeInsets(top: Spacing.unit, left: Spacing.double, bottom: Spacing.unit, right: Spacing.double)
        setup.setHuggingPriority(.defaultLow, for: .horizontal)
        let bar = SurfaceView(.bar)
        bar.addSubview(setup)
        setup.pin(to: bar)
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(equalToConstant: 160).isActive = true
        progressBar.setAccessibilityIdentifier("recon.progress")
        let cancel = button("Cancel", id: "recon.cancel", tip: "Stop the compare (⌘.)", target: self, action: #selector(cancelQuery(_:)))
        cancel.controlSize = .small
        progressStrip.setViews([progressBar, progressLabel, cancel], in: .leading)
        progressStrip.spacing = Spacing.unit
        progressStrip.edgeInsets = NSEdgeInsets(top: Spacing.half, left: Spacing.double, bottom: Spacing.half, right: Spacing.double)
        progressStrip.isHidden = true
        let objects = NSStackView(views: [label("Objects", font: .systemFont(ofSize: 12, weight: .semibold), color: .secondaryLabelColor),
                                          source.objects, label("→", font: .systemFont(ofSize: 15, weight: .medium), color: .secondaryLabelColor),
                                          target.objects])
        objects.spacing = Spacing.double
        objects.edgeInsets = NSEdgeInsets(top: 0, left: Spacing.double, bottom: Spacing.unit, right: Spacing.double)
        objects.setHuggingPriority(.defaultLow, for: .horizontal)
        objectBar.addSubview(objects)
        objects.pin(to: objectBar)
        objectBar.isHidden = true
        let line = ReconWindowController.line()
        let stack = NSStackView(views: [bar, objectBar, line, progressStrip, results.view])
        stack.orientation = .vertical
        stack.distribution = .fill
        stack.spacing = 0
        // The setup and progress keep their height; the results take the rest.
        setup.setHuggingPriority(.defaultHigh, for: .vertical)
        progressStrip.setHuggingPriority(.defaultHigh, for: .vertical)
        stack.alignment = .leading
        for view in [bar, objectBar, line, progressStrip, results.view] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        root.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    /// A separator line between bars: one point high (a hairline has no height of its own).
    static func line() -> Hairline {
        let line = Hairline()
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    var isRunning: Bool { task != nil }

    var level: ReconLevel { ReconLevel(rawValue: toolbarItems.level.indexOfSelectedItem) ?? .database }

    /// Compares servers, databases or objects from now on.
    func choose(level: ReconLevel) {
        toolbarItems.level.selectItem(at: level.rawValue)
        source.level = level
        target.level = level
        objectBar.isHidden = level != .object
        serverResult = nil
        update()
    }

    /// Fills both sides in (a start from the tree); without a `right`, the target is left to choose.
    func start(_ level: ReconLevel, left: ReconStart, right: ReconStart?) {
        choose(level: level)
        source.choose(left.connection, database: left.database, object: left.object)
        if let right { target.choose(right.connection, database: right.database, object: right.object) }
        window?.makeFirstResponder(level == .object ? target.objects : target.popup)
    }

    /// Brings the controls up to date with the choices, the run and the result.
    func update() {
        toolbarItems.update()
        results.update()
        window?.title = source.summary.isEmpty ? "Compare" : "Compare \(source.summary) with \(target.summary)"
    }

    /// Why Compare can't start now, or nil when it can.
    var compareBlocked: String? {
        if isRunning { return "A compare is running: wait for it, or Cancel it" }
        if Self.connect == nil { return "This build of AirSQL can't open connections yet" }
        if source.connection == nil || target.connection == nil { return "Choose a connection on each side first" }
        let sameConnection = source.connection?.id == target.connection?.id
        if level == .server { return sameConnection ? "Choose two different connections: these are the same one" : nil }
        if source.database.isEmpty || target.database.isEmpty { return "Choose a database on each side first" }
        let sameDatabase = sameConnection && source.database == target.database
        if level == .database { return sameDatabase ? "Choose two different databases: these are the same one" : nil }
        guard let left = source.object, let right = target.object else { return "Choose an object on each side first" }
        if left.kind != right.kind { return "Choose two of one kind: a \(left.kind.rawValue) and a \(right.kind.rawValue) can't be compared" }
        return sameDatabase && left.name == right.name ? "Choose two different objects: these are the same one" : nil
    }

    /// The connection the sync script of the shown result belongs to.
    var comparedConnection: SavedConnection? { comparedTarget ?? target.connection }

    /// Why the result has no sync script to show, or nil when it has.
    var scriptBlocked: String? {
        guard let result else { return "Compare first: then there is something to show" }
        return result.isServer ? "A script belongs to one pair of databases: open one first" : nil
    }

    /// Why Tables… can't open now, or nil when it can: it needs a compare's list or a source to read one from.
    var tablesBlocked: String? {
        if level == .server { return "Tables… chooses within one database: open a pair of databases first" }
        if level == .object {
            guard let object = source.object else { return "Choose an object for the source first" }
            return object.kind == .table ? nil : "Only tables have columns and rows to choose"
        }
        if result != nil { return nil }
        if isRunning || Self.connect == nil { return compareBlocked }
        return source.connection == nil || source.database.isEmpty ? "Choose a connection and a database for the source first" : nil
    }

    // MARK: Comparing

    /// Tables…: the last compare's tables or, before one, the source's, so that a long first run can be limited.
    @objc func showTables(_ sender: Any?) {
        guard let window, tablesBlocked == nil else { return }
        if level == .object, let object = source.object {
            return ReconTablesSheet.show(for: self, tables: [object.name], on: window)
        }
        if let result {
            let tables = result.objects.filter { $0.kind == .table && $0.status != .onlyInTarget }.map(\.name)
            return ReconTablesSheet.show(for: self, tables: tables, on: window)
        }
        guard let connect = Self.connect, let left = source.connection else { return }
        let database = source.database
        progressBar.doubleValue = 0
        progressLabel.stringValue = "Reading the tables of \(database)…"
        progressStrip.isHidden = false
        task = Task { [weak self] in
            var tables: [String] = [], failure: Error?
            do {
                let session = try await connect(left, window).toolsSession()
                do {
                    let cache = SchemaCache(source: session, includes: { $0 == database })
                    try await cache.load()
                    tables = cache.snapshot.database(database)?.tables.filter { $0.kind == .table }.map(\.name) ?? []
                } catch {
                    failure = error
                }
                await session.close()
            } catch {
                failure = error
            }
            guard let self else { return }
            self.task = nil
            self.progressStrip.isHidden = true
            self.update()
            if failure is CancellationError || (failure as? AirSQLError)?.kind == .cancelled { return }
            if let failure { return showError(failure.localizedDescription, title: "The tables couldn't be read", on: window) }
            if tables.isEmpty {
                return showError("\(left.displayName) has no tables in \(database), or this login can't see them.",
                                 title: "No tables to choose", on: window)
            }
            ReconTablesSheet.show(for: self, tables: tables, on: window)
        }
        update()
    }

    /// Compare again (⌘R).
    @objc func refresh(_ sender: Any?) {
        guard compareBlocked == nil, let connect = Self.connect, let left = source.connection, let right = target.connection
        else { return }
        var options = self.options
        options.only = nil
        if level == .object, let first = source.object, let second = target.object {
            options.only = ReconPair(kind: first.kind, source: first.name, target: second.name)
        }
        let (leftDatabase, rightDatabase, level) = (self.level == .server ? "" : source.database,
                                                    self.level == .server ? "" : target.database, self.level)
        activity = model.activity.start("Comparing \(source.summary) with \(target.summary)", connection: right.id) { [weak self] in
            self?.task?.cancel()
        }
        progressBar.doubleValue = 0
        progressLabel.stringValue = "Connecting…"
        progressStrip.isHidden = false
        let window = self.window
        task = Task { [weak self] in
            var sessions: [DBConnection] = []
            let outcome: Result<ReconResult, Error>
            do {
                let a = try await connect(left, window).toolsSession()
                sessions.append(a)
                let b = try await connect(right, window).toolsSession()
                sessions.append(b)
                let sides = (ReconSide(name: left.displayName, database: leftDatabase, session: a),
                             ReconSide(name: right.displayName, database: rightDatabase, session: b))
                let progress: (ReconProgress) -> Void = { step in DispatchQueue.main.async { self?.show(step) } }
                outcome = .success(level == .server
                    ? try await Recon.runServer(source: sides.0, target: sides.1, options: options, progress: progress)
                    : try await Recon.run(source: sides.0, target: sides.1, options: options, progress: progress))
            } catch {
                outcome = .failure(error)
            }
            for session in sessions { await session.close() }
            if case .success = outcome { self?.comparedTarget = right }
            self?.finished(outcome)
        }
        update()
    }

    /// Stops the compare (⌘.).
    @objc func cancelQuery(_ sender: Any?) {
        task?.cancel()
        progressLabel.stringValue = "Stopping…"
    }

    private func show(_ step: ReconProgress) {
        guard isRunning else { return }
        var text = step.step
        if step.table != nil, step.chunks > 0 {
            text += " · chunk \(step.chunk.formatted()) of \(step.chunks.formatted())"
        }
        if step.rowsChecked > 0 { text += " · \(step.rowsChecked.formatted()) rows checked" }
        progressLabel.stringValue = text
        progressLabel.toolTip = text
        progressBar.doubleValue = step.fraction
        activity?.progress = step.tables > 0 ? step.fraction : nil
        activity?.detail = text
    }

    private func finished(_ outcome: Result<ReconResult, Error>) {
        task = nil
        activity?.end()
        activity = nil
        progressStrip.isHidden = true
        switch outcome {
        case .success(let result):
            serverResult?.update(pair: result.source.database, with: result)
            show(result)
        case .failure(let error) where error is CancellationError || (error as? AirSQLError)?.kind == .cancelled:
            break
        case .failure(let error):
            showError(error.localizedDescription, title: "The compare stopped with an error", on: window)
        }
        update()
    }

    /// Shows a compare's result (tests and screenshots give one directly).
    func show(_ result: ReconResult) {
        self.result = result
        results.show(result)
        update()
    }

    /// Opens a pair of a server compare: its own result, list and sync script, as a database compare.
    func openPair(_ object: ReconObject) {
        guard let result, let pair = result.databases[object.name], !isRunning else { return }
        let (left, right) = (source.connection, target.connection)
        choose(level: .database)
        source.choose(left, database: object.name)
        target.choose(right, database: object.targetName)
        serverResult = result  // after the pickers, as choosing starts anew
        show(pair)
    }

    /// Back to the pairs of the server compare, with what was done in the open pair.
    @objc func backToServer(_ sender: Any?) {
        guard var server = serverResult, let result, !isRunning else { return }
        server.update(pair: result.source.database, with: result)
        choose(level: .server)
        show(server)
    }

    /// The objects leave the sync script, or come back to it.
    func set(_ objects: [ReconObject], leftOut: Bool) {
        guard var changed = result else { return }
        for object in objects {
            if let index = changed.objects.firstIndex(where: { $0.kind == object.kind && $0.name == object.name }) {
                changed.objects[index].leftOut = leftOut
            }
        }
        result = changed
        results.refresh(changed)
        update()
    }

    @objc func swapSides(_ sender: Any?) {
        let (connection, database, object) = (source.connection, source.database, source.object)
        source.choose(target.connection, database: target.database, object: target.object)
        target.choose(connection, database: database, object: object)
        update()
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        Self.open.removeAll { $0 === self }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let reason: String?
        switch menuItem.action {
        case #selector(refresh(_:)): reason = compareBlocked
        case #selector(cancelQuery(_:)): reason = isRunning ? nil : "No compare is running"
        case #selector(showSyncScript(_:)):
            reason = scriptBlocked
        case #selector(exportReport(_:)):
            reason = result == nil ? "Compare first: then there is something to show" : nil
        case #selector(backToServer(_:)):
            reason = serverResult == nil ? "No server compare is open behind this one" : isRunning ? compareBlocked : nil
        case #selector(copySyncScript(_:)), #selector(includeInSync(_:)):
            reason = scriptBlocked ?? (results.selected.isEmpty ? "Select objects in the list first" : nil)
            if menuItem.action == #selector(includeInSync(_:)) {
                menuItem.state = !results.selected.isEmpty && results.selected.allSatisfy { !$0.leftOut } ? .on : .off
            }
        case #selector(nextDifference(_:)), #selector(previousDifference(_:)):
            reason = results.detail.differenceBlocked
        case #selector(leaveOutOfCompare(_:)):
            reason = level != .database ? "Only a compare of two databases has tables to leave out"
                : results.selected.isEmpty ? "Select objects in the list first" : nil
        case #selector(NSText.copy(_:)):
            reason = results.selected.isEmpty ? "Select objects in the list first" : nil
        default: return true
        }
        menuItem.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }
}
