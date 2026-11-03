import AirSQLCore
import AppKit

/// Heatmap and Highlight Equal Values (grid-spec §3): colours over the cells, worked out from the rows loaded. A number
/// column's heatmap runs from pale to strong between its smallest and largest value; one with negative and positive
/// values runs red below zero and green above (diverging); one of only 0 and 1 marks the 1s (boolean).
extension GridViewer {
    /// A column's heatmap scale.
    struct HeatScale {
        var low: Double
        var high: Double

        var diverging: Bool { low < 0 && high > 0 }
        var boolean: Bool { low == 0 && high == 1 }
    }

    /// Heatmap: on for the selected number columns (all of them with everything selected), off when they all have it.
    @objc func toggleHeatmap(_ sender: Any?) {
        guard let source else { return }
        if transposed || record != nil { transposeGrid(nil) }
        let all = grid.selection.areas.contains(.all)
        let columns = (all ? Array(source.columns.indices) : focusedColumns).filter { source.columns[$0].kind == .number }
        guard !columns.isEmpty else { return NSSound.beep() }
        if columns.allSatisfy({ heat[$0] != nil }) {
            for column in columns { heat[column] = nil }
        } else {
            for column in columns { heat[column] = scale(column) }
        }
        updateTint()
    }

    /// Highlight Equal Values: tints every cell that holds the focused cell's value.
    @objc func highlightEqualValues(_ sender: Any?) {
        highlightsEqual.toggle()
        updateTint()
    }

    /// The scales again after rows arrived.
    func rescaleHeat() {
        guard !heat.isEmpty else { return }
        for column in heat.keys { heat[column] = scale(column) }
        updateTint()
    }

    /// The smallest and largest number in a column's loaded rows (the first 100,000 looked at).
    private func scale(_ column: Int) -> HeatScale? {
        guard let source else { return nil }
        var low = Double.infinity, high = -Double.infinity
        for row in 0..<min(source.rowCount, 100_000) {
            guard let number = source.value(row, column).flatMap(Double.init), number.isFinite else { continue }
            low = min(low, number)
            high = max(high, number)
        }
        return low <= high ? HeatScale(low: low, high: high) : nil
    }

    /// Sets the grid's tint for the heatmaps and equal values shown now.
    func updateTint() {
        guard !heat.isEmpty || highlightsEqual else {
            grid.cellTint = nil
            return
        }
        let heat = heat, equal = highlightsEqual
        let accent = NSColor.accent, good = NSColor.statusOK, bad = NSColor.statusBad, same = NSColor.statusWarning
        grid.cellTint = { [weak self] row, column in
            guard let self, !transposed, record == nil, let source else { return nil }
            if equal, let cursor = grid.selection.cursor, cursor.row < source.rowCount, cursor.column < grid.columnCount {
                let focused = source.value(cursor.row, grid.sourceColumn(cursor.column))
                if focused != nil, source.value(row, column) == focused { return same.withAlphaComponent(0.28) }
            }
            guard let scale = heat[column], let number = source.value(row, column).flatMap(Double.init) else { return nil }
            if scale.boolean { return number == 1 ? good.withAlphaComponent(0.3) : nil }
            if scale.diverging {
                let reach = max(-scale.low, scale.high)
                return (number < 0 ? bad : good).withAlphaComponent(CGFloat(0.06 + 0.44 * min(1, abs(number) / reach)))
            }
            let share = scale.high > scale.low ? (number - scale.low) / (scale.high - scale.low) : 1
            return accent.withAlphaComponent(CGFloat(0.06 + 0.44 * share))
        }
    }
}
