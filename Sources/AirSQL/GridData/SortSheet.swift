import AirSQLCore
import AppKit

/// Sort by Columns… (grid-spec §4: a sort dialog for many columns): the columns the rows sort by, in order, each
/// ascending or descending, beside the header's ⌥-click that adds a column. Sort hands back the keys; no columns at all
/// is the rows' own order.
@MainActor
final class SortSheet: NSWindowController {
    typealias Key = (column: Int, ascending: Bool)

    private let columns: [GridColumn]
    private var keys: [Key]
    private let completion: ([Key]) -> Void
    private let rows = NSStackView()
    private var addButton: NSButton!
    private var retainUntilClosed: SortSheet?

    /// Shows the sheet with the sort `keys` of `columns` (the grid's, by index) for the rows of `title`.
    static func show(columns: [GridColumn], keys: [Key], title: String, on window: NSWindow, completion: @escaping ([Key]) -> Void) {
        let sheet = SortSheet(columns: columns, keys: keys.isEmpty ? [(0, true)] : keys, title: title, completion: completion)
        sheet.retainUntilClosed = sheet
        window.beginSheet(sheet.window!)
    }

    private init(columns: [GridColumn], keys: [Key], title: String, completion: @escaping ([Key]) -> Void) {
        self.columns = columns
        self.keys = keys
        self.completion = completion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.title = "Sort \(title)"
        super.init(window: window)
        window.contentView = makeContent(title)
        showKeys()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeContent(_ title: String) -> NSView {
        let heading = label("Sort the rows of \(title) by:", font: .systemFont(ofSize: 13, weight: .semibold), truncates: true)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Spacing.unit
        rows.setAccessibilityIdentifier("sort.keys")
        addButton = button("Add Column", id: "sort.add", tip: "Sort by one more column, after those above", target: self,
                           action: #selector(addKey(_:)))
        let cancel = button("Cancel", id: "sort.cancel", tip: "Close without sorting", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = button("Sort", id: "sort.ok", tip: "Sort the rows by these columns, the first one first", target: self,
                        action: #selector(ok(_:)), primary: true)
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [helpButton(.tableData), NSView(), cancel, ok])
        let stack = NSStackView(views: [heading, rows, addButton, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.double
        stack.edgeInsets = NSEdgeInsets(top: Spacing.double, left: Spacing.double, bottom: Spacing.double, right: Spacing.double)
        for view in [heading, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Spacing.double).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 480).isActive = true
        return stack
    }

    /// One line per key: "Sort by" or "then by", the column, the direction, and buttons to move or remove it.
    private func showKeys() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let names = columns.map(\.name)
        for (index, key) in keys.enumerated() {
            let lead = label(index == 0 ? "Sort by" : "then by", color: .secondaryLabelColor)
            lead.alignment = .right
            lead.widthAnchor.constraint(equalToConstant: 56).isActive = true
            let column = popup(names, selected: key.column, id: "sort.column.\(index)", tip: "Choose the column to sort by",
                               target: self, action: #selector(columnChosen(_:)))
            column.widthAnchor.constraint(equalToConstant: 170).isActive = true
            let direction = popup(["Ascending", "Descending"], selected: key.ascending ? 0 : 1, id: "sort.direction.\(index)",
                                  tip: "Choose smallest first (ascending) or largest first (descending)", target: self,
                                  action: #selector(directionChosen(_:)))
            let up = symbolButton("chevron.up", id: "sort.up.\(index)", tip: "Move this column up: sort by it before the one above",
                                  action: #selector(moveKeyUp(_:)))
            up.isEnabled = index > 0
            let down = symbolButton("chevron.down", id: "sort.down.\(index)", tip: "Move this column down: sort by it after the one below",
                                    action: #selector(moveKeyDown(_:)))
            down.isEnabled = index < keys.count - 1
            let remove = symbolButton("minus.circle", id: "sort.remove.\(index)", tip: "Stop sorting by this column",
                                      action: #selector(removeKey(_:)))
            for control in [column, direction, up, down, remove] { control.tag = index }
            let line = NSStackView(views: [lead, column, direction, up, down, remove])
            line.spacing = Spacing.unit
            rows.addArrangedSubview(line)
        }
        if keys.isEmpty {
            rows.addArrangedSubview(label("No columns: the rows show in their own order. Add a column to sort by it.",
                                          color: .secondaryLabelColor, wraps: true))
        }
        addButton.isEnabled = keys.count < columns.count
        addButton.toolTip = addButton.isEnabled ? "Sort by one more column, after those above" : "Every column is in the sort already"
        window?.layoutIfNeeded()
        if let content = window?.contentView { window?.setContentSize(content.fittingSize) }
    }

    private func symbolButton(_ symbol: String, id: String, tip: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: self,
                              action: action)
        button.title = ""
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.setAccessibilityIdentifier(id)
        button.setAccessibilityLabel(tip)
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    @objc private func columnChosen(_ sender: NSPopUpButton) {
        let column = sender.indexOfSelectedItem
        // A column sorts once: choosing one that is already in the sort takes it from where it was.
        if let other = keys.indices.first(where: { $0 != sender.tag && keys[$0].column == column }) {
            keys[other].column = keys[sender.tag].column
        }
        keys[sender.tag].column = column
        showKeys()
    }

    @objc private func directionChosen(_ sender: NSPopUpButton) { keys[sender.tag].ascending = sender.indexOfSelectedItem == 0 }

    @objc private func moveKeyUp(_ sender: NSButton) {
        guard sender.tag > 0 else { return }
        keys.swapAt(sender.tag, sender.tag - 1)
        showKeys()
    }

    @objc private func moveKeyDown(_ sender: NSButton) {
        guard sender.tag < keys.count - 1 else { return }
        keys.swapAt(sender.tag, sender.tag + 1)
        showKeys()
    }

    @objc private func removeKey(_ sender: NSButton) {
        keys.remove(at: sender.tag)
        showKeys()
    }

    @objc private func addKey(_ sender: Any?) {
        guard let column = columns.indices.first(where: { index in !keys.contains { $0.column == index } }) else { return }
        keys.append((column, true))
        showKeys()
    }

    @objc private func cancel(_ sender: Any?) { finish(nil) }
    @objc private func ok(_ sender: Any?) { finish(keys) }

    private func finish(_ keys: [Key]?) {
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        if let keys { completion(keys) }
        retainUntilClosed = nil
    }
}
