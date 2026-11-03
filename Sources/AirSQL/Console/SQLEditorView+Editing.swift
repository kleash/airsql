import AirSQLCore
import AppKit

/// The editor's line commands: comment or uncomment the lines (⌘/), indent and outdent them (⌘], ⌘[, Tab and ⇧Tab
/// on several lines), and Return keeping the indentation. Each is one change that Undo takes back.
extension SQLEditorView {
    /// Puts the text in place as the starting text (not undoable), coloured.
    func setText(_ text: String) {
        string = text
        highlightAll()
        (enclosingScrollView?.verticalRulerView as? LineNumberRuler)?.fitWidth()
    }

    /// Replaces `range` with `text` as an edit the person made: undoable, coloured, reported. Selects `select` after.
    func replace(_ range: NSRange, with text: String, select: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        if let select { setSelectedRange(select) }
    }

    /// The whole lines the selection touches.
    var selectedLines: NSRange {
        let text = string as NSString
        var range = text.lineRange(for: selectedRange())
        // A selection ending at the start of a line doesn't take that line.
        let selection = selectedRange()
        if selection.length > 0, NSMaxRange(selection) == NSMaxRange(range), range.length > 0,
           NSMaxRange(selection) > range.location, text.character(at: NSMaxRange(selection) - 1) == 0x0A,
           NSMaxRange(range) < text.length {
            range = text.lineRange(for: NSRange(location: selection.location, length: selection.length - 1))
        }
        return range
    }

    /// Changes each selected line with `change` (nil: leaves it), as one edit, selecting the lines after.
    private func changeLines(_ change: ([String]) -> [String]) {
        let range = selectedLines
        let block = (string as NSString).substring(with: range)
        let endsWithNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if endsWithNewline { lines.removeLast() }
        let changed = change(lines).joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        guard changed != block else { return }
        replace(range, with: changed, select: NSRange(location: range.location, length: (changed as NSString).length))
    }

    /// Comments the lines out with "-- " at their common indentation, or takes the comment away when every line that
    /// has text is one already.
    @objc func toggleComment(_ sender: Any?) {
        changeLines { lines in
            let filled = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !filled.isEmpty else { return lines }
            let commented = filled.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
            if commented {
                return lines.map { line in
                    guard let marker = line.range(of: "--") , line[..<marker.lowerBound].allSatisfy({ $0 == " " || $0 == "\t" })
                    else { return line }
                    var after = marker.upperBound
                    if after < line.endIndex, line[after] == " " { after = line.index(after: after) }
                    return String(line[..<marker.lowerBound]) + String(line[after...])
                }
            }
            let indent = filled.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
            return lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                let index = line.index(line.startIndex, offsetBy: indent)
                return String(line[..<index]) + "-- " + String(line[index...])
            }
        }
    }

    @objc func indentLines(_ sender: Any?) {
        changeLines { $0.map { $0.isEmpty ? $0 : Self.indentUnit + $0 } }
    }

    @objc func outdentLines(_ sender: Any?) {
        changeLines { lines in
            lines.map { line in
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                return String(line.dropFirst(min(Self.indentUnit.count, line.prefix { $0 == " " }.count)))
            }
        }
    }

    override func insertTab(_ sender: Any?) {
        if (string as NSString).substring(with: selectedRange()).contains("\n") { return indentLines(sender) }
        insertText(Self.indentUnit, replacementRange: selectedRange())
    }

    override func insertBacktab(_ sender: Any?) { outdentLines(sender) }

    /// Return keeps the line's indentation.
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let line = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let indent = text.substring(with: line).prefix { $0 == " " || $0 == "\t" }
        insertText("\n" + indent, replacementRange: selectedRange())
    }

    // MARK: Drag and drop

    /// .sql files dropped on the editor open in console tabs of their own; names and text dropped from elsewhere (the
    /// tree, the helpers, other apps) go in where they are dropped, as text.
    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] { Self.sqlFiles(info) }

    /// The .sql (and .txt) files being dragged: the editor's and the main window's drops open them in console tabs.
    static func sqlFiles(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).filter { ["sql", "txt"].contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty || onDropFiles == nil ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty || onDropFiles == nil ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = droppedFiles(sender)
        guard !files.isEmpty, let onDropFiles else { return super.performDragOperation(sender) }
        onDropFiles(files)
        return true
    }

    /// The editor's menu (plan §2.12): Run Statement, Run Selection, Explain, Format SQL, Comment Lines, Cut, Copy,
    /// Paste. A right-click outside the selection moves the cursor there first, as a click would.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if !NSLocationInRange(index, selectedRange()) { setSelectedRange(NSRange(location: index, length: 0)) }
        let menu = NSMenu(title: "SQL Editor")
        menu.add([Commands.runStatement, Commands.runSelection, Commands.explain, Commands.formatSQL, Commands.toggleComment,
                  nil, Commands.cut, Commands.copy, Commands.paste])
        return menu
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(toggleComment(_:)), #selector(indentLines(_:)), #selector(outdentLines(_:)):
            return isEditable
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}
