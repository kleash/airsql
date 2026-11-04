import AirSQLCore
import AppKit

// The table editor's layout: its bar (the sections, Discard, Apply), the list or the options, and the SQL under them;
// and its commands (Apply, Discard, Preview SQL, Undo, Add Row, Duplicate Row, Delete Rows).
extension TableEditorController {
    func buildView() -> NSView {
        sections.segmentStyle = .rounded
        sections.trackingMode = .selectOne
        sections.selectedSegmentBezelColor = .selectedSegment
        sections.segmentCount = Section.allCases.count
        sections.selectedSegment = 0
        sections.target = self
        sections.action = #selector(sectionChosen(_:))
        sections.setAccessibilityIdentifier("tableEditor.sections")
        sections.toolTip = "Show the table's columns, indexes, foreign keys, checks or options"
        sections.translatesAutoresizingMaskIntoConstraints = false
        // Squeezed (a long count, the spinner while applying) rather than widening the window past its minimum.
        sections.setContentCompressionResistancePriority(.init(490), for: .horizontal)
        status.style = .spinning
        status.controlSize = .small
        status.isDisplayedWhenStopped = false
        status.toolTip = "Applying the changes on the server"
        applyButton.keyEquivalent = "s"
        applyButton.keyEquivalentModifierMask = .command
        applyButton.target = self
        discardButton.target = self
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [sections, spacer, status, discardButton, applyButton, helpButton(.editors)])
        bar.spacing = Spacing.unit
        bar.edgeInsets = NSEdgeInsets(top: Spacing.unit, left: Spacing.double, bottom: Spacing.unit, right: Spacing.double)

        configureList()
        listScroll.documentView = list
        listScroll.hasVerticalScroller = true
        listScroll.hasHorizontalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.borderType = .noBorder
        for (control, symbol, name, tip, action, id) in [
            (addButton, "plus", "Add Row", Commands.addRow.tip, Commands.addRow.action, "tableEditor.add"),
            (removeButton, "minus", "Remove Rows", "Remove the selected rows from the design; they go when you apply",
             Commands.deleteRows.action, "tableEditor.remove"),
        ] {
            control.bezelStyle = .rounded
            control.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
            control.target = self
            control.action = action
            control.toolTip = tip
            control.setAccessibilityIdentifier(id)
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: 28).isActive = true
        }
        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.spacing = 0
        buttons.edgeInsets = NSEdgeInsets(top: Spacing.half, left: Spacing.unit, bottom: Spacing.half, right: Spacing.unit)
        let line = Hairline()
        for view in [listScroll, line, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            listColumn.addSubview(view)
        }
        NSLayoutConstraint.activate([
            listScroll.topAnchor.constraint(equalTo: listColumn.topAnchor),
            listScroll.leadingAnchor.constraint(equalTo: listColumn.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: listColumn.trailingAnchor),
            line.topAnchor.constraint(equalTo: listScroll.bottomAnchor), line.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: listColumn.leadingAnchor), line.trailingAnchor.constraint(equalTo: listColumn.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: line.bottomAnchor), buttons.leadingAnchor.constraint(equalTo: listColumn.leadingAnchor),
            buttons.bottomAnchor.constraint(equalTo: listColumn.bottomAnchor),
        ])
        listHolder.addSubview(listColumn)
        listColumn.pin(to: listHolder)
        options.editor = self
        listHolder.addSubview(options)
        options.pin(to: listHolder)

        sqlText.isEditable = false
        sqlText.isSelectable = true
        sqlText.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        sqlText.textContainerInset = NSSize(width: Spacing.double - 4, height: Spacing.unit)
        sqlText.isVerticallyResizable = true
        sqlText.autoresizingMask = [.width]
        sqlText.textContainer?.widthTracksTextView = true
        sqlText.drawsBackground = false
        sqlText.setAccessibilityIdentifier("tableEditor.sql")
        sqlText.toolTip = "The SQL Apply will run, kept up to date as you edit"
        let sqlScroll = NSScrollView()
        sqlScroll.documentView = sqlText
        sqlScroll.hasVerticalScroller = true
        sqlScroll.autohidesScrollers = true
        sqlScroll.drawsBackground = false
        let sqlBox = SurfaceView(.ground)
        sqlBox.addSubview(sqlScroll)
        sqlScroll.pin(to: sqlBox)

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.autosaveName = "TableEditorSplit"
        split.addArrangedSubview(listHolder)
        split.addArrangedSubview(sqlBox)
        // The list takes the room the window gains; the SQL keeps its height (about eight lines) unless dragged.
        split.setHoldingPriority(.init(250), forSubviewAt: 0)
        split.setHoldingPriority(.init(270), forSubviewAt: 1)
        listHolder.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        sqlBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        let preferred = sqlBox.heightAnchor.constraint(equalToConstant: 150)
        preferred.priority = .init(240)
        preferred.isActive = true

        let root = editorLayout(bar: bar, content: split)
        root.addSubview(overlay)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: split.topAnchor), overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        root.setAccessibilityIdentifier("tableEditor")
        updateSectionTitles()
        showSection(.columns)
        return root
    }

    @objc func sectionChosen(_ sender: NSSegmentedControl) {
        showSection(Section(rawValue: sender.selectedSegment) ?? .columns)
    }

    /// Shows a section: a list, or the options.
    func showSection(_ new: Section) {
        endEditing()
        section = new
        sections.selectedSegment = new.rawValue
        let isOptions = new == .options
        options.isHidden = !isOptions
        listColumn.isHidden = isOptions
        if isOptions { options.show(self) } else { configureList() }
        updateButtons()
    }

    func updateSectionTitles() {
        let counts = [design.columns.count, design.indexes.count, design.foreignKeys.count, design.checks.count + columnCheckRows.count]
        let names = ["Columns", "Indexes", "Foreign keys", "Checks", "Options"]
        for (index, name) in names.enumerated() {
            let count = index < counts.count && counts[index] > 0 ? " · \(counts[index])" : ""
            sections.setLabel(name + count, forSegment: index)
            sections.setWidth(0, forSegment: index)
        }
    }

    /// The SQL box: what Apply runs, why nothing would, or that nothing changed.
    func updateSQL() {
        let text: String, color: NSColor
        switch statements {
        case .success(let statements) where statements.isEmpty:
            text = "-- No changes yet: edit the columns, indexes, keys, checks or options above"
            color = .secondaryLabelColor
        case .success(let statements):
            text = "-- Will run on Apply\n" + ChangeSQL(title: "", statements: statements, connection: context.connection.id).text
            color = .labelColor
        case .failure(let error):
            text = "-- Fix this first: " + error.message
            color = .statusWarning
        }
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        sqlText.textStorage?.setAttributedString(color == .labelColor
            ? SQLPreviewSheet.coloured(text, font: font, noBackslashEscapes: server.noBackslashEscapes)
            : NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        updateButtons()
    }

    func updateButtons() {
        let reason = applyReason
        applyButton.isEnabled = reason == nil
        applyButton.toolTip = reason ?? "Show the SQL in the preview sheet, then run it on the server (⌘S)"
        discardButton.isEnabled = !isBusy && isEdited && before != nil
        discardButton.toolTip = discardButton.isEnabled ? "Throw away your changes and show the table as the server has it"
            : (isBusy ? "Wait until the server has answered" : "Nothing to discard")
        addButton.isEnabled = !isBusy && section != .options
        removeButton.isEnabled = !isBusy && section != .options && !list.selectedRowIndexes.isEmpty
        removeButton.toolTip = removeButton.isEnabled ? "Remove the selected rows from the design; they go when you apply"
            : "Select a row first"
        if isBusy { status.startAnimation(nil) } else { status.stopAnimation(nil) }
        status.isHidden = !isBusy  // out of the bar's width while idle
    }

    /// Why Apply can't run now (nil: it can).
    var applyReason: String? {
        if isBusy { return "Wait until the server has answered" }
        if context.connection.readOnly {
            return "“\(context.connection.displayName)” is read-only: turn that off in its connection settings to change anything"
        }
        switch statements {
        case .failure(let error): return "Fix this first: " + error.message
        case .success(let statements): return statements.isEmpty ? "Nothing to apply yet" : nil
        }
    }

    // MARK: Commands

    @objc func applyChanges(_ sender: Any?) { preview(run: true) }
    @objc func previewChanges(_ sender: Any?) { preview(run: true) }

    @objc func revertChanges(_ sender: Any?) {
        guard let before, !isBusy else { return }
        endEditing()
        update { $0 = before }
        reloadList()
    }

    /// Ends an edit in a cell or field (keeping it), the focus staying in the list.
    func endEditing() {
        guard let window = sections.window, window.firstResponder is NSText else { return }
        if section == .options || !window.makeFirstResponder(list) { window.makeFirstResponder(nil) }
    }

    @objc func undo(_ sender: Any?) { undo.undo() }

    @objc func redo(_ sender: Any?) { undo.redo() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        var enabled = true, reason: String?
        switch item.action {
        case Commands.apply.action?, Commands.previewChanges.action?:
            reason = applyReason
            enabled = reason == nil
        case Commands.revert.action?:
            enabled = discardButton.isEnabled
            reason = discardButton.toolTip
        case Commands.undo.action?, Commands.redo.action?:
            let isUndo = item.action == Commands.undo.action
            enabled = !isBusy && (isUndo ? undo.canUndo : undo.canRedo)
            item.title = isUndo ? (enabled ? "Undo Change" : "Undo") : (enabled ? "Redo Change" : "Redo")
            reason = isUndo ? "Nothing to undo" : "Nothing to redo"
        case Commands.addRow.action?, Commands.duplicateRow.action?, Commands.deleteRows.action?:
            enabled = !isBusy && section != .options && (item.action == Commands.addRow.action || !list.selectedRowIndexes.isEmpty)
            reason = section == .options ? "Show a list first: columns, indexes, keys or checks" : "Select a row first"
            // Off while typing: ⌘⌫ reaches the text as delete to the line's start.
            if item.action == Commands.deleteRows.action, sections.window?.firstResponder is NSText {
                enabled = false
                reason = "Finish typing in the cell first"
            }
        case Commands.moveRowsUp.action?, Commands.moveRowsDown.action?:
            enabled = canMoveRows
            reason = section == .columns ? "Select a column first" : "Show the columns first"
        case Commands.copy.action?:
            enabled = canCopyRows
            reason = section == .options ? "Show a list first: columns, indexes, keys or checks" : "Select a row first"
        case Commands.paste.action?:
            enabled = canPasteRows
            reason = "Copy rows of this list first, here or in another table"
        default:
            break
        }
        item.explain(enabled: enabled, reason: enabled ? nil : reason)
        return enabled
    }
}
