import AirSQLCore
import AppKit

// What the table tab's bars say, and which commands it can do now (each disabled one says why).
extension TableDataController: NSMenuItemValidation {
    func updateBars() {
        guard let source else {
            bar.scope.isHidden = true
            notice.show(.problem, problem)
            status.rows.stringValue = problem == nil ? "Loading…" : ""
            for link in [status.count, status.more, status.all] { link.isHidden = true }
            return
        }
        bar.scope.isHidden = false
        let local = source.localFilter != nil
        if local {
            bar.scope.style = .neutral
            bar.scope.text = "Local · \(source.shownLoadedRows.formatted()) of \(source.loadedRows.formatted()) loaded rows"
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
            notice.show(.pending, (restored ? "Left from before AirSQL quit: " : "") + pendingSummary(source.changes))
        } else {
            notice.show(.readOnly, source.readOnlyReason.map { "Read-only. " + $0 })
        }
        let loaded = source.loadedRows.formatted()
        if !source.hasMore {
            status.rows.stringValue = "\(loaded) \(source.loadedRows == 1 ? "row" : "rows")"
        } else if let total, total.filter == source.filter {
            status.rows.stringValue = "\(loaded) of \(total.exact ? "" : "about ")\(total.rows.formatted()) rows"
        } else {
            status.rows.stringValue = "\(loaded) rows loaded"
        }
        status.count.isHidden = total?.exact == true && total?.filter == source.filter || !source.hasMore
        status.more.isHidden = !source.hasMore
        status.all.isHidden = !source.hasMore
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
        let (enabled, reason) = state(of: menuItem.action)
        menuItem.explain(enabled: enabled, reason: reason)
        if menuItem.action == Commands.copyAs.action { menuItem.state = GridCopy.format(of: menuItem) == GridCopy.format ? .on : .off }
        if menuItem.action == Commands.autoRefresh.action { menuItem.state = menuItem.tag == autoRefreshSeconds ? .on : .off }
        return enabled
    }

    /// Whether a command can run now, and why not.
    private func state(of action: Selector?) -> (Bool, String?) {
        guard let source else { return (false, "The table is still loading") }
        let readOnly = source.readOnlyReason ?? "This table can't be edited"
        let hasSelection = !GridCopy.covered(grid).rows.isEmpty
        let pending = !source.changes.isEmpty
        switch action {
        case Commands.addRow.action: return (source.key != nil, readOnly)
        case Commands.duplicateRow.action, Commands.duplicateRowWithoutKeys.action, Commands.deleteRows.action:
            return source.key == nil ? (false, readOnly) : (hasSelection, "Select the rows first")
        case Commands.setNull.action:
            let cells = selectedCells().filter { source.canEdit($0.row, $0.column) }
            if source.key == nil { return (false, readOnly) }
            if cells.isEmpty { return (false, "Select cells you can edit first") }
            return (cells.contains { source.table.columns[$0.column].nullable }, "These columns can't be NULL")
        case Commands.setDefault.action:
            if source.key == nil { return (false, readOnly) }
            return (selectedCells().contains { source.canEdit($0.row, $0.column) }, "Select cells you can edit first")
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
            return (grid.selection.cursor != nil || focusedColumn() != nil, "Select a cell first")
        case Commands.clearSort.action: return (!source.sort.isEmpty, "The rows aren't sorted")
        case Commands.clearFilter.action:
            return (!bar.filterText.isEmpty || !bar.searchField.stringValue.isEmpty, "The rows aren't filtered")
        case Commands.exportRows.action: return (source.rowCount > 0 || source.hasMore, "There are no rows to export")
        case Commands.copy.action, Commands.copyWithHeaders.action, Commands.copyAs.action, Commands.copyColumnName.action:
            return (hasSelection, "Select cells first")
        default: return (true, nil)
        }
    }
}
