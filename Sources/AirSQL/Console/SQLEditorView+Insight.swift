import AirSQLCore
import AppKit

/// What the console gives the editor's Code commands.
struct InsightHooks {
    /// The connection refuses writes: they're marked while typing.
    var isReadOnly: () -> Bool = { false }
    var disabledInspections: () -> Set<String> = { [] }
    var refreshSchema: () -> Void = {}
    /// Runs a SELECT into a result, changing nothing.
    var previewRows: ((String) -> Void)?
    /// Opens a table or routine of the server.
    var openObject: ((SQLSymbol) -> Void)?
}

/// One background reading of the text: the next one makes it pointless.
final class InsightTicket {
    private let lock = NSLock()
    private var isCancelled = false
    var cancelled: Bool {
        get { lock.withLock { isCancelled } }
        set { lock.withLock { isCancelled = newValue } }
    }
}

/// Code insight in the SQL editor: the text is read a moment after the typing stops, on a background queue
/// (`SQLAnalysis`, `SQLInspections`); nothing goes to the server. Underlines come from that; the Code menu works from it.
extension SQLEditorView {
    /// Past this many characters the text isn't read: a dump, not something being written.
    static let insightLimit = 3_000_000
    private static let insightQueue = DispatchQueue(label: "console.insight", qos: .utility)

    func inspect(_ text: String, noBackslashEscapes: Bool) {
        insightTicket?.cancelled = true
        guard (text as NSString).length <= Self.insightLimit else {
            insight = nil
            inspected = []
            return
        }
        let context = nameContext?(), readOnly = insightHooks.isReadOnly(), disabled = insightHooks.disabledInspections()
        let ticket = InsightTicket()
        insightTicket = ticket
        Self.insightQueue.async { [weak self] in
            guard !ticket.cancelled else { return }
            let analysis = SQLAnalysis(text, snapshot: context?.snapshot, database: context?.database, changed: context?.changed ?? [],
                                       noBackslashEscapes: noBackslashEscapes)
            let found = SQLInspections.problems(analysis, readOnly: readOnly, disabled: disabled, noBackslashEscapes: noBackslashEscapes)
            DispatchQueue.main.async {
                guard let self, self.string == text else { return }  // the check after this edit is on its way
                self.insight = analysis
                self.inspected = found
            }
        }
    }

    /// Calls `body` with a reading of the text as it is now.
    func withInsight(_ body: @escaping (SQLAnalysis) -> Void) {
        if let insight, insight.text == string { return body(insight) }
        let text = string, noBackslashEscapes = noBackslashEscapes, context = nameContext?()
        Self.insightQueue.async { [weak self] in
            let analysis = SQLAnalysis(text, snapshot: context?.snapshot, database: context?.database, changed: context?.changed ?? [],
                                       noBackslashEscapes: noBackslashEscapes)
            DispatchQueue.main.async {
                guard let self, self.string == text else { return }
                self.insight = analysis
                body(analysis)
            }
        }
    }

    static func underline(_ severity: SQLProblem.Severity) -> [NSAttributedString.Key: Any] {
        switch severity {
        case .error: return [.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: NSColor.statusBad]
        case .warning: return [.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: NSColor.statusWarning]
        case .weak:
            return [.underlineStyle: NSUnderlineStyle.single.union(.patternDot).rawValue, .underlineColor: NSColor.tertiaryLabelColor]
        }
    }

    private var caret: Int { selectedRange().location }

    // MARK: Fixes and actions

    /// What Option-Return lists at `caret`: fixes of the problems there, then what can be done.
    func contextActions(at caret: Int, in analysis: SQLAnalysis) -> [SQLFix] {
        problems.filter { $0.range.lowerBound <= caret && caret <= $0.range.upperBound }.flatMap(\.fixes)
            + SQLIntentions.actions(at: caret, in: analysis)
    }

    @objc func showContextActions(_ sender: Any?) {
        withInsight { [weak self] analysis in
            guard let self else { return }
            let actions = self.contextActions(at: self.caret, in: analysis)
            guard !actions.isEmpty else { return self.showNote("Nothing to Do Here", "Put the cursor on a name, an underlined word or a statement.") }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for action in actions {
                let item = NSMenuItem(title: action.title, action: #selector(self.applyFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = FixBox(action)
                item.toolTip = action.title
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: self.caretPoint(), in: self)
        }
    }

    @objc private func applyFromMenu(_ item: NSMenuItem) {
        if let box = item.representedObject as? FixBox { apply(box.fix) }
    }

    func apply(_ fix: SQLFix) {
        switch fix.action {
        case .edit(let edits): apply(edits)
        case .refreshSchema: insightHooks.refreshSchema()
        case .previewRows(let sql): insightHooks.previewRows?(sql)
        case .rename: renameSymbol(nil)
        }
    }

    /// Makes `edits` as one step of Undo.
    func apply(_ edits: [SQLEdit]) {
        guard let first = edits.map(\.range.lowerBound).min(), let last = edits.map(\.range.upperBound).max() else { return }
        let text = Array(string.utf16)
        guard last <= text.count else { return }
        var replacement: [UInt16] = [], position = first
        for edit in edits.sorted(by: { ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound) }) {
            replacement += text[position..<max(position, edit.range.lowerBound)]
            replacement += Array(edit.text.utf16)
            position = max(position, edit.range.upperBound)
        }
        replacement += text[position..<last]
        let cover = NSRange(first..<last), new = String(decoding: replacement, as: UTF16.self)
        guard shouldChangeText(in: cover, replacementString: new) else { return }
        breakUndoCoalescing()
        textStorage?.replaceCharacters(in: cover, with: new)
        didChangeText()
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: first + replacement.count, length: 0))
    }

    // MARK: Going to names

    @objc func goToDeclaration(_ sender: Any?) {
        withInsight { [weak self] analysis in
            guard let self else { return }
            guard let symbol = analysis.reference(at: self.caret)?.symbol else {
                return self.showNote("Nothing Declared Here", "Put the cursor on an alias, a WITH query, a table or a column.")
            }
            if let declaration = symbol.declaration {
                self.select(declaration)
            } else if [.table, .column, .routine].contains(symbol.kind) {
                self.insightHooks.openObject?(symbol)
            } else {
                NSSound.beep()
            }
        }
    }

    private func select(_ range: Range<Int>) {
        let target = NSRange(range)
        setSelectedRange(target)
        scrollRangeToVisible(target)
        showFindIndicator(for: target)
    }

    /// The places that mean what's at `caret`, a user variable's too.
    private func usages(at caret: Int, in analysis: SQLAnalysis) -> [Range<Int>] {
        if let symbol = analysis.reference(at: caret)?.symbol { return analysis.usages(of: symbol).map(\.range) }
        return SQLIntentions.renameVariable(at: caret, to: "x", in: analysis, noBackslashEscapes: noBackslashEscapes)?.map(\.range) ?? []
    }

    @objc func findUsages(_ sender: Any?) {
        withInsight { [weak self] analysis in
            guard let self else { return }
            let found = self.usages(at: self.caret, in: analysis)
            guard !found.isEmpty else { return self.showNote("No Usages", "Put the cursor on a name to list where it's used.") }
            let text = self.string as NSString
            let menu = NSMenu()
            menu.autoenablesItems = false
            for range in found {
                let line = text.lineRange(for: NSRange(location: range.lowerBound, length: 0))
                let number = text.substring(to: line.location).components(separatedBy: "\n").count
                let words = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
                let item = NSMenuItem(title: "\(number): \(words.prefix(80))", action: #selector(self.goToUsage(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NSValue(range: NSRange(range))
                item.toolTip = "Go to this use"
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: self.caretPoint(), in: self)
        }
    }

    @objc private func goToUsage(_ item: NSMenuItem) {
        if let range = (item.representedObject as? NSValue)?.rangeValue, let target = Range(range) { select(target) }
    }

    /// Asks a moment after the caret stops, so moving through a script stays free.
    func markUsagesLater() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(markUsages), object: nil)
        perform(#selector(markUsages), with: nil, afterDelay: 0.25)
    }

    func clearUsageMarks() {
        guard let layout = layoutManager else { return }
        let length = (string as NSString).length
        for range in usageMarks where NSMaxRange(range) <= length {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        usageMarks = []
    }

    /// Tints the other places of the name at the caret, and the partner of a BEGIN, CASE or END there.
    @objc func markUsages() {
        clearUsageMarks()
        guard selectedRange().length == 0, let analysis = insight, analysis.text == string, let layout = layoutManager else { return }
        var ranges = usages(at: caret, in: analysis)
        if ranges.count < 2 { ranges = [] }
        ranges += SQLBlocks.pair(at: caret, tokens: tokens, text: analysis.text)
        let color = NSColor.accent.withAlphaComponent(0.14)
        for range in ranges {
            layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: NSRange(range))
            usageMarks.append(NSRange(range))
        }
    }

    // MARK: Rename

    /// Renames what's at `caret` to `name` in this text, or says why not.
    func rename(at caret: Int, to name: String, in analysis: SQLAnalysis) -> String? {
        if let symbol = analysis.reference(at: caret)?.symbol {
            switch SQLIntentions.rename(symbol, to: name, at: caret, in: analysis) {
            case .success(let edits): apply(edits)
            case .failure(let error): return error.message
            }
        } else if let edits = SQLIntentions.renameVariable(at: caret, to: name, in: analysis, noBackslashEscapes: noBackslashEscapes) {
            apply(edits)
        }
        return nil
    }

    @objc func renameSymbol(_ sender: Any?) {
        withInsight { [weak self] analysis in
            guard let self, let window = self.window else { return }
            let at = self.caret, found = self.usages(at: at, in: analysis), symbol = analysis.reference(at: at)?.symbol
            guard !found.isEmpty else { return self.showNote("Nothing to Rename", "Put the cursor on an alias, a WITH query, a variable, a table or a column.") }
            let alert = NSAlert()
            alert.messageText = "Rename “\((self.string as NSString).substring(with: NSRange(found[0])))”"
            let places = found.count == 1 ? "1 place" : "\(found.count) places"
            alert.informativeText = symbol?.isLocal == false && symbol?.kind != .database
                ? "Changes \(places) in this text and writes the statement that renames it on the server above this one. Nothing runs until you run it."
                : "Changes \(places) in this text."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.stringValue = symbol?.name ?? ""
            field.toolTip = "Type the new name"
            alert.accessoryView = field
            alert.addButton(withTitle: "Rename").toolTip = "Change the name in this text"
            alert.addButton(withTitle: "Cancel").toolTip = "Leave the name as it is"
            alert.window.initialFirstResponder = field
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                if let refusal = self.rename(at: at, to: field.stringValue, in: analysis) { self.showNote("Can’t Rename", refusal) }
            }
        }
    }

    // MARK: Notes at the caret

    @objc func quickDocumentation(_ sender: Any?) {
        withInsight { [weak self] analysis in
            guard let self else { return }
            if let doc = SQLIntentions.documentation(at: self.caret, in: analysis) {
                self.showNote(doc.title, doc.body)
            } else {
                self.showNote("No Documentation", "Put the cursor on a table, a column, a function or an alias.")
            }
        }
    }

    @objc func parameterInfo(_ sender: Any?) {
        withInsight { [weak self] analysis in
            guard let self else { return }
            guard let info = SQLIntentions.parameters(at: self.caret, in: analysis) else {
                return self.showNote("No Parameters Here", "Put the cursor inside a function's brackets or an INSERT row.")
            }
            let body = NSMutableAttributedString()
            let plain = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
            for (index, item) in info.items.enumerated() {
                if index > 0 { body.append(NSAttributedString(string: ", ", attributes: [.font: plain, .foregroundColor: NSColor.labelColor])) }
                body.append(NSAttributedString(string: item, attributes: [.font: index == info.active ? bold : plain, .foregroundColor: NSColor.labelColor]))
            }
            self.showNote(info.title, body)
        }
    }

    @objc func nextProblem(_ sender: Any?) { moveToProblem(forward: true) }
    @objc func previousProblem(_ sender: Any?) { moveToProblem(forward: false) }

    private func moveToProblem(forward: Bool) {
        let all = problems.sorted { $0.range.lowerBound < $1.range.lowerBound }
        let here = selectedRange().location
        guard let target = forward ? all.first(where: { $0.range.lowerBound > here }) ?? all.first
                : all.last(where: { $0.range.lowerBound < here }) ?? all.last else {
            return showNote("No Problems", "Nothing is underlined in this text.")
        }
        select(target.range)
        showNote("Problem", target.message)
    }

    @objc func showProblem(_ sender: Any?) {
        let found = problems.first { $0.range.lowerBound <= caret && caret <= $0.range.upperBound }
        showNote("Problem", found?.message ?? "Nothing is underlined at the cursor.")
    }

    @objc func previewAffectedRows(_ sender: Any?) {
        withInsight { [weak self] analysis in
            guard let self else { return }
            guard let statement = analysis.statement(at: self.caret), let sql = SQLIntentions.preview(of: statement, in: analysis) else {
                return self.showNote("Nothing to Preview", "Put the cursor in an UPDATE or DELETE without syntax errors.")
            }
            self.insightHooks.previewRows?(sql)
        }
    }

    private func caretPoint() -> NSPoint {
        guard let layout = layoutManager, let container = textContainer else { return .zero }
        let glyph = layout.glyphIndexForCharacter(at: min(caret, max((string as NSString).length - 1, 0)))
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return NSPoint(x: rect.minX + textContainerOrigin.x, y: rect.maxY + textContainerOrigin.y + 2)
    }

    func showNote(_ title: String, _ body: String) {
        showNote(title, NSAttributedString(string: body, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                                                      .foregroundColor: NSColor.labelColor]))
    }

    /// A small popover at the caret; any key or click away closes it.
    private func showNote(_ title: String, _ body: NSAttributedString) {
        notePopover?.close()
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 12)
        let text = NSTextField(labelWithAttributedString: body)
        text.maximumNumberOfLines = 30
        text.preferredMaxLayoutWidth = 520
        let stack = NSStackView(views: [heading, text])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.setAccessibilityIdentifier("console.insightNote")
        let holder = NSViewController()
        holder.view = stack
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = holder
        notePopover = popover
        shownNote = title + "\n" + body.string
        guard window != nil else { return }
        let point = caretPoint()
        popover.show(relativeTo: NSRect(x: point.x, y: point.y - 14, width: 1, height: 14), of: self, preferredEdge: .maxY)
    }

    // MARK: The margin

    /// Keeps the stripe beside the scroller up to date.
    func problemsChanged() {
        guard let scroll = enclosingScrollView else { return }
        if problemStripe == nil, !problems.isEmpty {
            let stripe = ProblemStripe(editor: self)
            scroll.addSubview(stripe)
            problemStripe = stripe
        }
        problemStripe?.update()
    }

    func goToProblem(_ problem: SQLProblem) {
        select(problem.range)
    }
}

/// A fix on a menu item.
private final class FixBox {
    let fix: SQLFix
    init(_ fix: SQLFix) { self.fix = fix }
}

/// Marks beside the scroller, one per problem at its height in the text, under a count of errors and warnings: a click
/// on a mark goes to it.
final class ProblemStripe: NSView {
    private weak var editor: SQLEditorView?
    private var marks: [(y: CGFloat, problem: SQLProblem)] = []
    private static let width: CGFloat = 8

    init(editor: SQLEditorView) {
        self.editor = editor
        super.init(frame: .zero)
        autoresizingMask = [.minXMargin, .height]
        setAccessibilityIdentifier("console.problemStripe")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func update() {
        guard let editor, let scroll = editor.enclosingScrollView else { return }
        let content = scroll.contentView.frame
        frame = NSRect(x: content.maxX - Self.width, y: content.minY, width: Self.width, height: content.height)
        let text = Array(editor.string.utf16)
        var lineStarts = [0]
        for (index, unit) in text.enumerated() where unit == 0x0A { lineStarts.append(index + 1) }
        marks = editor.problems.map { problem in
            let line = lineStarts.lastIndex { $0 <= problem.range.lowerBound } ?? 0
            return (CGFloat(line) / CGFloat(max(lineStarts.count, 1)) * bounds.height, problem)
        }
        let errors = editor.problems.filter { $0.severity == .error }.count, warnings = editor.problems.filter { $0.severity == .warning }.count
        toolTip = marks.isEmpty ? nil : "\(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s"): click a mark to go to it"
        isHidden = marks.isEmpty
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        for mark in marks {
            let color: NSColor = mark.problem.severity == .error ? .statusBad : mark.problem.severity == .warning ? .statusWarning : .tertiaryLabelColor
            color.setFill()
            NSRect(x: 1, y: min(mark.y, bounds.height - 3), width: bounds.width - 2, height: 3).intersection(bounds).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        if let nearest = marks.min(by: { abs($0.y - y) < abs($1.y - y) }) { editor?.goToProblem(nearest.problem) }
    }
}
