import AirSQLCore
import AppKit

// What the table tab's bars say, and which commands it can do now (each disabled one says why).
extension TableDataController: NSMenuItemValidation {
    func updateBars() {
        guard let source else {
            bar.scope.isHidden = true
            notice.show(.problem, problem)
            viewer.status.rows.stringValue = problem == nil ? "Loading…" : ""
            for link in [countLink, moreLink, allLink] { link.isHidden = true }
            viewer.status.update()
            return
        }
        bar.scope.isHidden = false
        let local = source.localFilter != nil || !source.localSort.isEmpty
        if local {
            bar.scope.style = .neutral
            bar.scope.text = "Local · " + (source.localFilter == nil ? "sorted, " : "")
                + "\(source.shownLoadedRows.formatted()) of \(source.loadedRows.formatted()) loaded rows"
        } else {
            bar.scope.style = .accent
            let filtered = !source.filter.isEmpty, sorted = !source.sort.isEmpty
            bar.scope.text = "On server · " + (filtered && sorted ? "filtered, sorted" : filtered ? "filtered" : sorted ? "sorted" : "all rows")
        }
        bar.scope.toolTip = local ? "The search runs on the rows loaded so far; untick Loaded rows only to search every row"
            : "The filter and the sort run on the server, over every row of the table"
        if let problem {
            notice.show(.problem, problem)
        } else if !source.changes.isEmpty {
            notice.show(.pending, (restored ? "Kept from before: " : "") + pendingSummary(source.changes))
        } else {
            notice.show(.readOnly, editingOff.map { "Read-only. " + $0 + "." })
        }
        let loaded = source.loadedRows.formatted()
        let rows = viewer.status.rows
        if !source.hasMore {
            rows.stringValue = "\(loaded) \(source.loadedRows == 1 ? "row" : "rows")"
        } else if let total, total.filter == source.filter {
            rows.stringValue = "\(loaded) of \(total.exact ? "" : "about ")\(total.rows.formatted()) rows"
        } else {
            rows.stringValue = "\(loaded) rows loaded"
        }
        rows.toolTip = total?.exact == false && source.hasMore ? "The server's estimate: Count Exactly counts the rows" : nil
        countLink.isHidden = total?.exact == true && total?.filter == source.filter || !source.hasMore
        moreLink.isHidden = !source.hasMore
        allLink.isHidden = !source.hasMore
        viewer.status.update()
    }

    /// "3 pending changes: 1 edited row, 1 new row, 1 deleted row".
    func pendingSummary(_ changes: PendingChanges) -> String {
        let edited = changes.state.edits.keys.filter { !changes.isDeleted($0) }.count
        let parts = [(edited, "edited row"), (changes.state.inserts.count, "new row"), (changes.state.deletes.count, "deleted row")]
            .filter { $0.0 > 0 }.map { "\($0.0.formatted()) \($0.1)\($0.0 == 1 ? "" : "s")" }
        let count = changes.rowCount
        return "\(count.formatted()) pending \(count == 1 ? "change" : "changes"): " + parts.joined(separator: ", ")
            + ". Apply (⌘S) writes them in one transaction."
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let action = menuItem.action, !Self.instancesRespond(to: action), viewer.responds(to: action) {
            return viewer.validateMenuItem(menuItem)
        }
        var (enabled, reason) = state(of: menuItem.action)
        if menuItem.action == Commands.filterLess.action, GridCondition.Operator.allCases.indices.contains(menuItem.tag) {
            reason = QuickFilter.reason(GridCondition.Operator.allCases[menuItem.tag], focusedValues())
            enabled = reason == nil
        }
        menuItem.explain(enabled: enabled, reason: reason)
        if menuItem.action == Commands.autoRefresh.action { menuItem.state = menuItem.tag == autoRefreshSeconds ? .on : .off }
        return enabled
    }

    // The viewer's commands (Go to Row, Copy As, Record View…) reach it from the menu bar while the focus is in the grid
    // bar or the find bar.
    override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || viewer.responds(to: selector) }
    override func forwardingTarget(for selector: Selector!) -> Any? { viewer.responds(to: selector) ? viewer : nil }

    /// Whether a command can run now, and why not.
    private func state(of action: Selector?) -> (Bool, String?) {
        guard let source else { return (false, "The table is still loading") }
        let readOnly = editingOff ?? "This table can't be edited"
        let editable = editingOff == nil
        let hasSelection = !GridCopy.covered(grid).rows.isEmpty
        let pending = !source.changes.isEmpty
        switch action {
        case Commands.addRow.action: return (editable, readOnly)
        case Commands.duplicateRow.action, Commands.duplicateRowWithoutKeys.action, Commands.deleteRows.action:
            return !editable ? (false, readOnly) : (hasSelection, "Select the rows first")
        case Commands.setNull.action, Commands.setDefault.action, Commands.insertValue.action:
            if !editable { return (false, readOnly) }
            // The first cells tell (listing a big selection would take a while).
            let cells = viewer.selectedCells(limit: 10_000).filter { source.canEdit($0.row, $0.column) }
            if cells.isEmpty { return (false, "Select cells you can edit first") }
            guard action == Commands.setNull.action else { return (true, nil) }
            return (cells.contains { source.table.columns[$0.column].nullable }, "These columns can't be NULL")
        case Commands.relatedRows.action:
            guard let cell = viewer.focusedCell, case .loaded = source.row(cell.row) else { return (false, "Select a cell of a loaded row first") }
            return (true, nil)
        case Commands.chooseReferencedRow.action:
            if !editable { return (false, readOnly) }
            return (viewer.focusedCell.map { foreignKey($0.column) != nil } ?? false, "Select a cell of a foreign key column first")
        case Commands.pasteAsNewRows.action, #selector(paste(_:)):
            if !editable { return (false, readOnly) }
            return (NSPasteboard.general.string(forType: .string)?.isEmpty == false, "Copy some cells first")
        case Commands.apply.action, Commands.previewChanges.action, #selector(revertAllChanges(_:)):
            return (pending && loading == nil, pending ? "Wait until the rows have loaded" : "No changes are pending")
        case Commands.revert.action:
            let (keys, inserts) = selectedRows()
            let changed = !inserts.isEmpty || keys.contains { source.changes.isEdited($0) || source.changes.isDeleted($0) }
            return (changed, "The selected rows have no pending changes")
        case Commands.undo.action: return (source.changes.canUndo, "Nothing to undo")
        case Commands.redo.action: return (source.changes.canRedo, "Nothing to redo")
        case Commands.loadMore.action, Commands.loadAll.action:
            return (source.hasMore && loading == nil, source.hasMore ? "Wait until the rows have loaded" : "Every row is loaded")
        case Commands.countRows.action: return (loading == nil, "Wait until the rows have loaded")
        case Commands.filterEquals.action, Commands.filterNotEquals.action, Commands.sortAscending.action,
             Commands.sortDescending.action:
            return (viewer.focusedCell != nil || focusedColumn() != nil, "Select a cell first")
        case Commands.filterPrompt.action: return (viewer.focusedCell != nil, "Select a cell first")
        case Commands.clearSort.action: return (!source.sort.isEmpty || !source.localSort.isEmpty, "The rows aren't sorted")
        case Commands.sortColumns.action: return (!(grid.source is TransposedSource), "Leave Transpose or Record View first")
        case Commands.filterByValues.action: return (focusedColumn() != nil, "Select a cell or a column first")
        case Commands.clearFilter.action:
            return (!bar.filterText.isEmpty || !bar.searchField.stringValue.isEmpty, "The rows aren't filtered")
        case Commands.exportRows.action: return (source.rowCount > 0 || source.hasMore, "There are no rows to export")
        default: return (true, nil)
        }
    }
}
