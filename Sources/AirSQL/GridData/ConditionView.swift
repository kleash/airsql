import AirSQLCore
import AppKit

/// The WHERE bar's condition (grid-spec §4): SQL coloured as the console colours it, in a box that grows from one line
/// to eight as the condition wraps, then scrolls. Return applies it, ⌥↩ starts a new line, Tab moves on, ⌥↓ lists the
/// recent filters; ⌥⎋ completes through the delegate.
@MainActor
final class ConditionView: NSTextView {
    static let maxLines = 8
    /// What it shows when empty.
    var placeholder = "" { didSet { needsDisplay = true } }
    var onReturn: (() -> Void)?
    var onRecent: (() -> Void)?
    /// The session's NO_BACKSLASH_ESCAPES, which decides where strings end.
    var noBackslashEscapes = false { didSet { colour() } }
    /// The box the bar shows: a field's border around the text and its scroller.
    let box = SurfaceView(.content, radius: Radius.control, border: .separatorColor)

    static func make(fontSize: CGFloat = 12) -> ConditionView {
        // A frame to start from, the text view as wide as the scroller leaves it: it wraps to the box's width from then on.
        let scroll = ConditionScroll(frame: NSRect(x: 0, y: 0, width: 300, height: 16))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = ConditionView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.typingAttributes = [.font: view.font!, .foregroundColor: NSColor.labelColor]
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        for off in [\NSTextView.isAutomaticQuoteSubstitutionEnabled, \.isAutomaticDashSubstitutionEnabled, \.isAutomaticTextReplacementEnabled,
                    \.isAutomaticSpellingCorrectionEnabled, \.isContinuousSpellCheckingEnabled, \.isAutomaticLinkDetectionEnabled,
                    \.isAutomaticDataDetectionEnabled, \.isAutomaticTextCompletionEnabled, \.smartInsertDeleteEnabled] {
            view[keyPath: off] = false
        }
        view.drawsBackground = false
        view.insertionPointColor = .accent
        view.textContainerInset = NSSize(width: 2, height: 1)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.focusRingType = .exterior
        scroll.documentView = view
        view.box.translatesAutoresizingMaskIntoConstraints = false
        view.box.addSubview(scroll)
        // Its scroller clear of the box's rounded corners.
        scroll.pin(to: view.box, insets: NSEdgeInsets(top: 3, left: 1, bottom: 3, right: 1))
        scroll.setContentHuggingPriority(.required, for: .vertical)
        scroll.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    /// The condition; set from outside, it is coloured, the box fits it and shows its start.
    var text: String {
        get { string }
        set {
            string = newValue
            colour()
            enclosingScrollView?.invalidateIntrinsicContentSize()
            scroll(.zero)
        }
    }

    private var lineHeight: CGFloat { layoutManager?.defaultLineHeight(for: font ?? .systemFont(ofSize: 12)) ?? 15 }

    /// How tall the text shows: its wrapped lines, from one to eight (then it scrolls).
    var shownHeight: CGFloat {
        guard let layoutManager, let textContainer else { return lineHeight }
        layoutManager.ensureLayout(for: textContainer)
        let lines = Int((layoutManager.usedRect(for: textContainer).height / lineHeight).rounded())
        return ceil(CGFloat(min(max(lines, 1), Self.maxLines)) * lineHeight + 2 * textContainerInset.height)
    }

    override func didChangeText() {
        super.didChangeText()
        colour()
        enclosingScrollView?.invalidateIntrinsicContentSize()
    }

    private func colour() {
        guard let storage = textStorage, let font else { return }
        let text = storage.string, all = NSRange(location: 0, length: storage.length)
        let tokens = SQLLexer.tokens(text, noBackslashEscapes: noBackslashEscapes)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: all)
        SQLPreviewSheet.colour(storage, tokens: tokens, tokens.indices, text: Array(text.utf16), font: font)
        storage.endEditing()
    }

    // MARK: Keys

    override func insertNewline(_ sender: Any?) { onReturn?() }
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(self) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(self) }
    /// ⌥↓, as in a pop-up: the recent filters.
    override func moveToEndOfParagraph(_ sender: Any?) { onRecent?() }

    // MARK: Look

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let font else { return }
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        (placeholder as NSString).draw(at: NSPoint(x: x, y: textContainerInset.height),
                                       withAttributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor])
    }

    /// The focus ring goes round the box, as round a field.
    override var focusRingMaskBounds: NSRect { convert(box.bounds, from: box) }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: Radius.control, yRadius: Radius.control).fill()
    }
}

/// The condition's scroll view, as tall as its text shows: a narrower bar wraps the text onto more lines, so a new width
/// works the height out again (another layout pass).
private final class ConditionScroll: NSScrollView {
    private var measuredWidth: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: (documentView as? ConditionView)?.shownHeight ?? 17)
    }

    override func layout() {
        super.layout()
        guard bounds.width != measuredWidth else { return }
        measuredWidth = bounds.width
        invalidateIntrinsicContentSize()
    }
}
