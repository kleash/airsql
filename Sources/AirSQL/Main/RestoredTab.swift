import AirSQLCore
import AppKit
import Combine

extension Tab {
    /// What brings this tab back after a relaunch, by name only; nil: it isn't kept.
    var place: SavedPlace? {
        switch shown {
        case let restored as RestoredTabContent:
            return restored.place
        case let table as TableDataController:
            return SavedPlace(kind: .table, database: table.database, object: table.tableName)
        case let editor as TableEditorController:
            return editor.table.map { SavedPlace(kind: .structure, database: editor.database, object: $0) }
        case let editor as ObjectEditorController:
            guard let kind = SavedPlace.Kind(rawValue: editor.kind.rawValue) else { return nil }
            return editor.name.map { SavedPlace(kind: kind, database: editor.database, object: $0) }
        case is ProcessListContent:
            return SavedPlace(kind: .processes)
        case let collection as MongoCollectionController:
            return SavedPlace(kind: .collection, database: collection.database, object: collection.name, query: collection.bar.query,
                              page: collection.page.rawValue)
        case let aggregation as MongoAggregationController:
            return SavedPlace(kind: .aggregation, database: aggregation.database, object: aggregation.collection,
                              text: aggregation.editor.string)
        default:
            return nil
        }
    }
}

/// A table, structure, process-list, MongoDB collection or pipeline tab back after a relaunch. AirSQL never connects by
/// itself, so the tab says what it was until the person presses its button, which connects the normal way (prompts,
/// Trust sheet, error sheet) and puts the real tab in its place.
@MainActor
final class RestoredTabContent: NSViewController, TabContent {
    let place: SavedPlace
    private let model: AppModel
    private let connectionID: UUID
    /// The window it's in now: a tab can move to another.
    private var main: MainWindowController? { model.windows.first { $0.tabs.contains { $0.shown === self } } }
    /// The person pressed the button: the tab loads once the connect ends. A failed connect keeps it, for the error
    /// sheet's Try Again; a cancelled one ends it.
    private var wanted = false
    private let what = label("", font: .systemFont(ofSize: 13), color: .secondaryLabelColor, wraps: true)
    private let state = label("", font: .systemFont(ofSize: 13), wraps: true)
    private let spinner = NSProgressIndicator()
    private lazy var open = button("", id: "restored.open", tip: "", target: self, action: #selector(openTab(_:)), primary: true)
    private lazy var edit = button("Edit Connection…", id: "restored.edit", tip: "Open the connection's settings", target: self,
                                   action: #selector(editConnection(_:)))
    private lazy var help = button("Troubleshooting", id: "restored.help",
                                   tip: "Open the help page on what to do about failed connections", target: self,
                                   action: #selector(troubleshoot(_:)))
    private var observers: [AnyCancellable] = []

    init(_ place: SavedPlace, title: String, connection: UUID, main: MainWindowController) {
        self.place = place
        model = main.model
        connectionID = connection
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let heading = label(title ?? "", font: .systemFont(ofSize: 15, weight: .semibold), truncates: true)
        heading.toolTip = title
        what.setAccessibilityIdentifier("restored.what")
        state.setAccessibilityIdentifier("restored.state")
        spinner.style = .spinning
        spinner.controlSize = .small
        let stateRow = NSStackView(views: [spinner, state])
        stateRow.spacing = Spacing.unit
        let buttons = NSStackView(views: [open, edit, help])
        buttons.spacing = Spacing.unit
        open.keyEquivalent = "\r"
        let stack = NSStackView(views: [heading, what, stateRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.unit
        stack.setCustomSpacing(Spacing.double, after: stateRow)
        heading.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        for line in [what, stateRow] { line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        view = centered(card(stack, id: "restored"), width: 460)
        // A moment later: both publish before the value changes, and a connect attaches right after its state.
        observers.append(model.$states.sink { [weak self] _ in DispatchQueue.main.async { self?.update() } })
        observers.append(model.$data.sink { [weak self] _ in DispatchQueue.main.async { self?.update() } })
        // A MongoDB collection waits for its database's collections to be read (`load`).
        observers.append(NotificationCenter.default.publisher(for: .openConnectionDidChange).sink { [weak self] _ in self?.update() })
        update()
    }

    private var summary: String {
        let name = place.object ?? "", database = place.database ?? ""
        switch place.kind {
        case .table: return "The rows of \(name) in \(database)"
        case .structure: return "The structure of \(name) in \(database)"
        case .processes: return "The server's process list"
        case .view, .procedure, .function, .trigger, .event: return "The \(place.kind.rawValue) \(name) in \(database)"
        case .collection: return "The documents of \(name) in \(database)"
        case .aggregation: return "A pipeline on \(name) in \(database)"
        }
    }

    private var connected: Bool { model.openConnection(connectionID) != nil || model.openMongo[connectionID] != nil }

    private func update() {
        guard let saved = model.connection(connectionID) else { return }
        let connected = self.connected
        let current = model.states[connectionID]
        var failed = false, connecting = false
        if case .failed? = current { failed = true }
        if case .connecting? = current { connecting = true }
        if current == nil { wanted = false }
        if wanted, connected { return load() }
        what.stringValue = summary + ", on " + saved.displayName + (saved.marks.isEmpty ? "" : " (\(saved.marks))")
        state.stringValue = stateText(current)
        state.textColor = failed ? .systemRed : .labelColor
        spinner.isHidden = !connecting
        if connecting { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        open.title = connected ? "Open" : failed ? "Try Again" : "Connect and Open"
        open.isEnabled = !(wanted && connecting)
        open.toolTip = connected ? "Load this tab from the server"
            : wanted && connecting ? "Connecting: the tab loads once it's connected, or cancel in the status bar"
            : "Connect to \(saved.displayName), then load this tab"
        edit.isHidden = !failed
        help.isHidden = !failed
    }

    /// Loads the real tab; if one on the same thing was opened meanwhile, that one shows and this tab goes.
    private func load() {
        if let main, let mongo = model.openMongo[connectionID] { return loadMongo(mongo, in: main) }
        guard let main, let opened = model.openConnection(connectionID),
              let context = Editors.context(model.connection(connectionID), in: model) else { return }
        wanted = false
        if showsOpenedTab(in: main) { return }
        let content: NSViewController
        switch place.kind {
        case .table:
            content = TableDataController(model: model, context: context, database: place.database ?? "", table: place.object ?? "",
                                          filter: nil)
        case .structure:
            content = TableEditorController(context: context, database: place.database, table: place.object, activity: model.activity)
        case .processes:
            content = ProcessListContent(opened)
        case .view, .procedure, .function, .trigger, .event:
            guard let kind = ObjectKind(rawValue: place.kind.rawValue) else { return }
            content = ObjectEditorController(context: context, kind: kind, database: place.database ?? "", name: place.object,
                                             table: nil, activity: model.activity)
        case .collection, .aggregation:
            return
        }
        main.replace(self, with: content)
    }

    /// If a tab on the same thing was opened meanwhile, that one shows and this tab goes.
    private func showsOpenedTab(in main: MainWindowController) -> Bool {
        guard let tab = main.tabs.first(where: { $0.connectionID == connectionID && !($0.shown is Self) && $0.place == place }),
              let mine = main.tabs.first(where: { $0.shown === self }) else { return false }
        main.close(mine) { main.select(tab) }
        return true
    }

    /// A MongoDB collection tab with its query bar and page, which then finds its documents, or a pipeline tab with its
    /// pipeline, which waits for Run.
    private func loadMongo(_ mongo: OpenMongoConnection, in main: MainWindowController) {
        let database = place.database ?? "", name = place.object ?? ""
        // A view or time-series collection is read-only: its kind comes from the database's listing, read first.
        let listed = mongo.collections[database] ?? (mongo.loadErrors[database] == nil ? nil : [])
        if place.kind == .collection, listed == nil { return mongo.loadDatabase(database) }
        wanted = false
        if showsOpenedTab(in: main) { return }
        if place.kind == .collection {
            let info = listed?.first { $0.name == name } ?? MongoCollectionInfo(name: name, kind: .collection)
            let content = MongoCollectionController(model: model, connection: connectionID, database: database, collection: info)
            if let query = place.query { content.bar.query = query }
            main.replace(self, with: content)
            _ = content.view
            if let page = place.page.flatMap(MongoCollectionController.Page.init), page != .documents { content.show(page) }
        } else {
            let content = MongoAggregationController(model: model, connection: connectionID, database: database, collection: name)
            main.replace(self, with: content)
            _ = content.view
            if let text = place.text { content.editor.string = text }
        }
    }

    @objc private func openTab(_ sender: Any?) {
        wanted = true
        if !connected { model.connector.connect(connectionID, on: main?.window) }
        update()
    }

    @objc private func editConnection(_ sender: Any?) {
        if let saved = model.connection(connectionID) { main?.edit(saved, isNew: false) }
    }

    @objc private func troubleshoot(_ sender: Any?) { NSWorkspace.shared.open(HelpPage.troubleshooting.url) }
}
