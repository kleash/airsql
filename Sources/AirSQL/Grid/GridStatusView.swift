import AirSQLCore
import AppKit

/// A grid's part of the status bar (grid-spec §2–3): what the host says about its rows ("1,000 of ≈2,348,245
/// rows"), the focused cell and the selection's size ("r3 : c5 · 3 cells"), and one figure for the selected cells
/// ("Sum 6,563.95"): a click shows them all and picks the one shown; ⇧⌘C copies it.
@MainActor
final class GridStatusView: NSStackView {
    weak var viewer: GridViewer?
    let rows = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor)
    let position = label("", font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular), color: .secondaryLabelColor)
    let figure = NSButton(title: "", target: nil, action: nil)
    /// The figure shown, for every grid.
    static var shown = GridAggregate.Kind.sum
    /// The most cells the figures are worked out for: more would make the selection lag.
    static let limit = 100_000
    private(set) var aggregate: GridAggregate?

    init() {
        super.init(frame: .zero)
        spacing = 10
        translatesAutoresizingMaskIntoConstraints = false
        figure.isBordered = false
        figure.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        figure.target = self
        figure.action = #selector(showFigures(_:))
        figure.setAccessibilityIdentifier("grid.figure")
        figure.setContentCompressionResistancePriority(.required, for: .horizontal)
        rows.setAccessibilityIdentifier("grid.rows")
        position.setAccessibilityIdentifier("grid.position")
        position.toolTip = "The focused cell (row : column) and how much is selected"
        setViews([rows, position, figure], in: .leading)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Grid status")
        setAccessibilityIdentifier("grid.status")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the selection as it is now.
    func update() {
        rows.isHidden = rows.stringValue.isEmpty
        guard let grid = viewer?.grid, let source = grid.source, let cursor = grid.selection.cursor else {
            position.isHidden = true
            figure.isHidden = true
            aggregate = nil
            return
        }
        let selection = grid.selection, count = selection.cellCount(rows: grid.rowCount, columns: grid.columnCount)
        var size = "\(count.formatted()) cell\(count == 1 ? "" : "s")"
        if selection.areas.count == 1 {
            switch selection.areas[0] {
            case .rows(let r): size = "\(r.count.formatted()) row\(r.count == 1 ? "" : "s")"
            case .columns(let c): size = "\(c.count.formatted()) column\(c.count == 1 ? "" : "s")"
            default: break
            }
        }
        position.stringValue = "r\(cursor.row + 1) : c\(cursor.column + 1) · \(size)"
        position.isHidden = false
        if let cells = selection.cells(rows: grid.rowCount, columns: grid.columnCount, limit: Self.limit) {
            aggregate = GridAggregate(cells.map { source.value($0.row, grid.sourceColumn($0.column)) })
        } else {
            aggregate = nil
        }
        showFigure()
    }

    private func showFigure() {
        guard let aggregate else {
            figure.title = "Too many cells to add up"
            figure.toolTip = "Select fewer than \(Self.limit.formatted()) cells to see their sum, average and count"
            figure.isHidden = false
            return
        }
        // A sum of words falls back to the count.
        let kind = aggregate.text(Self.shown) == nil ? .count : Self.shown
        let text = "\(kind.title) \(aggregate.text(kind) ?? "")"
        figure.attributedTitle = NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.accent, .font: figure.font!])
        figure.toolTip = "Show every figure for the selected cells and choose the one shown here; ⇧⌘C copies it"
        figure.isHidden = false
    }

    /// The figure shown now, as plain text for the clipboard.
    var copyText: String? {
        guard let aggregate else { return nil }
        return aggregate.copyText(aggregate.text(Self.shown) == nil ? .count : Self.shown)
    }

    /// A borderless button in the accent colour, as the status bar's actions look ("Load more").
    static func link(_ title: String, id: String, tip: String, action: Selector?) -> NSButton {
        let link = NSButton(title: title, target: nil, action: action)
        link.isBordered = false
        link.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.accent,
                                                                              .font: NSFont.systemFont(ofSize: 11.5)])
        link.toolTip = tip
        link.setAccessibilityIdentifier(id)
        link.translatesAutoresizingMaskIntoConstraints = false
        link.setContentCompressionResistancePriority(.required, for: .horizontal)
        return link
    }

    @objc private func showFigures(_ sender: Any?) {
        guard let aggregate else { return }
        let menu = NSMenu(title: "Figures")
        for kind in GridAggregate.Kind.allCases {
            let text = aggregate.text(kind)
            let item = NSMenuItem(title: "\(kind.title)  \(text ?? "—")", action: text == nil ? nil : #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.state = kind == Self.shown ? .on : .off
            item.toolTip = text == nil ? "Only for numbers: some selected values aren't" : "Show the \(kind.title.lowercased()) here"
            menu.addItem(item)
        }
        if aggregate.nulls > 0 {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "\(aggregate.nulls.formatted()) NULL\(aggregate.nulls == 1 ? "" : "s") left out", action: nil,
                                  keyEquivalent: "")
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(Commands.copySummary.item())
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: figure.bounds.height + 4), in: figure)
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = GridAggregate.Kind(rawValue: raw) else { return }
        Self.shown = kind
        showFigure()
    }
}
