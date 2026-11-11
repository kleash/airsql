import AirSQLCore
import AppKit

/// Import Documents…: an Extended JSON file (JSON Lines, documents one after another, or one array) or a CSV file (its
/// header row naming the fields, each column's type auto or chosen under Types) into a collection, an existing one or a
/// new name. The sheet shows the first documents, about how many the file holds and exactly what
/// Import will write; nothing is written before Import. The documents are inserted off the main thread in batches with
/// the activity's progress and Cancel, and a summary says how many went in, were refused or skipped, and why.
@MainActor
final class MongoImportSheet: NSWindowController, NSComboBoxDelegate {
    private let ref: MongoCollectionRef
    private let activity: ActivityCenter
    private let fileLabel = label("No file chosen", font: .systemFont(ofSize: 12.5), color: .secondaryLabelColor, truncates: true)
    private let choose = button("Choose…", id: "mongoImport.choose", tip: "Choose a file of Extended JSON documents, or a CSV file",
                                target: nil, action: nil)
    private let collection = NSComboBox()
    private let errors = popup(["Stop at the first error", "Skip lines that can't be read and refused documents"], selected: 0,
                               id: "mongoImport.errors",
                               tip: "Choose whether a bad line or a refused document stops the import, or is skipped and listed",
                               target: nil, action: nil)
    /// A CSV file's columns, and the type each is read as (auto when not chosen).
    let column = popup([], selected: 0, id: "mongoImport.column", tip: "Choose a column of the CSV file to set the type its cells are read as",
                       target: nil, action: nil)
    let columnType = popup(["auto: by each cell's shape"] + MongoCSVType.allCases.dropFirst().map(\.rawValue), selected: 0,
                           id: "mongoImport.type", tip: "Read the column's cells as this type; auto takes numbers, true and false, "
                               + "null, dates and ObjectIds by their shape, the rest as strings", target: nil, action: nil)
    private var typesRow: NSGridRow!
    private var types: [String: MongoCSVType] = [:]
    let preview = label("", font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: .secondaryLabelColor, truncates: false)
    let statement = label("", font: .systemFont(ofSize: 12.5), wraps: true)
    private var importButton: NSButton!
    private var file: URL?
    private var looked: (documents: [BSONDocument], problems: [String], estimate: Int)?
    private var looking: Task<Void, Never>?
    private var retainUntilClosed: MongoImportSheet?
    static let previewDocuments = 5

    /// Why documents can't be imported here, or nil.
    static func refusal(_ ref: MongoCollectionRef) -> String? {
        if ref.open.saved.readOnly { return "This connection is read-only: Import would write to it" }
        if !ref.collection.isEmpty, ref.kind != .collection { return "Views and time-series collections are read-only here" }
        return nil
    }

    static func show(_ ref: MongoCollectionRef, activity: ActivityCenter, on window: NSWindow) {
        let sheet = MongoImportSheet(ref, activity: activity)
        sheet.retainUntilClosed = sheet
        window.beginSheet(sheet.window!)
    }

    private init(_ ref: MongoCollectionRef, activity: ActivityCenter) {
        self.ref = ref
        self.activity = activity
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = "Import Documents into \(ref.database)"
        window.backgroundColor = .ground
        super.init(window: window)
        choose.target = self
        choose.action = #selector(chooseFile(_:))
        errors.target = self
        errors.action = #selector(errorsChanged(_:))
        column.target = self
        column.action = #selector(columnChosen(_:))
        columnType.target = self
        columnType.action = #selector(typeChosen(_:))
        collection.addItems(withObjectValues: collections.map(\.name))
        collection.stringValue = ref.collection
        collection.placeholderString = "Name of a new collection"
        collection.toolTip = "Choose the collection the documents go into, or type a new one's name"
        collection.setAccessibilityIdentifier("mongoImport.collection")
        collection.completes = true
        collection.delegate = self
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.widthAnchor.constraint(equalToConstant: 260).isActive = true
        fileLabel.setAccessibilityIdentifier("mongoImport.file")
        fileLabel.lineBreakMode = .byTruncatingMiddle  // a path: its file name stays in sight
        fileLabel.widthAnchor.constraint(equalToConstant: 330).isActive = true
        window.contentView = makeContent()
        window.setContentSize(window.contentView!.fittingSize)
        update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The database's collections as the tree last read them.
    private var collections: [MongoCollectionInfo] { ref.open.collections[ref.database] ?? [] }

    private func makeContent() -> NSView {
        let heading = label("Import documents into \(ref.database)", font: .systemFont(ofSize: 15, weight: .semibold))
        let form = Form()
        form.row("File", [fileLabel, choose])
        form.row("Collection", [collection])
        form.row("Errors", [errors])
        typesRow = form.row("Types", [column, columnType])
        typesRow.isHidden = true
        let cancel = button("Cancel", id: "mongoImport.cancel", tip: "Close without importing", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        importButton = button("Import", id: "mongoImport.run", tip: "Insert the file's documents into the collection", target: self,
                              action: #selector(run(_:)), primary: true)
        importButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, importButton])
        buttons.spacing = Spacing.unit
        preview.setAccessibilityIdentifier("mongoImport.preview")
        preview.lineBreakMode = .byClipping
        preview.maximumNumberOfLines = Self.previewDocuments + 4
        preview.toolTip = "The file's first documents, as they'll be inserted"
        preview.widthAnchor.constraint(equalToConstant: 520).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 110).isActive = true
        statement.setAccessibilityIdentifier("mongoImport.statement")
        statement.preferredMaxLayoutWidth = 520
        statement.widthAnchor.constraint(equalToConstant: 520).isActive = true
        let stack = NSStackView(views: [heading, form.finish(), preview, statement, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.double
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        return stack
    }

    private var skipBad: Bool { errors.indexOfSelectedItem == 1 }
    private var name: String { collection.stringValue.trimmingCharacters(in: .whitespaces) }

    @objc private func chooseFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a file of Extended JSON documents (JSON Lines, documents one after another, or one array), or a "
            + "CSV file whose first row names the fields"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.look(at: url)
        }
    }

    /// Reads the first documents of `url` (again, when the way errors are taken changes), off the main thread.
    func look(at url: URL) {
        if url != file { types = [:] }
        file = url
        fileLabel.stringValue = url.path
        fileLabel.textColor = .labelColor
        looked = nil
        looking?.cancel()
        update()
        let (skipBad, types) = (self.skipBad, self.types)
        looking = Task { [weak self] in
            let count = Self.previewDocuments
            let (found, names) = await Task.detached {
                (MongoImport.preview(url, skipBad: skipBad, types: types, count: count),
                 MongoImport.isCSV(url) ? (try? MongoCSVReader(url))?.names ?? [] : [])
            }.value
            guard !Task.isCancelled, let self else { return }
            looked = found
            showColumns(names)
            update()
        }
    }

    /// A CSV file's columns in the Types row, the one chosen kept.
    private func showColumns(_ names: [String]) {
        typesRow.isHidden = names.isEmpty
        guard names != column.itemTitles else { return }
        column.removeAllItems()
        column.addItems(withTitles: names)
        columnChosen(nil)
    }

    @objc private func columnChosen(_ sender: Any?) {
        let type = column.titleOfSelectedItem.flatMap { types[$0] } ?? .auto
        columnType.selectItem(at: MongoCSVType.allCases.firstIndex(of: type) ?? 0)
    }

    /// The chosen column's type: the preview is read again with it.
    @objc func typeChosen(_ sender: Any?) {
        guard let name = column.titleOfSelectedItem, let file else { return }
        types[name] = MongoCSVType.allCases[columnType.indexOfSelectedItem]
        look(at: file)
    }

    @objc private func errorsChanged(_ sender: Any?) {
        if let file { look(at: file) } else { update() }
    }

    func controlTextDidChange(_ notification: Notification) { update() }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { self.update() }  // the field takes the chosen name after this
    }

    /// The preview, what Import will write, and whether it can.
    private func update() {
        var reason: String?
        let existing = collections.first { $0.name == name }
        if file == nil {
            preview.stringValue = ""
            statement.stringValue = "Choose a file of Extended JSON documents (JSON Lines, documents one after another, or one array), "
                + "or a CSV file whose first row names the fields."
            reason = "Choose a file first"
        } else if let looked {
            let csv = MongoImport.isCSV(file!)
            let lines = looked.documents.map { String((csv ? $0.shellForm() : $0.extendedJSON()).prefix(200)) } + looked.problems.prefix(3)
            preview.stringValue = lines.isEmpty ? "The file holds no documents" : lines.joined(separator: "\n")
            if looked.documents.isEmpty {
                reason = looked.problems.isEmpty ? "The file holds no documents" : "The file's first document can't be read"
            }
        } else {
            preview.stringValue = "Reading the first documents…"
            reason = "Wait for the first documents to be read"
        }
        if name.isEmpty {
            reason = reason ?? "Type the name of the collection the documents go into"
        } else if let existing, existing.kind != .collection {
            reason = reason ?? "\(name) is a view or time-series collection, which are read-only here"
        }
        if let looked, let file, reason == nil {
            let count = looked.documents.count < Self.previewDocuments ? looked.documents.count.formatted() : "about " + looked.estimate.formatted()
            statement.stringValue = "Import adds \(count) document\(looked.estimate == 1 ? "" : "s") from \(file.lastPathComponent) to "
                + (existing == nil ? "\(ref.database).\(name), a new collection. " : "the collection \(ref.database).\(name). ")
                + (MongoImport.isCSV(file) ? "Each row is a document: the header names its fields (a.b makes a sub-document) and an "
                    + "empty cell leaves its field out. " : "")
                + "A document without an _id gets a new ObjectId; nothing is replaced or deleted. "
                + (skipBad ? "Lines that can't be read and documents the server refuses (such as a duplicate _id) are skipped and listed "
                    + "at the end" + (MongoImport.isCSV(file) ? "." : "; each line must hold one whole document.")
                    : "It stops at the first document that can't be read or that the server refuses (such as a duplicate _id); "
                    + "the documents before it stay.")
        } else if file != nil {
            statement.stringValue = (reason ?? "") + "."
        }
        importButton.isEnabled = reason == nil
        importButton.toolTip = reason ?? "Insert the file's documents into the collection"
    }

    @objc private func cancel(_ sender: Any?) { dismiss() }

    private func dismiss() {
        looking?.cancel()
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
        retainUntilClosed = nil
    }

    @objc private func run(_ sender: Any?) {
        // The gate (plan §2.8): reading a file of this Mac into a server is the person's to do.
        guard !AgentGuard.refuses("Import Documents reads a file on this Mac into the server: only the person at the Mac can run it. "
                                  + "Leave the sheet for them.") else { return }
        guard let file, importButton.isEnabled, let parent = window?.sheetParent else { return }
        let target = MongoCollectionRef(open: ref.open, database: ref.database, collection: name, kind: .collection)
        let isNew = !collections.contains { $0.name == name }
        dismiss()
        Self.importFile(file, into: target, skipBad: skipBad, types: types, isNew: isNew, activity: activity, parent: parent)
    }

    static func importFile(_ file: URL, into ref: MongoCollectionRef, skipBad: Bool, types: [String: MongoCSVType] = [:], isNew: Bool,
                           activity: ActivityCenter, parent: NSWindow?, done: (@MainActor (MongoImport.Report) -> Void)? = nil) {
        let stop = StopFlag(), open = ref.open, connection = ref.open.connection
        let work = activity.start("Importing documents into \(ref.collection)", connection: open.saved.id) { stop.set() }
        Task.detached {
            let report: MongoImport.Report
            do {
                let session = try await connection.session(.data)
                report = await MongoImport.run(session, database: ref.database, collection: ref.collection, file: file, skipBad: skipBad,
                                               types: types, stop: stop) { inserted, fraction in
                    Task { @MainActor in
                        work.detail = inserted.formatted() + " documents inserted"
                        work.progress = fraction
                    }
                }
            } catch {
                var failed = MongoImport.Report(stopped: MongoImport.message(error))
                failed.note(MongoImport.message(error))
                report = failed
            }
            await MainActor.run {
                work.end()
                if isNew, report.inserted > 0 { open.loadDatabase(ref.database, again: true) }
                if let done { return done(report) }
                let (title, text) = summary(report, collection: ref.collection)
                let alert = NSAlert()
                alert.alertStyle = report.stopped == nil && report.refused + report.skipped == 0 ? .informational : .warning
                alert.messageText = title
                alert.accessoryView = alertText([label(text, wraps: true)], width: 420)
                alert.addOK()
                if let parent { alert.beginSheetModal(for: parent) } else { alert.runModal() }
            }
        }
    }

    /// The summary's title and its lines: how many went in, were refused (duplicates among them) or skipped, and the
    /// first problems with their line or document number.
    nonisolated static func summary(_ report: MongoImport.Report, collection: String) -> (String, String) {
        let inserted = "\(report.inserted.formatted()) document\(report.inserted == 1 ? "" : "s")"
        let title = report.cancelled ? "Import cancelled: \(inserted) inserted into \(collection)"
            : report.stopped != nil ? "The import stopped: \(inserted) inserted into \(collection)"
            : "\(inserted) imported into \(collection)"
        var lines = ["Inserted: \(report.inserted.formatted())"]
        if report.refused > 0 {
            lines.append("Refused by the server: \(report.refused.formatted())"
                         + (report.duplicates > 0 ? " (\(report.duplicates.formatted()) with an _id the collection holds already)" : ""))
        }
        if report.skipped > 0 { lines.append("Lines skipped, which couldn't be read: \(report.skipped.formatted())") }
        if report.cancelled { lines.append("The documents after them weren't read.") }
        if !report.problems.isEmpty {
            let more = report.noted - report.problems.count
            lines.append("\n" + (report.problems.count == 1 ? "The problem:" : "The first problems:"))
            lines += report.problems
            if more > 0 { lines.append("… and \(more.formatted()) more") }
        }
        return (title, lines.joined(separator: "\n"))
    }
}
