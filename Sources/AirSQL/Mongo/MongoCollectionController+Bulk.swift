import AirSQLCore
import AppKit

// Update Many… and Delete Many… (mongo-plan, Phase 2 bulk): the filter (the tab's own to start with) and the update are
// typed in `MongoBulkSheet`; the documents the filter matches are counted on the tab's data session, and the preview
// sheet shows the exact command and that count, which the person types to confirm (an empty filter's delete: the
// collection's name). It then runs on the same session with the busy indicator and Cancel, and an alert says what the
// server matched and changed, warning when that isn't the count shown; the documents are read again after.
extension MongoCollectionController {
    /// Why Update Many… and Delete Many… can't run now (nil: they can).
    var bulkOff: String? {
        if model.connection(connectionID)?.readOnly == true {
            return "This connection is read-only: turn that off in Edit Connection… ▸ Options to change documents"
        }
        var probe = MongoChanges(database: database, collection: name, kind: info.kind)
        do { try probe.insert(BSONDocument()) } catch { return Self.words(error) }  // a view or a time-series collection
        if !changes.isEmpty { return "Apply or discard the pending changes first" }
        return loading != nil ? "Wait for the work under way, or cancel it (⌘.)" : nil
    }

    /// The menus' reason for the bulk commands; nil for any other item.
    func bulkReason(_ item: NSMenuItem) -> String? {
        item.action == Commands.updateMany.action || item.action == Commands.deleteMany.action ? bulkOff : nil
    }

    @objc func updateMany(_ sender: Any?) { askForBulk(delete: false) }
    @objc func deleteMany(_ sender: Any?) { askForBulk(delete: true) }

    /// The first sheet: the filter (the tab's) and the update; Preview… counts and shows the command.
    private func askForBulk(delete: Bool) {
        guard bulkOff == nil, let window = view.window else { return NSSound.beep() }
        let query = bar.query, (database, name) = (database, name)
        let collation = query.collation.trimmingCharacters(in: .whitespacesAndNewlines)
        let caption = (delete ? "Every document the filter matches is deleted." : "Every document the filter matches is changed, "
                       + "with update operators or an aggregation pipeline; a replacement document is refused, and upsert is off.")
            + " The filter starts as the tab's." + (collation.isEmpty ? "" : " Strings compare by the tab's collation, \(collation).")
            + " Preview… counts the documents and shows the command; nothing runs before you confirm."
        MongoBulkSheet.show(title: "\(delete ? "Delete" : "Update") Many Documents in \(name)", caption: caption, filter: query.filter,
                            update: delete ? nil : "{ $set: {  } }", on: window) { [weak self] filter, update in
            do {
                let collation = try MongoQueryText(collation: query.collation).find().collation
                let bulk = try update.map { try MongoBulk(database: database, collection: name, filter: filter, update: $0, collation: collation) }
                    ?? MongoBulk(database: database, collection: name, filter: filter, collation: collation)
                self?.countAndPreview(bulk)
                return nil
            } catch let problem as MongoQueryText.Problem {
                return "The tab's collation can't be read: \(problem.message)"
            } catch {
                return Self.words(error)
            }
        }
    }

    /// Counts what the filter matches now, then shows the command with that count to type.
    private func countAndPreview(_ bulk: MongoBulk) {
        guard let connection else { return }
        let read = begin("Counting the documents to \(bulk.isDelete ? "delete" : "update") in \(name)")
        loading = Task { [self] in
            do {
                let count = try await connection.session(.data, slot: slot).count(bulk)
                try Task.checkCancellation()
                endRead(read)
                preview(bulk, count: count)
            } catch where Task.isCancelled {
                endRead(read)
            } catch {
                endRead(read)
                showError("The documents weren't counted, so nothing ran: " + error.localizedDescription, title: "Nothing changed",
                          on: view.window)
            }
        }
    }

    private func preview(_ bulk: MongoBulk, count: Int64) {
        guard let window = view.window, let open = model.openMongo[connectionID] else { return }
        let verb = bulk.isDelete ? "deletes" : "changes"
        var request = SQLPreviewRequest(
            change: ChangeSQL(title: "\(bulk.isDelete ? "Delete" : "Update") many in \(name)", statements: [bulk.shellForm],
                              connection: connectionID),
            heading: bulk.heading(count: count),
            caption: "Counted just now on this tab's session. The server \(verb) the documents that match when it runs: if that "
                + "isn't \(count.formatted()), AirSQL says so. Cancel (⌘.) stops it, and what it did before it stopped stays.")
        if bulk.isDelete && bulk.filter.fields.isEmpty {
            request.warnings = ["The filter is empty: every document of \(name) is deleted. The collection and its indexes stay."]
        }
        request.actionTitle = bulk.isDelete ? "Delete" : "Update"
        request.destructive = bulk.isDelete
        request.shellCommands = true
        request.typeToConfirm = bulk.confirmation(count: count)
        SQLPreviewSheet.show(request, connection: open.saved, on: window) { [weak self] result in
            if result.approved { self?.runBulk(bulk, counted: count) }
        }
    }

    /// Runs it on the tab's data session, says what the server did, and reads the documents again.
    private func runBulk(_ bulk: MongoBulk, counted: Int64) {
        guard let connection, loading == nil else { return NSSound.beep() }
        let read = begin("\(bulk.isDelete ? "Deleting" : "Updating") documents in \(name)")
        loading = Task { [self] in
            let alert = NSAlert()
            do {
                let (matched, modified) = try await connection.session(.data, slot: slot).run(bulk)
                let report = bulk.report(counted: counted, matched: matched, modified: bulk.isDelete ? nil : modified)
                alert.messageText = report.differs ? "The server matched \(matched.formatted()), not \(counted.formatted())"
                    : bulk.isDelete ? "Documents deleted" : "Documents updated"
                alert.informativeText = report.message
                alert.alertStyle = report.differs ? .warning : .informational
            } catch {
                let unknown = (error as? AirSQLError)?.kind == .outcomeUnknown
                alert.messageText = unknown ? "AirSQL can't tell whether \(name) changed" : "\(bulk.isDelete ? "Delete" : "Update") Many stopped"
                alert.informativeText = bulk.failure(error)
                alert.alertStyle = .warning
            }
            endRead(read)
            run()  // the documents as they are now
            alert.addOK()
            if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
        }
    }
}
