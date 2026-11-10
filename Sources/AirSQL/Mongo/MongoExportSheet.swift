import AirSQLCore
import AppKit
import UniformTypeIdentifiers

/// Export Documents…, as Export Rows… is for a table: which documents (the collection's, or what its tab's query finds),
/// the format (Extended JSON relaxed or canonical, one per line or one array; or CSV with a column per field path, filled
/// in from the first documents), a preview of the first lines, then a file. The documents are written off the main
/// thread with the activity's progress and Cancel; the file appears only when complete.
@MainActor
final class MongoExportSheet: NSWindowController, NSTextFieldDelegate {
    private let ref: MongoCollectionRef
    private let activity: ActivityCenter
    /// The tab's query as a find, when it has one to offer.
    private let query: MongoFind?
    private let scope: NSPopUpButton
    private let format = popup(["Extended JSON, relaxed", "Extended JSON, canonical (keeps every type)", "CSV"], selected: 0,
                               id: "mongoExport.format",
                               tip: "Choose the file's format: Extended JSON reads back into MongoDB, CSV opens in spreadsheets",
                               target: nil, action: nil)
    private let layout = popup(["One document per line (JSON Lines)", "One JSON array"], selected: 0, id: "mongoExport.layout",
                               tip: "Choose one document per line, as mongoexport writes, or one array of them", target: nil, action: nil)
    private let paths = AirSQL.textField("", placeholder: "Field paths, separated by commas", id: "mongoExport.paths",
                                         tip: "Type the fields to write as columns, separated by commas", width: 340)
    private let cells = popup(["As the shell shows them: ObjectId(…)", "As relaxed Extended JSON: {\"$oid\": …}"], selected: 0,
                              id: "mongoExport.cells", tip: "Choose how values that aren't text or numbers are written in CSV",
                              target: nil, action: nil)
    let preview = label("", font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: .secondaryLabelColor, truncates: false)
    private var exportButton: NSButton!
    /// The first documents of the chosen scope: the preview and the CSV columns come from them.
    private var sample: [BSONDocument]?
    private var sampleProblem: String?
    private var sampling: Task<Void, Never>?
    /// The person has typed in the columns: a new sample no longer rewrites them.
    private var pathsEdited = false
    private var retainUntilClosed: MongoExportSheet?
    static let sampleSize = 1000
    static let previewDocuments = 8

    static func show(_ ref: MongoCollectionRef, activity: ActivityCenter, on window: NSWindow) {
        let sheet = MongoExportSheet(ref, activity: activity)
        sheet.retainUntilClosed = sheet
        window.beginSheet(sheet.window!)
    }

    private init(_ ref: MongoCollectionRef, activity: ActivityCenter) {
        self.ref = ref
        self.activity = activity
        query = ref.query.flatMap { $0 == MongoQueryText() ? nil : try? $0.find() }
        var scopes = ["Every document of \(ref.collection)"]
        if let summary = ref.query?.summary, query != nil {
            scopes.append("What the tab's query finds: " + (summary.count > 50 ? String(summary.prefix(49)) + "…" : summary))
        }
        scope = popup(scopes, selected: scopes.count - 1, id: "mongoExport.scope",
                      tip: "Export every document of the collection, or those the tab's query finds", target: nil, action: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = "Export Documents of \(ref.collection)"
        window.backgroundColor = .ground
        super.init(window: window)
        for control in [format, layout, cells] {
            control.target = self
            control.action = #selector(formatChanged(_:))
        }
        scope.target = self
        scope.action = #selector(scopeChanged(_:))
        paths.delegate = self
        window.contentView = makeContent()
        window.setContentSize(window.contentView!.fittingSize)
        scopeChanged(nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeContent() -> NSView {
        let heading = label("Export documents of \(ref.database).\(ref.collection)", font: .systemFont(ofSize: 15, weight: .semibold))
        let form = Form()
        form.row("Documents", [scope])
        // A long query is shortened in the button, whole in its menu.
        scope.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scope.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        form.row("Format", [format])
        form.row("Layout", [layout])
        form.row("Columns", [paths])
        form.row("Values", [cells])
        let cancel = button("Cancel", id: "mongoExport.cancel", tip: "Close without exporting", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        exportButton = button("Export…", id: "mongoExport.save", tip: "Choose a file and write the documents to it", target: self,
                              action: #selector(save(_:)), primary: true)
        exportButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, exportButton])
        buttons.spacing = Spacing.unit
        preview.setAccessibilityIdentifier("mongoExport.preview")
        preview.lineBreakMode = .byClipping
        preview.maximumNumberOfLines = Self.previewDocuments + 3
        preview.toolTip = "The first documents, as they'll be written"
        preview.widthAnchor.constraint(equalToConstant: 480).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 140).isActive = true
        let stack = NSStackView(views: [heading, form.finish(), preview, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.double
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
        return stack
    }

    /// The find of the scope chosen. Not the tab's time limit: it would end a long export part-way.
    private var find: MongoFind {
        var find = scope.indexOfSelectedItem == 1 ? query ?? MongoFind() : MongoFind()
        find.maxTimeMS = nil
        return find
    }

    private var chosenPaths: [String] {
        paths.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var chosenFormat: MongoExport.Format {
        switch format.indexOfSelectedItem {
        case 2: return .csv(chosenPaths, cells.indexOfSelectedItem == 1 ? .relaxedJSON : .shell)
        case let index: return .json(index == 1 ? .canonical : .relaxed, layout.indexOfSelectedItem == 1 ? .array : .lines)
        }
    }

    /// Reads the first documents of the scope again, on the data session.
    @objc private func scopeChanged(_ sender: Any?) {
        sampling?.cancel()
        (sample, sampleProblem) = (nil, nil)
        formatChanged(nil)
        var find = self.find
        find.limit = min(find.limit.flatMap { $0 > 0 ? $0 : nil } ?? Int64(Self.sampleSize), Int64(Self.sampleSize))
        let (connection, database, collection) = (ref.open.connection, ref.database, ref.collection)
        sampling = Task { [weak self] in
            var documents: [BSONDocument] = []
            var problem: String?
            do {
                let cursor = try await connection.session(.data).find(database: database, collection: collection, find)
                let batch = try await cursor.next(maxCount: Self.sampleSize, maxBytes: 16 << 20)
                await cursor.close()
                documents = try await Task.detached { try batch.map { try BSONDocument(bytes: $0) } }.value
            } catch {
                problem = "The first documents didn't load: " + ((error as? BSONError)?.message ?? error.localizedDescription)
            }
            guard !Task.isCancelled, let self else { return }
            (sample, sampleProblem) = (documents, problem)
            if !pathsEdited { paths.stringValue = MongoCSVWriter.paths(of: documents).joined(separator: ", ") }
            formatChanged(nil)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        pathsEdited = true
        formatChanged(nil)
    }

    @objc private func formatChanged(_ sender: Any?) {
        let csv = format.indexOfSelectedItem == 2
        layout.isEnabled = !csv
        layout.toolTip = csv ? "CSV has one row per document" : "Choose one document per line, as mongoexport writes, or one array of them"
        paths.isEnabled = csv
        paths.toolTip = csv ? "Type the fields to write as columns, separated by commas" : "Only CSV has columns"
        cells.isEnabled = csv
        cells.toolTip = csv ? "Choose how values that aren't text or numbers are written in CSV" : "Extended JSON writes every value in full"
        let noColumns = csv && chosenPaths.isEmpty
        exportButton.isEnabled = !noColumns
        exportButton.toolTip = noColumns ? "Type at least one field for CSV's columns" : "Choose a file and write the documents to it"
        if let sampleProblem {
            preview.stringValue = sampleProblem
        } else if let sample {
            let text = MongoExport.Encoder.text(chosenFormat, Array(sample.prefix(Self.previewDocuments)))
            // Long lines are cut here only: the preview is for the shape of the file.
            preview.stringValue = sample.isEmpty ? "No documents: the file will be empty"
                : text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.prefix(160) }.joined(separator: "\n")
        } else {
            preview.stringValue = "Reading the first documents…"
        }
    }

    @objc private func cancel(_ sender: Any?) { dismiss() }

    private func dismiss() {
        sampling?.cancel()
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
        retainUntilClosed = nil
    }

    @objc private func save(_ sender: Any?) {
        // The gate (plan §2.8): a file on this Mac is the person's to write.
        guard !AgentGuard.refuses("Export Documents writes a file on this Mac: only the person at the Mac can save one. Leave the "
                                  + "sheet for them.") else { return }
        guard let parent = window?.sheetParent else { return }
        let (format, find, ref, activity) = (chosenFormat, self.find, self.ref, self.activity)
        let whole = scope.indexOfSelectedItem == 0
        dismiss()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ref.collection + "." + format.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.message = "Export the documents of \(ref.collection)"
        panel.beginSheetModal(for: parent) { response in
            guard response == .OK, let url = panel.url else { return }
            Self.export(ref, find: find, whole: whole, format: format, to: url, activity: activity, parent: parent)
        }
    }

    static func export(_ ref: MongoCollectionRef, find: MongoFind, whole: Bool, format: MongoExport.Format, to url: URL,
                       activity: ActivityCenter, parent: NSWindow?) {
        let stop = StopFlag(), connection = ref.open.connection
        let work = activity.start("Exporting the documents of \(ref.collection)", connection: ref.open.saved.id) {
            stop.set()
            // A batch's read can be slow (a filter no index serves): ended on the server.
            Task { try? await connection.session(.data).cancel() }
        }
        Task.detached {
            do {
                let session = try await connection.session(.data)
                let total = whole ? try? await session.estimatedCount(database: ref.database, collection: ref.collection) : nil
                _ = try await MongoExport.write(session, database: ref.database, collection: ref.collection, find: find, format: format,
                                                to: url, stop: stop) { count in
                    Task { @MainActor in
                        work.detail = count.formatted() + (total.map { " of about \($0.formatted())" } ?? "") + " documents"
                        work.progress = total.map { $0 > 0 ? min(1, Double(count) / Double($0)) : 1 }
                    }
                }
                await MainActor.run { work.end() }
            } catch {
                await MainActor.run {
                    work.end()
                    guard !stop.isSet else { return }
                    showError((error as? BSONError)?.message ?? error.localizedDescription,
                              title: "The documents of \(ref.collection) weren't exported", on: parent)
                }
            }
        }
    }
}
