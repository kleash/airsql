import AirSQLCore
import AppKit

/// Copying a grid's selection (grid-spec §6) for any screen that hosts one: ⌘C in the format last chosen in Copy As
/// (TSV at first), ⌥⌘C with the column names first, Copy As ▸ every format. A host gives the values whole (never
/// shortened) and, for the SQL formats, the table they come from.
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

    /// The selection as text in `format`.
    static func text(_ grid: DataGridView, format: CopyFormat, headers: Bool, value: (Int, Int) -> String?,
                     database: String? = nil, table: String = "table", noBackslashEscapes: Bool = false) -> String? {
        guard let source = grid.source else { return nil }
        let (rows, columns) = covered(grid)
        guard !rows.isEmpty, !columns.isEmpty else { return nil }
        var options = CopyOptions(headers: headers, nullText: format == .tsv || format == .csv ? grid.nullText : "NULL")
        options.noBackslashEscapes = noBackslashEscapes
        var writer = CopyWriter(format, columns: columns.map { source.columns[$0] }, database: database, table: table, options: options)
        var text = writer.header()
        for row in rows { text += writer.row(columns.map { value(row, $0) }) }
        return text + writer.footer()
    }

    /// Puts the selection on the pasteboard; beeps when nothing is selected.
    static func copy(_ grid: DataGridView, format: CopyFormat, headers: Bool = false, value: (Int, Int) -> String?,
                     database: String? = nil, table: String = "table", noBackslashEscapes: Bool = false) {
        guard let text = text(grid, format: format, headers: headers, value: value, database: database, table: table,
                              noBackslashEscapes: noBackslashEscapes) else { return NSSound.beep() }
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
