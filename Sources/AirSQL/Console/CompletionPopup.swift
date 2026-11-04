import AirSQLCore
import AppKit

/// The completion list under the cursor (mockup's .pop): each suggestion with its kind and type or origin, from the
/// schema cache. The editor keeps the focus: typing narrows the list, ↑ and ↓ choose, Return or Tab inserts, Escape
/// closes. A click selects a suggestion, a double-click inserts it.
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private weak var editor: NSTextView?
    private(set) var items: [CompletionItem] = []
    /// The text the suggestions replace.
    private var range = 0..<0
    static let rowHeight: CGFloat = 22
    static let footerHeight: CGFloat = 24

    init(editor: NSTextView, id: String = "completion.list",
         footer text: String = "↩ inserts · ⎋ closes · from the schema cache: nothing is sent while you type") {
        self.editor = editor
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.setAccessibilityIdentifier(id)
        table.setAccessibilityLabel("Completions")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let footer = label(text, font: .systemFont(ofSize: 11), color: .secondaryLabelColor, truncates: true)
        footer.toolTip = footer.stringValue
        let bar = SurfaceView(.bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let box = SurfaceView(.content, radius: Radius.card, border: .separatorColor)
        for view in [scroll, bar] { box.addSubview(view) }
        bar.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: Spacing.half),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: Spacing.half),
            bar.leadingAnchor.constraint(equalTo: box.leadingAnchor), bar.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: box.bottomAnchor), bar.heightAnchor.constraint(equalToConstant: Self.footerHeight),
            footer.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -10),
            footer.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        panel.contentView = box
    }

    var isShown: Bool { panel.isVisible }
    var selected: CompletionItem? { items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil }

    /// Shows `items` (replacing `range`) under the cursor, or closes when there are none.
    func show(_ items: [CompletionItem], replacing range: Range<Int>) {
        guard !items.isEmpty, let editor, let window = editor.window else { return close() }
        self.items = items
        self.range = range
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.scrollRowToVisible(0)
        let rows = CGFloat(min(items.count, 8))
        let size = NSSize(width: 460, height: rows * Self.rowHeight + Self.footerHeight + 2 * Spacing.half)
        var caret = editor.firstRect(forCharacterRange: NSRange(location: range.lowerBound, length: 0), actualRange: nil)
        if caret.isEmpty && caret.origin == .zero { caret = window.convertToScreen(editor.convert(editor.visibleRect, to: nil)) }
        var origin = NSPoint(x: caret.minX - 6, y: caret.minY - size.height - 2)
        if let screen = window.screen?.visibleFrame, origin.y < screen.minY { origin.y = caret.maxY + 2 }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        items = []
    }

    /// ↑ or ↓.
    func move(_ step: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, table.selectedRow + step))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /// Puts the chosen suggestion in place of the word typed so far.
    func accept() {
        guard let item = selected, let editor else { return close() }
        let replaced = NSRange(range)
        close()
        guard NSMaxRange(replaced) <= (editor.string as NSString).length else { return }
        editor.insertText(item.text, replacementRange: replaced)
    }

    @objc private func doubleClicked(_ sender: Any?) { accept() }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let (letter, color) = Self.badge(item.kind)
        let badge = label(letter, font: .systemFont(ofSize: 8.5, weight: .bold), color: .white)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = color.cgColor
        badge.layer?.cornerRadius = Radius.cell
        let name = label(item.label, font: .systemFont(ofSize: 12), truncates: true)
        name.toolTip = item.label
        let detail = label(item.detail, font: .systemFont(ofSize: 11), color: .quietText, truncates: true)
        detail.toolTip = item.detail
        detail.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let rowView = NSView()
        for view in [badge, name, detail] { rowView.addSubview(view) }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 10),
            badge.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 16), badge.heightAnchor.constraint(equalToConstant: 15),
            name.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: Spacing.unit),
            name.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 14),
            detail.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -10),
            detail.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
        ])
        return rowView
    }

    /// The kind's letter and colour, as the tree draws them (mockup's .ic).
    static func badge(_ kind: CompletionItem.Kind) -> (String, NSColor) {
        switch kind {
        case .join: return ("FK", .hex(0x3A7BD9))
        case .column: return ("C", .hex(0x6B7785))
        case .table, .alias: return ("T", .hex(0x3A7BD9))
        case .view: return ("V", .hex(0x8A4BAF))
        case .database: return ("DB", .hex(0x6B7785))
        case .function, .routine: return ("F", .hex(0x0A7F91))
        case .keyword: return ("K", .hex(0x9B2F8A))
        case .value: return ("=", .hex(0x2E7D4F))
        }
    }
}
