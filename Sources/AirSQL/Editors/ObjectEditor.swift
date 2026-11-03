import AirSQLCore
import AppKit

/// An object editor: a view, procedure, function, trigger or event as its CREATE statement, with who it runs as
/// (DEFINER). Apply shows the statements that replace it in the SQL preview sheet, then runs them on a tools session
/// under the object's own sql_mode (and an event's time zone).
@MainActor
final class ObjectEditorController: NSViewController, TabContent, NSMenuItemValidation, NSTextViewDelegate {
    let context: EditorContext
    let kind: ObjectKind
    let database: String
    /// The object's name on the server; nil until a new one is created.
    private(set) var name: String?
    private let table: String?
    let activity: ActivityCenter
    private(set) var definition: ObjectDefinition?
    var server = SchemaServer(version: "8.0.0")
    /// Who the person is on the server (user@host).
    var account: String?
    private(set) var isBusy = false

    let code = NSTextView()
    let definer = popup([], selected: 0, id: "objectEditor.definer", tip: "", target: nil, action: nil)
    let applyButton = button("Apply", id: "objectEditor.apply", tip: "", target: nil, action: #selector(AirSQLActions.applyChanges(_:)),
                             primary: true)
    let revertButton = button("Revert", id: "objectEditor.revert", tip: "", target: nil, action: #selector(AirSQLActions.revertChanges(_:)))
    let note = label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, truncates: true)
    let status = NSProgressIndicator()
    let overlay = EditorOverlay()

    init(context: EditorContext, kind: ObjectKind, database: String, name: String?, table: String?, activity: ActivityCenter) {
        self.context = context
        self.kind = kind
        self.database = database
        self.name = name
        self.table = table
        self.activity = activity
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func edits(_ connection: UUID, _ kind: ObjectKind, _ database: String, _ name: String) -> Bool {
        context.connection.id == connection && self.kind == kind && self.database == database && self.name == name
    }

    var tabTitle: String { name.map { $0 + " · " + kind.rawValue } ?? "New " + kind.rawValue }

    /// The code as the server has it (a new object: its template).
    var original: String { definition?.code ?? ObjectCode.template(kind, name: "new_" + kind.rawValue, table: table) }

    var isEdited: Bool { name == nil || code.string != original }

    override func loadView() {
        code.isRichText = false
        code.isAutomaticQuoteSubstitutionEnabled = false
        code.isAutomaticDashSubstitutionEnabled = false
        code.isAutomaticTextReplacementEnabled = false
        code.isAutomaticSpellingCorrectionEnabled = false
        code.isContinuousSpellCheckingEnabled = false
        code.allowsUndo = true
        code.usesFindBar = true
        code.isIncrementalSearchingEnabled = true
        code.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        code.textContainerInset = NSSize(width: Spacing.unit, height: Spacing.unit)
        code.isVerticallyResizable = true
        code.autoresizingMask = [.width]
        code.textContainer?.widthTracksTextView = true
        code.delegate = self
        code.setAccessibilityIdentifier("objectEditor.code")
        code.toolTip = "Edit the \(kind.rawValue)'s CREATE statement, then Apply"
        let scroll = NSScrollView()
        scroll.documentView = code
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let kindLabel = label(kind.keyword, font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
        let definerLabel = label("Runs as:", font: .systemFont(ofSize: 12))
        definer.target = self
        definer.action = #selector(definerChosen(_:))
        definer.controlSize = .small
        status.style = .spinning
        status.controlSize = .small
        status.isDisplayedWhenStopped = false
        applyButton.keyEquivalent = "s"
        applyButton.keyEquivalentModifierMask = .command
        applyButton.target = self
        revertButton.target = self
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [kindLabel, definerLabel, definer, spacer, status, revertButton, applyButton,
                                      helpButton(.editors)])
        bar.spacing = Spacing.unit
        bar.alignment = .centerY
        bar.setCustomSpacing(Spacing.double, after: kindLabel)
        bar.edgeInsets = NSEdgeInsets(top: Spacing.unit, left: Spacing.double, bottom: Spacing.unit, right: Spacing.double)
        let footer = NSStackView(views: [note])
        footer.edgeInsets = NSEdgeInsets(top: Spacing.half + 1, left: Spacing.double, bottom: Spacing.half + 1, right: Spacing.double)

        let root = editorLayout(bar: bar, content: scroll, footer: footer)
        root.addSubview(overlay)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: scroll.topAnchor), overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        root.setAccessibilityIdentifier("objectEditor")
        view = root
        load()
    }

    // MARK: Reading

    func load() {
        isBusy = true
        overlay.show(loading: name.map { "Reading \($0)…" } ?? "Getting ready…")
        updateControls()
        let work = activity.start(name.map { "Reading the code of \($0)" } ?? "Preparing a new \(kind.rawValue)",
                                  connection: context.connection.id) {}
        let context = self.context, kind = self.kind, database = self.database, name = self.name
        Task {
            defer { work.end() }
            do {
                if context.schema.snapshot.server == nil { try await context.schema.load() }
                guard let server = context.schema.snapshot.server else { throw DesignError("The server didn't say what it is") }
                self.server = server
                let (account, definition) = try await context.read { session -> (String?, ObjectDefinition?) in
                    let account = try await EditorQueries.currentAccount(from: session)
                    guard let name else { return (account, nil) }
                    return (account, try await ObjectDefinition.load(kind, database: database, name: name, from: session))
                }
                self.account = account
                self.definition = definition
                code.string = original
                colourCode()
                code.undoManager?.removeAllActions()
                isBusy = false
                overlay.hide()
                NotificationCenter.default.post(name: .tabContentDidChange, object: self)
            } catch {
                isBusy = false
                overlay.show(error: error.localizedDescription, retry: (self, #selector(retry(_:))))
            }
            updateControls()
        }
    }

    @objc private func retry(_ sender: Any?) { load() }

    func textDidChange(_ notification: Notification) {
        colourCode()
        updateControls()
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
    }

    /// Colours the code as the SQL preview does, in place (the caret and the undo stay).
    func colourCode() {
        guard let storage = code.textStorage else { return }
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let coloured = SQLPreviewSheet.coloured(code.string, font: font, noBackslashEscapes: server.noBackslashEscapes)
        storage.beginEditing()
        coloured.enumerateAttributes(in: NSRange(location: 0, length: coloured.length)) { attributes, range, _ in
            storage.setAttributes(attributes, range: range)
        }
        storage.endEditing()
    }

    /// The definer pop-up, Apply, Revert and the note, for the code as it is now.
    func updateControls() {
        let header = CreateHeader(code.string)
        let written = CreateHeader(original)?.definerAccount
        definer.removeAllItems()
        if let written { definer.addItem(withTitle: "Its definer, " + written) }
        definer.addItem(withTitle: "Me" + (account.map { ", " + $0 } ?? ""))
        definer.selectItem(at: header?.definer == nil || written == nil ? definer.numberOfItems - 1 : 0)
        definer.isEnabled = !isBusy && header != nil
        definer.toolTip = "Choose who the \(kind.rawValue) runs as (its DEFINER): as it was written, or you"
        let reason = applyReason
        applyButton.isEnabled = reason == nil
        applyButton.toolTip = reason ?? "Show the statements in the preview sheet, then run them on the server (⌘S)"
        revertButton.isEnabled = !isBusy && name != nil && code.string != original
        revertButton.toolTip = revertButton.isEnabled ? "Put back the code the server has" : "Nothing to revert"
        code.isEditable = !isBusy
        var notes: [String] = []
        if let mode = definition?.sqlMode { notes.append("sql_mode: " + (mode.isEmpty ? "none" : mode)) }
        if let zone = definition?.timeZone { notes.append("time zone: " + zone) }
        if ObjectCode.dropsFirst(kind, server: server), name != nil {
            notes.append("MySQL replaces a \(kind.rawValue) by dropping it first")
        }
        note.stringValue = notes.isEmpty ? "Apply runs the code as written" : notes.joined(separator: " · ")
        note.toolTip = note.stringValue
        if isBusy { status.startAnimation(nil) } else { status.stopAnimation(nil) }
    }

    /// The statements Apply would run, or why there are none.
    var statements: Result<[String], DesignError> {
        do {
            return .success(try ObjectCode.statements(code.string, kind: kind, database: database, original: name, definition: definition,
                                                      server: server))
        } catch {
            return .failure(error as? DesignError ?? DesignError(error.localizedDescription))
        }
    }

    var applyReason: String? {
        if isBusy { return "Wait until the server has answered" }
        if context.connection.readOnly {
            return "“\(context.connection.displayName)” is read-only: turn that off in its connection settings to change anything"
        }
        if name != nil, code.string == original { return "Nothing to apply yet" }
        if case .failure(let error) = statements { return "Fix this first: " + error.message }
        return nil
    }

    func isBusyNow(_ busy: Bool) {
        isBusy = busy
        updateControls()
    }

    /// The object as the server now has it, after Apply.
    func setLoaded(name: String, definition: ObjectDefinition?) {
        self.name = name
        if let definition { self.definition = definition }
        code.string = original
        colourCode()
        code.undoManager?.removeAllActions()
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
        guard let main = view.window?.windowController as? MainWindowController,
              let tab = main.tabs.first(where: { $0.content === self }) else { return }
        main.rename(tab, to: tabTitle)
    }

    @objc func definerChosen(_ sender: NSPopUpButton) {
        let written = CreateHeader(original)?.definerAccount
        let mine = sender.indexOfSelectedItem == sender.numberOfItems - 1
        let changed = ObjectCode.settingDefiner(code.string, to: mine ? nil : written.map(ObjectCode.quotedAccount))
        guard changed != code.string, code.shouldChangeText(in: NSRange(location: 0, length: code.string.utf16.count),
                                                            replacementString: changed) else { return }
        code.textStorage?.replaceCharacters(in: NSRange(location: 0, length: code.string.utf16.count), with: changed)
        code.didChangeText()
    }
}
