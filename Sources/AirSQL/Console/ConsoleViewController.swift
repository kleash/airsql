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
/// on a session of its own (its own transaction and database, shown in the toolbar and the status bar), or on the
/// connection's main session where the connection has its query tabs share one.
@MainActor
final class ConsoleViewController: NSViewController, TabContent {
    // A connected connection's sessions, its schema cache and its query timeout in seconds: the app sets them to the
    // connected connections (`AppModel.open`), tests to their own. Nil: not connected.
    static var openConnection: (UUID) -> Connection? = { _ in nil }
    static var schemaCache: (UUID) -> SchemaCache? = { _ in nil }
    static var queryTimeout: (UUID) -> Int = { _ in 0 }
    /// The most rows a result keeps (Settings ▸ Grid).
    static var rowCap: () -> Int = { 100_000 }

    /// What goes with a session: a tab's own, or the main session its connection's tabs share.
    struct Shared {
        /// The console running a statement on it: one at a time, so each Cancel stops its own statement.
        var runner: UUID?
        /// The database the session is in: the last USE on it (nil: the connection's own).
        var database: String?
        /// Rows changed in the open transaction.
        var changes: UInt64 = 0
        var isolation: IsolationLevel?
        /// The session, once a console has used it.
        var session: DBConnection?
        /// Names of tables CREATE, ALTER, DROP or RENAME touched on it: temporary tables are only known from here.
        var changedNames = Set<String>()
        /// CALL or EXECUTE ran on it, so it may hold temporary tables nothing here can name.
        var ranCode = false
    }
    /// By `sessionKey`.
    static var shared: [UUID: Shared] = [:]
    /// The width Query Helpers last had, in any tab.
    static var helpersWidth: CGFloat = 260

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
    /// The tick or cross and the time at the end of each statement run.
    private(set) var runMarks: RunMarksView!
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
    /// While the helpers show: what tells them the tree's selection moved.
    var treeObserver: NSObjectProtocol?
    /// The foreign keys the person defined on this connection, for completion's joins, as last read.
    var virtualKeys: [String: [String: [SchemaForeignKey]]] = [:]
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
    /// Query ▸ Save as Changeset… hands the sync script back to its compare too, which saves a changeset per step.
    var syncChangesets: (() -> Bool)?
    /// Whether its session is the shared one, fixed while it has a session: changing the connection's setting mustn't
    /// lose sight of an open transaction. Nil: the connection's setting.
    var sharing: Bool?
    /// The database of a tab with a session of its own, once it has run or been given one.
    var chosenDatabase: String?
    /// A session that ended unasked, until the person answers; then what its replacement takes over from it.
    var lostSession: LostSession?
    var carried: LostSession?
    /// The next run keeps the result tabs (Keep Results).
    var keepsResults = false
    /// Run Result Again every so often: the seconds (0: off), the timer and the tab it reruns.
    var refreshSeconds = 0
    var refreshTimer: Timer?
    weak var refreshedResult: ResultTab?
    /// How the file is stored, which Save keeps.
    var fileFormat = ConsoleScript.FileFormat()
    /// The file's date on disk as last read or saved.
    var fileDate: Date?
    /// The values last given to `?` and `:name`, offered at the next run.
    var parameterValues: [String: String] = [:]
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
        NotificationCenter.default.addObserver(self, selector: #selector(schemaChanged(_:)), name: .openConnectionDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(checkFile), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = SurfaceView(.content)
        let (scroll, editor) = SQLEditorView.make(fontSize: CGFloat(model.data.settings.editorFontSize))
        self.editor = editor
        editorScroll = scroll
        editor.setText(initialText)
        runMarks = RunMarksView(editor: editor)
        (scroll.verticalRulerView as? LineNumberRuler)?.onRun = { [weak self] in self?.runStatement(nil) }
        editor.onChange = { [weak self] in self?.textChanged() }
        editor.onDropFiles = { [weak self] urls in self?.mainWindow?.openFiles(urls) }
        editor.completions = { [weak self] text, caret in
            guard let self else { return (caret..<caret, []) }
            let snapshot = self.connectionID.flatMap { Self.schemaCache($0)?.snapshot }?.adding(self.virtualKeys)
            self.refreshVirtualKeys()
            return SQLCompletion.suggestions(text: text, caret: caret, snapshot: snapshot, database: self.database,
                                             noBackslashEscapes: self.editor.noBackslashEscapes,
                                             options: self.model.data.settings.completionOptions(recent: CompletionPopup.chosen))
        }
        editor.completionDocs = { [weak self] item in
            guard let self else { return nil }
            return SQLCompletion.documentation(item, snapshot: self.connectionID.flatMap { Self.schemaCache($0)?.snapshot }, database: self.database)
        }
        editor.nameContext = { [weak self] in
            guard let self, let id = self.connectionID, !self.shared.ranCode else { return nil }
            return (Self.schemaCache(id)?.snapshot, self.database, self.shared.changedNames)
        }
        wireInsight()
        split.isVertical = false
        split.dividerStyle = .thin
        split.autosaveName = layoutName("Console")
        split.translatesAutoresizingMaskIntoConstraints = false
        let find = FindBar(editor: editor)
        findBar = find
        editor.onFind = { [weak find] action in find?.perform(action) }
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(results)
        split.setHoldingPriority(.defaultLow - 1, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        outer.isVertical = true
        outer.dividerStyle = .thin
        outer.addArrangedSubview(split)
        // Find and replace across the editor and the helpers: beside the helpers it needed a wider window.
        let column = NSStackView(views: [find, outer])
        column.orientation = .vertical
        // Filling: by its gravity areas the column hugged the split to its smallest, which held the results to 120 pt.
        column.distribution = .fill
        column.spacing = 0
        root.addSubview(column)
        column.pin(to: root)
        for view in [find, outer] { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            results.heightAnchor.constraint(greaterThanOrEqualToConstant: ResultsView.barHeight + 90),
        ])
        results.onSelect = { [weak self] tab in self?.selectResult(tab) }
        results.onMove = { [weak self] tab, other in
            guard let self, let from = self.resultTabs.firstIndex(where: { $0 === tab }),
                  let to = self.resultTabs.firstIndex(where: { $0 === other }) else { return }
            self.resultTabs.insert(self.resultTabs.remove(at: from), at: to)
            self.showResults()
        }
        results.onRename = { [weak self] tab, title in
            tab.title = title
            self?.showResults()
        }
        results.onClose = { [weak self] in self?.closeResult(nil) }
        results.tabMenu = { [weak self] in self?.resultMenu() ?? NSMenu() }
        messagesView.onOpen = { [weak self] message in self?.reveal(message) }
        view = root
        showResults()
        // Connecting or disconnecting, or the first connection saved, changes what the results say; Settings ▸ Editor the
        // text size.
        observers.append(model.$states.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.noticeLostSession()
                self?.showResults()
            }
        })
        observers.append(model.$data.map(\.connections.isEmpty).removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.showResults() }
        })
        observers.append(model.$data.map(\.settings.editorFontSize).removeDuplicates().dropFirst().sink { [weak self] size in
            guard let self, self.zoomedSize == nil else { return }
            self.editor.setFontSize(CGFloat(size))
        })
        observers.append(model.$data.map(\.settings).removeDuplicates { ($0.editorFontFamily, $0.editorTabWidth, $0.editorUsesTabs)
            == ($1.editorFontFamily, $1.editorTabWidth, $1.editorUsesTabs) }.sink { [weak self] settings in
            self?.editor.applyStyle(family: settings.editorFontFamily, tabWidth: settings.editorTabWidth, usesTabs: settings.editorUsesTabs)
        })
        observers.append(model.$data.map(\.settings.editorWordWrap).removeDuplicates().sink { [weak self] wraps in
            self?.editor.setWraps(wraps)
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
        showDatabase()
        checkFile()
        syncToolbar()
    }

    // MARK: State

    var text: String { editor?.string ?? initialText }
    var connection: SavedConnection? { model.connection(connectionID) }
    /// What goes with its session; nothing once the session is closed (Disconnect), as the last USE, the isolation level
    /// and the transaction went with it.
    var shared: Shared {
        guard let value = Self.shared[sessionKey], value.session?.isConnected != false else { return Shared() }
        return value
    }

    /// Its session as it stands, if it has used one and that is still connected.
    var session: DBConnection? {
        guard let id = connectionID, Self.openConnection(id) != nil, let session = Self.shared[sessionKey]?.session,
              session.isConnected else { return nil }
        return session
    }

    /// The database its statements run in, made current on the session before the next statement: the tab's own, else
    /// the connection's current one (the navigator's bold one, chosen there or in the toolbar), else the last USE on the
    /// session, else the connection's own.
    var database: String? {
        (sharesSession ? nil : chosenDatabase) ?? model.openConnection(connectionID)?.currentDatabase ?? shared.database
            ?? connectionID.flatMap { Self.openConnection($0)?.options.database }
            ?? connection.flatMap { $0.database.isEmpty ? nil : $0.database }
    }

    var isConnected: Bool {
        guard let id = connectionID, Self.openConnection(id) != nil else { return false }
        if case .connected? = model.states[id] { return true }
        return Self.shared[sessionKey]?.session?.isConnected == true
    }

    func changeShared(_ change: (inout Shared) -> Void) {
        guard let id = connectionID else { return }
        var value = shared
        change(&value)
        Self.shared[sessionKey] = value
        NotificationCenter.default.post(name: .consoleSessionDidChange, object: id)
    }

    @objc private func sessionChanged(_ notification: Notification) {
        guard notification.object as? UUID == connectionID else { return }
        contentChanged()
        editor?.checkLater()
    }

    /// The schema or the current database may have changed: what's unknown may have too. A database chosen in the tree
    /// or the toolbar is for the tab on show.
    @objc private func schemaChanged(_ notification: Notification) {
        if let open = notification.object as? OpenConnection, open.id == connectionID, isShown, chosenDatabase != nil {
            chosenDatabase = open.currentDatabase
        }
        editor?.checkLater()
    }

    /// Tells the tab bar and the status bar.
    func contentChanged() {
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
        syncToolbar()
        if session?.inTransaction == true, badgeTimer == nil {
            badgeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    self?.noticeLostSession()
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

    var reopen: ((MainWindowController) -> Void)? {
        if let fileURL { return { $0.openFiles([fileURL]) } }
        guard let copy = duplicate() else { return nil }
        let title = tab?.title ?? "Query", connection = connectionID
        return { $0.open(copy, title: title, connection: connection) }
    }

    var transactionBadge: String? {
        if lostSession?.transaction == true { return "Transaction rolled back: the connection ended" }
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
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        Self.rememberConnection(of: url, connectionID)
        self.savedText = savedText
        shownEdited = isEdited
        if let tab { mainWindow?.rename(tab, to: url.lastPathComponent) }
        ConsoleDocuments.shared.changed(self)
        contentChanged()
    }

    /// A tab without a connection works on the one the toolbar shows: nothing to choose while the window has one.
    func takeWindowConnection() {
        guard connectionID == nil, isViewLoaded, let id = mainWindow?.activeConnection?.id else { return }
        setConnection(id)
        showResults()
    }

    func setConnection(_ id: UUID) {
        endSession()
        connectionID = id
        if let fileURL { Self.rememberConnection(of: fileURL, id) }
        tab?.connectionID = id
        ConsoleDocuments.shared.changed(self)
        mainWindow?.refresh()
        contentChanged()
    }
}
