import AirSQLCore
import AppKit
import Combine

extension Notification.Name {
    /// Posted (object: the connection's id) when a connection's shared console state changes: a run starts or ends,
    /// the database, the transaction.
    static let consoleSessionDidChange = Notification.Name("AirSQLConsoleSessionDidChange")
}

/// A console tab (plan §2.6): a document bound to one connection, saved to a .sql file or kept as an unsaved tab that
/// comes back after relaunch. The editor above, the result tabs and Messages below. Its statements run one at a time
/// on the connection's main session, which every console tab of the connection shares (one transaction, shown in the
/// toolbar and the status bar).
@MainActor
final class ConsoleViewController: NSViewController, TabContent {
    // A connected connection's sessions, its schema cache and its query timeout in seconds: the app sets them to the
    // connected connections (`AppModel.open`), tests to their own. Nil: not connected.
    static var openConnection: (UUID) -> Connection? = { _ in nil }
    static var schemaCache: (UUID) -> SchemaCache? = { _ in nil }
    static var queryTimeout: (UUID) -> Int = { _ in 0 }

    /// What the console tabs of one connection share, as they share its main session.
    struct Shared {
        /// The console running a statement on it: one at a time, so each Cancel stops its own statement.
        var runner: UUID?
        /// The current database: the connection's own, then the last USE.
        var database: String?
        /// Rows changed in the open transaction.
        var changes: UInt64 = 0
        var isolation: IsolationLevel?
        /// The main session, once a console has used it.
        var session: DBConnection?
    }
    static var shared: [UUID: Shared] = [:]

    let model: AppModel
    /// The document's own id: what restores it after relaunch.
    let documentID: UUID
    private(set) var connectionID: UUID?
    private(set) var fileURL: URL?
    /// The text as last saved to its file ("" for an untitled console).
    var savedText = ""
    private(set) var editor: SQLEditorView!
    private(set) var editorScroll: NSScrollView!
    private(set) var findBar: FindBar!
    let results = ResultsView()
    let messagesView = ConsoleMessagesView()
    lazy var messagesTab: ResultTab = {
        let tab = ResultTab(title: "Messages", content: .messages, summary: "")
        tab.makeView = { [weak self] in self?.messagesView ?? NSView() }
        return tab
    }()
    var resultTabs: [ResultTab] = []
    var selectedResult: ResultTab?
    let split = NSSplitView()
    /// The editor and results, and the helpers panel beside them when shown.
    let outer = NSSplitView()
    lazy var helpers: HelpersPanel = makeHelpers()
    private let initialText: String
    /// The run under way, if any.
    var running: ConsoleRun?
    /// Result tabs made so far ("Result 3").
    var resultNumber = 0
    /// The editor's font size while zoomed (⌘+, ⌘−); nil: Settings ▸ Editor's.
    var zoomedSize: CGFloat?
    /// How the last statement run ended (agents' read_console reads it).
    var lastOutcome: ConsoleOutcome?
    /// A compare's sync script (plan §2.9): Run hands it back to the compare, which shows it in the SQL preview and
    /// runs it on a session of its own; false once the compare's window is closed.
    var syncScript: (() -> Bool)?
    /// It said yes to closing: it isn't kept for the next launch.
    var closing = false
    private var placedDivider = false
    /// Whether the tab bar shows the unsaved dot.
    private var shownEdited = false
    private var observers: [AnyCancellable] = []
    /// Brings the Tx badge's minutes up to date while a transaction is open.
    private var badgeTimer: Timer?

    init(model: AppModel, connection: UUID?, text: String = "", fileURL: URL? = nil, documentID: UUID = UUID()) {
        self.model = model
        connectionID = connection
        initialText = text
        self.fileURL = fileURL
        self.documentID = documentID
        if fileURL != nil { savedText = text }
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionChanged(_:)), name: .consoleSessionDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = SurfaceView(.content)
        let (scroll, editor) = SQLEditorView.make(fontSize: CGFloat(model.data.settings.editorFontSize))
        self.editor = editor
        editorScroll = scroll
        editor.setText(initialText)
        editor.onChange = { [weak self] in self?.textChanged() }
        editor.onDropFiles = { [weak self] urls in self?.mainWindow?.openFiles(urls) }
        editor.completions = { [weak self] text, caret in
            guard let self else { return (caret..<caret, []) }
            let snapshot = self.connectionID.flatMap { Self.schemaCache($0)?.snapshot }
            return SQLCompletion.suggestions(text: text, caret: caret, snapshot: snapshot, database: self.database,
                                             noBackslashEscapes: self.editor.noBackslashEscapes)
        }
        split.isVertical = false
        split.dividerStyle = .thin
        split.autosaveName = layoutName("Console")
        split.translatesAutoresizingMaskIntoConstraints = false
        let find = FindBar(editor: editor)
        findBar = find
        editor.onFind = { [weak find] action in find?.perform(action) }
        let top = NSStackView(views: [find, scroll])
        top.orientation = .vertical
        top.spacing = 0
        top.setHuggingPriority(.defaultLow, for: .vertical)
        split.addArrangedSubview(top)
        split.addArrangedSubview(results)
        split.setHoldingPriority(.defaultLow - 1, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        outer.isVertical = true
        outer.dividerStyle = .thin
        outer.addArrangedSubview(split)
        root.addSubview(outer)
        outer.pin(to: root)
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            results.heightAnchor.constraint(greaterThanOrEqualToConstant: ResultsView.barHeight + 90),
        ])
        results.onSelect = { [weak self] tab in self?.selectResult(tab) }
        results.onRename = { [weak self] tab, title in
            tab.title = title
            self?.showResults()
        }
        results.tabMenu = { [weak self] in self?.resultMenu() ?? NSMenu() }
        messagesView.onOpen = { [weak self] message in self?.reveal(message) }
        view = root
        showResults()
        // Connecting or disconnecting changes what the results say; Settings ▸ Editor the text size.
        observers.append(model.$states.sink { [weak self] _ in DispatchQueue.main.async { self?.showResults() } })
        observers.append(model.$data.map(\.settings.editorFontSize).removeDuplicates().dropFirst().sink { [weak self] size in
            guard let self, self.zoomedSize == nil else { return }
            self.editor.setFontSize(CGFloat(size))
        })
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        placeDivider()
    }

    /// The editor over the results, about half each, the first time the console is laid out at its size, unless the
    /// person moved the divider before (then it is where they left it).
    private func placeDivider() {
        guard !placedDivider, split.bounds.height > 2 * 120 else { return }
        placedDivider = true
        if split.autosaveName == nil || UserDefaults.standard.object(forKey: "NSSplitView Subview Frames Console") == nil {
            split.setPosition((split.bounds.height * 0.45).rounded(), ofDividerAt: 0)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // A new tab's first layout comes before it has its size, and none follows.
        view.window?.layoutIfNeeded()
        placeDivider()
        view.window?.makeFirstResponder(editor)
        syncToolbar()
    }

    // MARK: State

    var text: String { editor?.string ?? initialText }
    var connection: SavedConnection? { model.connection(connectionID) }
    /// What the connection's consoles share; nothing once its session is closed (Disconnect), as the last USE, the
    /// isolation level and the transaction went with it.
    var shared: Shared {
        guard let id = connectionID, let value = Self.shared[id], value.session?.isConnected != false else { return Shared() }
        return value
    }

    /// The connection's main session as it stands, if a console has used it and it is still connected.
    var session: DBConnection? {
        guard let id = connectionID, Self.openConnection(id) != nil, let session = Self.shared[id]?.session,
              session.isConnected else { return nil }
        return session
    }

    /// The database its statements run in: the last USE on the connection's main session, else the connection's own.
    var database: String? {
        shared.database ?? connectionID.flatMap { Self.openConnection($0)?.options.database }
            ?? connection.flatMap { $0.database.isEmpty ? nil : $0.database }
    }

    var isConnected: Bool {
        guard let id = connectionID, Self.openConnection(id) != nil else { return false }
        if case .connected? = model.states[id] { return true }
        return Self.shared[id]?.session?.isConnected == true
    }

    func changeShared(_ change: (inout Shared) -> Void) {
        guard let id = connectionID else { return }
        var value = shared
        change(&value)
        Self.shared[id] = value
        NotificationCenter.default.post(name: .consoleSessionDidChange, object: id)
    }

    @objc private func sessionChanged(_ notification: Notification) {
        guard notification.object as? UUID == connectionID else { return }
        contentChanged()
    }

    /// Tells the tab bar and the status bar.
    func contentChanged() {
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
        syncToolbar()
        if session?.inTransaction == true, badgeTimer == nil {
            badgeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self, self.session?.inTransaction == true else {
                        timer.invalidate()
                        self?.badgeTimer = nil
                        return
                    }
                    NotificationCenter.default.post(name: .tabContentDidChange, object: self)
                }
            }
        }
    }

    private func textChanged() {
        resultsRuler?.errorLine = nil
        if findBar?.isHidden == false { findBar.update() }
        ConsoleDocuments.shared.changed(self)
        // The tab bar hears of it only when the unsaved dot comes or goes, not at every key.
        if isEdited != shownEdited {
            shownEdited = isEdited
            contentChanged()
        }
    }

    var resultsRuler: LineNumberRuler? { editorScroll?.verticalRulerView as? LineNumberRuler }

    /// The main window's tab that shows this console.
    var tab: Tab? { mainWindow?.tabs.first { $0.content === self } }
    var mainWindow: MainWindowController? { view.window?.windowController as? MainWindowController }

    // MARK: TabContent

    var canRename: Bool { fileURL == nil }
    var isEdited: Bool { fileURL == nil ? !text.isEmpty : text != savedText }
    var canDuplicate: Bool { true }

    func duplicate() -> NSViewController? {
        ConsoleViewController(model: model, connection: connectionID, text: text)
    }

    var transactionBadge: String? {
        guard let session, session.inTransaction else { return nil }
        var badge = "Transaction open"
        let changes = shared.changes
        if changes > 0 { badge += " · \(changes.formatted()) change\(changes == 1 ? "" : "s")" }
        if let started = session.transactionStarted, let connection {
            let minutes = Int(Date().timeIntervalSince(started) / 60)
            if minutes >= model.data.safety(for: connection).openTransactionMinutes { badge += " · \(minutes) min" }
        }
        return badge
    }

    func shouldClose(_ answer: @escaping (Bool) -> Void) {
        ConsoleClosing.ask(self, answer: answer)
    }

    // MARK: File

    /// The console now shows `url`, saved with `text`.
    func setFile(_ url: URL, savedText: String) {
        fileURL = url
        self.savedText = savedText
        shownEdited = isEdited
        if let tab { mainWindow?.rename(tab, to: url.lastPathComponent) }
        ConsoleDocuments.shared.changed(self)
        contentChanged()
    }

    func setConnection(_ id: UUID) {
        connectionID = id
        tab?.connectionID = id
        ConsoleDocuments.shared.changed(self)
        mainWindow?.refresh()
        contentChanged()
    }
}
