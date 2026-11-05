import AirSQLCore
import AppKit

/// The editor's line commands: comment or uncomment the lines (⌘/), indent and outdent them (⌘], ⌘[, Tab and ⇧Tab
/// on several lines), and Return keeping the indentation. Each is one change that Undo takes back.
extension SQLEditorView {
    /// Puts the text in place as the starting text (not undoable), coloured.
    func setText(_ text: String) {
        folds = []
        string = text
        undoManager?.removeAllActions()
        runProblem = nil
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
    func changeLines(_ change: ([String]) -> [String]) {
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
        changeLines { $0.map { $0.isEmpty ? $0 : indentUnit + $0 } }
    }

    @objc func outdentLines(_ sender: Any?) {
        changeLines { lines in
            lines.map { line in
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                return String(line.dropFirst(min(tabWidth, line.prefix { $0 == " " }.count)))
            }
        }
    }

    override func insertTab(_ sender: Any?) {
        if (string as NSString).substring(with: selectedRange()).contains("\n") { return indentLines(sender) }
        insertText(indentUnit, replacementRange: selectedRange())
    }

    override func insertBacktab(_ sender: Any?) { outdentLines(sender) }

    /// Return keeps the line's indentation, one level deeper after a bracket; between a pair the closer gets a line of its own.
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString, selection = selectedRange()
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let indent = String(text.substring(with: line).prefix { $0 == " " || $0 == "\t" })
        let opened = selection.location > 0 && text.character(at: selection.location - 1) == 0x28
            && !tokens.contains { $0.kind != .symbol && $0.range.lowerBound < selection.location && selection.location <= $0.range.upperBound }
        guard opened else { return insertText("\n" + indent, replacementRange: selection) }
        let closes = NSMaxRange(selection) < text.length && text.character(at: NSMaxRange(selection)) == 0x29
        let inner = "\n" + indent + indentUnit
        replace(selection, with: inner + (closes ? "\n" + indent : ""),
                select: NSRange(location: selection.location + (inner as NSString).length, length: 0))
    }

    /// Several values pasted between the brackets of an IN become a quoted list, and text pasted inside a 'string' is
    /// escaped for it, each as one undoable step; anything else pastes as usual (Paste Without Formatting always does).
    override func paste(_ sender: Any?) {
        if !extraCarets.isEmpty, !applyingCarets { return pasteAtEveryCaret() }
        guard let clipboard = NSPasteboard.general.string(forType: .string),
              let selection = Range(selectedRange()) else { return super.paste(sender) }
        let context = nameContext?()
        let edit = SQLInPaste.edit(pasting: clipboard, into: string, selection: selection, snapshot: context?.snapshot,
                                   database: context?.database, noBackslashEscapes: noBackslashEscapes)
            ?? SQLEditing.pastedInString(clipboard, into: string, selection: selection, noBackslashEscapes: noBackslashEscapes)
        guard let edit else { return super.paste(sender) }
        breakUndoCoalescing()
        replace(NSRange(edit.range), with: edit.text,
                select: NSRange(location: edit.range.lowerBound + (edit.text as NSString).length, length: 0))
        breakUndoCoalescing()
    }

    /// One line of the clipboard per caret when the counts match, as a copy from as many carets gives; else all of it at each.
    private func pasteAtEveryCaret() {
        guard let clipboard = NSPasteboard.general.string(forType: .string) else { return }
        let lines = clipboard.components(separatedBy: "\n")
        var pieces = lines.count == extraCarets.count + 1 ? lines : []
        atEveryCaret {
            let piece = pieces.popLast() ?? clipboard
            self.replace(self.selectedRange(), with: piece,
                         select: NSRange(location: self.selectedRange().location + (piece as NSString).length, length: 0))
        }
    }

    // MARK: Drag and drop

    /// .sql files dropped on the editor open in console tabs of their own; names and text dropped from elsewhere (the
    /// tree, the helpers, other apps) go in where they are dropped, as text.
    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] { Self.sqlFiles(info) }

    /// The files being dragged that the editor's and the main window's drops take to `openFiles`: .sql and .txt, .csv and
    /// .sql.gz.
    static func sqlFiles(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).filter { ["sql", "txt"].contains($0.pathExtension.lowercased()) || opensInSheet($0) }
    }

    /// A file for Import CSV… or Run SQL File…, not a console.
    static func opensInSheet(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".csv") || name.hasSuffix(".sql.gz")
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

    /// Go to Line… (⌃G): the line that messages name.
    @objc func goToLine(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let lines = string.utf16.reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
        askText("Go to Line", message: "Type a line number from 1 to \(lines.formatted())", placeholder: "\(lines)", action: "Go",
                id: "goToLine.text", on: window) { [weak self] text in
            guard let line = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
            self?.goTo(line: line)
        }
    }

    /// Puts the cursor at the start of the line, the nearest there is, and shows it.
    func goTo(line: Int) {
        let text = string as NSString
        var start = 0
        for _ in 1..<max(line, 1) {
            let next = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            guard next > start else { break }
            start = next
        }
        setSelectedRange(NSRange(location: start, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// The editor's menu (plan §2.12): Run Statement, Run Selection, Explain, Format SQL, Comment Lines, Edit as Table,
    /// Cut, Copy, Paste, Paste Without Formatting. A right-click outside the selection moves the cursor there first, as a click would.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if !NSLocationInRange(index, selectedRange()) { setSelectedRange(NSRange(location: index, length: 0)) }
        let menu = NSMenu(title: "SQL Editor")
        menu.add([Commands.runStatement, Commands.runSelection, Commands.explain, Commands.formatSQL, Commands.toggleComment,
                  Commands.editAsTable, nil, Commands.cut, Commands.copy, Commands.paste, Commands.pastePlain])
        return menu
    }

    /// The commands that change the text: they need an editable editor, and an agent can't choose them in a production
    /// console, where deleting a WHERE line would change what the person then runs.
    static let textCommands: Set<Selector> = [
        #selector(toggleComment(_:)), #selector(indentLines(_:)), #selector(outdentLines(_:)), #selector(duplicateLine(_:)),
        #selector(deleteLine(_:)), #selector(moveLineUp(_:)), #selector(moveLineDown(_:)), #selector(joinLines(_:)),
        #selector(sortLines(_:)), #selector(reverseLines(_:)), #selector(toggleCase(_:)), #selector(toggleBlockComment(_:)),
        #selector(completeStatement(_:)), #selector(moveStatementUp(_:)), #selector(moveStatementDown(_:)), #selector(surroundWith(_:)),
        #selector(pasteFromHistory(_:)),
    ]

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case Commands.copy.action:
            return !string.isEmpty  // with no selection, it copies the line
        case let action? where Self.textCommands.contains(action):
            return isEditable
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}
