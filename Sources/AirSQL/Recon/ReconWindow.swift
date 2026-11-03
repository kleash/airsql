import AirSQLCore
import AppKit

/// The compare window (plan §2.9, mockups screen 8): two databases, on the same or different connections, compared in
/// structure and data; the differences listed with what makes them; a sync script reviewed in the SQL preview and run
/// only when the person says so, on a session of its own.
@MainActor
final class ReconWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// Reaches a saved connection's sessions: the connections lane's connection manager (the integrator sets it). Each
    /// compare and each sync opens tools sessions of its own on it and closes them when done.
    static var connect: ((SavedConnection) async throws -> Connection)?

    nonisolated static let minimumSize = NSSize(width: 960, height: 600)
    nonisolated static let defaultSize = NSSize(width: 1240, height: 780)

    /// Open compare windows (nothing else holds them).
    private static var open: [ReconWindowController] = []

    let model: AppModel
    var options = ReconOptions()
    private(set) var result: ReconResult?
    private var task: Task<Void, Never>?
    private var activity: Activity?

    let source = ReconSidePicker(side: "source"), target = ReconSidePicker(side: "target")
    let toolbarItems = ReconToolbar()
    let progressBar = NSProgressIndicator()
    let progressLabel = label("", color: .secondaryLabelColor, truncates: true)
    let progressStrip = NSStackView()
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
            picker.changed = { [weak self] in self?.update() }
        }
        toolbarItems.window = self
        results.window = self
        window.open(size: Self.defaultSize, autosave: layoutName("Compare"))
        Self.open.append(self)
        update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeContent() -> NSView {
        let root = SurfaceView(.ground)
        let arrow = label("→", font: .systemFont(ofSize: 15, weight: .medium), color: .secondaryLabelColor)
        arrow.toolTip = "The script makes the target (right) match the source (left)"
        let swap = button("Swap", id: "recon.swap", tip: "Swap source and target", target: self, action: #selector(swapSides(_:)))
        let setup = NSStackView(views: [source.view, arrow, target.view, swap])
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
        let line = ReconWindowController.line()
        let stack = NSStackView(views: [bar, line, progressStrip, results.view])
        stack.orientation = .vertical
        stack.distribution = .fill
        stack.spacing = 0
        // The setup and progress keep their height; the results take the rest.
        setup.setHuggingPriority(.defaultHigh, for: .vertical)
        progressStrip.setHuggingPriority(.defaultHigh, for: .vertical)
        stack.alignment = .leading
        for view in [bar, line, progressStrip, results.view] {
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
        if source.database.isEmpty || target.database.isEmpty { return "Choose a database on each side first" }
        if source.connection?.id == target.connection?.id && source.database == target.database {
            return "Choose two different databases: these are the same one"
        }
        return nil
    }

    // MARK: Comparing

    /// Compare again (⌘R).
    @objc func refresh(_ sender: Any?) {
        guard compareBlocked == nil, let connect = Self.connect, let left = source.connection, let right = target.connection
        else { return }
        let (leftDatabase, rightDatabase, options) = (source.database, target.database, self.options)
        activity = model.activity.start("Comparing \(source.summary) with \(target.summary)", connection: right.id) { [weak self] in
            self?.task?.cancel()
        }
        progressBar.doubleValue = 0
        progressLabel.stringValue = "Connecting…"
        progressStrip.isHidden = false
        task = Task { [weak self] in
            var sessions: [DBConnection] = []
            let outcome: Result<ReconResult, Error>
            do {
                let a = try await connect(left).toolsSession()
                sessions.append(a)
                let b = try await connect(right).toolsSession()
                sessions.append(b)
                outcome = .success(try await Recon.run(
                    source: ReconSide(name: left.displayName, database: leftDatabase, session: a),
                    target: ReconSide(name: right.displayName, database: rightDatabase, session: b), options: options) { step in
                        DispatchQueue.main.async { self?.show(step) }
                    })
            } catch {
                outcome = .failure(error)
            }
            for session in sessions { await session.close() }
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
        case .success(let result): show(result)
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

    @objc func swapSides(_ sender: Any?) {
        let (connection, database) = (source.connection, source.database)
        source.choose(target.connection, database: target.database)
        target.choose(connection, database: database)
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
        case #selector(showSyncScript(_:)), #selector(exportReport(_:)):
            reason = result == nil ? "Compare first: then there is something to show" : nil
        case #selector(copySyncScript(_:)), #selector(leaveOutOfCompare(_:)), #selector(NSText.copy(_:)):
            reason = results.selected.isEmpty ? "Select objects in the list first" : nil
        default: return true
        }
        menuItem.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }
}
