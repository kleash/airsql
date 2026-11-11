import AirSQLCore
import AppKit

// Editing a collection's documents (mongo-plan, Safe editing): a field's new value, a removed field, and new, duplicated
// and deleted documents wait in `changes` (drawn over the grid by `MongoDocumentSource`) until Apply, which shows
// MongoApply's commands, runs them on the tab's data session and reads what changed back. What may change, and why not,
// is MongoChanges' to say: the tab tries each change on a copy and shows its words.
extension MongoCollectionController {
    /// Why nothing in this tab can be edited, if so.
    var editingOff: String? {
        if model.connection(connectionID)?.readOnly == true {
            return "This connection is read-only: turn that off in Edit Connection… ▸ Options to change documents"
        }
        var probe = changes
        do { try probe.insert(BSONDocument()) } catch { return Self.words(error) }
        if !shown.projection.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Clear Project to edit: Apply compares whole documents, and these were read in part"
        }
        return isApplying ? "Wait for Apply to finish" : nil
    }

    /// An error's message without its full stop, for a tooltip or a notice.
    static func words(_ error: Error) -> String {
        let text = (error as? AirSQLError)?.message ?? "\(error)"
        return text.hasSuffix(".") ? String(text.dropLast()) : text
    }

    /// Why a cell can't be edited (nil: it can), by MongoChanges' rules tried on a copy of the changes. A new document's
    /// cells open the whole document.
    func whyReadOnly(_ row: Int, _ column: Int) -> String? {
        if let off = editingOff { return off }
        guard row < source.loadedCount else { return nil }
        if source.mark(row, column) == .deleted { return "This document is to be deleted: Revert (⌥⌘Z) it first" }
        guard let document = source.document(row) else { return "This document's bytes can't be read" }
        var probe = changes
        do { try probe.edit(document, path: source.paths[column], to: .null) } catch { return Self.words(error) }
        return nil
    }

    // MARK: The grid and the value panel

    func dataGrid(_ grid: DataGridView, canEditRow row: Int, column: Int) -> Bool { whyReadOnly(row, column) == nil }

    func dataGrid(_ grid: DataGridView, edit row: Int, column: Int, typed: String?) -> Bool {
        guard row >= source.loadedCount else { return false }
        editNewDocument(row - source.loadedCount)
        return true
    }

    func dataGrid(_ grid: DataGridView, check text: String, row: Int, column: Int) -> String? {
        var probe = changes
        do { try edit(&probe, text, type: nil, row, column) } catch { return Self.words(error) }
        return nil
    }

    func dataGrid(_ grid: DataGridView, didEditRow row: Int, column: Int, text: String) {
        keep(text, row: row, column: column)
    }

    /// Keeps `text` as the cell's pending value, read as the field's type, or as `type` (the only way to change it); why
    /// not, if not.
    @discardableResult
    func keep(_ text: String, type: String? = nil, row: Int, column: Int) -> String? {
        change { try self.edit(&$0, text, type: type, row, column) }
    }

    /// The edit of `text` at a loaded document's cell, made in `changes`. The type is kept unless `type` is chosen, or a
    /// type chosen before is kept again.
    private func edit(_ changes: inout MongoChanges, _ text: String, type: String?, _ row: Int, _ column: Int) throws {
        guard row < source.loadedCount, let document = source.document(row) else {
            throw AirSQLError(.readOnly, "A new document is edited whole: Edit Value… opens it.")
        }
        let path = source.paths[column], shown = source.bsonValue(row, column)
        let value: BSONValue
        if let type {
            value = type == "null" ? .null : try MongoChanges.value(text, keeping: MongoValueSheet.template(type))
            guard value.typeAlias == type else { throw AirSQLError(.other, "The text isn't a \(type) value in shell form.") }
        } else {
            value = try MongoChanges.value(text, keeping: shown)
        }
        let loaded = MongoChanges.value(at: path, in: document)
        try changes.edit(document, path: path, to: value, changingType: type != nil || shown?.typeByte != loaded?.typeByte)
    }

    /// Makes a change to `changes`, undoably; nothing changes when it throws, and why is returned.
    @discardableResult
    func change(_ body: (inout MongoChanges) throws -> Void) -> String? {
        var next = changes
        do { try body(&next) } catch { return Self.words(error) }
        undone.append(changes)
        redone = []
        changes = next
        changesDidChange()
        return nil
    }

    /// After every change: drawn over the rows, the bars and the tab's dot brought up to date.
    func changesDidChange() {
        source.changes = changes
        viewer.reloadData()
        updateBars()
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
    }

    /// "3 pending changes: 1 edited document, 1 new document, 1 deleted document. …"
    var pendingSummary: String {
        let parts = [(changes.edits.count, "edited document"), (changes.inserts.count, "new document"), (changes.deletes.count, "deleted document")]
            .filter { $0.0 > 0 }.map { "\($0.0.formatted()) \($0.1)\($0.0 == 1 ? "" : "s")" }
        let count = changes.steps.count
        return "\(count.formatted()) pending \(count == 1 ? "change" : "changes"): " + parts.joined(separator: ", ")
            + ". Apply (⌘S) shows the commands, then writes them."
    }

    /// Asks before pending changes would be lost (a new find, closing the tab); Discard forgets them and runs `discard`.
    func askToDiscard(_ discard: @escaping () -> Void, staying: @escaping () -> Void = {}) {
        let alert = NSAlert()
        alert.messageText = "Discard the changes to \(name)?"
        alert.informativeText = pendingSummary.components(separatedBy: ". Apply").first! + ", not applied. Discarded, they are lost; "
            + "Apply (⌘S) first to keep them."
        alert.addButton(withTitle: "Cancel").toolTip = "Keep the changes and stay"
        let button = alert.addButton(withTitle: "Discard")
        button.hasDestructiveAction = true
        button.toolTip = "Forget the pending changes: nothing is written"
        let answer = { [weak self] (response: NSApplication.ModalResponse) in
            guard let self, response == .alertSecondButtonReturn else { return staying() }
            changes = MongoChanges(database: database, collection: name, kind: info.kind)
            (undone, redone) = ([], [])
            changesDidChange()
            discard()
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: answer) } else { answer(alert.runModal()) }
    }

    // MARK: Commands

    /// Insert Document (⌘I): a new document typed in shell form; without an _id it gets a new ObjectId.
    @objc func addRow(_ sender: Any?) {
        guard editingOff == nil, let window = view.window else { return NSSound.beep() }
        MongoValueSheet.show(title: "Insert a Document into \(name)", caption: "Type the document in shell form. Without an _id it "
                             + "gets a new ObjectId. It is inserted when you apply the changes.", text: "{\n  \n}", type: nil,
                             on: window, complete: autofill(nil)) { [weak self] text, _ in
            guard let self else { return nil }
            let refusal = change { try $0.insert(try Self.newDocument(text)) }
            if refusal == nil { focus(row: source.rowCount - 1) }
            return refusal
        }
    }

    /// The document editor's autofill: the collection's fields under `path` (an array's elements as `[]`; nil: a document).
    func autofill(_ path: String?) -> MongoAutofill.Complete {
        { [weak self] text, caret in
            guard let self, let open = model.openMongo[connectionID] else { return (caret..<caret, []) }
            return open.autofill(.document, text, caret, database: database, collection: name, path: path, loaded: knownPaths)
        }
    }

    /// A new document's text, with a new ObjectId first when it has no _id.
    static func newDocument(_ text: String) throws -> BSONDocument {
        var document = try BSONDocument(shellForm: text)
        if document["_id"] == nil { document.fields.insert(("_id", .objectId(BSONObjectId.generate())), at: 0) }
        return document
    }

    /// A new document, not applied yet, edited whole.
    func editNewDocument(_ offset: Int) {
        guard let window = view.window, changes.inserts.indices.contains(offset) else { return NSSound.beep() }
        MongoValueSheet.show(title: "Edit the New Document", caption: "The document in shell form, inserted when you apply the "
                             + "changes.", text: changes.inserts[offset].shellForm(pretty: true), type: nil, on: window,
                             complete: autofill(nil)) { [weak self] text, _ in
            self?.change { try $0.replaceInsert(offset, with: try Self.newDocument(text)) }
        }
    }

    /// Edit Value…: the focused field in shell form, with its type to keep or change; a new document whole.
    @objc func editValue(_ sender: Any?) {
        guard let (row, column) = viewer.focusedCell, let window = view.window else { return NSSound.beep() }
        if row >= source.loadedCount { return editNewDocument(row - source.loadedCount) }
        guard whyReadOnly(row, column) == nil else { return viewer.dataGridOpenValue(grid) }
        let shown = source.bsonValue(row, column), path = source.paths[column].joined(separator: ".")
        MongoValueSheet.show(title: "Edit \(path)", caption: "The value in shell form. It keeps its type, the text read as one, "
                             + "unless you choose another type below.", text: shown?.shellForm(pretty: true) ?? "",
                             type: shown?.typeAlias ?? "as typed", on: window,
                             complete: autofill(source.paths[column].map { Int($0) == nil ? $0 : "[]" }.joined(separator: "."))) { [weak self] text, type in
            self?.keep(text, type: type, row: row, column: column)
        }
    }

    /// Remove Field: the selected cells' fields go from their documents.
    @objc func removeField(_ sender: Any?) {
        let cells = viewer.selectedCells().filter { $0.row < source.loadedCount && source.mark($0.row, $0.column) != .deleted }
        guard !cells.isEmpty else { return NSSound.beep() }
        let refusal = change { changes in
            for (row, column) in cells {
                guard let document = source.document(row) else { continue }
                try changes.edit(document, path: source.paths[column], to: nil)
            }
        }
        if let refusal { showError(refusal + ".", title: "No field was removed", on: view.window) }
    }

    /// Duplicate Document (⌘D): a copy of each selected document as it shows, with a new ObjectId for its _id.
    @objc func duplicateRow(_ sender: Any?) {
        let rows = viewer.selectedRows(), loaded = source.loadedCount
        guard editingOff == nil, !rows.isEmpty else { return NSSound.beep() }
        let refusal = change { changes in
            for row in rows {
                guard var document = source.document(row) else { continue }
                if row < loaded { document = changes.applied(to: document) }
                let id = BSONValue.objectId(BSONObjectId.generate())
                if let at = document.fields.firstIndex(where: { $0.key == "_id" }) { document.fields[at].value = id } else {
                    document.fields.insert(("_id", id), at: 0)
                }
                try changes.insert(document)
            }
        }
        if let refusal { return showError(refusal + ".", title: "Nothing was duplicated", on: view.window) }
        focus(row: source.rowCount - 1)
    }

    /// Delete Documents (⌘⌫): the selected loaded documents are deleted at Apply; new ones go now.
    @objc func deleteRows(_ sender: Any?) {
        let rows = viewer.selectedRows(), loaded = source.loadedCount
        guard editingOff == nil, !rows.isEmpty else { return NSSound.beep() }
        let refusal = change { changes in
            for row in rows where row < loaded {
                if let document = source.document(row) { try changes.delete(document) }
            }
            changes.removeInserts(rows.filter { $0 >= loaded }.map { $0 - loaded })
        }
        if let refusal { showError(refusal + ".", title: "Nothing was deleted", on: view.window) }
    }

    /// Revert (⌥⌘Z): the selected documents' changes.
    @objc func revertChanges(_ sender: Any?) {
        let rows = viewer.selectedRows(), loaded = source.loadedCount
        change { changes in
            for row in rows where row < loaded {
                if let id = source.document(row)?["_id"] { changes.revert(id) }
            }
            changes.removeInserts(rows.filter { $0 >= loaded }.map { $0 - loaded })
        }
    }

    @objc func revertAllChanges(_ sender: Any?) {
        change { $0 = MongoChanges(database: database, collection: name, kind: info.kind) }
    }

    @objc func undo(_ sender: Any?) {
        guard let last = undone.popLast() else { return NSSound.beep() }
        redone.append(changes)
        changes = last
        changesDidChange()
    }

    @objc func redo(_ sender: Any?) {
        guard let next = redone.popLast() else { return NSSound.beep() }
        undone.append(changes)
        changes = next
        changesDidChange()
    }

    /// Selects a row's first cell and scrolls to it, in the grid.
    func focus(row: Int) {
        viewer.backToGrid(nil)
        guard row >= 0, row < grid.rowCount, grid.columnCount > 0 else { return }
        grid.selection.select(GridPosition(row: row, column: 0))
        grid.reveal(grid.cellRect(GridPosition(row: row, column: 0)))
        view.window?.makeFirstResponder(grid)
    }

    // MARK: Apply

    /// Apply (⌘S): the sheet lists the exact commands, and on a standalone says first that a failure leaves the changes
    /// before it applied; Apply runs them on the tab's data session.
    @objc func applyChanges(_ sender: Any?) {
        viewer.valuePanel?.keepValue(nil)
        guard grid.endEditing(commit: true), viewer.valuePanel?.edited != true else { return }
        guard !changes.isEmpty, loading == nil, let window = view.window else { return NSSound.beep() }
        guard let open = model.openMongo[connectionID] else {
            return showError("The changes are kept: connect again (double-click the connection in the sidebar), then Apply.",
                             title: "\(model.connection(connectionID)?.displayName ?? "The server") isn't connected", on: window)
        }
        let atomic = MongoApply.isAtomic(open.server), count = changes.steps.count
        var request = SQLPreviewRequest(
            change: ChangeSQL(title: "Apply changes to \(name)", statements: [changes.preview.joined(separator: "\n")], connection: connectionID),
            heading: "Apply \(count) \(count == 1 ? "change" : "changes") to \(database).\(name)?",
            caption: "Each document is read back first and must still be exactly as loaded, or Apply stops there."
                + (atomic ? " They run in one transaction: all of them, or none." : ""))
        if !atomic {
            request.warnings = ["\(open.saved.displayName) is a standalone server, which has no transactions: if a change fails, "
                                + "the changes before it stay applied."]
        }
        request.destructive = !changes.deletes.isEmpty
        request.shellCommands = true
        SQLPreviewSheet.show(request, connection: open.saved, on: window) { [weak self] result in
            if result.approved { self?.runApply(atomic: atomic) }
        }
    }

    @objc func previewChanges(_ sender: Any?) { applyChanges(sender) }
    /// ⌘S: AppKit stops at the first item with a shortcut, enabled or not, and that is File ▸ Save.
    @objc func saveQuery(_ sender: Any?) { applyChanges(sender) }

    /// Runs MongoApply with a spinner and Cancel (which ends the command on the server), then says how it went: applied,
    /// stopped at a document and why, or unknown (reload to see; never run again). What was applied is read back.
    func runApply(atomic: Bool) {
        guard let connection, loading == nil, !changes.isEmpty else { return }
        let applying = changes, slot = slot
        isApplying = true
        let read = begin("Applying changes to \(name)")
        loading = Task { [self] in
            let session: MongoSession
            do {
                session = try await connection.session(.data, slot: slot)
            } catch {
                isApplying = false
                endRead(read)
                return showError("Nothing was applied: " + error.localizedDescription, title: "Apply stopped", on: view.window)
            }
            let report = await MongoApply.run(applying, on: session, atomic: atomic)
            // What is left to apply: nothing, or (stopped) the step that stopped it and those after. An unknown outcome
            // leaves nothing, so that nothing is ever sent twice.
            var rest = applying
            rest.dropApplied(report.outcome == .stopped ? report.applied : report.total)
            changes = rest
            (undone, redone) = ([], [])
            if report.outcome != .unknown, report.applied > 0 { await readBack(applying, leaving: rest, on: session) }
            isApplying = false
            changesDidChange()
            endRead(read)
            guard report.outcome != .applied else { return announce(report.message) }
            point(at: report.failedStep, of: applying)
            showError(report.message, title: report.outcome == .unknown ? "AirSQL can't tell whether \(name) changed"
                      : "Apply stopped", on: view.window)
        }
    }

    /// Selects the document of the step that stopped Apply.
    private func point(at step: Int?, of applied: MongoChanges) {
        guard let step else { return }
        let (deletes, edits) = (applied.deletes.count, applied.edits.count)
        let id = step < deletes ? applied.deletes[step]["_id"] : step < deletes + edits ? applied.edits[step - deletes].id : nil
        guard let row = id.flatMap(source.row(of:)) else { return }
        grid.selection.selectRow(row)
        grid.reveal(grid.rowRect(row))
    }

    /// The documents Apply changed or inserted, read again by _id; the deleted ones leave the grid.
    private func readBack(_ applied: MongoChanges, leaving rest: MongoChanges, on session: MongoSession) async {
        func ids(_ changes: MongoChanges) -> [BSONValue] {
            changes.deletes.compactMap { $0["_id"] } + changes.edits.map(\.id) + changes.inserts.compactMap { $0["_id"] }
        }
        let left = ids(rest)
        let done = ids(applied).filter { !left.contains($0) }
        let gone = applied.deletes.compactMap { $0["_id"] }.filter(done.contains)
        let wanted = done.filter { !gone.contains($0) }
        var found: [(id: BSONValue, bytes: [UInt8])] = []
        if !wanted.isEmpty {
            do {
                let filter = BSONDocument([("_id", .document(BSONDocument([("$in", .array(wanted))])))])
                let cursor = try await session.find(database: database, collection: name,
                                                    MongoFind(filter: filter, collation: BSONDocument([("locale", .string("simple"))])))
                while !cursor.isExhausted {
                    for bytes in try await cursor.next() {
                        if let id = try? BSONDocument(bytes: bytes)["_id"] { found.append((id, bytes)) }
                    }
                }
            } catch {
                problem = "The changes were applied, but they weren't read back: \(error.localizedDescription) Refresh (⌘R) reads them."
                return
            }
        }
        var rows: [[UInt8]] = []
        for row in 0..<source.loadedCount {
            let bytes = source.bytes(row), id = (try? BSONDocument.value(at: ["_id"], in: bytes)) ?? nil
            if let id, gone.contains(id) { continue }
            if let id, let at = found.firstIndex(where: { $0.id == id }) { rows.append(found.remove(at: at).bytes) } else { rows.append(bytes) }
        }
        let fresh = MongoDocumentSource()
        for path in source.paths where path.count > 1 {
            for n in 1..<path.count where source.isExpanded(Array(path.prefix(n))) { fresh.setExpanded(Array(path.prefix(n)), true) }
        }
        fresh.append(rows + found.map(\.bytes))  // the new documents after the loaded ones
        source = fresh
        if total?.exact == true { total = cursor?.isExhausted == false ? nil : (Int64(source.loadedCount), true) }
        showSource(keepingPlace: true)
    }

    // MARK: Menus

    /// Why an editing command can't run now (nil: it can, or the item isn't one).
    func editingReason(_ item: NSMenuItem) -> String? {
        switch item.action {
        case Commands.addRow.action?:
            return editingOff
        case Commands.duplicateRow.action?, Commands.deleteRows.action?:
            return editingOff ?? (viewer.selectedRows().isEmpty ? "Select documents first" : nil)
        case Commands.editValue.action?, Commands.removeField.action?:
            guard let (row, column) = viewer.focusedCell else { return editingOff ?? "Select a field first" }
            if row >= source.loadedCount {
                return item.action == Commands.removeField.action ? "A new document is edited whole: Edit Value… opens it" : editingOff
            }
            return whyReadOnly(row, column)
        case Commands.revert.action?:
            let loaded = source.loadedCount
            let changed = viewer.selectedRows().prefix(1_000).contains { row in
                row >= loaded || source.document(row)?["_id"].map { id in
                    changes.edits.contains { $0.id == id } || changes.deletes.contains { $0["_id"] == id }
                } == true
            }
            return changed ? nil : "The selected documents have no pending changes"
        case Commands.apply.action?, Commands.save.action?, Commands.previewChanges.action?:
            if changes.isEmpty { return "No changes are pending" }
            if connection == nil { return "Connect again to apply them: they are kept" }
            return isApplying ? "Apply is under way" : loading != nil ? "Wait for the read under way, or cancel it (⌘.)" : nil
        case Commands.undo.action?: return undone.isEmpty || isApplying ? "Nothing to undo" : nil
        case Commands.redo.action?: return redone.isEmpty || isApplying ? "Nothing to redo" : nil
        default: return nil
        }
    }

    /// The editing commands' titles and tips here, where the table tab's say "row".
    static let editingTitles: [Selector: String] = [
        Commands.addRow.action: "Insert Document", Commands.duplicateRow.action: "Duplicate Document",
        Commands.deleteRows.action: "Delete Documents", Commands.previewChanges.action: "Preview Commands…",
    ]
    static let editingTips: [Selector: String] = [
        Commands.addRow.action: "Add a new document, typed in shell form; it is inserted when you apply the changes",
        Commands.duplicateRow.action: "Add a copy of each selected document, with a new ObjectId for its _id",
        Commands.deleteRows.action: "Mark the selected documents for deletion; they are deleted when you apply",
        Commands.revert.action: "Discard the pending changes of the selected documents",
        Commands.apply.action: "Show the commands, then write the pending changes to the server",
        Commands.save.action: "Show the commands, then write the pending changes to the server",
        Commands.previewChanges.action: "Show the commands Apply would run",
    ]

    /// The editing items of the cells' menu.
    func addEditingItems(to menu: NSMenu) {
        menu.add([nil, Commands.editValue, Commands.removeField, nil, Commands.addRow, Commands.duplicateRow, Commands.deleteRows,
                  Commands.revert, nil, Commands.apply])
        for item in menu.items {
            if let action = item.action, let title = Self.editingTitles[action] { item.title = title }
            if item.target == nil { item.target = self }
        }
    }
}
