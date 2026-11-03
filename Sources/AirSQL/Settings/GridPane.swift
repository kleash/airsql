import AirSQLCore
import AppKit

/// Settings ▸ Grid: its text, how many rows load at a time and when Load All asks, how NULL looks, and whether a
/// one-row result opens transposed.
final class GridPane: SettingsPaneController {
    override func build() {
        form.row("Text size", [choice(\.gridFontSize, id: "settings.gridFontSize",
                                      tip: "The size of the grid's text (12 pt by default)", fontSizes)])
        form.row("Rows per page", [number(\.rowsPerPage, id: "settings.rowsPerPage",
                                          tip: "How many rows a table or result loads at a time (1,000 by default)",
                                          range: 100...100_000, width: 90)],
                 caption: "Load More (⌥⌘↓) loads the next page.")
        form.row("Load All asks above", [number(\.loadAllAsksAbove, id: "settings.loadAllAsksAbove",
                                                tip: "Ask before loading every row of a table with more rows than this",
                                                range: 1_000...100_000_000, width: 110), label("rows")],
                 caption: "All the rows are held in memory while the tab is open.")
        form.row("NULL shown as", [text(\.nullText, id: "settings.nullText",
                                        tip: "How empty (NULL) values look in the grid; they are drawn in grey italics",
                                        placeholder: "NULL", width: 120)],
                 caption: "Only how it looks: an empty text is still different from NULL.")
        form.row("", [toggle("Transpose results with one row", id: "settings.transposeSingleRow",
                             tip: "Show a console result with a single row turned on its side, one line per column",
                             \.transposeSingleRow)],
                 caption: "Transpose (⌥⌘T) turns any grid back and forth.")
    }
}
