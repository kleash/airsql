import AirSQLCore
import AppKit

/// What the SQL preview sheet shows (plan §2.4): the one sheet that shows SQL before it runs, for grid Apply, the table
/// editor, drop and rename, restore and recon sync.
struct SQLPreviewRequest {
    var change: ChangeSQL
    /// "Apply 4 changes to shop.orders?"
    var heading: String
    /// What happens when it runs ("They run in one transaction…").
    var caption: String
    var actionTitle = "Apply"
    /// Drops, truncates, deletes: the button says so in red.
    var destructive = false
    /// Cascade and engine warnings ("orders uses MyISAM: a failed Apply can't be rolled back").
    var warnings: [String] = []
    /// A name the person must type before it runs (dropping a database; a table on Production).
    var typeToConfirm: String?
    /// The agent that asked for it (the agents' gate): it waits for the person's approval here, and agents can't press
    /// its Run. Shown from an agent's request (`AgentGate.agent`), it is that agent's.
    var agent: String?
    /// Text to show instead of the statements (what an agent would type into a production console).
    var text: String?
    /// The caller's own options under the SQL ("Read new rows back").
    var accessory: NSView?
    /// Shows "Save as Liquibase changeset": the caller saves the change once it has run, when the box is ticked.
    var offersChangeset = false
    /// The session's NO_BACKSLASH_ESCAPES (`DBConnection.noBackslashEscapes`), as `SQLQuote.string` wrote the SQL: it
    /// decides where the strings end, so the colours match what the server will read.
    var noBackslashEscapes = false

    init(change: ChangeSQL, heading: String, caption: String) {
        self.change = change
        self.heading = heading
        self.caption = caption
    }
}

/// What the person chose: run it or not, and whether to save it as a Liquibase changeset once it has run.
struct SQLPreviewResult {
    var approved: Bool
    var saveAsChangeset: Bool
}

/// The SQL preview sheet. "Save as Liquibase changeset" shows for the callers that offer it (`offersChangeset`): they
/// run the SQL and, when it succeeded and the box was ticked, pass the change to the writer.
@MainActor
final class SQLPreviewSheet: NSWindowController, NSTextFieldDelegate {
    /// Saves a change as a Liquibase changeset (L8b sets it), with the session's NO_BACKSLASH_ESCAPES its strings were
    /// written for.
    static var changesetWriter: ((_ change: ChangeSQL, _ noBackslashEscapes: Bool) -> Void)?

    private let request: SQLPreviewRequest
    private let completion: (SQLPreviewResult) -> Void
    private let runButton: NSButton
    private let confirmField = NSTextField()
    private var saveBox: NSButton?

    /// Shows the sheet on `window` for a change on `connection`.
    @discardableResult
    static func show(_ request: SQLPreviewRequest, connection: SavedConnection?, on window: NSWindow,
                     completion: @escaping (SQLPreviewResult) -> Void) -> SQLPreviewSheet {
        var request = request
        request.agent = request.agent ?? AgentGate.agent
        let sheet = SQLPreviewSheet(request, connection: connection, completion: completion)
        window.beginSheet(sheet.window!)
        sheet.retainUntilClosed = sheet
        return sheet
    }

    /// Held while the sheet is shown (nothing else keeps its controller).
    private var retainUntilClosed: SQLPreviewSheet?

    private init(_ request: SQLPreviewRequest, connection: SavedConnection?, completion: @escaping (SQLPreviewResult) -> Void) {
        self.request = request
        self.completion = completion
        runButton = button(request.actionTitle, id: "preview.run", tip: "", target: nil, action: nil, primary: !request.destructive)
        if request.destructive { runButton.contentTintColor = .statusBad }  // the mockups' danger button
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 400), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.title = request.heading
        super.init(window: window)
        window.contentView = makeContent(connection)
        window.setContentSize(window.contentView!.fittingSize)
        window.initialFirstResponder = request.typeToConfirm == nil ? runButton : confirmField
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeContent(_ connection: SavedConnection?) -> NSView {
        let heading = label(request.heading, font: .systemFont(ofSize: 14, weight: .semibold), wraps: true)
        heading.setAccessibilityIdentifier("preview.heading")
        let caption = label(request.caption, font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, wraps: true)
        var views: [NSView] = [heading, caption]
        if let agent = request.agent {
            views.append(banner("Asked by \(agent). Nothing runs until you approve it here; agents can't approve their own "
                                + "changes.", symbol: "sparkles", color: .accent, id: "preview.agent"))
        }
        if let connection, connection.colour == .production {
            let words = request.text == nil ? "This runs on \(connection.displayName), a production connection."
                : "\(connection.displayName) is a production connection."
            views.append(banner(words, symbol: "exclamationmark.octagon.fill",
                                color: ConnectionColour.production.color!, id: "preview.production"))
        }
        for warning in request.warnings {
            views.append(banner(warning, symbol: "exclamationmark.triangle.fill", color: .statusWarning, id: "preview.warning"))
        }
        views.append(codeBox())
        if let name = request.typeToConfirm {
            let prompt = label("Type “\(name)” to confirm:", font: .systemFont(ofSize: 12.5))
            confirmField.placeholderString = name
            confirmField.toolTip = "Type the name exactly, to show this is the one you mean"
            confirmField.setAccessibilityIdentifier("preview.confirm")
            confirmField.delegate = self
            confirmField.translatesAutoresizingMaskIntoConstraints = false
            confirmField.widthAnchor.constraint(equalToConstant: 260).isActive = true
            let row = NSStackView(views: [prompt, confirmField])
            row.spacing = Spacing.unit
            row.alignment = .firstBaseline
            views.append(row)
        }
        var options: [NSView] = []
        if request.offersChangeset {
            let box = checkbox("Save as Liquibase changeset", id: "preview.saveChangeset",
                               tip: "Save these statements as a changeset in your changelog once they have run", on: false,
                               target: nil, action: nil)
            saveBox = box
            options.append(box)
        }
        if let accessory = request.accessory { options.append(accessory) }
        if !options.isEmpty {
            let row = NSStackView(views: options)
            row.spacing = Spacing.double + 2
            views.append(row)
        }
        views.append(buttons())
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: heading)
        for view in views {
            // Texts, banners, the SQL and the buttons span the sheet; the option rows hug their content.
            let spans = view is NSTextField || view is SurfaceView || view === views.last
            (spans ? view.widthAnchor.constraint(equalTo: stack.widthAnchor)
                : view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)).isActive = true
        }
        let root = SurfaceView(.ground)
        root.addSubview(stack)
        stack.pin(to: root, insets: NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20))
        root.widthAnchor.constraint(equalToConstant: 720).isActive = true
        return root
    }

    /// The SQL, in a box that scrolls past 16 lines (the sheet fits a 13-inch display).
    private func codeBox() -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        text.textStorage?.setAttributedString(Self.coloured(request.text ?? request.change.text, font: font,
                                                            noBackslashEscapes: request.noBackslashEscapes))
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.setAccessibilityIdentifier("preview.sql")
        text.toolTip = "The statements that will run, in this order"
        // As tall as the statements laid out at the sheet's width (long ones wrap), from 3 to 16 lines.
        let width = 720 - 2 * 20 - 2 * Radius.control
        text.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        text.textContainer?.containerSize = NSSize(width: width - 2 * text.textContainerInset.width, height: .greatestFiniteMagnitude)
        let line = text.layoutManager?.defaultLineHeight(for: font) ?? 15
        var used = line * 3
        if let layout = text.layoutManager, let container = text.textContainer {
            layout.ensureLayout(for: container)
            used = layout.usedRect(for: container).height
        }
        let height = min(max(used, line * 3), line * 16) + 2 * text.textContainerInset.height
        let box = SurfaceView(.content, radius: Radius.control, border: .separatorColor)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        scroll.pin(to: box, insets: .all(Radius.control))
        box.heightAnchor.constraint(equalToConstant: ceil(height) + 2 * Radius.control).isActive = true
        return box
    }

    /// `sql` coloured as the mockups colour SQL: reserved words in semibold, calls, names, strings, numbers, and comments
    /// in italic. Words that aren't reserved count as names, since only reserved words can't be one.
    nonisolated static func coloured(_ sql: String, font: NSFont, noBackslashEscapes: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(string: sql, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let tokens = SQLLexer.tokens(sql, noBackslashEscapes: noBackslashEscapes)
        colour(result, tokens: tokens, tokens.indices, text: Array(sql.utf16), font: font)
        return result
    }

    /// Colours `tokens[indices]` of `text` in `string` as `coloured` does: the console's editor colours what changed.
    nonisolated static func colour(_ string: NSMutableAttributedString, tokens: [SQLToken], _ indices: Range<Int>, text: [UInt16],
                                   font: NSFont) {
        let semibold = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
        let italic = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) ?? font
        for k in indices {
            let token = tokens[k]
            var color = NSColor.sqlIdentifier, style: NSFont?
            switch token.kind {
            case .comment, .hint, .codeStart, .codeEnd: (color, style) = (.sqlComment, italic)
            case .string: color = .sqlString
            case .number: color = .sqlNumber
            case .quotedName: break
            case .variable, .symbol: continue
            case .word:
                let next = k + 1 < tokens.count ? tokens[k + 1] : nil
                if SQLWords.reserved.contains(String(decoding: text[token.range], as: UTF16.self).uppercased()) {
                    (color, style) = (.sqlKeyword, semibold)
                } else if let next, next.kind == .symbol, text[next.range.lowerBound] == 0x28 {  // a call: name(
                    color = .sqlFunction
                }
            }
            string.addAttribute(.foregroundColor, value: color, range: NSRange(token.range))
            if let style { string.addAttribute(.font, value: style, range: NSRange(token.range)) }
        }
    }

    private func banner(_ text: String, symbol: String, color: NSColor, id: String) -> NSView {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = color
        image.setContentHuggingPriority(.required, for: .horizontal)
        let words = label(text, font: .systemFont(ofSize: 12), wraps: true)
        let row = NSStackView(views: [image, words])
        row.alignment = .firstBaseline
        row.spacing = Spacing.unit
        let box = SurfaceView(color.withAlphaComponent(0.12), radius: Radius.control)
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.group)
        box.setAccessibilityLabel(text)
        box.setAccessibilityIdentifier(id)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        row.pin(to: box, insets: NSEdgeInsets(top: Spacing.unit, left: 10, bottom: Spacing.unit, right: 10))
        return box
    }

    private func buttons() -> NSView {
        let help = helpButton(.sqlPreview)
        let copy = button("Copy SQL", id: "preview.copy", tip: "Copy the statements, to keep them or run them elsewhere",
                          target: self, action: #selector(copySQL(_:)))
        let cancel = button(request.agent == nil ? "Cancel" : "Decline", id: "preview.cancel",
                            tip: request.agent == nil ? "Don't run it: nothing changes" : "Refuse the agent's change: nothing runs",
                            target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        runButton.target = self
        runButton.action = #selector(run(_:))
        runButton.keyEquivalent = "\r"
        runButton.hasDestructiveAction = request.destructive
        runButton.toolTip = request.typeToConfirm.map { "Type “\($0)” first" }
            ?? (request.text != nil ? "Put the text in the console's editor: nothing runs"
                : "Run these statements now" + (request.change.statements.count > 1 ? ", in this order" : ""))
        runButton.isEnabled = request.typeToConfirm == nil
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [help, copy, spacer, cancel, runButton])
        row.spacing = Spacing.unit
        return row
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let name = request.typeToConfirm else { return }
        runButton.isEnabled = confirmField.stringValue == name
        runButton.toolTip = runButton.isEnabled ? "Run these statements now" : "Type “\(name)” first"
    }

    @objc private func copySQL(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(request.change.text, forType: .string)
    }

    @objc private func cancel(_ sender: Any?) { finish(SQLPreviewResult(approved: false, saveAsChangeset: false)) }

    @objc private func run(_ sender: Any?) {
        guard runButton.isEnabled else { return }
        // The gate (plan §2.8): what this sheet shows runs only when the person at the Mac says so.
        guard !AgentGuard.refuses("Only the person at the Mac can approve what this sheet shows: ask them to check it and "
                                  + "press \(runButton.title). Nothing has run.") else { return }
        finish(SQLPreviewResult(approved: true, saveAsChangeset: saveBox?.state == .on))
    }

    private func finish(_ result: SQLPreviewResult) {
        if let sheet = window, let parent = sheet.sheetParent { parent.endSheet(sheet) }
        completion(result)
        retainUntilClosed = nil
    }
}
