import AirSQLCore
import AppKit

// Collections, views and databases (mongo-plan, Phase 2 admin): Create Collection…, Create View…, Create Database…,
// Rename Collection…, Validation Rules…, Drop Collection… (or View) and Drop Database…, from the tree's menus and Data ▸
// Collection. Each asks what it needs in a small sheet, shows its exact command in the preview sheet (drops in red, their
// name typed first where MySQL's would be), runs it on the connection's admin session with Cancel in Activity, then reads
// the tree again; tabs of what was dropped or renamed say so.

/// What the admin commands act on, and how they run.
@MainActor
enum MongoAdminActions {
    static let actions: Set<Selector> = Set(Commands.mongoAdminCommands.map(\.action))

    /// Why `action` can't act on `ref` now (nil: it can); `title` becomes Drop View… for a view.
    static func reason(_ action: Selector?, _ ref: MongoCollectionRef?, model: AppModel?, title: inout String) -> String? {
        guard let ref else { return "Select a MongoDB database or collection in the tree, or open a collection in a tab" }
        // The connection as saved now: Read-only may have been turned on since it connected.
        if (model?.connection(ref.open.saved.id) ?? ref.open.saved).readOnly { return "This connection is read-only: turn that off in Edit Connection… ▸ Options to change it" }
        let hasCollection = !ref.collection.isEmpty
        switch action {
        case Commands.createMongoDatabase.action:
            return nil
        case Commands.createCollection.action, Commands.createView.action:
            return ref.database.isEmpty ? "Select a database or collection in the tree first" : MongoAdmin.refusal(database: ref.database)
        case Commands.dropMongoDatabase.action:
            return ref.database.isEmpty || hasCollection ? "Select a database in the tree first" : MongoAdmin.refusal(database: ref.database)
        case Commands.dropCollection.action:
            if ref.kind == .view { title = "Drop View…" }
            return hasCollection ? MongoAdmin.refusal(database: ref.database, collection: ref.collection)
                : "Select a collection or view in the tree, or open one in a tab"
        case Commands.renameCollection.action:
            guard hasCollection else { return "Select a collection in the tree, or open one in a tab" }
            switch ref.kind {
            case .view: return "A view can't be renamed: drop it and create it again under the new name"
            case .timeseries: return "MongoDB can't rename a time-series collection"
            case .collection: return MongoAdmin.refusal(database: ref.database, collection: ref.collection)
            }
        case Commands.editValidation.action:
            guard hasCollection else { return "Select a collection in the tree, or open one in a tab" }
            return ref.kind == .collection ? MongoAdmin.refusal(database: ref.database, collection: ref.collection)
                : "Views and time-series collections have no validation rules"
        default:
            return nil
        }
    }

    static func validate(_ item: NSMenuItem, _ ref: MongoCollectionRef?, model: AppModel?) -> Bool {
        var title = Commands.all.first { $0.action == item.action }?.title ?? item.title
        let why = reason(item.action, ref, model: model, title: &title)
        item.title = title
        item.explain(enabled: why == nil, reason: why)
        return why == nil
    }

    static func perform(_ action: Selector, _ ref: MongoCollectionRef?, model: AppModel, window: NSWindow?) {
        var title = ""
        guard let ref, let window, reason(action, ref, model: model, title: &title) == nil else { return NSSound.beep() }
        switch action {
        case Commands.createCollection.action: createCollection(ref, database: ref.database, model: model, window: window)
        case Commands.createMongoDatabase.action: createCollection(ref, database: nil, model: model, window: window)
        case Commands.createView.action: createView(ref, model: model, window: window)
        case Commands.renameCollection.action: rename(ref, model: model, window: window)
        case Commands.editValidation.action: MongoValidationSheet.open(ref, model: model, on: window)
        case Commands.dropCollection.action: drop(ref, model: model, window: window)
        case Commands.dropMongoDatabase.action: dropDatabase(ref, model: model, window: window)
        default: NSSound.beep()
        }
    }

    // MARK: The commands

    /// The name a create command gives.
    private static func created(_ command: MongoAdminCommand) -> String {
        if case .string(let name)? = command.command["create"] { return name }
        return ""
    }

    /// Create Collection… in `database`, or Create Database… (nil): a new database is its first collection.
    static func createCollection(_ ref: MongoCollectionRef, database: String?, model: AppModel, window: NSWindow) {
        MongoCreateSheet.show(database: database, on: window) { command in
            let db = command.database, name = created(command)
            run(command, on: ref.open, model: model, window: window, title: database == nil ? "Create database \(db)" : "Create collection \(name)",
                heading: database == nil ? "Create the database \(db) with its first collection, \(name)?" : "Create the collection \(name) in \(db)?",
                caption: "Nothing else changes.", action: "Create", destructive: false) {
                if database == nil { ref.open.refresh() } else { ref.open.refresh(db) }
            }
        }
    }

    static func createView(_ ref: MongoCollectionRef, model: AppModel, window: NSWindow) {
        let sources = (ref.open.collections[ref.database] ?? []).map(\.name)
        MongoViewSheet.show(database: ref.database, sources: sources, source: ref.collection, on: window) { command in
            let name = created(command)
            run(command, on: ref.open, model: model, window: window, title: "Create view \(name)",
                heading: "Create the view \(name) in \(ref.database)?",
                caption: "A view stores no documents: its pipeline runs each time it is read, and it can't be edited.",
                action: "Create", destructive: false) { ref.open.refresh(ref.database) }
        }
    }

    static func rename(_ ref: MongoCollectionRef, model: AppModel, window: NSWindow) {
        let field = textField(ref.collection, placeholder: "New name", id: "mongoRename.name", tip: "Type the collection's new name", width: 300)
        let dropTarget = checkbox("Replace a collection that has this name (drops it first)", id: "mongoRename.dropTarget",
                                  tip: "Drop the collection that already has the new name, with its documents, before renaming",
                                  on: false, target: nil, action: nil)
        let stack = NSStackView(views: [field, dropTarget])
        stack.orientation = .vertical
        stack.alignment = .leading
        NavigatorActions.ask("Rename \(ref.collection)", "Give \(ref.database).\(ref.collection) a new name in the same database.",
                             field: stack, action: "Next…", tip: "Go on: the next step shows the command before anything runs",
                             on: window) {
            let replace = dropTarget.state == .on
            let command: MongoAdminCommand
            do {
                command = try MongoAdmin.rename(database: ref.database, collection: ref.collection, to: field.stringValue, dropTarget: replace)
            } catch {
                return showError("\(error)", title: "\(ref.collection) wasn't renamed", on: window)
            }
            let to = field.stringValue.trimmingCharacters(in: .whitespaces)
            run(command, on: ref.open, model: model, window: window, title: "Rename \(ref.collection)",
                heading: "Rename \(ref.collection) to \(to)?",
                caption: "Its documents, indexes and rules go with it. Views and code that use the old name aren't changed.",
                action: "Rename", destructive: replace,
                warnings: replace ? ["A collection named \(to) is dropped first, with its documents: this can't be undone."] : [],
                typeToConfirm: replace ? to : nil) {
                gone(ref, words: "\(ref.database).\(ref.collection) is now named \(to): open it from the tree.")
                ref.open.refresh(ref.database)
            }
        }
    }

    static func drop(_ ref: MongoCollectionRef, model: AppModel, window: NSWindow) {
        guard let saved = model.connection(ref.open.saved.id) else { return }
        let command: MongoAdminCommand
        do { command = try MongoAdmin.drop(database: ref.database, collection: ref.collection) } catch { return NSSound.beep() }
        let noun = ref.kind == .view ? "view" : "collection"
        run(command, on: ref.open, model: model, window: window, title: "Drop \(noun) \(ref.collection)",
            heading: "Drop the \(noun) \(ref.collection) from \(ref.database)?",
            caption: ref.kind == .view ? "The view goes; the collection it reads keeps its documents."
                : "It is deleted from the server for good, with its documents and indexes.",
            action: "Drop", destructive: true, typeToConfirm: model.data.safety(for: saved).typeNameForTables ? ref.collection : nil) {
            gone(ref, words: "\(ref.database).\(ref.collection) was dropped: close this tab.")
            ref.open.refresh(ref.database)
        }
    }

    static func dropDatabase(_ ref: MongoCollectionRef, model: AppModel, window: NSWindow) {
        let command: MongoAdminCommand
        do { command = try MongoAdmin.dropDatabase(ref.database) } catch { return NSSound.beep() }
        run(command, on: ref.open, model: model, window: window, title: "Drop database \(ref.database)",
            heading: "Drop the database \(ref.database)?",
            caption: "Every collection and view in it is deleted from the server for good, with their documents and indexes.",
            action: "Drop", destructive: true, typeToConfirm: ref.database) {
            gone(MongoCollectionRef(open: ref.open, database: ref.database, collection: "", kind: .collection),
                 words: "The database \(ref.database) was dropped: close this tab.")
            ref.open.refresh()
        }
    }

    // MARK: Running

    /// Shows `command` in the preview sheet; Run runs it on the connection's admin session with a line in Activity whose
    /// Cancel stops it, then `done` (or what went wrong, in `failure`'s words).
    static func run(_ command: MongoAdminCommand, on open: OpenMongoConnection, model: AppModel, window: NSWindow, title: String,
                    heading: String, caption: String, action: String, destructive: Bool, warnings: [String] = [],
                    typeToConfirm: String? = nil, failure: @escaping (Error) -> String = { $0.localizedDescription },
                    done: @escaping @MainActor () -> Void) {
        guard let saved = model.connection(open.saved.id) else { return NSSound.beep() }
        var request = SQLPreviewRequest(change: ChangeSQL(title: title, statements: [command.shellForm], connection: saved.id),
                                        heading: heading, caption: caption)
        request.actionTitle = action
        request.destructive = destructive
        request.warnings = warnings
        request.typeToConfirm = typeToConfirm
        request.shellCommands = true
        SQLPreviewSheet.show(request, connection: saved, on: window) { result in
            guard result.approved else { return }
            let connection = open.connection
            var task: Task<Void, Never>?
            let activity = model.activity.start(title, connection: saved.id) {
                task?.cancel()
                Task { try? await connection.session(.data, slot: "admin").cancel() }
            }
            task = Task { @MainActor in
                do {
                    try await connection.session(.data, slot: "admin").run(command)
                    activity.end()
                    done()
                    announce("\(title): done")
                } catch {
                    activity.end()
                    let words = Task.isCancelled ? "Cancelled. Refresh (⌘R) shows whether it was done." : failure(error)
                    open.refresh()
                    showError(words, title: "\(title) didn't happen", on: window)
                }
            }
        }
    }

    /// The tabs of `ref`'s collection (every collection of its database when `collection` is empty), in every window,
    /// say `words` in their notice: what they show is gone.
    static func gone(_ ref: MongoCollectionRef, words: String) {
        for main in NSApp.windows.compactMap({ $0.windowController as? MainWindowController }) {
            for tab in main.tabs {
                guard let content = tab.shown as? MongoCollectionController, content.connectionID == ref.open.saved.id,
                      content.database == ref.database, ref.collection.isEmpty || content.name == ref.collection else { continue }
                content.problem = words
                content.updateBars()
            }
        }
    }
}

// MARK: Menus

/// The target of Data ▸ Collection's admin items: the tree's selection while the tree has the focus, else the collection
/// tab in front.
@MainActor
final class MongoAdminMenu: NSObject, NSMenuItemValidation {
    static let shared = MongoAdminMenu()

    private var main: MainWindowController? {
        let windows = [NSApp.mainWindow, NSApp.keyWindow].compactMap { $0 } + NSApp.orderedWindows
        return windows.lazy.compactMap { $0.windowController as? MainWindowController }.first
    }

    private var ref: MongoCollectionRef? {
        guard let main else { return nil }
        if let focus = main.window?.firstResponder as? NSView, focus.isDescendant(of: main.sidebar.view) { return main.sidebar.mongoAdminRef }
        guard let tab = main.selectedTab?.shown as? MongoCollectionController, let open = main.model.openMongo[tab.connectionID] else { return nil }
        return MongoCollectionRef(open: open, database: tab.database, collection: tab.name, kind: tab.info.kind)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { MongoAdminActions.validate(item, ref, model: main?.model) }

    private func perform(_ action: Selector) {
        guard let main else { return }
        MongoAdminActions.perform(action, ref, model: main.model, window: main.window)
    }

    @objc func createCollection(_ sender: Any?) { perform(Commands.createCollection.action) }
    @objc func createView(_ sender: Any?) { perform(Commands.createView.action) }
    @objc func createMongoDatabase(_ sender: Any?) { perform(Commands.createMongoDatabase.action) }
    @objc func renameCollection(_ sender: Any?) { perform(Commands.renameCollection.action) }
    @objc func editValidation(_ sender: Any?) { perform(Commands.editValidation.action) }
    @objc func dropCollection(_ sender: Any?) { perform(Commands.dropCollection.action) }
    @objc func dropMongoDatabase(_ sender: Any?) { perform(Commands.dropMongoDatabase.action) }
}

extension SidebarController {
    /// The one database or collection selected in a connected MongoDB tree, or the connection alone (database empty).
    var mongoAdminRef: MongoCollectionRef? {
        if let (open, items) = mongoSelection {
            guard items.count == 1, items[0].index == nil else { return nil }
            let item = items[0]
            return MongoCollectionRef(open: open, database: item.database, collection: item.collection ?? "",
                                      kind: item.collection == nil ? .collection : mongoInfo(open.saved.id, item)?.kind ?? .collection)
        }
        let ids = selectedConnectionIDs
        guard ids.count == 1, selectedNodes.count == 1, let open = model.openMongo[ids[0]] else { return nil }
        return MongoCollectionRef(open: open, database: "", collection: "", kind: .collection)
    }

    /// The admin commands' state in the tree's menus; nil when `item` isn't one of them.
    func validateMongoAdmin(_ item: NSMenuItem) -> Bool? {
        MongoAdminActions.actions.contains(item.action ?? Selector(("none"))) ? MongoAdminActions.validate(item, mongoAdminRef, model: model) : nil
    }

    private func performAdmin(_ action: Selector) { MongoAdminActions.perform(action, mongoAdminRef, model: model, window: view.window) }

    @objc func createCollection(_ sender: Any?) { performAdmin(Commands.createCollection.action) }
    @objc func createView(_ sender: Any?) { performAdmin(Commands.createView.action) }
    @objc func createMongoDatabase(_ sender: Any?) { performAdmin(Commands.createMongoDatabase.action) }
    @objc func renameCollection(_ sender: Any?) { performAdmin(Commands.renameCollection.action) }
    @objc func editValidation(_ sender: Any?) { performAdmin(Commands.editValidation.action) }
    @objc func dropCollection(_ sender: Any?) { performAdmin(Commands.dropCollection.action) }
    @objc func dropMongoDatabase(_ sender: Any?) { performAdmin(Commands.dropMongoDatabase.action) }
}

// MARK: Sheets

/// The frame of the admin sheets: a heading, a note, the content, a problem line and Cancel / Preview…; Preview… asks
/// `make` for the command, shows the field that's wrong under the content, or hands the command to `next`.
@MainActor
class MongoAdminSheet: NSWindowController {
    let problem = label("", font: .systemFont(ofSize: 12), color: .statusBad, wraps: true)
    var make: () throws -> MongoAdminCommand = { throw CancellationError() }
    private let next: (MongoAdminCommand) -> Void
    private var retainUntilClosed: MongoAdminSheet?
    let id: String

    init(id: String, title: String, heading: String, note: String, content: NSView, width: CGFloat = 540,
         next: @escaping (MongoAdminCommand) -> Void) {
        self.id = id
        self.next = next
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = title
        super.init(window: window)
        let headingLabel = label(heading, font: .systemFont(ofSize: 14, weight: .semibold), wraps: true)
        let noteLabel = label(note, font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, wraps: true)
        problem.setAccessibilityIdentifier(id + ".problem")
        problem.isSelectable = true
        problem.isHidden = true
        let cancel = button("Cancel", id: id + ".cancel", tip: "Close this and change nothing", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = button("Preview…", id: id + ".preview", tip: "Show the command, to run it or not", target: self,
                        action: #selector(preview(_:)), primary: true)
        ok.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, ok])
        let stack = NSStackView(views: [headingLabel, noteLabel, content, problem, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: headingLabel)
        for view in [headingLabel, noteLabel, problem, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let root = SurfaceView(.ground)
        root.addSubview(stack)
        stack.pin(to: root, insets: NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20))
        root.widthAnchor.constraint(equalToConstant: width).isActive = true
        window.contentView = root
        fit()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func begin(on window: NSWindow) {
        retainUntilClosed = self
        window.beginSheet(self.window!)
    }

    /// The window as tall as its content, after rows were shown or hidden.
    func fit() {
        guard let window, let root = window.contentView else { return }
        root.layoutSubtreeIfNeeded()
        window.setContentSize(root.fittingSize)
    }

    @objc func preview(_ sender: Any?) {
        do {
            let command = try make()
            finish()
            next(command)
        } catch {
            NSSound.beep()
            problem.stringValue = "\(error)"
            problem.isHidden = false
            fit()
        }
    }

    @objc func cancel(_ sender: Any?) { finish() }

    func finish() {
        if let sheet = window, let parent = sheet.sheetParent { parent.endSheet(sheet) }
        retainUntilClosed = nil
    }
}

/// A monospaced text view for shell form, in a bordered scroll view `height` tall.
@MainActor
func shellTextView(_ text: String, id: String, tip: String, height: CGFloat) -> (NSScrollView, NSTextView) {
    let scroll = NSTextView.scrollableTextView()
    let textView = scroll.documentView as! NSTextView
    textView.string = text
    textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    textView.isRichText = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.textContainerInset = NSSize(width: 6, height: 6)
    textView.setAccessibilityIdentifier(id)
    textView.toolTip = tip
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.borderType = .bezelBorder
    scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
    return (scroll, textView)
}

/// Create Collection… and Create Database…: the name, and under More Options its kind (capped, time-series, clustered),
/// a default collation and validation rules.
@MainActor
final class MongoCreateSheet: MongoAdminSheet {
    static let kinds = ["Plain", "Capped: a fixed size, oldest documents go first", "Time-series: measurements over time",
                        "Clustered: stored in _id order"]
    let database = textField("", placeholder: "Database name", id: "mongoCreate.database", tip: "Type the new database's name", width: 340)
    let name = textField("", placeholder: "Collection name", id: "mongoCreate.name", tip: "Type the new collection's name", width: 340)
    let more = NSButton(title: "", target: nil, action: nil)
    let kind = popup(kinds, selected: 0, id: "mongoCreate.kind", tip: "Choose what kind of collection to make", target: nil, action: nil)
    let size = textField("", placeholder: "Bytes", id: "mongoCreate.size", tip: "The most the collection holds, in bytes", width: 120)
    let max = textField("", placeholder: "No limit", id: "mongoCreate.max", tip: "The most documents it holds; empty: only its size limits it",
                        width: 120)
    let timeField = textField("", placeholder: "timestamp", id: "mongoCreate.timeField", tip: "The field that holds each measurement's date",
                              width: 120)
    let metaField = textField("", placeholder: "None", id: "mongoCreate.metaField",
                              tip: "The field that says what was measured (a sensor's id), which rarely changes", width: 120)
    let granularity = popup(["The server's default"] + MongoAdmin.granularities, selected: 0, id: "mongoCreate.granularity",
                            tip: "Choose how far apart measurements of one source usually are", target: nil, action: nil)
    let collation = textField("", placeholder: "{ locale: \"en\", strength: 2 }", id: "mongoCreate.collation",
                              tip: "How it compares strings by default, in shell form; empty: simple, by bytes", width: 340)
    let validator = textField("", placeholder: "{ $jsonSchema: { required: [\"name\"] } }", id: "mongoCreate.validator",
                              tip: "The rules every document must follow, in shell form; Validation Rules… edits them later", width: 340)
    let level = popup(MongoAdmin.validationLevels, selected: 0, id: "mongoCreate.level",
                      tip: "Check every insert and update (strict), or leave documents that already fail alone (moderate)",
                      target: nil, action: nil)
    let action = popup(MongoAdmin.validationActions, selected: 0, id: "mongoCreate.action",
                       tip: "Refuse a document that fails the rules (error), or only log it (warn)", target: nil, action: nil)
    private var optionRows: [NSGridRow] = []
    private var cappedRow: NSGridRow!, seriesRows: [NSGridRow] = []

    /// `database` nil: Create Database…, which asks its name too.
    static func show(database: String?, on window: NSWindow, next: @escaping (MongoAdminCommand) -> Void) {
        MongoCreateSheet(database: database, next: next).begin(on: window)
    }

    private init(database db: String?, next: @escaping (MongoAdminCommand) -> Void) {
        let form = Form()
        let fields = [database, name, size, max, timeField, metaField, collation, validator]
        for field in fields { field.font = .monospacedSystemFont(ofSize: 12, weight: .regular) }
        if db == nil { form.row("Database", [database]) }
        form.row(db == nil ? "First Collection" : "Name", [name])
        more.setButtonType(.onOff)
        more.bezelStyle = .disclosure
        more.title = ""
        more.toolTip = "Show or hide the options: capped, time-series, collation and validation rules"
        more.setAccessibilityIdentifier("mongoCreate.more")
        more.setAccessibilityLabel("More Options")
        form.row("", [more, label("More Options", font: .systemFont(ofSize: 12.5))])
        let kindRow = form.row("Kind", [kind])
        cappedRow = form.row("Size", [size, label("bytes, at most", font: .systemFont(ofSize: 12.5)), max, label("documents",
                                                                                                                font: .systemFont(ofSize: 12.5))])
        seriesRows = [form.row("Time Field", [timeField, label("Meta Field:", font: .systemFont(ofSize: 12.5)), metaField]),
                      form.row("Granularity", [granularity])]
        optionRows = [kindRow, cappedRow] + seriesRows + [form.row("Collation", [collation]), form.row("Validator", [validator]),
                                                           form.row("Validation", [level, action])]
        let heading = db.map { "Create a Collection in \($0)" } ?? "Create a Database"
        let note = db == nil ? "MongoDB keeps no empty database: a new one starts with its first collection. The command shows before it runs."
            : "Type its name; More Options makes it capped, time-series or clustered, or gives it rules. The command shows before it runs."
        super.init(id: "mongoCreate", title: db == nil ? "Create Database" : "Create Collection", heading: heading, note: note,
                   content: form.finish(), next: next)
        more.target = self
        more.action = #selector(showOptions(_:))
        kind.target = self
        kind.action = #selector(showOptions(_:))
        make = { [unowned self] in
            let k = kind.indexOfSelectedItem, rules = !validator.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
            let options = more.state == .on
            return try MongoAdmin.createCollection(
                database: db ?? self.database.stringValue, name: name.stringValue,
                size: options && k == 1 ? size.stringValue : "", max: options && k == 1 ? max.stringValue : "",
                timeField: options && k == 2 ? timeField.stringValue : "", metaField: options && k == 2 ? metaField.stringValue : "",
                granularity: options && k == 2 && granularity.indexOfSelectedItem > 0 ? granularity.titleOfSelectedItem ?? "" : "",
                clustered: options && k == 3, collation: options ? collation.stringValue : "",
                validator: options ? validator.stringValue : "", level: options && rules ? level.titleOfSelectedItem ?? "" : "",
                action: options && rules ? action.titleOfSelectedItem ?? "" : "")
        }
        showOptions(nil)
        window?.initialFirstResponder = db == nil ? database : name
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc func showOptions(_ sender: Any?) {
        let shown = more.state == .on
        for row in optionRows { row.isHidden = !shown }
        cappedRow.isHidden = !shown || kind.indexOfSelectedItem != 1
        for row in seriesRows { row.isHidden = !shown || kind.indexOfSelectedItem != 2 }
        fit()
    }
}

/// Create View…: its name, the collection or view it reads, and the pipeline in shell form.
@MainActor
final class MongoViewSheet: MongoAdminSheet {
    let name = textField("", placeholder: "View name", id: "mongoView.name", tip: "Type the new view's name", width: 340)
    let source: NSPopUpButton
    let pipeline: NSTextView

    static func show(database: String, sources: [String], source: String, on window: NSWindow,
                     next: @escaping (MongoAdminCommand) -> Void) {
        MongoViewSheet(database: database, sources: sources, source: source, next: next).begin(on: window)
    }

    private init(database: String, sources: [String], source chosen: String, next: @escaping (MongoAdminCommand) -> Void) {
        source = popup(sources, selected: max(0, sources.firstIndex(of: chosen) ?? 0), id: "mongoView.source",
                       tip: "Choose the collection or view the view reads", target: nil, action: nil)
        let (scroll, text) = shellTextView("[\n  { $match: {} }\n]", id: "mongoView.pipeline",
                                           tip: "The stages the view runs on each read, in shell form", height: 150)
        pipeline = text
        name.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let form = Form()
        form.row("Name", [name])
        form.row("Source", [source])
        let content = NSStackView(views: [form.finish(), label("Pipeline:", font: .systemFont(ofSize: 12.5)), scroll])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        scroll.widthAnchor.constraint(equalToConstant: 500).isActive = true
        super.init(id: "mongoView", title: "Create View", heading: "Create a View in \(database)",
                   note: "A view is a read-only collection whose documents its pipeline computes on each read. The command shows before it runs.",
                   content: content, next: next)
        make = { [unowned self] in
            try MongoAdmin.createView(database: database, name: name.stringValue, on: source.titleOfSelectedItem ?? "",
                                      pipeline: pipeline.string)
        }
        window?.initialFirstResponder = name
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
