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
    /// The completion list, once it has been shown.
    var completionPopup: CompletionPopup?
    /// .sql files dropped on the editor: the console opens them.
    var onDropFiles: (([URL]) -> Void)?
    /// Where the last Run failed, underlined until the text changes.
    var runProblem: SQLProblem? { didSet { if runProblem != oldValue { underlineProblems() } } }
    private(set) var tokens: [SQLToken] = []
    private var highlightedLength = 0
    static let indentUnit = "    "

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
        setFontSize(fontSize)
        registerForDraggedTypes(readablePasteboardTypes + [.fileURL])
        setAccessibilityIdentifier("console.editor")
        setAccessibilityLabel("SQL editor")
        toolTip = nil
    }

    /// The editor's font: SF Mono at `size` (Settings ▸ Editor, or zoomed for a moment).
    func setFontSize(_ size: CGFloat) {
        font = .monospacedSystemFont(ofSize: size, weight: .regular)
        typingAttributes = [.font: font!, .foregroundColor: NSColor.labelColor]
        highlightAll()
        underlineProblems()
        (enclosingScrollView?.verticalRulerView as? LineNumberRuler)?.fitWidth()
    }

    var fontSize: CGFloat { font?.pointSize ?? 13 }

    override func performTextFinderAction(_ sender: Any?) {
        guard let onFind, let tag = (sender as? NSValidatedUserInterfaceItem)?.tag, let action = NSTextFinder.Action(rawValue: tag)
        else { return super.performTextFinderAction(sender) }
        onFind(action)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)) { return onFind != nil }
        return super.validateMenuItem(item)
    }

    // MARK: Colours

    /// Colours the whole text again (a new font or backslash mode).
    func highlightAll() {
        tokens = []
        highlightedLength = 0
        highlight()
    }

    override func didChangeText() {
        super.didChangeText()
        // A long script is coloured a moment after the typing stops, so keys never wait for it.
        if (string as NSString).length > Self.longText {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(highlightLater), object: nil)
            perform(#selector(highlightLater), with: nil, afterDelay: 0.2)
        } else {
            highlight()
        }
        clearMarks()
        runProblem = nil
        (enclosingScrollView?.verticalRulerView as? LineNumberRuler)?.fitWidth()
        onChange?()
    }

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
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix {
            let a = old[old.count - 1 - suffix], b = new[new.count - 1 - suffix]
            guard a.kind == b.kind, a.isClosed == b.isClosed, a.range.lowerBound + delta == b.range.lowerBound,
                  a.range.count == b.range.count else { break }
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
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: range)
        SQLPreviewSheet.colour(storage, tokens: new, first..<(new.count - suffix), text: Array(text.utf16), font: font)
        storage.endEditing()
    }

    /// Shows for a moment, behind its text, the statement that ran (no chooser: the highlight says what ran).
    func flash(_ range: NSRange) {
        guard let layout = layoutManager, NSMaxRange(range) <= (string as NSString).length else { return }
        let color = NSColor.accent.withAlphaComponent(0.16)
        layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let layout = self.layoutManager, NSMaxRange(range) <= (self.string as NSString).length else { return }
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
    }

    // MARK: Problems (underlined in red, the message on hover)

    var problems: [SQLProblem] { [runProblem].compactMap { $0 } }

    /// Draws `problems` again. The hover areas are fixed rectangles, so they're remade whenever the text moves.
    private func underlineProblems() {
        guard let layout = layoutManager, let container = textContainer else { return }
        let length = (string as NSString).length
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: NSRange(location: 0, length: length))
        layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: NSRange(location: 0, length: length))
        removeAllToolTips()
        for problem in problems where problem.range.upperBound <= length {
            let range = NSRange(problem.range)
            layout.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: NSColor.statusBad],
                                          forCharacterRange: range)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let none = NSRange(location: NSNotFound, length: 0)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: none, in: container) { rect, _ in
                self.addToolTip(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y), owner: self, userData: nil)
            }
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let index = characterIndexForInsertion(at: point)
        return problems.first { ($0.range.lowerBound...$0.range.upperBound).contains(index) }?.message ?? ""
    }

    // MARK: Marks (what ran, the matching bracket)

    private var bracketMarks: [NSRange] = []

    private func clearMarks() {
        guard let layout = layoutManager else { return }
        let length = (string as NSString).length
        for range in bracketMarks where NSMaxRange(range) <= length {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        bracketMarks = []
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !stillSelecting else { return }
        clearMarks()
        markMatchingBracket()
        onSelectionChange?()
    }

    /// The bracket next to the caret and its partner, outside strings and comments.
    private func markMatchingBracket() {
        let caret = selectedRange()
        guard caret.length == 0, let layout = layoutManager else { return }
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
