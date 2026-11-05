import AppKit

/// The tick (or cross) and the time at the end of each statement of the last run, over the editor. The marks follow the
/// text; editing a statement takes its mark away.
final class RunMarksView: NSView {
    struct Mark {
        var range: NSRange
        var failed: Bool
        var time: String
    }

    private(set) var marks: [Mark] = []
    private unowned let editor: SQLEditorView
    private var observer: NSObjectProtocol?

    init(editor: SQLEditorView) {
        self.editor = editor
        super.init(frame: editor.bounds)
        autoresizingMask = [.width, .height]
        editor.addSubview(self)
        observer = NotificationCenter.default.addObserver(forName: NSTextStorage.willProcessEditingNotification, object: editor.textStorage,
                                                          queue: nil) { [weak self] notification in
            guard let storage = notification.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            self?.textChanged(storage.editedRange, by: storage.changeInLength)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Clicks go through to the text.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    func clear() {
        marks = []
        needsDisplay = true
    }

    func add(_ range: NSRange, failed: Bool, time: String) {
        marks.append(Mark(range: range, failed: failed, time: time))
        needsDisplay = true
    }

    /// `edited`: the changed text as it is now, `delta` longer than it was.
    private func textChanged(_ edited: NSRange, by delta: Int) {
        guard !marks.isEmpty else { return }
        let end = NSMaxRange(edited) - delta  // where the edit ended in the text before it
        marks = marks.compactMap { mark in
            if NSMaxRange(mark.range) <= edited.location { return mark }
            guard mark.range.location >= end else { return nil }
            var moved = mark
            moved.range.location += delta
            return moved
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !marks.isEmpty, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        let origin = editor.textContainerOrigin
        let area = dirtyRect.intersection(bounds)
        let glyphs = layout.glyphRange(forBoundingRectWithoutAdditionalLayout: area.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let shown = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let font = NSFont.systemFont(ofSize: max(editor.fontSize - 2, 9))
        let length = (editor.string as NSString).length
        NSGraphicsContext.current?.saveGraphicsState()
        area.clip()
        // The last mark of a line is the one that shows: statements sharing a line share its end.
        var lines: [CGFloat: Mark] = [:], places: [CGFloat: CGFloat] = [:]
        for mark in marks where NSMaxRange(mark.range) <= length && mark.range.length > 0 {
            guard NSLocationInRange(NSMaxRange(mark.range) - 1, shown) else { continue }
            let line = layout.lineFragmentUsedRect(forGlyphAt: layout.glyphIndexForCharacter(at: NSMaxRange(mark.range) - 1), effectiveRange: nil)
            lines[line.minY] = mark
            places[line.minY] = line.maxX
        }
        for (top, mark) in lines {
            let color: NSColor = mark.failed ? .statusBad : .statusOK
            let text = NSAttributedString(string: (mark.failed ? "✕ " : "✓ ") + mark.time, attributes: [.font: font, .foregroundColor: color])
            let x = min((places[top] ?? 0) + origin.x + 14, bounds.maxX - text.size().width - 4)
            text.draw(at: NSPoint(x: x, y: top + origin.y + 1))
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
