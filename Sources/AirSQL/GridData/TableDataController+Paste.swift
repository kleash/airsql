import AirSQLCore
import AppKit

// Paste (grid-spec §5): cells copied from a spreadsheet or a grid (tab-separated, or CSV) fill the cells from the
// focused one as pending edits, numbers and dates converted as the cells write them; rows past the last loaded one, or
// all of them with Paste as New Rows, become new rows. One value over several selected cells fills them all.
extension TableDataController {
    @objc func paste(_ sender: Any?) { pasteCells(asNewRows: false) }
    @objc func pasteAsNewRows(_ sender: Any?) { pasteCells(asNewRows: true) }
    /// Paste with Format…: the Paste Format sheet first, whatever the guesses.
    @objc func pasteWithFormat(_ sender: Any?) { pasteCells(asNewRows: false, asking: true) }

    /// The clipboard's text, and whether it says it is CSV.
    private var clipboard: (text: String, csv: Bool)? {
        let board = NSPasteboard.general
        guard let text = board.string(forType: .string), !text.isEmpty else { return nil }
        return (text, board.types?.contains(NSPasteboard.PasteboardType("public.comma-separated-values-text")) == true)
    }

    /// The clipboard's cells: CSV when it says so, else split on tabs (what Excel, Numbers and grids copy).
    var clipboardCells: [[String]] {
        clipboard.map { Paste.cells($0.text, separator: $0.csv ? .comma : .auto) } ?? []
    }

    /// Numbers and dates as the cells show them; the grid's NULL text (what its copies write for NULL) is NULL.
    private var pasteFormat: PasteFormat { PasteFormat(nullText: model.data.settings.nullText) }

    /// Pastes as `chosen` says (the Paste Format sheet's choice); without it, from the guesses, asking first when they
    /// leave something in doubt or when `asking`.
    private func pasteCells(asNewRows: Bool, format chosen: PasteFormat? = nil, asking: Bool = false) {
        guard let source, editingOff == nil, !AgentGuard.refuses("The clipboard is the person's: agents can't paste. Nothing was pasted.")
        else { return NSSound.beep() }
        guard let (text, csv) = clipboard else { return NSSound.beep() }
        var format = chosen ?? pasteFormat
        if chosen == nil, csv { format.separator = .comma }
        let cells = Paste.cells(text, separator: format.separator)
        guard !cells.isEmpty else { return NSSound.beep() }
        let shown = viewer.shownColumns, focused = viewer.focusedCell
        let first = focused.flatMap { shown.firstIndex(of: $0.column) } ?? 0
        let single = !asNewRows && cells.count == 1 && cells[0].count == 1 && selectedCells().count > 1
        let targets = single ? Array(Set(selectedCells().map(\.column))).sorted()
            : Array(shown[first..<min(shown.count, first + (cells.map(\.count).max() ?? 0))])
        if chosen == nil, let window = view.window {
            let columns = targets.map { source.table.columns[$0] }
            let doubts = single ? targets.reduce(into: Paste.Doubts()) { $0.formUnion(Paste.doubts(text, cells: cells, columns: [source.table.columns[$1]],
                                                                                                    separator: format.separator)) }
                : Paste.doubts(text, cells: cells, columns: columns, separator: format.separator)
            if asking || !doubts.isEmpty {
                let guessed = Paste.guessed(cells, columns: single ? Array(columns.prefix(1)) : columns, format: format)
                return PasteFormatSheet.show(guessed, doubts: doubts, on: window) { [weak self] picked in
                    self?.pasteCells(asNewRows: asNewRows, format: picked)
                }
            }
        }
        if single {
            // One value over several cells: each takes it as its own column reads it.
            return setSelected { column in
                Paste.values(cells, columns: [source.table.columns[column]], format: format, context: self.values).values[0][0]
            }
        }
        let (values, failures) = Paste.values(cells, columns: targets.map { source.table.columns[$0] }, format: format,
                                              context: self.values)
        let start = asNewRows ? nil : focused?.row
        guard !failures.isEmpty, let window = view.window else { return fill(values, columns: targets, from: start) }
        let names = targets.map { source.columns[$0].name }
        let alert = NSAlert()
        alert.messageText = "\(failures.count.formatted()) of the copied cells can't go in their columns"
        alert.informativeText = failures.prefix(6).map { failure in
            "Row \(failure.row + 1), \(failure.column < names.count ? names[failure.column] : "past the last column"): "
                + "“\(failure.text.prefix(30))” — \(failure.reason)."
        }.joined(separator: "\n") + (failures.count > 6 ? "\n…and \((failures.count - 6).formatted()) more." : "")
            + "\n\nThe other cells can go in as pending edits; those cells stay as they are."
        alert.addButton(withTitle: "Paste the Others").toolTip = "Paste the cells that fit, leaving the others as they are"
        alert.addButton(withTitle: "Cancel").toolTip = "Paste nothing"
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.fill(values, columns: targets, from: start) }
        }
    }

    /// Puts pasted values in the rows from `start` (nil: all as new rows), one step for undo, and selects them.
    private func fill(_ values: [[PendingChanges.Value?]], columns: [Int], from start: Int?) {
        guard let source else { return }
        viewer.backToGrid(nil)
        let depth = source.changes.undoDepth
        var firstNew: UUID?
        for (offset, line) in values.enumerated() {
            let pairs = zip(columns, line).compactMap { column, value in value.map { (column, $0) } }
            if let start, start + offset < source.rowCount, source.row(start + offset) != nil {
                for (column, value) in pairs where source.canEdit(start + offset, column) {
                    source.set(value, row: start + offset, column: column)
                }
            } else {
                let id = source.changes.addRow(Dictionary(pairs.filter { source.table.columns[$0.0].generated == nil }
                    .map { (source.columns[$0.0].name, $0.1) }, uniquingKeysWith: { first, _ in first }))
                firstNew = firstNew ?? id
            }
        }
        source.changes.squashUndo(to: depth)
        changesDidChange()
        let top = start ?? firstNew.flatMap(source.index(of:)) ?? 0
        let columnsShown = grid.columnOrder
        guard let left = columns.first.flatMap(columnsShown.firstIndex(of:)), top < grid.rowCount else { return }
        let right = columns.last.flatMap(columnsShown.firstIndex(of:)) ?? left, bottom = min(grid.rowCount - 1, top + values.count - 1)
        grid.selection.select(GridPosition(row: top, column: left))
        grid.selection.select(GridPosition(row: bottom, column: right), extend: true)
        grid.reveal(grid.cellRect(GridPosition(row: top, column: left)))
        view.window?.makeFirstResponder(grid)
    }
}
