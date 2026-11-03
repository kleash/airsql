import AirSQLCore
import AppKit

/// The Paste Format sheet (grid-spec §5): how copied text separates its cells, writes decimals and orders dates, when
/// the guesses can't tell (or Paste with Format… asks). Each pop-up starts at the guess; what is in doubt is said first.
@MainActor
enum PasteFormatSheet {
    static func show(_ format: PasteFormat, doubts: Paste.Doubts, on window: NSWindow, paste: @escaping (PasteFormat) -> Void) {
        let separators: [(String, PasteFormat.Separator)] = [("Tabs, as spreadsheets copy", .auto), ("Commas (CSV)", .comma),
                                                              ("Semicolons", .semicolon)]
        let marks: [(String, Character)] = [("Point: 1.5", "."), ("Comma: 1,5", ",")]
        let orders: [(String, PasteFormat.DateOrder)] = [("Day, month, year: 31/12/2026", .dayMonthYear),
                                                         ("Month, day, year: 12/31/2026", .monthDayYear),
                                                         ("Year, month, day: 2026-12-31", .yearMonthDay)]
        func popUp<T: Equatable>(_ choices: [(String, T)], _ current: T, id: String, tip: String) -> NSPopUpButton {
            let button = NSPopUpButton(frame: .zero, pullsDown: false)
            button.addItems(withTitles: choices.map(\.0))
            button.selectItem(at: choices.firstIndex { $0.1 == current } ?? 0)
            button.setAccessibilityIdentifier(id)
            button.toolTip = tip
            return button
        }
        let separator = popUp(separators, format.separator == .tab ? .auto : format.separator, id: "pasteFormat.separator",
                              tip: "Choose what separates the copied cells")
        let mark = popUp(marks, format.decimalSeparator ?? ".", id: "pasteFormat.decimal", tip: "Choose how the copied numbers write decimals")
        let order = popUp(orders, format.dateOrder ?? .dayMonthYear, id: "pasteFormat.dateOrder",
                          tip: "Choose the order of day, month and year in the copied dates")
        let grid = NSGridView(views: [[label("Cells separated by:"), separator], [label("Decimal mark:"), mark], [label("Dates:"), order]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = Spacing.unit
        grid.frame.size = grid.fittingSize
        var unsure: [String] = []
        if doubts.contains(.separator) { unsure.append("the lines hold commas or semicolons but no tabs") }
        if doubts.contains(.decimalMark) { unsure.append("numbers such as 1,234 read either way") }
        if doubts.contains(.dateOrder) { unsure.append("dates such as 03/04/2026 read either way") }
        let alert = NSAlert()
        alert.messageText = "How should AirSQL read the copied cells?"
        alert.informativeText = (unsure.isEmpty ? "" : "AirSQL can't tell: " + unsure.joined(separator: "; ") + ". ")
            + "Check each choice, then paste: the cells become pending changes, which you can still look at before applying."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Paste").toolTip = "Paste the cells read this way"
        alert.addButton(withTitle: "Cancel").toolTip = "Paste nothing"
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            var chosen = format
            chosen.separator = separators[max(0, separator.indexOfSelectedItem)].1
            chosen.decimalSeparator = marks[max(0, mark.indexOfSelectedItem)].1
            chosen.dateOrder = orders[max(0, order.indexOfSelectedItem)].1
            paste(chosen)
        }
    }
}
