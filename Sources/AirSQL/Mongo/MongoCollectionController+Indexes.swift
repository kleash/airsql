import AirSQLCore
import AppKit

// A collection's indexes (mongo-plan, Indexes): the Indexes page reads them on the tab's data session; Create Index…,
// Drop Index… and Hide Index… show their exact command in the preview sheet, then run it there with the tab's spinner
// and Cancel, and read the indexes again (the tree's too). The tree's index commands come here, through the tab.
extension MongoCollectionController {
    /// Why this collection's indexes can't be changed, if so.
    var indexesOff: String? { Self.indexesOff(model.connection(connectionID), info.kind) }

    static func indexesOff(_ saved: SavedConnection?, _ kind: MongoCollectionInfo.Kind) -> String? {
        if saved?.readOnly == true {
            return "This connection is read-only: turn that off in Edit Connection… ▸ Options to change indexes"
        }
        switch kind {
        case .view: return "A view has no indexes of its own: its collection's indexes serve it"
        case .timeseries: return "A time-series collection is read-only here, its indexes too"
        case .collection: return nil
        }
    }

    /// Why `index` can't be dropped or hidden (`hide`), if so.
    static func whyNot(_ index: MongoIndex?, hide: Bool) -> String? {
        guard let index else { return "Select an index first" }
        if index.name == "_id_" { return "The _id index can't be \(hide ? "hidden" : "dropped"): every collection keeps it" }
        return index.building ? "Wait for the index to be built" : nil
    }

    /// Why a command of the Indexes page can't run now (nil: it can), and its title: Hide or Unhide.
    func indexReason(_ action: Selector?, title: inout String) -> String? {
        let busy = loading != nil ? "Wait for the work under way, or cancel it (⌘.)" : nil
        switch action {
        case Commands.createIndex.action:
            return indexesOff ?? busy
        case Commands.dropIndex.action:
            return indexesOff ?? Self.whyNot(indexesView.selected, hide: false) ?? busy
        case Commands.hideIndex.action:
            if indexesView.selected?.isHidden == true { title = "Unhide Index…" }
            return indexesOff ?? Self.whyNot(indexesView.selected, hide: true) ?? busy
        default:
            return nil
        }
    }

    /// The bar's buttons enabled, titled and explained as the menu's items are.
    func updateIndexButtons() {
        for button in [indexesView.createButton, indexesView.dropButton, indexesView.hideButton] {
            let command = Commands.all.first { $0.action == button.action }!
            var title = command.title
            let reason = indexReason(button.action, title: &title)
            button.title = title
            button.isEnabled = reason == nil
            button.toolTip = reason ?? (title.hasPrefix("Unhide") ? "Let the query planner use the selected index again" : command.tip)
        }
    }

    /// Runs `body` once the read under way (a new tab's first find) has ended.
    private func whenIdle(_ body: @escaping () -> Void) {
        guard let busy = loading else { return body() }
        Task { [weak self] in
            await busy.value
            self?.whenIdle(body)
        }
    }

    // MARK: Reading

    /// The collection's indexes with their sizes and use, once the tab is idle.
    func loadIndexes() {
        whenIdle { [weak self] in self?.readIndexes() }
    }

    private func readIndexes() {
        guard let connection else { return }
        let (database, name) = (self.database, self.name)
        let read = begin("Reading the indexes of \(name)")
        loading = Task { [self] in
            do {
                let found = try await connection.session(.data, slot: slot).indexes(database: database, collection: name)
                try Task.checkCancellation()
                let host = found.indexes.lazy.compactMap(\.host).first
                var caption = host.map { "Uses on \($0) since the date shown: each member counts its own, from its restart" }
                    ?? "Uses aren't counted here"
                if let missing = found.unavailable { caption += ". Not read: " + missing }
                indexesView.show(found.indexes, caption: caption + " · read " + GridStatusView.time(Date()),
                                 emptyText: info.kind == .view ? "A view has no indexes of its own: its collection's indexes serve it."
                                    : "\(name) has no indexes yet. Create Index… makes one: give its keys, such as { field: 1 }.")
                problem = nil
            } catch where Task.isCancelled {
                if read == reads { problem = "Cancelled: the indexes weren't read. Refresh (⌘R) reads them." }
            } catch {
                problem = "The indexes weren't read: " + error.localizedDescription
            }
            endRead(read)
        }
    }

    // MARK: Commands

    /// Create Index…: the sheet, then the command in the preview sheet, then the index made.
    @objc func createIndex(_ sender: Any?) {
        guard indexesOff == nil, let window = view.window else { return NSSound.beep() }
        if page != .indexes { show(.indexes) }
        MongoIndexSheet.show(collection: name, on: window) { [weak self] keys, options in
            guard let self else { return }
            let command = MongoIndex.createCommand(collection: name, keys: keys, options: options)
            let made: String
            if case .array(let indexes)? = command["indexes"], case .document(let index)? = indexes.first,
               case .string(let given)? = index["name"] { made = given } else { made = "" }
            run(command, title: "Create index \(made)", heading: "Create the index \(made) on \(database).\(name)?",
                caption: "The server builds it from every document while other work goes on.",
                action: "Create", destructive: false, choosing: made) { session in
                try await session.createIndex(database: self.database, collection: self.name, keys: keys, options: options)
            } failure: { MongoIndex.createFailure($0) }
        }
    }

    /// Drop Index…: the dropIndexes command, marked destructive; when the connection's safety settings ask for it (a
    /// Production connection's do), its name is typed first.
    @objc func dropIndex(_ sender: Any?) {
        guard let index = indexesView.selected else { return NSSound.beep() }
        drop(index)
    }

    func drop(_ index: MongoIndex) {
        guard indexesOff == nil, Self.whyNot(index, hide: false) == nil, let saved = model.connection(connectionID) else {
            return NSSound.beep()
        }
        run(MongoIndex.dropCommand(collection: name, name: index.name), title: "Drop index \(index.name)",
            heading: "Drop the index \(index.name) from \(database).\(name)?",
            caption: "Queries that used it get slower; making it again reads every document.", action: "Drop", destructive: true,
            typeToConfirm: model.data.safety(for: saved).typeNameForTables ? index.name : nil) { session in
            try await session.dropIndex(database: self.database, collection: self.name, name: index.name)
        } failure: { $0.localizedDescription }
    }

    /// Hide Index… or Unhide Index…: collMod, previewed the same way.
    @objc func toggleIndexHidden(_ sender: Any?) {
        guard let index = indexesView.selected else { return NSSound.beep() }
        setHidden(index)
    }

    func setHidden(_ index: MongoIndex) {
        guard indexesOff == nil, Self.whyNot(index, hide: true) == nil else { return NSSound.beep() }
        let hide = !index.isHidden
        run(MongoIndex.hideCommand(collection: name, name: index.name, hidden: hide), title: "\(hide ? "Hide" : "Unhide") index \(index.name)",
            heading: "\(hide ? "Hide" : "Unhide") the index \(index.name) of \(database).\(name)?",
            caption: hide ? "The query planner stops using it; it is still kept up to date, so Unhide brings it back at once."
                : "The query planner may use it again.", action: hide ? "Hide" : "Unhide", destructive: false, choosing: index.name) { session in
            try await session.setIndexHidden(database: self.database, collection: self.name, name: index.name, hidden: hide)
        } failure: { $0.localizedDescription }
    }

    /// Shows `command` in the preview sheet; its Run runs `work` on the tab's data session (once the tab is idle), with the
    /// spinner and Cancel, then reads the indexes again, here and in the tree, `choosing` one of them.
    private func run(_ command: BSONDocument, title: String, heading: String, caption: String, action: String, destructive: Bool,
                     typeToConfirm: String? = nil, choosing: String? = nil, _ work: @escaping (MongoSession) async throws -> Void,
                     failure: @escaping (Error) -> String) {
        guard let window = view.window, let saved = model.connection(connectionID) else { return NSSound.beep() }
        var request = SQLPreviewRequest(change: ChangeSQL(title: title, statements: [MongoIndex.shellForm(command, database: database)],
                                                          connection: connectionID), heading: heading, caption: caption)
        request.actionTitle = action
        request.destructive = destructive
        request.typeToConfirm = typeToConfirm
        request.shellCommands = true
        SQLPreviewSheet.show(request, connection: saved, on: window) { [weak self] result in
            guard result.approved else { return }
            self?.whenIdle { self?.perform(title, choosing: choosing, work, failure: failure) }
        }
    }

    private func perform(_ title: String, choosing: String?, _ work: @escaping (MongoSession) async throws -> Void,
                         failure: @escaping (Error) -> String) {
        guard let connection else { return NSSound.beep() }
        let read = begin(title)
        loading = Task { [self] in
            var failed: Error?
            do {
                try await work(connection.session(.data, slot: slot))
            } catch where Task.isCancelled {
                failed = AirSQLError(.cancelled, "Cancelled. Refresh (⌘R) shows whether it was done.")
            } catch {
                failed = error
            }
            endRead(read)
            model.openMongo[connectionID]?.loadIndexes(database, name, again: true)
            indexesView.wanted = choosing
            readIndexes()
            if let failed { return showError(failure(failed), title: "\(title) didn't happen", on: view.window) }
            announce("\(title): done")
        }
    }
}
