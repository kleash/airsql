import AirSQLCore
import AppKit
import UniformTypeIdentifiers

/// Save as Changeset (plan §2.9; scope: save any change as a changeset): changesets added at the end of the changelog
/// the person chooses, shown first exactly as they will be written. A new file starts with the --liquibase formatted
/// sql line; an existing one must be a changelog Liquibase reads, and the new ids carry on its numbering. Files are
/// read and written off the main thread.
@MainActor
final class ChangesetSheet: NSWindowController {
    private let model: AppModel
    private let changesets: [LiquibaseChangeset]
    private let file = label("", font: .systemFont(ofSize: 12.5), truncates: true)
    private let status = label("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor, wraps: true)
    private let code = NSTextView.scrollableTextView()
    private let saveButton: NSButton
    private var url: URL?
    /// The chosen file is a new changelog (or replaces one): written from the header on.
    private var startsNew = false
    private var text = ""
    private var retained: ChangesetSheet?

    /// Shows the sheet on `window` for `changesets` (ids are given here, from the changelog chosen).
    static func show(_ changesets: [LiquibaseChangeset], heading: String, model: AppModel, on window: NSWindow) {
        guard !changesets.isEmpty else {
            return showError("There is nothing to save: the change has no statements Liquibase would run (USE and the "
                             + "transaction around them are Liquibase's own).", title: "No changeset to save", on: window)
        }
        let sheet = ChangesetSheet(changesets, heading: heading, model: model)
        sheet.retained = sheet
        window.beginSheet(sheet.window!)
        let saved = model.data.settings.liquibase.changelog
        if !saved.isEmpty { sheet.use(URL(fileURLWithPath: saved), new: false) }
    }

    private init(_ changesets: [LiquibaseChangeset], heading: String, model: AppModel) {
        self.model = model
        self.changesets = changesets
        saveButton = button("Save", id: "changeset.save", tip: "Choose a changelog first", target: nil, action: nil, primary: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.title = heading
        super.init(window: window)
        window.contentView = makeContent(heading)
        window.setContentSize(window.contentView!.fittingSize)
        window.initialFirstResponder = saveButton
        window.autorecalculatesKeyViewLoop = true
        file.stringValue = "None chosen yet"
        file.textColor = .secondaryLabelColor
        prepare(nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeContent(_ heading: String) -> NSView {
        let title = label(heading, font: .systemFont(ofSize: 14, weight: .semibold), wraps: true)
        title.setAccessibilityIdentifier("changeset.heading")
        let explain = label(changesets.count == 1 ? "It goes at the end of the changelog you choose, as Liquibase will read it:"
                            : "They go at the end of the changelog you choose, in this order, as Liquibase will read them:",
                            font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, wraps: true)
        file.setAccessibilityIdentifier("changeset.file")
        file.lineBreakMode = .byTruncatingMiddle  // a path: its file name stays in sight
        let choose = button("Choose…", id: "changeset.choose", tip: "Choose the changelog file to add to", target: self,
                            action: #selector(chooseFile(_:)))
        let new = button("New…", id: "changeset.new", tip: "Start a new changelog file", target: self, action: #selector(newFile(_:)))
        let fileLabel = label("Changelog:")
        let fileRow = NSStackView(views: [fileLabel, file, choose, new])
        fileRow.alignment = .firstBaseline
        fileRow.spacing = Spacing.unit
        file.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        status.setAccessibilityIdentifier("changeset.status")
        status.isSelectable = true
        let views: [NSView] = [title, explain, fileRow, codeBox(), status, buttons()]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: title)
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let root = SurfaceView(.ground)
        root.addSubview(stack)
        stack.pin(to: root, insets: NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20))
        root.widthAnchor.constraint(equalToConstant: 720).isActive = true
        return root
    }

    private func codeBox() -> NSView {
        code.translatesAutoresizingMaskIntoConstraints = false
        code.borderType = .noBorder
        code.drawsBackground = false
        let view = code.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.setAccessibilityIdentifier("changeset.sql")
        view.toolTip = "The changesets as they will be written in the changelog"
        let box = SurfaceView(.content, radius: Radius.control, border: .separatorColor)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(code)
        code.pin(to: box, insets: .all(Radius.control))
        box.heightAnchor.constraint(equalToConstant: 260).isActive = true
        return box
    }

    private func buttons() -> NSView {
        let copy = button("Copy", id: "changeset.copy", tip: "Copy the changesets, to paste them into a changelog yourself", target: self,
                          action: #selector(copyText(_:)))
        let cancel = button("Cancel", id: "changeset.cancel", tip: "Close without saving: the change itself has run already",
                            target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.keyEquivalent = "\r"
        saveButton.isEnabled = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [helpButton(.liquibase), copy, spacer, cancel, saveButton])
        row.spacing = Spacing.unit
        return row
    }

    // MARK: The changelog

    /// Adds to `chosen` (an existing changelog), or starts it anew (`new`): reads it off the main thread first, for the
    /// ids its changesets have.
    func use(_ chosen: URL, new: Bool) {
        url = chosen
        startsNew = new
        file.stringValue = SettingsPaneController.shown(chosen)
        file.textColor = .labelColor
        file.toolTip = file.stringValue
        saveButton.isEnabled = false
        status.textColor = .secondaryLabelColor
        status.stringValue = "Reading \(chosen.lastPathComponent)…"
        show("")
        Task {
            let read = await Task.detached { () -> Result<LiquibaseChangelog?, Error> in
                guard !new, FileManager.default.fileExists(atPath: chosen.path) else { return .success(nil) }
                return Result { try LiquibaseChangelog(String(contentsOf: chosen, encoding: .utf8)) }
            }.value
            guard url == chosen else { return }
            switch read {
            case .success(let changelog): prepare(changelog)
            case .failure(let error):
                fail("\(chosen.lastPathComponent) isn't a changelog Liquibase reads (\(error.localizedDescription)). Choose "
                     + "another, or New… to start one.")
            }
        }
    }

    /// The changesets numbered after `changelog`'s, checked as Liquibase reads them (off the main thread: a compare's
    /// rows can make many).
    private func prepare(_ changelog: LiquibaseChangelog?) {
        let settings = model.data.settings.liquibase, changesets = self.changesets, chosen = url
        Task {
            let made = await Task.detached { () -> Result<[String], Error> in
                let numbered = Liquibase.numbered(changesets, settings: settings, first: (changelog?.changesets.count ?? 0) + 1,
                                                  taken: Set(changelog?.changesets.map(\.id) ?? []))
                return Result { try numbered.map { try $0.checkedText(settings.delimiter) } }
            }.value
            guard url == chosen else { return }
            switch made {
            case .success(let texts): ready(texts, changelog)
            case .failure(let error): fail(error.localizedDescription)
            }
        }
    }

    /// Shows the changesets (the first 200,000 characters' worth: all of them are saved) and what Save will do.
    private func ready(_ texts: [String], _ changelog: LiquibaseChangelog?) {
        text = texts.joined(separator: "\n")
        var shown = "", count = 0
        for piece in texts where shown.utf16.count < 200_000 {
            shown += (count == 0 ? "" : "\n") + piece
            count += 1
        }
        show(count < texts.count ? shown + "\n-- … and \(texts.count - count) more changesets, saved with these\n" : shown)
        status.textColor = .secondaryLabelColor
        guard url != nil else {
            status.stringValue = "Choose the changelog to add to, or New… to start one: the ids then carry on its numbering."
            return
        }
        status.stringValue = changelog.map { "Added after its \(ObjectPicker.count($0.changesets.count, "changeset"))." }
            ?? "A new changelog, starting with the line \(LiquibaseChangelog.header)."
        saveButton.isEnabled = true
        saveButton.toolTip = "Add " + (texts.count == 1 ? "the changeset" : "the \(texts.count) changesets") + " to "
            + (url?.lastPathComponent ?? "the changelog")
    }

    private func show(_ sql: String) {
        let view = code.documentView as! NSTextView
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        view.textStorage?.setAttributedString(SQLPreviewSheet.coloured(sql, font: font, noBackslashEscapes: false))
    }

    private func fail(_ message: String) {
        status.textColor = .statusBad
        status.stringValue = message
        saveButton.isEnabled = false
        saveButton.toolTip = "Choose a changelog Liquibase reads first"
    }

    @objc private func chooseFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.message = "Choose the formatted SQL changelog to add the changesets to."
        if let url { panel.directoryURL = url.deletingLastPathComponent() }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let chosen = panel.url else { return }
            self?.use(chosen, new: false)
        }
    }

    @objc private func newFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = "changelog.sql"
        panel.message = "Name the new changelog. Liquibase reads it as formatted SQL."
        if let url { panel.directoryURL = url.deletingLastPathComponent() }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let chosen = panel.url else { return }
            self?.use(chosen, new: true)
        }
    }

    @objc private func copyText(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((code.documentView as? NSTextView)?.string ?? "", forType: .string)
    }

    @objc private func cancel(_ sender: Any?) { close() }

    @objc private func save(_ sender: Any?) {
        guard saveButton.isEnabled, let url, let window else { return }
        // The gate (plan §2.8): files on this Mac are the person's.
        guard !AgentGuard.refuses("A changelog is a file on this Mac: only the person at the Mac can save to one. Leave the "
                                  + "sheet for them.") else { return }
        let text = self.text, new = startsNew
        saveButton.isEnabled = false
        Task {
            let written = await Task.detached { () -> Error? in
                do {
                    try Self.append(text, to: url, new: new)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let written {
                saveButton.isEnabled = true
                return showError(written.localizedDescription, title: "The changeset wasn't saved", on: window)
            }
            model.data.settings.liquibase.changelog = url.path
            close()
        }
    }

    /// Adds `text` at the end of the changelog at `url`, or writes a new one from its header (`new`, or no file there).
    /// A changelog that can't be opened for writing (read-only) throws: it is never written over.
    nonisolated static func append(_ text: String, to url: URL, new: Bool) throws {
        guard !new, FileManager.default.fileExists(atPath: url.path) else {
            return try (LiquibaseChangelog.header + "\n\n" + text).write(to: url, atomically: true, encoding: .utf8)
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var ending = ""
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            ending = try handle.readToEnd().map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        try handle.write(contentsOf: Data(((ending == "\n" ? "" : "\n") + "\n" + text).utf8))
    }

    override func close() {
        if let sheet = window, let parent = sheet.sheetParent { parent.endSheet(sheet) }
        retained = nil
    }
}
