import AirSQLCore
import AppKit
import UniformTypeIdentifiers

/// What a grid can export (grid-spec §6): its selected and loaded rows, and for a table every row, streamed from the
/// server in batches as they are written (`all`), never held in memory.
struct ExportRowsRequest {
    var title: String
    var columns: [GridColumn]
    var database: String?
    var table: String
    var noBackslashEscapes = false
    /// The columns hidden in the grid, which aren't written.
    var hiddenColumns = 0
    var selectedCount: Int
    var selected: () -> [[String?]]
    var loadedCount: Int
    var loaded: () -> [[String?]]
    /// Sends every row to `write` in batches, off the main thread; nil when there is nothing more than the loaded rows.
    var all: ((@escaping ([[String?]]) throws -> Void) async throws -> Void)?
}

/// Export Rows…: which rows, the format (each copy format, and Excel), the options, then a file or the clipboard. The
/// rows are written off the main thread, with the activity's progress and Cancel.
@MainActor
final class ExportRowsSheet: NSWindowController {
    private let request: ExportRowsRequest
    private let activity: ActivityCenter
    private let scope: NSPopUpButton
    private let format: NSPopUpButton
    private let headers = checkbox("Column names first", id: "export.headers", tip: "Write the column names as the first line",
                                   on: true, target: nil, action: nil)
    private let nullText = popup(["NULL", "\\N", "Empty"], selected: 0, id: "export.null",
                                 tip: "Choose how NULL values are written in CSV, TSV, Markdown and HTML", target: nil, action: nil)
    private let crlf = checkbox("Windows line endings", id: "export.crlf", tip: "End lines with CR LF, as Windows apps expect",
                                on: false, target: nil, action: nil)
    private var copyButton: NSButton!
    private var retainUntilClosed: ExportRowsSheet?
    /// The formats in the pop-up: Excel last.
    private static let formats: [CopyFormat?] = [.csv, .tsv, .json, .jsonLines, .insert, .insertIgnore, .replace, .markdown, .html, .xml, nil]

    static func show(_ request: ExportRowsRequest, activity: ActivityCenter, on window: NSWindow) {
        let sheet = ExportRowsSheet(request, activity: activity)
        sheet.retainUntilClosed = sheet
        window.beginSheet(sheet.window!)
    }

    private init(_ request: ExportRowsRequest, activity: ActivityCenter) {
        self.request = request
        self.activity = activity
        var scopes = ["Selected rows (\(request.selectedCount.formatted()))", "Loaded rows (\(request.loadedCount.formatted()))"]
        if request.all != nil { scopes.append("All rows, from the server") }
        scope = popup(scopes, selected: request.selectedCount > 1 ? 0 : 1, id: "export.rows",
                      tip: "Export the selected rows, the rows loaded so far, or every row of the table", target: nil, action: nil)
        format = popup(Self.formats.map { $0?.title ?? "Excel (.xlsx)" }, selected: 0, id: "export.format",
                       tip: "Choose the file's format: CSV and Excel for spreadsheets, JSON, SQL statements, Markdown, HTML or XML",
                       target: nil, action: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.title = "Export Rows of \(request.title)"
        super.init(window: window)
        format.target = self
        format.action = #selector(formatChanged(_:))
        window.contentView = makeContent()
        window.setContentSize(window.contentView!.fittingSize)
        formatChanged(nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeContent() -> NSView {
        let heading = label("Export rows of \(request.title)", font: .systemFont(ofSize: 15, weight: .semibold))
        let form = Form()
        form.row("Rows", [scope])
        form.row("Format", [format])
        form.row("Options", [headers])
        form.row("NULL as", [nullText])
        form.row("", [crlf])
        if request.hiddenColumns > 0 {
            let count = request.hiddenColumns
            form.row("", [label("\(count) hidden column\(count == 1 ? " is" : "s are") left out: show them first to export them",
                               font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor)])
        }
        let cancel = button("Cancel", id: "export.cancel", tip: "Close without exporting", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        copyButton = button("Copy", id: "export.copy", tip: "Put the rows on the clipboard in this format", target: self,
                            action: #selector(copyRows(_:)))
        let save = button("Export…", id: "export.save", tip: "Choose a file and write the rows to it", target: self,
                          action: #selector(saveRows(_:)))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [helpButton(.tableData), NSView(), cancel, copyButton, save])
        buttons.spacing = Spacing.unit
        let stack = NSStackView(views: [heading, form.finish(), buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.double
        stack.edgeInsets = NSEdgeInsets(top: Spacing.triple, left: Spacing.triple, bottom: Spacing.double, right: Spacing.triple)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Spacing.triple).isActive = true
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        return stack
    }

    private var chosenFormat: CopyFormat? { Self.formats[max(0, format.indexOfSelectedItem)] }

    @objc private func formatChanged(_ sender: Any?) {
        let chosen = chosenFormat
        headers.isEnabled = chosen == nil || chosen?.hasOptionalHeaders == true
        copyButton.isEnabled = chosen != nil
        copyButton.toolTip = chosen == nil ? "Excel files can't go on the clipboard: export to a file instead"
            : "Put the rows on the clipboard in this format"
    }

    private var options: CopyOptions {
        var options = CopyOptions(headers: headers.state == .on, nullText: ["NULL", "\\N", ""][max(0, nullText.indexOfSelectedItem)])
        options.lineEnding = crlf.state == .on ? "\r\n" : "\n"
        options.noBackslashEscapes = request.noBackslashEscapes
        return options
    }

    @objc private func cancel(_ sender: Any?) { dismiss() }

    private func dismiss() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
        retainUntilClosed = nil
    }

    @objc private func copyRows(_ sender: Any?) {
        guard let format = chosenFormat else { return }
        let rows = scope.indexOfSelectedItem == 0 ? request.selected() : request.loaded()
        let text = CopyWriter.text(format, columns: request.columns, rows: rows, database: request.database, table: request.table,
                                   options: options)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        dismiss()
    }

    @objc private func saveRows(_ sender: Any?) {
        // The gate (plan §2.8): a file on this Mac is the person's to write.
        guard !AgentGuard.refuses("Export Rows writes a file on this Mac: only the person at the Mac can save one. Copy the rows "
                                  + "instead, or leave the sheet for them.") else { return }
        guard let parent = window?.sheetParent else { return }
        let format = chosenFormat, options = options, request = request, activity = activity
        let which = scope.indexOfSelectedItem
        dismiss()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = request.title + "." + (format?.fileExtension ?? "xlsx")
        panel.allowedContentTypes = [UTType(filenameExtension: format?.fileExtension ?? "xlsx") ?? .data]
        panel.message = "Export the rows of \(request.title)"
        panel.beginSheetModal(for: parent) { response in
            guard response == .OK, let url = panel.url else { return }
            // The rows at hand are taken now, on the main thread; every row streams from the server instead.
            let rows: [[String?]]? = which == 0 ? request.selected() : which == 1 ? request.loaded() : nil
            let stop = StopFlag()
            let work = activity.start("Exporting the rows of \(request.title)") { stop.set() }
            Task.detached {
                do {
                    let output = try ExportOutput(url: url, format: format, columns: request.columns, database: request.database,
                                                  table: request.table, options: options)
                    if let rows {
                        try output.write(rows)
                    } else if let all = request.all {
                        try await all { batch in
                            if stop.isSet { throw CancellationError() }
                            try output.write(batch)
                        }
                    }
                    try output.finish()
                    let cut = output.cutCells
                    await MainActor.run {
                        work.end()
                        guard cut > 0 else { return }
                        showError("\(cut.formatted()) \(cut == 1 ? "cell was" : "cells were") longer than the 32,767 characters a cell of Excel "
                                  + "holds, and the file has only the start of them. Export as CSV to keep every value whole.",
                                  title: "\(url.lastPathComponent) was saved with values cut", on: parent)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    await MainActor.run {
                        work.end()
                        guard !(error is CancellationError) else { return }
                        showError(error.localizedDescription,
                                  title: "The rows of \(request.title) weren't exported", on: parent)
                    }
                }
            }
        }
    }
}

/// A file being written in one format: text through a `CopyWriter`, or an Excel workbook.
final class ExportOutput: @unchecked Sendable {
    private var writer: CopyWriter?
    private let workbook: XLSXWriter?
    private let file: FileHandle?

    init(url: URL, format: CopyFormat?, columns: [GridColumn], database: String?, table: String, options: CopyOptions) throws {
        if let format {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteNoPermission) }
            file = try FileHandle(forWritingTo: url)
            writer = CopyWriter(format, columns: columns, database: database, table: table, options: options)
            workbook = nil
            try file?.write(contentsOf: Data((writer?.header() ?? "").utf8))
        } else {
            workbook = try XLSXWriter(url: url, columns: columns, headers: options.headers)
            file = nil
        }
    }

    /// The cells Excel's limit cut.
    var cutCells: Int { workbook?.cutCells ?? 0 }

    func write(_ rows: [[String?]]) throws {
        if let workbook {
            for row in rows { try workbook.add(row) }
            return
        }
        var text = ""
        for row in rows { text += writer?.row(row) ?? "" }
        try file?.write(contentsOf: Data(text.utf8))
    }

    func finish() throws {
        if let workbook { return try workbook.finish() }
        try file?.write(contentsOf: Data((writer?.footer() ?? "").utf8))
        try file?.close()
    }
}
