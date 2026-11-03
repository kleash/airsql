import AirSQLCore
import AppKit

/// The value panel (⇧↩, grid-spec §3): the focused cell's whole value beside the grid, never shortened, as wrapped
/// text, a JSON tree, hex or an image, with its size under it. It follows the cursor; it picks the view that fits the
/// value, and the one chosen stays while it fits. Where the host lets the cell be edited (`keep`), its text is the
/// long-value editor (grid-spec §5): ⌘↩ or leaving it keeps the value as a pending edit, Esc puts it back; JSON can be
/// formatted or compacted, and a file loaded into the cell. Save to File… writes any value out.
@MainActor
final class GridValuePanel: NSView, NSTextViewDelegate {
    enum Mode: Int, CaseIterable {
        case text, json, hex, image

        var title: String { ["Text", "JSON", "Hex", "Image"][rawValue] }
    }

    private let title = label("Value", font: .systemFont(ofSize: 12, weight: .semibold), truncates: true)
    let modes = NSSegmentedControl(labels: Mode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let text = NSTextView()
    private let textScroll = NSScrollView()
    private let outlineScroll = JSONTreeView()
    var outline: NSOutlineView { outlineScroll.outline }
    private let image = NSImageView()
    let footer = label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor, truncates: true)
    private let wrap = checkbox("Wrap", id: "valuePanel.wrap", tip: "Wrap long lines to the panel's width", on: true, target: nil,
                                action: nil)
    let actions = NSPopUpButton(frame: .zero, pullsDown: true)
    private(set) var mode = Mode.text
    /// The mode the person picked, kept while the values fit it.
    private var picked: Mode?
    private var tree: JSONNode?
    private var bytes: [UInt8]?
    private var value: String?
    /// What the server puts in the cell at Apply ("auto", "default", "ƒ NOW()"), shown instead of NULL.
    private var placeholder: String?
    private var column: GridColumn?
    /// Keeps the text as the cell's pending value, or says why it can't (nil: the cell can't be edited here).
    var keep: ((String) -> String?)? { didSet { text.isEditable = keep != nil && mode == .text } }
    /// The text was changed and not kept yet.
    private(set) var edited = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("valuePanel")
        modes.target = self
        modes.action = #selector(pick(_:))
        modes.segmentStyle = .rounded
        modes.controlSize = .small
        modes.toolTip = "Show the value as text, a JSON tree, hex or an image"
        modes.setAccessibilityIdentifier("valuePanel.mode")
        wrap.target = self
        wrap.action = #selector(toggleWrap(_:))
        wrap.controlSize = .small
        text.isEditable = false
        text.delegate = self
        text.allowsUndo = true
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.setAccessibilityIdentifier("valuePanel.text")
        textScroll.documentView = text
        textScroll.hasVerticalScroller = true
        outline.setAccessibilityIdentifier("valuePanel.tree")
        image.imageScaling = .scaleProportionallyDown
        // The picture fits the panel; it never sizes the panel (or the grid beside it).
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            image.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: orientation)
            image.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: orientation)
        }
        image.setAccessibilityIdentifier("valuePanel.image")
        let top = NSStackView()
        top.setViews([title], in: .leading)
        top.setViews([modes], in: .trailing)
        top.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        actions.addItem(withTitle: "")
        actions.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Value actions")
        for (title, action) in [("Keep Value", #selector(keepValue(_:))), ("Put Back", #selector(putBack(_:))),
                                ("Format JSON", #selector(formatJSON(_:))), ("Compact JSON", #selector(compactJSON(_:))),
                                ("Load from File…", #selector(loadFile(_:))), ("Save to File…", #selector(saveFile(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.toolTip = Self.tips[action]
            actions.menu?.addItem(item)
        }
        (actions.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        actions.isBordered = false
        actions.controlSize = .small
        actions.toolTip = "Keep, put back, format, compact, load or save the value"
        actions.setAccessibilityIdentifier("valuePanel.actions")
        let bottom = NSStackView()
        bottom.setViews([footer], in: .leading)
        bottom.setViews([wrap, actions], in: .trailing)
        bottom.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 6, right: 8)
        for bar in [top, bottom] { bar.setHuggingPriority(.defaultHigh, for: .vertical) }
        for view in [top, textScroll, outlineScroll, image, bottom] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for body in [textScroll, outlineScroll, image] as [NSView] {
            NSLayoutConstraint.activate([
                body.topAnchor.constraint(equalTo: top.bottomAnchor), body.bottomAnchor.constraint(equalTo: bottom.topAnchor),
                body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor), top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor), bottom.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        show(column: nil, value: nil, bytes: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows a cell: `value` nil for NULL (or no cell when `column` is nil); `bytes` as the server sent them;
    /// `placeholder` what the server will put there at Apply.
    func show(column: GridColumn?, value: String?, bytes: [UInt8]?, placeholder: String? = nil) {
        edited = false
        self.column = column
        self.value = value
        self.placeholder = placeholder
        self.bytes = bytes ?? value.map { Array($0.utf8) }
        title.stringValue = column.map { "Value · \($0.name)" } ?? "Value"
        title.toolTip = title.stringValue
        let first = value?.first(where: { !$0.isWhitespace })
        tree = first == "{" || first == "[" ? value.flatMap(JSONNode.parse) : nil
        let picture = column?.kind == .binary ? self.bytes.flatMap { NSImage(data: Data($0)) } : nil
        image.image = picture
        let fits: [Mode: Bool] = [.text: value != nil, .json: tree != nil, .hex: value != nil, .image: picture != nil]
        for item in Mode.allCases { modes.setEnabled(fits[item] == true, forSegment: item.rawValue) }
        if let picked, fits[picked] == true { mode = picked } else { mode = picture != nil ? .image : tree != nil ? .json : .text }
        modes.selectedSegment = value == nil ? -1 : mode.rawValue
        footer.stringValue = column == nil ? "Select a cell to see its whole value here" : summary
        footer.toolTip = footer.stringValue
        footer.textColor = .secondaryLabelColor
        refresh()
    }

    /// The footer's words for the cell shown.
    private var summary: String {
        if let placeholder { return placeholder + " · the server sets it when you apply" }
        return value == nil ? "NULL" : describe()
    }

    private func describe() -> String {
        let count = bytes?.count ?? 0
        let size = "\(count.formatted()) byte\(count == 1 ? "" : "s")"
        switch mode {
        case .json: return "Valid JSON · " + size
        case .image: return image.image.map { "\(Int($0.size.width)) × \(Int($0.size.height)) image · " + size } ?? size
        default:
            let characters = value?.count ?? 0
            return "\(characters.formatted()) character\(characters == 1 ? "" : "s") · " + size
        }
    }

    private func refresh() {
        text.isEditable = keep != nil && mode == .text
        textScroll.isHidden = !(mode == .text || mode == .hex) || value == nil && keep == nil
        outlineScroll.isHidden = mode != .json || tree == nil
        image.isHidden = mode != .image
        wrap.isHidden = mode != .text
        switch mode {
        case .text: text.string = value ?? ""
        case .hex: text.string = Self.hexDump(bytes ?? [])
        case .json: outlineScroll.tree = tree
        case .image: break
        }
        setWrap(mode == .text && wrap.state == .on)
    }

    /// Offsets, 16 bytes in hex and as ASCII per line; the first 64 KB.
    static func hexDump(_ bytes: [UInt8]) -> String {
        var lines: [String] = []
        for start in stride(from: 0, to: min(bytes.count, 65_536), by: 16) {
            let chunk = bytes[start..<min(start + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(chunk.map { (0x20..<0x7F).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08X  ", start) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii)
        }
        if bytes.count > 65_536 { lines.append("… \((bytes.count - 65_536).formatted()) more bytes") }
        return lines.joined(separator: "\n")
    }

    private func setWrap(_ on: Bool) {
        text.isHorizontallyResizable = !on
        textScroll.hasHorizontalScroller = !on
        text.textContainer?.widthTracksTextView = on
        text.textContainer?.containerSize = NSSize(width: on ? textScroll.contentSize.width : .greatestFiniteMagnitude,
                                                   height: .greatestFiniteMagnitude)
        text.autoresizingMask = on ? .width : []
        if on { text.frame.size.width = textScroll.contentSize.width }
    }

    @objc private func pick(_ sender: NSSegmentedControl) {
        guard let chosen = Mode(rawValue: sender.selectedSegment) else { return }
        picked = chosen
        mode = chosen
        footer.stringValue = summary
        refresh()
    }

    @objc private func toggleWrap(_ sender: Any?) { setWrap(wrap.state == .on) }

    // MARK: Editing

    static let tips: [Selector: String] = [
        #selector(keepValue(_:)): "Keep the text as the cell's pending value (⌘↩)",
        #selector(putBack(_:)): "Throw the text away and show the cell's value again (Esc)",
        #selector(formatJSON(_:)): "Lay the JSON out on several lines, indented",
        #selector(compactJSON(_:)): "Put the JSON on one line without spaces",
        #selector(loadFile(_:)): "Put a file's contents in the cell (a pending edit)",
        #selector(saveFile(_:)): "Save the value as a file",
    ]

    /// Edits the value as text (a long value's double click): the text gets the keyboard.
    func beginEditing() {
        guard keep != nil else { return NSSound.beep() }
        showAsText()
        window?.makeFirstResponder(text)
    }

    /// The value as text, the view edits happen in.
    private func showAsText() {
        picked = .text
        if mode != .text {
            mode = .text
            modes.selectedSegment = mode.rawValue
            refresh()
        }
        textScroll.isHidden = false
    }

    func textDidChange(_ notification: Notification) {
        edited = true
        say("Not kept yet: ⌘↩ keeps it, Esc puts the value back", problem: false)
    }

    /// Leaving the text keeps it; a value the column refuses keeps the keyboard here, saying why.
    func textShouldEndEditing(_ textObject: NSText) -> Bool { commit() }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            commit()
            return true
        }
        guard selector == #selector(cancelOperation(_:)), edited else { return false }
        putBack(nil)
        return true
    }

    /// Keeps the text through `keep`; false, saying why, when the column refuses it.
    @discardableResult
    private func commit() -> Bool {
        guard edited, let keep else { return true }
        edited = false
        guard let refusal = keep(text.string) else { return true }
        edited = true
        say(refusal + ". Fix the value, or press Esc to put the cell's value back.", problem: true)
        return false
    }

    private func say(_ message: String, problem: Bool) {
        if problem { NSSound.beep() }
        footer.textColor = problem ? .systemRed : .secondaryLabelColor
        footer.stringValue = message
        footer.toolTip = message
    }

    @objc func keepValue(_ sender: Any?) { commit() }

    @objc func putBack(_ sender: Any?) {
        edited = false
        show(column: column, value: value, bytes: bytes)
    }

    @objc func formatJSON(_ sender: Any?) { reshapeJSON(JSONText.pretty) }
    @objc func compactJSON(_ sender: Any?) { reshapeJSON(JSONText.compact) }

    /// The JSON laid out again: while its text is being edited, as one more edit (undo takes it back); otherwise kept as
    /// the cell's pending value at once. Says why when it isn't JSON.
    private func reshapeJSON(_ reshape: (String) throws -> String) {
        guard let keep else { return NSSound.beep() }
        let editing = window?.firstResponder === text
        showAsText()
        do {
            let shaped = try reshape(text.string)
            guard editing else {
                if let refusal = keep(shaped) { say(refusal, problem: true) }
                return
            }
            let all = NSRange(location: 0, length: (text.string as NSString).length)
            guard text.shouldChangeText(in: all, replacementString: shaped) else { return }
            text.replaceCharacters(in: all, with: shaped)
            text.didChangeText()
        } catch {
            say((error as? EditError)?.message ?? error.localizedDescription, problem: true)
        }
    }

    /// A file's contents become the cell's pending value: its bytes as hex in a binary column, else its UTF-8 text.
    @objc func loadFile(_ sender: Any?) {
        guard let keep, let window, !AgentGuard.refuses("Agents can't read the person's files into a cell: nothing was loaded.")
        else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a file to put in \(column?.name ?? "the cell"); it's kept as a pending edit until Apply"
        let binary = column?.kind == .binary
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let loaded = await Task.detached { () -> Result<String, Error> in
                    Result {
                        let data = try Data(contentsOf: url)
                        guard data.count <= 64 << 20 else { throw AirSQLError(.other, "The file is over 64 MB") }
                        if binary { return "0x" + data.map { String(format: "%02X", $0) }.joined() }
                        guard let text = String(data: data, encoding: .utf8) else {
                            throw AirSQLError(.other, "The file isn't UTF-8 text; load it into a binary column instead")
                        }
                        return text
                    }
                }.value
                switch loaded {
                case .success(let text): if let refusal = keep(text) { self?.say(refusal, problem: true) }
                case .failure(let error): self?.say((error as? AirSQLError)?.message ?? error.localizedDescription, problem: true)
                }
            }
        }
    }

    /// The value as a file: a binary value's bytes, else its text in UTF-8.
    @objc func saveFile(_ sender: Any?) {
        guard let value, let window, !AgentGuard.refuses("Agents can't save files: nothing was saved.") else { return }
        // A binary value shown whole as 0x… (a table's, a pending one) decodes; otherwise the bytes as the server sent them.
        let data = Data(column?.kind == .binary ? (try? ColumnType.hexBytes(value)) ?? bytes ?? [] : bytes ?? Array(value.utf8))
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (column?.name ?? "value") + (column?.kind == .json ? ".json" : column?.kind == .binary ? ".bin" : ".txt")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let saved = await Task.detached { Result { try data.write(to: url, options: .atomic) } }.value
                if case .failure(let error) = saved { self?.say("The file wasn't saved: " + error.localizedDescription, problem: true) }
            }
        }
    }
}

extension GridValuePanel: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action, let tip = Self.tips[action] else { return true }
        let json = column?.kind == .json || ["{", "["].contains(text.string.first(where: { !$0.isWhitespace }))
        let (enabled, reason): (Bool, String) = switch action {
        case #selector(keepValue(_:)), #selector(putBack(_:)): (edited, "The text hasn't been changed")
        case #selector(formatJSON(_:)), #selector(compactJSON(_:)):
            keep == nil ? (false, "This cell can't be edited") : (json, "The value isn't JSON")
        case #selector(loadFile(_:)): (keep != nil, "This cell can't be edited")
        default: (value != nil, "NULL has nothing to save")
        }
        item.toolTip = enabled ? tip : reason
        return enabled
    }
}
