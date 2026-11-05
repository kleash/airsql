import AirSQLCore
import AppKit

/// Settings ▸ Grid: its text, how many rows load at a time and when Load All asks, how much of a long value a page reads, how NULL looks, and whether a
/// one-row result opens transposed.
final class GridPane: SettingsPaneController {
    override func build() {
        form.row("Text size", [choice(\.gridFontSize, id: "settings.gridFontSize",
                                      tip: "Choose the size of the grid's text (12 pt by default)", fontSizes)])
        form.row("Font", [choice(\.gridFontFamily, id: "settings.gridFontFamily", tip: "Choose the grid's font, or the system's",
                                 [(title: "System", value: "")] + NSFontManager.shared.availableFontFamilies.map { (title: $0, value: $0) })])
        form.row("Lines per row", [number(\.gridRowLines, id: "settings.gridRowLines",
                                          tip: "Type how many lines of a value with line breaks each row shows (1 by default)",
                                          range: 1...5, width: 60)])
        form.row("Date format", [text(\.gridDatePattern, id: "settings.gridDatePattern",
                                      tip: "Type the pattern Display As ▸ Settings' Date Format uses, such as dd/MM/yyyy HH:mm",
                                      placeholder: "yyyy-MM-dd HH:mm:ss", width: 180)])
        form.row("Rows per page", [number(\.rowsPerPage, id: "settings.rowsPerPage",
                                          tip: "Type how many rows a table or result loads at a time (1,000 by default)",
                                          range: 100...100_000, width: 90)],
                 caption: "Load More (⌥⌘↓) loads the next page.")
        form.row("Most rows in a result", [number(\.resultRowCap, id: "settings.resultRowCap",
                                                  tip: "Type how many rows a console result keeps before the statement stops (100,000 by default)",
                                                  range: 1_000...10_000_000, width: 110), label("rows")],
                 caption: "The rows are held in memory while the tab is open. Run to File has no limit.")
        form.row("Load All asks above", [number(\.loadAllAsksAbove, id: "settings.loadAllAsksAbove",
                                                tip: "Ask before loading every row of a table with more rows than this",
                                                range: 1_000...100_000_000, width: 110), label("rows")],
                 caption: "All the rows are held in memory while the tab is open.")
        form.row("Long values", [number(\.longValueLimit, id: "settings.longValueLimit",
                                        tip: "Type how many characters of a long value a table's page reads; 0 reads every value whole",
                                        range: 0...100_000_000, width: 110), label("characters")],
                 caption: "Load Full Cell reads the rest, as do editing, copying and exporting.")
        form.row("", [toggle("Open tables newest first", id: "settings.newestFirst",
                             tip: "Show a table with an AUTO_INCREMENT key from its newest row, until you sort it", \.newestFirst)],
                 caption: "A table's own sort, once you've set one, comes first.")
        form.row("NULL shown as", [text(\.nullText, id: "settings.nullText",
                                        tip: "Type how empty (NULL) values look in the grid; they are drawn in grey italics",
                                        placeholder: "NULL", width: 120)],
                 caption: "Only how it looks: an empty text is still different from NULL.")
        form.row("", [toggle("Transpose results with one row", id: "settings.transposeSingleRow",
                             tip: "Show a query result with a single row turned on its side, one line per column",
                             \.transposeSingleRow)],
                 caption: "Transpose (⌥⌘T) turns any grid back and forth.")
    }
}
