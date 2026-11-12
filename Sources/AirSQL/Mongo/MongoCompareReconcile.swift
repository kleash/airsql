import AirSQLCore
import AppKit
import Combine

/// One side of the MongoDB compare: a MongoDB connection, a database and a collection. Choosing a connection connects
/// it, so that its databases and collections fill the lists; a name can be typed too.
@MainActor
final class MongoCompareSidePicker: NSObject, NSComboBoxDelegate {
    weak var model: AppModel? {
        didSet {
            observer = model?.$openMongo.sink { [weak self] _ in DispatchQueue.main.async { self?.fill() } }
        }
    }
    var connections: [SavedConnection] = [] {
        didSet {
            popup.removeAllItems()
            popup.addItem(withTitle: "Choose a Connection")
            popup.addItems(withTitles: connections.map(\.displayName))
        }
    }
    var changed: (() -> Void)?
    let popup: NSPopUpButton
    let database = NSComboBox(), collection = NSComboBox()
    let view: NSStackView
    private var observer: AnyCancellable?

    init(_ side: String) {
        popup = AirSQL.popup([], selected: 0, id: "mongoCompare.\(side.lowercased()).connection",
                             tip: "Choose the \(side.lowercased())'s MongoDB connection", target: nil, action: nil)
        let title = label(side + ":", font: .systemFont(ofSize: 12, weight: .semibold), color: .secondaryLabelColor)
        popup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        view = NSStackView(views: [title, popup, database, collection])
        view.spacing = Spacing.unit
        super.init()
        popup.target = self
        popup.action = #selector(connectionChosen(_:))
        for (box, what, width) in [(database, "database", 170.0), (collection, "collection", 120.0)] {
            box.placeholderString = what.capitalized
            box.toolTip = "Choose or type the \(side.lowercased())'s \(what)"
            box.setAccessibilityIdentifier("mongoCompare.\(side.lowercased()).\(what)")
            box.completes = true
            box.delegate = self
            box.target = self
            box.action = #selector(nameChosen(_:))
            box.translatesAutoresizingMaskIntoConstraints = false
            box.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        NotificationCenter.default.addObserver(self, selector: #selector(treeRead(_:)), name: .openConnectionDidChange, object: nil)
    }

    var connection: SavedConnection? {
        let index = popup.indexOfSelectedItem - 1
        return connections.indices.contains(index) ? connections[index] : nil
    }

    var databaseName: String { database.stringValue.trimmingCharacters(in: .whitespaces) }
    var collectionName: String { collection.stringValue.trimmingCharacters(in: .whitespaces) }

    /// "Staging shop.orders", or "" until all three are chosen.
    var summary: String {
        guard let connection, !databaseName.isEmpty, !collectionName.isEmpty else { return "" }
        return "\(connection.displayName) \(databaseName).\(collectionName)"
    }

    func choose(_ saved: SavedConnection?, database name: String, collection collectionName: String) {
        popup.selectItem(at: saved.flatMap { saved in connections.firstIndex { $0.id == saved.id } }.map { $0 + 1 } ?? 0)
        database.stringValue = name
        collection.stringValue = collectionName
        fill()
    }

    @objc private func connectionChosen(_ sender: Any?) {
        if let connection, model?.openMongo[connection.id] == nil { model?.connector.connect(connection.id, on: view.window) }
        database.stringValue = ""
        collection.stringValue = ""
        fill()
        changed?()
    }

    @objc private func nameChosen(_ sender: Any?) {
        if (sender as? NSComboBox) === database { collection.stringValue = "" }
        fill()
        changed?()
    }

    func controlTextDidChange(_ notification: Notification) { changed?() }

    @objc private func treeRead(_ notification: Notification) {
        if let open = notification.object as? OpenMongoConnection, open.saved.id == connection?.id { fill() }
    }

    /// The lists from what the tree has read of the connection, the chosen database's collections read when they aren't.
    private func fill() {
        guard let connection, let open = model?.openMongo[connection.id] else {
            database.removeAllItems()
            collection.removeAllItems()
            return
        }
        let databases = (open.databases ?? []).map(\.name)
        if database.objectValues as? [String] != databases {
            database.removeAllItems()
            database.addItems(withObjectValues: databases)
        }
        let name = databaseName
        guard !name.isEmpty, databases.contains(name) else { return collection.removeAllItems() }
        guard let found = open.collections[name] else { return open.loadDatabase(name) }
        let names = found.map(\.name)
        if collection.objectValues as? [String] != names {
            collection.removeAllItems()
            collection.addItems(withObjectValues: names)
        }
    }

    /// The connection connected (its prompts on `window`) unless it is, once its connect ends.
    static func connect(_ saved: SavedConnection, model: AppModel, on window: NSWindow?) async throws -> OpenMongoConnection {
        if let open = model.openMongo[saved.id] { return open }
        model.connector.connect(saved.id, on: window)
        while true {
            try Task.checkCancellation()
            if let open = model.openMongo[saved.id] { return open }
            switch model.states[saved.id] {
            case .failed(let message)?: throw AirSQLError(.other, message)
            case nil: throw AirSQLError(.cancelled, "Not connected.")
            default: try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}

// MARK: Reconcile

extension MongoCompareWindowController {
    /// Why Reconcile can't start, or nil when it can.
    var reconcileBlocked: String? {
        guard let result, let compared else { return "Compare first: then there is something to reconcile" }
        if isRunning { return "Wait for the compare to finish, or Cancel it" }
        if model.connection(compared.saved.id)?.readOnly ?? compared.saved.readOnly {
            return "\(compared.saved.displayName) is read-only: turn that off in Edit Connection… ▸ Options to reconcile"
        }
        switch result.targetKind {
        case .collection: break
        case .view: return "The target is a view, which is read-only"
        case .timeseries: return "The target is a time-series collection, which AirSQL keeps read-only"
        }
        let kinds: [(NSButton, MongoCompareResult.Status)] = [(inserts, .onlyInSource), (replaces, .different), (deletes, .onlyInTarget)]
        if kinds.allSatisfy({ $0.0.state == .off }) { return "Tick what Reconcile does first: Insert Missing, Replace Different or Delete Extra" }
        if kinds.allSatisfy({ $0.0.state == .off || result.count($0.1) == 0 }) { return "Nothing to reconcile: what is ticked found no documents" }
        return nil
    }

    /// Reconcile…: the exact commands in the Apply sheet; run only when the person approves, through MongoApply.
    @objc func reconcile(_ sender: Any?) {
        guard reconcileBlocked == nil, let result, let compared, let window else { return NSSound.beep() }
        guard let open = model.openMongo[compared.saved.id] else {
            return showError("\(compared.saved.displayName) isn't connected any more: connect it and compare again.", title: "Nothing was reconciled", on: window)
        }
        let made: (changes: MongoChanges, skipped: [String])
        do {
            made = try result.changes(database: compared.database, collection: compared.collection, inserts: inserts.state == .on,
                                      replaces: replaces.state == .on, deletes: deletes.state == .on)
        } catch {
            return showError(error.localizedDescription, title: "Nothing to reconcile", on: window)
        }
        let changes = made.changes
        guard !changes.isEmpty else {
            return showError(made.skipped.joined(separator: "\n"), title: "AirSQL can't write these documents", on: window)
        }
        let atomic = MongoApply.isAtomic(open.server), saved = model.connection(compared.saved.id) ?? compared.saved
        let parts = [(changes.inserts.count, "insert"), (changes.replaces.count, "replace"), (changes.deletes.count, "delete")]
            .filter { $0.0 > 0 }.map { "\($0.0.formatted()) \($0.1)\($0.0 == 1 ? "" : "s")" }
        var request = SQLPreviewRequest(
            change: ChangeSQL(title: "Reconcile \(compared.collection)", statements: [changes.preview.joined(separator: "\n")], connection: saved.id),
            heading: "Reconcile \(compared.database).\(compared.collection): \(parts.joined(separator: ", "))?",
            caption: "Each document the target has is read back first and must still be exactly as compared, or Reconcile stops "
                + "there. A replace writes the source's document whole, ignored fields included."
                + (atomic ? " They run in one transaction: all of them, or none." : ""))
        if !atomic {
            request.warnings.append("\(saved.displayName) is a standalone server, which has no transactions: if a change fails, the "
                                    + "changes before it stay applied.")
        }
        if !changes.deletes.isEmpty { request.warnings.append("Destructive: \(changes.deletes.count == 1 ? "1 document" : "\(changes.deletes.count.formatted()) documents") only in the target \(changes.deletes.count == 1 ? "is" : "are") deleted.") }
        if result.truncated { request.warnings.append("Only the first \(MongoCompare.keep.formatted()) differences are listed and reconciled: compare again after.") }
        if !made.skipped.isEmpty {
            request.warnings.append("\(made.skipped.count.formatted()) documents are left out, as AirSQL doesn't write them: "
                                    + made.skipped.prefix(3).joined(separator: "; "))
        }
        request.destructive = !changes.deletes.isEmpty
        request.shellCommands = true
        request.actionTitle = "Reconcile"
        if saved.isProduction { request.typeToConfirm = compared.collection }
        SQLPreviewSheet.show(request, connection: saved, on: window) { [weak self] answer in
            if answer.approved { self?.runReconcile(changes, on: open, atomic: atomic) }
        }
    }

    /// Runs the changes on the target's session with Cancel, says what happened, then compares again.
    func runReconcile(_ changes: MongoChanges, on open: OpenMongoConnection, atomic: Bool) {
        let slot = self.slot + "-target", name = "\(changes.database).\(changes.collection)"
        let activity = model.activity.start("Reconciling \(name)", connection: open.saved.id)
        progress.startAnimation(nil)
        progressLabel.stringValue = "Reconciling \(name)…"
        reconciling = Task { [weak self] in
            let report: MongoApplyReport?, failure: Error?
            do {
                let session = try await open.connection.session(.data, slot: slot)
                (report, failure) = (await MongoApply.run(changes, on: session, atomic: atomic), nil)
            } catch {
                (report, failure) = (nil, error)
            }
            activity.end()
            guard let self else { return }
            self.reconciling = nil
            self.progress.stopAnimation(nil)
            self.progressLabel.stringValue = ""
            guard let report else {
                self.update()
                return showError("Nothing was applied: " + (failure?.localizedDescription ?? ""), title: "Reconcile stopped", on: self.window)
            }
            let alert = NSAlert()
            alert.alertStyle = report.outcome == .applied ? .informational : .warning
            alert.messageText = report.outcome == .applied ? "\(name) reconciled" : report.outcome == .unknown
                ? "AirSQL can't tell whether \(name) changed" : "Reconcile stopped"
            alert.informativeText = report.outcome == .applied ? Self.done(changes, report.applied) + " Compared again below."
                : report.message + " Compared again below, to show what is left."
            alert.addOK()
            if let window = self.window { alert.beginSheetModal(for: window, completionHandler: nil) }
            announce(alert.messageText)
            self.refresh(nil)
        }
        update()
    }

    /// "2 inserted, 3 replaced and 0 deleted." for the first `applied` steps (deletes, then replaces, then inserts).
    static func done(_ changes: MongoChanges, _ applied: Int) -> String {
        let deleted = min(applied, changes.deletes.count), replaced = min(applied - deleted, changes.replaces.count)
        let inserted = min(applied - deleted - replaced, changes.inserts.count)
        return "\(inserted.formatted()) inserted, \(replaced.formatted()) replaced and \(deleted.formatted()) deleted."
    }
}
