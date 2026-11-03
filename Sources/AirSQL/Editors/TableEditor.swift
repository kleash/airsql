import AirSQLCore
import AppKit

/// The table editor (mockups screen 10): columns, indexes, foreign keys, checks and options in one tab that never
/// blocks the window, with the SQL that Apply will run always shown under them. Apply shows that SQL in the preview
/// sheet and runs it on a tools session; nothing changes on the server before. Reading and applying run off the main
/// thread, each as an Activity with Cancel.
@MainActor
final class TableEditorController: NSViewController, TabContent, NSMenuItemValidation {
    enum Section: Int, CaseIterable {
        case columns, indexes, foreignKeys, checks, options
    }

    let context: EditorContext
    let activity: ActivityCenter
    /// nil for a new table until the person picks one (Options).
    var database: String?
    /// The table's name on the server; nil until a new table is created.
    var table: String?
    /// What the server has (nil: the table is new, so Apply creates it).
    var before: TableDesign?
    var design = TableDesign(name: "")
    var server = SchemaServer(version: "8.0.0")
    var collations: [Collation] = []
    var engines: [String] = []
    var section = Section.columns
    var isBusy = false
    /// The list shows no rows while its columns change.
    var emptied = false
    let undo = UndoManager()

    let sections = NSSegmentedControl()
    let list = EditorList()
    let listScroll = NSScrollView()
    let listHolder = NSView()
    /// The list, its hairline and its + and − buttons (hidden while the options show).
    let listColumn = NSView()
    let addButton = NSButton(), removeButton = NSButton()
    let options = TableOptionsView()
    let sqlText = NSTextView()
    let applyButton = button("Apply", id: "tableEditor.apply", tip: "", target: nil, action: #selector(AirSQLActions.applyChanges(_:)))
    let discardButton = button("Discard", id: "tableEditor.discard", tip: "", target: nil,
                               action: #selector(AirSQLActions.revertChanges(_:)))
    let status = NSProgressIndicator()
    let overlay = EditorOverlay()

    init(context: EditorContext, database: String?, table: String?, activity: ActivityCenter) {
        self.context = context
        self.database = database
        self.table = table
        self.activity = activity
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = buildView()
        load()
    }

    /// Whether this editor is on that table.
    func edits(_ connection: UUID, _ database: String?, _ table: String) -> Bool {
        context.connection.id == connection && self.database == database && self.table == table
    }

    var tabTitle: String { table.map { $0 + " · structure" } ?? "New table" }

    // MARK: Model

    /// The statements Apply would run now, or why there are none.
    var statements: Result<[String], DesignError> {
        guard let database else { return .failure(DesignError("Choose the database to create the table in (Options)")) }
        do {
            return .success(try design.statements(database: database, from: before, server: server))
        } catch let error as DesignError {
            return .failure(error)
        } catch {
            return .failure(DesignError(error.localizedDescription))
        }
    }

    /// Changes the design (undoably) and shows the new SQL.
    func update(_ change: (inout TableDesign) -> Void) {
        var changed = design
        change(&changed)
        guard changed != design else { return }
        let old = design
        undo.registerUndo(withTarget: self) { editor in editor.replace(old) }
        design = changed
        designChanged()
    }

    func replace(_ new: TableDesign) {
        let old = design
        undo.registerUndo(withTarget: self) { editor in editor.replace(old) }
        design = new
        designChanged()
        reloadList()
    }

    func designChanged() {
        updateSQL()
        updateSectionTitles()
        options.show(self)
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
    }

    // MARK: Reading

    /// Reads the table (or, for a new one, what its options offer) and shows it.
    func load() {
        isBusy = true
        overlay.show(loading: table.map { "Reading \($0)…" } ?? "Getting ready…")
        updateButtons()
        let work = activity.start(table.map { "Reading the structure of \($0)" } ?? "Preparing a new table", connection: context.connection.id) {}
        Task {
            defer { work.end() }
            do {
                try await read()
                isBusy = false
                overlay.hide()
                showSection(section)
                designChanged()
            } catch {
                isBusy = false
                overlay.show(error: error.localizedDescription, retry: (self, #selector(retry(_:))))
            }
            updateButtons()
        }
    }

    @objc private func retry(_ sender: Any?) { load() }

    private func read() async throws {
        let context = self.context, database = self.database, table = self.table
        if context.schema.snapshot.server == nil { try await context.schema.load() }
        guard let server = context.schema.snapshot.server else { throw DesignError("The server didn't say what it is") }
        self.server = server
        let (collations, engines) = try await context.read { session in
            (try await EditorQueries.collations(server: server, from: session), try await EditorQueries.engines(from: session))
        }
        self.collations = collations
        self.engines = engines
        if let database, let table {
            try await context.schema.loadDetails([database])
            try await context.schema.refresh([.table(database: database, name: table)])
            before = try await readTable(database, table)
            design = before!
        } else {
            if self.database == nil { self.database = context.schema.snapshot.databases.first?.name }
            var id = ColumnDesign(name: "id", type: TypeSpec(name: "int", unsigned: true))
            id.nullable = false
            id.autoIncrement = true
            design = TableDesign(name: "new_table")
            design.columns = [id]
            design.indexes = [IndexDesign(name: "PRIMARY", kind: .primary, parts: [.init(column: "id")])]
        }
        undo.removeAllActions()
    }

    // MARK: TabContent

    var isEdited: Bool { before.map { $0 != design } ?? true }

    func shouldClose(_ answer: @escaping (Bool) -> Void) {
        guard isEdited, let window = view.window else { return answer(true) }
        let alert = NSAlert()
        alert.messageText = before == nil ? "Close without creating the table?" : "Close without applying your changes?"
        alert.informativeText = "They aren't on the server yet; closing throws them away."
        let close = alert.addButton(withTitle: "Close")
        close.hasDestructiveAction = true
        close.toolTip = "Throw the changes away and close the tab"
        alert.addButton(withTitle: "Cancel").toolTip = "Keep the tab and the changes"
        alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
    }
}

/// What covers an editor while it reads (a spinner and what it is doing) or after reading failed (why, and Retry).
@MainActor
final class EditorOverlay: NSView {
    private let spinner = NSProgressIndicator()
    private let text = label("", font: .systemFont(ofSize: 13), color: .secondaryLabelColor, wraps: true)
    private let retry = button("Try Again", id: "editor.retry", tip: "Read it from the server again", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        let ground = SurfaceView(.content)
        addSubview(ground)
        ground.pin(to: self)
        spinner.style = .spinning
        spinner.controlSize = .small
        text.alignment = .center
        text.setAccessibilityIdentifier("editor.status")
        let stack = NSStackView(views: [spinner, text, retry])
        stack.orientation = .vertical
        stack.spacing = Spacing.unit
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2 * Spacing.triple),
            text.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(loading: String) {
        isHidden = false
        text.stringValue = loading
        spinner.isHidden = false
        spinner.startAnimation(nil)
        retry.isHidden = true
    }

    func show(error: String, retry action: (AnyObject, Selector)) {
        isHidden = false
        text.stringValue = error
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        retry.isHidden = false
        retry.target = action.0
        retry.action = action.1
    }

    func hide() {
        spinner.stopAnimation(nil)
        isHidden = true
    }
}
