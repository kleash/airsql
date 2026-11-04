import AirSQLCore
import AppKit

/// Copying a grid's selection (grid-spec §6), which `GridViewer` does for every grid: ⌘C in the format last chosen in
/// Copy As (TSV at first), ⌥⌘C with the column names first, Copy As ▸ every format. Values are whole (never shortened);
/// the SQL formats name the table they come from. View As ▸ Text shows the rows in the same format.
@MainActor
enum GridCopy {
    private static let formatKey = "gridCopyFormat"

    /// ⌘C's format: the last one chosen in Copy As.
    static var format: CopyFormat {
        get { UserDefaults.standard.string(forKey: formatKey).flatMap(CopyFormat.init(rawValue:)) ?? .tsv }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: formatKey) }
    }

    /// The rows and the source columns (in display order) the selection covers: every row of a selected column, every
    /// column of a selected row; the focused cell when nothing is selected.
    static func covered(_ grid: DataGridView) -> (rows: [Int], columns: [Int]) {
        var rows = IndexSet(), columns = IndexSet()
        let allRows = 0..<grid.rowCount, allColumns = 0..<grid.columnCount
        func clip(_ range: ClosedRange<Int>, _ all: Range<Int>) -> Range<Int> {
            let low = max(range.lowerBound, all.lowerBound), high = min(range.upperBound + 1, all.upperBound)
            return low..<max(low, high)
        }
        for area in grid.selection.areas {
            switch area {
            case .cells(let r, let c):
                rows.insert(integersIn: clip(r, allRows))
                columns.insert(integersIn: clip(c, allColumns))
            case .rows(let r):
                rows.insert(integersIn: clip(r, allRows))
                columns.insert(integersIn: allColumns)
            case .columns(let c):
                rows.insert(integersIn: allRows)
                columns.insert(integersIn: clip(c, allColumns))
            case .all:
                rows.insert(integersIn: allRows)
                columns.insert(integersIn: allColumns)
            }
        }
        if rows.isEmpty, let cursor = grid.selection.cursor, allRows.contains(cursor.row), allColumns.contains(cursor.column) {
            rows.insert(cursor.row)
            columns.insert(cursor.column)
        }
        return (Array(rows), columns.map(grid.sourceColumn))
    }

    /// `rows` by `columns` (source columns, in the order given) of `source` as text in `format`, whole values.
    static func text(_ source: GridSource, rows: [Int], columns: [Int], format: CopyFormat, headers: Bool, nullText: String,
                     database: String? = nil, table: String = "table", noBackslashEscapes: Bool = false,
                     selected: ((Int, Int) -> Bool)? = nil) -> String {
        var options = CopyOptions(headers: headers, nullText: format == .tsv || format == .csv ? nullText : "NULL")
        options.noBackslashEscapes = noBackslashEscapes
        // UPDATE and DELETE need the whole key, copied or not: part of one addresses more rows than were selected.
        let columns = format == .update || format == .delete
            ? columns + source.columns.indices.filter { source.columns[$0].isKey && !columns.contains($0) } : columns
        var written = columns.map { source.columns[$0] }
        // A result's flags mark part of a composite key too: only the tables it can edit have their whole key in it.
        if let editing = (source as? ResultEditSource)?.editing {
            for (index, column) in columns.enumerated() {
                written[index].isKey = editing.sources.contains { $0.keyColumns.contains(column) }
            }
        }
        var writer = CopyWriter(format, columns: written, database: database, table: table, options: options)
        var text = writer.header()
        // Cells of the block that weren't selected stay empty in a table of text; a statement or object needs its row whole.
        let holes = format == .tsv || format == .csv ? selected : nil
        for row in rows { text += writer.row(columns.map { holes?(row, $0) == false ? "" : source.value(row, $0) }) }
        return text + writer.footer()
    }

    /// Puts the cells the grid's selection covers on the pasteboard, read from `source` (in the grid's coordinates);
    /// beeps when nothing is selected.
    static func copy(_ grid: DataGridView, source: GridSource, format: CopyFormat, headers: Bool = false, database: String? = nil,
                     table: String = "table", noBackslashEscapes: Bool = false) {
        let (rows, columns) = covered(grid)
        guard !rows.isEmpty, !columns.isEmpty else { return NSSound.beep() }
        let shown = Dictionary(uniqueKeysWithValues: (0..<grid.columnCount).map { (grid.sourceColumn($0), $0) })
        let areas = grid.selection.areas
        let text = text(source, rows: rows, columns: columns, format: format, headers: headers, nullText: grid.nullText,
                        database: database, table: table, noBackslashEscapes: noBackslashEscapes) { row, column in
            areas.isEmpty || shown[column].map { grid.selection.contains(GridPosition(row: row, column: $0)) } ?? true
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Copy As ▸ every format, the current one ticked; each item sends `copyAs:` with its format's raw value.
    static func copyAsItem() -> NSMenuItem {
        let items = CopyFormat.allCases.map { format -> NSMenuItem in
            let item = Commands.copyAs.item()
            item.title = format.title
            item.representedObject = format.rawValue
            item.state = format == self.format ? .on : .off
            item.toolTip = "Copy the selected cells as \(format.title); it becomes ⌘C's format"
            return item
        }
        return MainMenu.submenu("Copy As", items, delegate: CopyAsTicks.shared)
    }

    /// The format a Copy As item stands for.
    static func format(of sender: Any?) -> CopyFormat? {
        ((sender as? NSMenuItem)?.representedObject as? String).flatMap(CopyFormat.init(rawValue:))
    }
}

/// Ticks ⌘C's format in a Copy As menu as it opens (the format changes from any grid).
@MainActor
final class CopyAsTicks: NSObject, NSMenuDelegate {
    static let shared = CopyAsTicks()

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            item.state = GridCopy.format(of: item) == GridCopy.format ? .on : .off
        }
    }
}
