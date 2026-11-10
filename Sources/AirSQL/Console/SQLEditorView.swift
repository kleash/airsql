import AirSQLCore
import AppKit

/// The console's SQL editor (plan §2.6): SF Mono, coloured by SQLLexer as the mockups colour SQL, line numbers, the
/// matching bracket, comment and indent commands, and Return keeping the line's indentation. Plain text only: nothing
/// is ever substituted (quotes, dashes, links, spelling).
final class SQLEditorView: NSTextView, NSViewToolTipOwner {
    /// The session's NO_BACKSLASH_ESCAPES, which decides where strings end.
    var noBackslashEscapes = false { didSet { if noBackslashEscapes != oldValue { highlightAll() } } }
    /// Called after every change of the text (the console saves and marks itself edited).
    var onChange: (() -> Void)?
    /// Called as the selection moves (the helpers panel follows the statement at the caret).
    var onSelectionChange: (() -> Void)?
    /// The menu's Find commands (their tag is the NSTextFinder action): the console's find bar.
    var onFind: ((NSTextFinder.Action) -> Void)?
    /// The suggestions at a place of a text: the console's, from its connection's schema cache.
    var completions: ((String, Int) -> (Range<Int>, [CompletionItem]))?
    /// What the list shows below itself for a suggestion.
    var completionDocs: ((CompletionItem) -> String?)?
    /// The completion list, once it has been shown.
    var completionPopup: CompletionPopup?
    /// The settings of every editor, consoles' and object editors' alike.
    static var settings: () -> AppSettings = { AppSettings() }
    /// .sql files dropped on the editor: the console opens them.
    var onDropFiles: (([URL]) -> Void)?
    /// Where the last Run failed, underlined until the text changes.
    var runProblem: SQLProblem? { didSet { if runProblem != oldValue { underlineProblems() } } }
    /// What the text leaves open (`ConsoleScript.unclosed`), as of the last pause in the typing.
    private var unclosed: [SQLProblem] = [] { didSet { if unclosed != oldValue { underlineProblems() } } }
    /// What the check for unknown names reads, as of now; nil: it stays silent (an object editor, no connection).
    var nameContext: (() -> (snapshot: SchemaSnapshot?, database: String?, changed: Set<String>)?)?
    /// Text in another language (a MongoDB pipeline): its own problems and folds take the place of SQL's checks and
    /// folds, and no word takes the keyword case.
    var otherLanguage: (problems: (String) -> [SQLProblem], folds: (String) -> [Range<Int>])?
    /// What `SQLInspections` said, as of the last pause in the typing.
    var inspected: [SQLProblem] = [] { didSet { if inspected != oldValue { underlineProblems() } } }
    /// The text changed since `unclosed` and `inspected` were made: their places, and so their fixes, are out of date.
    var problemsOutOfDate = false
    /// The text as last read (`SQLAnalysis`), for Option-Return and the Code menu.
    var insight: SQLAnalysis?
    /// What the console gives the Code menu: see `ConsoleViewController.wireInsight`.
    var insightHooks = InsightHooks()
    var insightTicket: InsightTicket?
    var usageMarks: [NSRange] = []
    var notePopover: NSPopover?
    /// What the last note said, for the tests.
    var shownNote = ""
    var problemStripe: ProblemStripe?
    var inlayOverlay: InlayOverlay?
    var hoverTracker: HoverTracker?
    private(set) var tokens: [SQLToken] = []
    private var highlightedLength = 0
    /// Its own, not the window's: Undo in one console must never change another's hidden text, and an object editor's
    /// loaded code must not wipe the consoles' steps.
    private let ownUndoManager = UndoManager()
    override var undoManager: UndoManager? { ownUndoManager }
    /// What Tab puts in, and how wide a tab shows, in spaces (Settings ▸ Editor).
    var indentUnit = "    "
    var tabWidth = 4 { didSet { if tabWidth != oldValue { setFontSize(fontSize) } } }
    /// The font's family (Settings ▸ Editor); empty: SF Mono.
    var fontFamily = "" { didSet { if fontFamily != oldValue { setFontSize(fontSize) } } }
    /// Tabs set at `tabWidth` spaces of the font, kept on the whole text.
    private var paragraph = NSParagraphStyle.default
    /// The text's statements, as of its last change.
    var statements: [SQLStatement] {
        if let cachedStatements { return cachedStatements }
        let found = SQLSplitter.statements(in: string, noBackslashEscapes: noBackslashEscapes)
        cachedStatements = found
        return found
    }
    private var cachedStatements: [SQLStatement]?
    /// Format SQL is reading the text.
    var isFormatting = false
    /// The steps Extend Selection took, for Shrink Selection.
    var grownSelections: [(from: NSRange, to: NSRange)] = []
    /// What's drawn now behind the text, to redraw it when the cursor moves.
    var shadedStatement: Range<Int>?
    var shownCaretBand = NSRect.zero
    /// The carets besides the main one, in the text's order, and whether `atEveryCaret` is moving through them.
    var extraCarets: [NSRange] = [] { didSet { markExtraSelections(old: oldValue) } }
    var applyingCarets = false
    var caretsChangedText = false
    /// Column Selection Mode.
    var columnSelection = false
    /// The last texts copied from any editor, for Paste from History.
    static var copied: [String] = []
    /// What's folded away, as ranges of the text.
    var folds: [Range<Int>] = []
    /// Where the lines marked with a bookmark start, in order (SQLEditorView+Bookmarks.swift).
    var bookmarks: [Int] = []
    var cachedFoldRegions: [Range<Int>]?
    /// A template being filled in: the places of each of its fields, the last being where the cursor ends, and which one
    /// Tab has reached.
    var templateFields: [[NSRange]] = []
    var templateField = 0
    /// "Ln 3, Col 14", in the editor's corner.
    let positionLabel = NSTextField(labelWithString: "")

    /// A TextKit 1 editor in a scroll view with a line-number ruler, not wrapping lines.
    static func make(fontSize: CGFloat) -> (NSScrollView, SQLEditorView) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        let editor = SQLEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 300), textContainer: container)
        editor.configure(fontSize: fontSize)
        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .content
        let ruler = LineNumberRuler(editor: editor)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        let position = editor.positionLabel
        position.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        position.textColor = .secondaryLabelColor
        position.drawsBackground = true
        position.backgroundColor = .content
        position.toolTip = "Shows the cursor's line and column, and how many characters are selected"
        position.setAccessibilityIdentifier("console.position")
        // By its frame: a scroll view neither lays out nor autoresizes what's added to it, so it follows by hand.
        scroll.addSubview(position)
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(editor, selector: #selector(updatePosition), name: NSView.frameDidChangeNotification, object: scroll)
        return (scroll, editor)
    }

    private func configure(fontSize: CGFloat) {
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = true
        autoresizingMask = [.width]
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        drawsBackground = true
        backgroundColor = .content
        insertionPointColor = .accent
        textContainerInset = NSSize(width: 4, height: 8)
        layoutManager?.allowsNonContiguousLayout = true
        layoutManager?.delegate = self
        textStorage?.delegate = self
        setFontSize(fontSize)
        registerForDraggedTypes(readablePasteboardTypes + [.fileURL])
        setAccessibilityIdentifier("console.editor")
        setAccessibilityLabel("SQL editor")
        toolTip = nil
    }

    /// The editor's font: `fontFamily` at `size` (Settings ▸ Editor, or zoomed for a moment).
    func setFontSize(_ size: CGFloat) {
        font = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = CGFloat(tabWidth) * (" " as NSString).size(withAttributes: [.font: font!]).width
        paragraph = style
        defaultParagraphStyle = style
        typingAttributes = [.font: font!, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
        highlightAll()
        underlineProblems()
        (enclosingScrollView?.verticalRulerView as? LineNumberRuler)?.fitWidth()
    }

    var fontSize: CGFloat { font?.pointSize ?? 13 }

    /// Settings ▸ Editor's font and indent.
    func applyStyle(family: String, tabWidth: Int, usesTabs: Bool) {
        fontFamily = family
        self.tabWidth = tabWidth
        indentUnit = usesTabs ? "\t" : String(repeating: " ", count: tabWidth)
    }

    /// Long lines wrap at the editor's edge, or run on and scroll sideways.
    func setWraps(_ wraps: Bool) {
        guard let scroll = enclosingScrollView, let container = textContainer else { return }
        isHorizontallyResizable = !wraps
        scroll.hasHorizontalScroller = !wraps
        container.widthTracksTextView = wraps
        container.size = NSSize(width: wraps ? scroll.contentSize.width : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        if wraps { setFrameSize(NSSize(width: scroll.contentSize.width, height: frame.height)) }
        updatePosition()
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard let onFind, let tag = (sender as? NSValidatedUserInterfaceItem)?.tag, let action = NSTextFinder.Action(rawValue: tag)
        else { return super.performTextFinderAction(sender) }
        onFind(action)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)), !usesFindBar { return onFind != nil }
        if item.action == Commands.undo.action { return ownUndoManager.canUndo }
        if item.action == Commands.redo.action { return ownUndoManager.canRedo }
        if item.action == Commands.columnSelection.action { item.state = columnSelection ? .on : .off }
        return super.validateMenuItem(item)
    }

    @objc func undo(_ sender: Any?) {
        completionPopup?.close()
        ownUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        completionPopup?.close()
        ownUndoManager.redo()
    }

    // MARK: Colours

    /// Colours the whole text again (a new font or backslash mode).
    func highlightAll() {
        tokens = []
        highlightedLength = 0
        cachedStatements = nil
        cachedFoldRegions = nil
        highlight()
        checkLater()
    }

    override func didChangeText() {
        super.didChangeText()
        cachedStatements = nil
        cachedFoldRegions = nil
        if applyingCarets {  // once, after the last caret
            caretsChangedText = true
            return
        }
        // A long script is coloured a moment after the typing stops, so keys never wait for it.
        if (string as NSString).length > Self.longText {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(highlightLater), object: nil)
            perform(#selector(highlightLater), with: nil, afterDelay: 0.2)
        } else {
            highlight()
        }
        clearMarks()
        clearUsageMarks()
        runProblem = nil
        checkLater()
        (enclosingScrollView?.verticalRulerView as? LineNumberRuler)?.fitWidth()
        onChange?()
    }

    /// What the edits since the last colouring replaced, as it stands in the new text.
    var editedSinceHighlight: Range<Int>?

    /// Past this many characters, colours and completion wait for a pause in the typing.
    static let longText = 150_000

    @objc private func highlightLater() { highlight() }

    /// Lexes the whole text (R19) and colours only the tokens that changed: those between the unchanged ones at the
    /// start and at the end, so typing in a long script stays quick.
    private func highlight() {
        guard let storage = textStorage, let font else { return }
        let text = storage.string
        let new = SQLLexer.tokens(text, noBackslashEscapes: noBackslashEscapes)
        let old = tokens, delta = (text as NSString).length - highlightedLength
        // Replaced text comes in uncoloured, even when its tokens are the same as those it replaced.
        let editStart = editedSinceHighlight?.lowerBound ?? .max, editEnd = editedSinceHighlight?.upperBound ?? 0
        editedSinceHighlight = nil
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix], new[prefix].range.upperBound <= editStart { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix {
            let a = old[old.count - 1 - suffix], b = new[new.count - 1 - suffix]
            guard a.kind == b.kind, a.isClosed == b.isClosed, a.range.lowerBound + delta == b.range.lowerBound,
                  a.range.count == b.range.count, b.range.lowerBound >= editEnd else { break }
            suffix += 1
        }
        tokens = new
        highlightedLength = (text as NSString).length
        // From the token before the first changed one: a word's colour depends on the token after it (name( is a call).
        let first = max(prefix - 1, 0)
        let start = first > 0 ? new[first - 1].range.upperBound : 0
        let end = suffix > 0 ? new[new.count - suffix].range.lowerBound : highlightedLength
        guard start <= end else { return }
        let range = NSRange(location: start, length: end - start)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: range)
        SQLPreviewSheet.colour(storage, tokens: new, first..<(new.count - suffix), text: Array(text.utf16), font: font)
        storage.endEditing()
    }

    /// Shows for a moment, behind its text, the statement that ran (no chooser: the highlight says what ran).
    func flash(_ range: NSRange) {
        guard let layout = layoutManager, NSMaxRange(range) <= (string as NSString).length else { return }
        let color = NSColor.accent.withAlphaComponent(0.16)
        // Line by line, without the line ends: a marked line end would fill the rest of the line, across the window.
        (string as NSString).enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: line)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let layout = self.layoutManager, NSMaxRange(range) <= (self.string as NSString).length else { return }
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
    }

    // MARK: Problems (underlined in red, the message on hover)

    var problems: [SQLProblem] { [runProblem].compactMap { $0 } + unclosed + inspected }

    /// A pause first: `(` is only a problem if nothing follows it.
    func checkLater() {
        problemsOutOfDate = true
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(check), object: nil)
        perform(#selector(check), with: nil, afterDelay: 0.5)
    }

    @objc func check() {
        if let otherLanguage {
            unclosed = []
            inspected = otherLanguage.problems(string)
            problemsOutOfDate = false
            return
        }
        let text = string, noBackslashEscapes = noBackslashEscapes
        unclosed = ConsoleScript.unclosed(in: text, noBackslashEscapes: noBackslashEscapes)
        inspect(text, noBackslashEscapes: noBackslashEscapes)
    }

    /// Draws `problems` again. The hover areas are fixed rectangles, so they're remade whenever the text moves.
    private func underlineProblems() {
        guard let layout = layoutManager, let container = textContainer else { return }
        let length = (string as NSString).length
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: NSRange(location: 0, length: length))
        layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: NSRange(location: 0, length: length))
        let tip = toolTip  // an object editor has one for the whole view
        removeAllToolTips()
        toolTip = tip
        for problem in problems where problem.range.upperBound <= length {
            let range = NSRange(problem.range)
            layout.addTemporaryAttributes(Self.underline(problem.severity), forCharacterRange: range)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let none = NSRange(location: NSNotFound, length: 0)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: none, in: container) { rect, _ in
                self.addToolTip(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y), owner: self, userData: nil)
            }
        }
        problemsChanged()
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let index = characterIndexForInsertion(at: point)
        return problems.first { ($0.range.lowerBound...$0.range.upperBound).contains(index) }?.message ?? hoverText(at: index)
    }

    // MARK: Marks (what ran, the matching bracket)

    private var bracketMarks: [NSRange] = []

    func clearMarks() {
        guard let layout = layoutManager else { return }
        let length = (string as NSString).length
        for range in bracketMarks where NSMaxRange(range) <= length {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        bracketMarks = []
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !stillSelecting, !applyingCarets else { return }
        openFoldsAtSelection()
        if !extraCarets.isEmpty { extraCarets = [] }
        // A block dragged out with ⌥ arrives as several selections: each becomes a caret.
        if ranges.count > 1 { return setCarets(ranges.map(\.rangeValue)) }
        clearMarks()
        markSelectedName()
        markMatchingBracket()
        updateCaretMarks()
        markUsagesLater()
        onSelectionChange?()
    }

    /// A selected name marks its other uses by spelling; at the caret the parser's `markUsages` knows the scope.
    private func markSelectedName() {
        guard let layout = layoutManager, selectedRange().length > 0 else { return }
        let color = NSColor.labelColor.withAlphaComponent(0.1)
        markSameNames { range in
            layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
            bracketMarks.append(range)
        }
    }

    /// The bracket next to the caret and its partner, outside strings and comments.
    private func markMatchingBracket() {
        let caret = selectedRange()
        guard caret.length == 0, marksTheText, let layout = layoutManager else { return }
        let utf16 = Array(string.utf16)
        // During an edit the tokens are the text's before it: only those still inside the text count.
        let symbols = tokens.filter { $0.kind == .symbol && $0.range.count == 1 && $0.range.upperBound <= utf16.count }
        let pairs: [UInt16: UInt16] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]
        let closers = Dictionary(uniqueKeysWithValues: pairs.map { ($1, $0) })
        guard let index = symbols.lastIndex(where: { [caret.location - 1, caret.location].contains($0.range.lowerBound)
            && (pairs[utf16[$0.range.lowerBound]] != nil || closers[utf16[$0.range.lowerBound]] != nil) }) else { return }
        let c = utf16[symbols[index].range.lowerBound]
        var depth = 0, partner: Int?
        if let close = pairs[c] {
            for i in index..<symbols.count {
                let s = utf16[symbols[i].range.lowerBound]
                if s == c { depth += 1 } else if s == close { depth -= 1; if depth == 0 { partner = i; break } }
            }
        } else if let open = closers[c] {
            for i in stride(from: index, through: 0, by: -1) {
                let s = utf16[symbols[i].range.lowerBound]
                if s == c { depth += 1 } else if s == open { depth -= 1; if depth == 0 { partner = i; break } }
            }
        }
        guard let partner else { return }
        let color = NSColor.accent.withAlphaComponent(0.25)
        for i in [index, partner] {
            let range = NSRange(symbols[i].range)
            layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
            bracketMarks.append(range)
        }
    }
}
