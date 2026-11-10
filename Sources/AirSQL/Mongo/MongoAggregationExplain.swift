import AirSQLCore
import AppKit

/// A MongoDB plan (mongo-plan, Explain): what makes it slow listed first, then `PlanView` with `MongoExplain`'s steps,
/// its Text page (`MongoExplain.tree`) and the server's own answer.
@MainActor
final class MongoExplainView: NSView {
    let plan: PlanView
    let warnings: [String]

    init(_ explain: MongoExplain, raw: String, settings: AppSettings) {
        plan = PlanView(table: nil, tree: explain.tree, nodes: explain.nodes, raw: raw, nullText: settings.nullText,
                        fontSize: CGFloat(settings.gridFontSize))
        warnings = explain.warnings
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("mongo.explain")
        // MySQL's plan table has no MongoDB counterpart; the tree of text is the plan as text.
        plan.choice.setEnabled(false, forSegment: 3)
        plan.choice.setToolTip("MongoDB's plan has no table: see Operations or Text", forSegment: 3)
        plan.choice.setLabel("Text", forSegment: 4)
        plan.choice.toolTip = "Show the plan as steps with figures, a diagram, a flame graph, indented text, or the server's own answer"
        // One label, a warning a line after an orange triangle: it wraps as one text.
        let font = NSFont.systemFont(ofSize: 12)
        let icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")?
            .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
        let words = NSMutableAttributedString()
        for warning in explain.warnings {
            if words.length > 0 { words.append(NSAttributedString(string: "\n")) }
            let mark = NSTextAttachment()
            mark.image = icon
            words.append(NSAttributedString(attachment: mark))
            words.append(NSAttributedString(string: " " + warning))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = Spacing.half
        words.addAttributes([.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph],
                            range: NSRange(location: 0, length: words.length))
        let list = NSTextField(wrappingLabelWithString: "")
        list.attributedStringValue = words
        list.isSelectable = true
        list.isHidden = explain.warnings.isEmpty
        list.setAccessibilityIdentifier("mongo.explainWarnings")
        list.setContentHuggingPriority(.defaultHigh, for: .vertical)
        let rows = explain.warnings
        // The steps over their details split the room as it was when made: none for the steps, unless they ask for some.
        func split(in view: NSView) -> NSSplitView? { view as? NSSplitView ?? view.subviews.lazy.compactMap { split(in: $0) }.first }
        if let steps = split(in: plan)?.arrangedSubviews.first {
            let room = steps.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
            room.priority = .defaultHigh + 10
            room.isActive = true
        }
        plan.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        let ground = SurfaceView(.content)
        addSubview(ground)
        ground.pin(to: self)
        addSubview(list)
        addSubview(plan)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.unit),
            list.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.double),
            list.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.double),
            plan.topAnchor.constraint(equalTo: rows.isEmpty ? topAnchor : list.bottomAnchor, constant: rows.isEmpty ? 0 : Spacing.half),
            plan.bottomAnchor.constraint(equalTo: bottomAnchor),
            plan.leadingAnchor.constraint(equalTo: leadingAnchor), plan.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// What shows before there is a plan: a line of text in the middle, on the content's ground.
    static func note(_ text: String, busy: Bool = false) -> NSView {
        let ground = SurfaceView(.content)
        ground.translatesAutoresizingMaskIntoConstraints = false
        let words = label(text, color: .secondaryLabelColor, wraps: true)
        words.alignment = .center
        words.isSelectable = true
        var views: [NSView] = [words]
        if busy {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            views.insert(spinner, at: 0)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = Spacing.unit
        stack.translatesAutoresizingMaskIntoConstraints = false
        ground.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: ground.centerXAnchor), stack.centerYAnchor.constraint(equalTo: ground.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: ground.widthAnchor, constant: -2 * Spacing.double),
        ])
        return ground
    }
}

/// Explain for a collection tab's find, in a window of its own: the find runs with executionStats on a session of the
/// window's, which closing the window (or Cancel in Activity) ends.
@MainActor
final class MongoExplainWindow: NSWindowController, NSWindowDelegate {
    static var open: [MongoExplainWindow] = []
    private var task: Task<Void, Never>?
    private var session: MongoSession?
    private weak var sessionOf: MongoConnection?
    private let slot = UUID().uuidString
    private var activity: Activity?
    private(set) var explainView: MongoExplainView?
    private(set) var problem: String?
    var isRunning: Bool { task != nil }

    /// The hook a collection tab's Explain calls: `@objc func explain(_ sender: Any?) { MongoExplainWindow.explain(self) }`.
    @discardableResult
    static func explain(_ tab: MongoCollectionController) -> MongoExplainWindow? {
        let find: MongoFind
        do {
            find = try tab.bar.query.find()
        } catch {
            tab.bar.show(error as? MongoQueryText.Problem)  // the only error `find` throws
            return nil
        }
        guard let connection = tab.model.openMongo[tab.connectionID]?.connection else {
            NSSound.beep()
            return nil
        }
        let window = MongoExplainWindow(title: "Explain: \(tab.name)")
        window.run(find, on: connection, database: tab.database, collection: tab.name, model: tab.model, id: tab.connectionID)
        window.showWindow(nil)
        return window
    }

    private init(title: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true)
        super.init(window: window)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = MongoExplainView.note("Running the find to measure it…", busy: true)
        window.center()
        Self.open.append(self)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func run(_ find: MongoFind, on connection: MongoConnection, database: String, collection: String, model: AppModel, id: UUID) {
        activity = model.activity.start("Explaining the find on \(collection)", connection: id) { [weak self] in self?.stop() }
        task = Task { [self] in
            do {
                let session = try await connection.session(.data, slot: slot)
                self.session = session
                sessionOf = connection
                try Task.checkCancellation()
                let answer = try await session.explain(database: database, collection: collection, find)
                try Task.checkCancellation()
                let shown = MongoExplainView(MongoExplain(answer), raw: answer.shellForm(pretty: true), settings: model.data.settings)
                explainView = shown
                window?.contentView = shown
            } catch {
                problem = Task.isCancelled ? "Cancelled: the find wasn't measured." : "The find wasn't explained: " + error.localizedDescription
                window?.contentView = MongoExplainView.note(problem ?? "")
            }
            finish()
        }
    }

    private func stop() {
        task?.cancel()
        if let session { Task { await session.cancel() } }
    }

    /// The session closes as soon as the plan is in: the window only shows it.
    private func finish() {
        activity?.end()
        activity = nil
        task = nil
        session = nil
        if let connection = sessionOf { Task { [slot] in await connection.closeSession(.data, slot: slot) } }
    }

    func windowWillClose(_ notification: Notification) {
        stop()
        if task != nil { finish() }
        Self.open.removeAll { $0 === self }
    }
}
