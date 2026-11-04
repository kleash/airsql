import AppKit

/// Find and replace in the editor (⌘F, ⌥⌘F; plan §2.6), with regular expressions: the matches marked in the text, the
/// one chosen selected, how many there are; Replace takes $1 and the like from a regular expression's groups, Replace
/// All is one change that Undo takes back. Escape closes it.
@MainActor
final class FindBar: NSView, NSSearchFieldDelegate, NSTextFieldDelegate {
    private weak var editor: SQLEditorView?
    let search = NSSearchField()
    let replacement = NSTextField()
    private let count = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor)
    let matchCase = NSButton(checkboxWithTitle: "Match Case", target: nil, action: nil)
    let regex = NSButton(checkboxWithTitle: "Regular Expression", target: nil, action: nil)
    private let replaceRow = NSStackView()
    private var marks: [NSRange] = []
    /// Shows or hides the bar (the console lays it out).
    var onVisibility: ((Bool) -> Void)?

    init(editor: SQLEditorView) {
        self.editor = editor
        super.init(frame: .zero)
        search.placeholderString = "Find"
        search.toolTip = "Type what to find; Return shows the next match"
        search.setAccessibilityIdentifier("find.search")
        search.delegate = self
        search.sendsWholeSearchString = false
        search.sendsSearchStringImmediately = true
        replacement.placeholderString = "Replace with"
        replacement.toolTip = "Type the replacement: $1, $2… put in a regular expression's groups"
        replacement.setAccessibilityIdentifier("find.replace")
        for box in [matchCase, regex] {
            box.target = self
            box.action = #selector(optionsChanged(_:))
            box.controlSize = .small
        }
        matchCase.toolTip = "Find only text with the same capitals"
        regex.toolTip = "Read what to find as a regular expression, such as ^id_[0-9]+"
        matchCase.setAccessibilityIdentifier("find.matchCase")
        regex.setAccessibilityIdentifier("find.regex")
        let previous = icon("chevron.left", "Previous Match", "Show the previous match (⇧⌘G)", #selector(previousMatch(_:)), "find.previous")
        let next = icon("chevron.right", "Next Match", "Show the next match (⌘G)", #selector(nextMatch(_:)), "find.next")
        let done = button("Done", id: "find.done", tip: "Close find and replace (Escape)", target: self, action: #selector(close(_:)))
        done.controlSize = .small
        let replace = button("Replace", id: "find.replaceOne", tip: "Replace the selected match, then show the next",
                             target: self, action: #selector(replaceOne(_:)))
        let all = button("Replace All", id: "find.replaceAll", tip: "Replace every match in one change (⌘Z takes it back)",
                         target: self, action: #selector(replaceAll(_:)))
        [replace, all].forEach { $0.controlSize = .small }
        let findRow = NSStackView(views: [search, previous, next, count, matchCase, regex, done])
        findRow.spacing = Spacing.unit
        findRow.setCustomSpacing(Spacing.half, after: previous)
        replaceRow.setViews([replacement, replace, all], in: .leading)
        replaceRow.spacing = Spacing.unit
        let rows = NSStackView(views: [findRow, replaceRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        let background = SurfaceView(.bar)
        let line = Hairline()
        for view in [background, rows, line] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        background.pin(to: self)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.unit),
            rows.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.unit),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor), line.heightAnchor.constraint(equalToConstant: 1),
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            search.widthAnchor.constraint(lessThanOrEqualToConstant: 240), replacement.widthAnchor.constraint(equalTo: search.widthAnchor),
        ])
        // 240 wide when there is room; narrower beside the helpers rather than widening the window.
        let preferred = search.widthAnchor.constraint(equalToConstant: 240)
        preferred.priority = .init(490)
        preferred.isActive = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func icon(_ symbol: String, _ name: String, _ tip: String, _ action: Selector, _ id: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: name) ?? NSImage(), target: self,
                              action: action)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.toolTip = tip
        button.setAccessibilityIdentifier(id)
        return button
    }

    /// What the menu's Find commands ask for (their tag is the NSTextFinder action).
    func perform(_ action: NSTextFinder.Action) {
        switch action {
        case .showFindInterface, .showReplaceInterface:
            show(replace: action == .showReplaceInterface)
        case .nextMatch: nextMatch(nil)
        case .previousMatch: previousMatch(nil)
        case .setSearchString:
            guard let editor, editor.selectedRange().length > 0 else { return }
            let selected = (editor.string as NSString).substring(with: editor.selectedRange())
            search.stringValue = regex.state == .on ? NSRegularExpression.escapedPattern(for: selected) : selected
            update()
        case .replaceAll: replaceAll(nil)
        case .replace, .replaceAndFind: replaceOne(nil)
        case .hideFindInterface, .hideReplaceInterface: close(nil)
        default: break
        }
    }

    func show(replace: Bool) {
        replaceRow.isHidden = !replace
        if isHidden {
            isHidden = false
            onVisibility?(true)
        }
        window?.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
        update()
    }

    @objc func close(_ sender: Any?) {
        clearMarks()
        isHidden = true
        onVisibility?(false)
        if let editor { window?.makeFirstResponder(editor) }
    }

    // MARK: Matching

    /// Every match in the editor's text; nil when the regular expression is wrong (the count says so).
    func matches() -> [NSRange]? {
        guard let editor, !search.stringValue.isEmpty else { return [] }
        let text = editor.string as NSString
        if regex.state == .on {
            guard let expression = try? NSRegularExpression(pattern: search.stringValue,
                                                            options: matchCase.state == .on ? [] : [.caseInsensitive]) else { return nil }
            return expression.matches(in: editor.string, range: NSRange(location: 0, length: text.length)).map(\.range)
                .filter { $0.length > 0 }
        }
        var found: [NSRange] = [], start = 0
        let options: NSString.CompareOptions = matchCase.state == .on ? [] : [.caseInsensitive]
        while start < text.length {
            let range = text.range(of: search.stringValue, options: options, range: NSRange(location: start, length: text.length - start))
            guard range.location != NSNotFound else { break }
            found.append(range)
            start = NSMaxRange(range)
        }
        return found
    }

    /// Marks the matches and says how many there are.
    func update() {
        clearMarks()
        guard let found = matches() else {
            count.stringValue = "Not a regular expression"
            count.textColor = .statusBad
            return
        }
        count.textColor = .secondaryLabelColor
        count.stringValue = search.stringValue.isEmpty ? "" : found.isEmpty ? "Not found"
            : "\(found.count.formatted()) match\(found.count == 1 ? "" : "es")"
        guard let layout = editor?.layoutManager else { return }
        marks = Array(found.prefix(5_000))
        for range in marks {
            layout.addTemporaryAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.45), forCharacterRange: range)
        }
    }

    private func clearMarks() {
        guard let editor, let layout = editor.layoutManager else { return }
        let length = (editor.string as NSString).length
        for range in marks where NSMaxRange(range) <= length {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        marks = []
    }

    @objc func nextMatch(_ sender: Any?) { step(forward: true) }
    @objc func previousMatch(_ sender: Any?) { step(forward: false) }

    private func step(forward: Bool) {
        guard let editor, let found = matches(), !found.isEmpty else { return NSSound.beep() }
        let selection = editor.selectedRange()
        let target = forward ? found.first { $0.location >= NSMaxRange(selection) && $0 != selection } ?? found[0]
            : found.last { NSMaxRange($0) <= selection.location && $0 != selection } ?? found[found.count - 1]
        editor.setSelectedRange(target)
        editor.scrollRangeToVisible(target)
        editor.showFindIndicator(for: target)
    }

    @objc private func replaceOne(_ sender: Any?) {
        guard let editor, let found = matches(), !Self.refusesAgentText(editor) else { return }
        let selection = editor.selectedRange()
        guard found.contains(selection) else { return step(forward: true) }
        editor.replace(selection, with: replacementText(for: selection), select: NSRange(location: selection.location, length: 0))
        update()
        step(forward: true)
    }

    @objc private func replaceAll(_ sender: Any?) {
        guard let editor, let found = matches(), !found.isEmpty else { return NSSound.beep() }
        guard !Self.refusesAgentText(editor) else { return }
        let text = editor.string as NSString, whole = NSRange(location: 0, length: text.length)
        let result: String
        if regex.state == .on, let expression = try? NSRegularExpression(pattern: search.stringValue,
                                                                          options: matchCase.state == .on ? [] : [.caseInsensitive]) {
            result = expression.stringByReplacingMatches(in: editor.string, range: whole, withTemplate: replacement.stringValue)
        } else {
            let copy = NSMutableString(string: text)
            for range in found.reversed() { copy.replaceCharacters(in: range, with: replacement.stringValue) }
            result = copy as String
        }
        editor.replace(whole, with: result, select: NSRange(location: 0, length: 0))
        count.stringValue = "Replaced \(found.count.formatted())"
        clearMarks()
    }

    /// The paste gate (plan §2.8): an agent's replacement text doesn't go into a production console unasked.
    private static func refusesAgentText(_ editor: SQLEditorView) -> Bool {
        AgentGuard.productionConsole(editor) != nil && AgentGuard.refuses("Replacing text in a production console needs the "
                                                                          + "person's OK: use set console.editor, which asks them once.")
    }

    /// The replacement for one match: with a regular expression, its groups put in for $1, $2….
    private func replacementText(for range: NSRange) -> String {
        guard regex.state == .on, let editor,
              let expression = try? NSRegularExpression(pattern: search.stringValue, options: matchCase.state == .on ? [] : [.caseInsensitive]),
              let match = expression.firstMatch(in: editor.string, range: range) else { return replacement.stringValue }
        return expression.replacementString(for: match, in: editor.string, offset: 0, template: replacement.stringValue)
    }

    @objc private func optionsChanged(_ sender: Any?) { update() }

    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSSearchField) === search { update() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): close(nil)
        case #selector(NSResponder.insertNewline(_:)):
            if control === search { nextMatch(nil) } else { replaceOne(nil) }
        default: return false
        }
        return true
    }
}
