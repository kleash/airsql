import AirSQLCore
import AppKit

/// A grid's part of the status bar (grid-spec §2–3): what the host says about its rows ("1,000 of ≈2,348,245
/// rows"), the focused cell and the selection's size ("r3 : c5 · 3 cells"), and one figure for the selected cells
/// ("Sum 6,563.95"): a click shows them all and picks the one shown; ⇧⌘C copies it. When the bar is too narrow, the
/// figure steps out, then the position; the rows and the host's links always stay.
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
    /// What the selection has to show; `fit` shows it if the bar has the room.
    private var hasPosition = false, hasFigure = false
    /// Every part's width, asked of the bar above its texts, which are cut short first (250), and below its items, which
    /// step out after (StatusBarView: 260); and the parts that always stay, which the bar can't squeeze.
    private var wanted: NSLayoutConstraint!, least: NSLayoutConstraint!

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
        // Packed to the right: room asked for but not used (a part left out) stays on the left, in the bar's gap.
        setViews([rows, position, figure], in: .trailing)
        setClippingResistancePriority(NSLayoutConstraint.Priority(255), for: .horizontal)
        wanted = widthAnchor.constraint(equalToConstant: 0)
        wanted.priority = NSLayoutConstraint.Priority(255)
        least = widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        NSLayoutConstraint.activate([wanted, least])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Grid status")
        setAccessibilityIdentifier("grid.status")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the selection as it is now.
    func update() {
        rows.isHidden = rows.stringValue.isEmpty
        guard let grid = viewer?.grid, grid.source != nil, let cursor = grid.selection.cursor else {
            hasPosition = false
            hasFigure = false
            aggregate = nil
            return fit()
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
        hasPosition = true
        fit()
        // A big selection is added up once it stops changing (a drag across it would lag otherwise).
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(addUp), object: nil)
        if count <= 10_000 || count > Self.limit { addUp() } else { perform(#selector(addUp), with: nil, afterDelay: 0.2) }
    }

    /// Works out the figures for the selection now.
    @objc private func addUp() {
        guard let grid = viewer?.grid, let source = grid.source, grid.selection.cursor != nil else { return }
        if let cells = grid.selection.cells(rows: grid.rowCount, columns: grid.columnCount, limit: Self.limit) {
            let columns = Set(cells.map { grid.sourceColumn($0.column) })
            aggregate = GridAggregate(cells.map { source.value($0.row, grid.sourceColumn($0.column)) },
                                      numbers: !columns.contains { source.columns[$0].type.lowercased().hasPrefix("bit") })
        } else {
            aggregate = nil
        }
        showFigure()
    }

    private func showFigure() {
        hasFigure = true
        defer { fit() }
        guard let aggregate else {
            figure.title = "Too many cells to add up"
            figure.toolTip = "Select fewer than \(Self.limit.formatted()) cells to see their sum, average and count"
            return
        }
        // A whole column's figure is only the loaded rows' while the table has more.
        let partial = (viewer?.source as? TableDataSource)?.hasMore == true && viewer?.grid.selection.areas.contains {
            if case .columns = $0 { return true }
            return $0 == .all
        } == true
        // A sum of words falls back to the count.
        let kind = aggregate.text(Self.shown) == nil ? .count : Self.shown
        let text = "\(kind.title)\(partial ? " of loaded rows" : "") \(aggregate.text(kind) ?? "")"
        figure.attributedTitle = NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.accent, .font: figure.font!])
        figure.toolTip = "Show every figure for the selected cells and choose the one shown here; ⇧⌘C copies it"
    }

    override func layout() {
        super.layout()
        fit()
    }

    /// Asks the bar for room for every part, and shows the position and the figure if it has it (the figure goes first).
    private func fit() {
        let kept = arrangedSubviews.filter { $0 !== position && $0 !== figure && !$0.isHidden }.map(\.intrinsicContentSize.width)
        let withPosition = kept + (hasPosition ? [position.intrinsicContentSize.width] : [])
        let all = withPosition + (hasPosition && hasFigure ? [figure.intrinsicContentSize.width] : [])
        if least.constant != span(kept) { least.constant = span(kept) }
        if wanted.constant != span(all) { wanted.constant = span(all) }
        let positionFits = hasPosition && span(withPosition) <= bounds.width + 0.5
        let figureFits = positionFits && hasFigure && span(all) <= bounds.width + 0.5
        if position.isHidden == positionFits { position.isHidden = !positionFits }
        if figure.isHidden == figureFits { figure.isHidden = !figureFits }
    }

    /// The width of parts side by side.
    private func span(_ widths: [CGFloat]) -> CGFloat { widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1)) }

    /// A right-click: Copy what the status says, then the host's actions shown beside it (Count Exactly, Load More).
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Grid Status")
        let copy = Commands.copy.item()
        copy.target = self
        copy.toolTip = "Copy what the grid's status says"
        menu.addItem(copy)
        let links = arrangedSubviews.compactMap { $0 as? NSButton }.filter { $0 !== figure && !$0.isHidden && $0.action != nil }
        if !links.isEmpty { menu.addItem(.separator()) }
        for link in links {
            // As the menu bar has it ("Count Rows Exactly"), with its shortcut.
            let item = Commands.all.first { $0.action == link.action }?.item() ?? NSMenuItem(title: link.title, action: link.action, keyEquivalent: "")
            item.target = link.target
            menu.addItem(item)
        }
        return menu
    }

    /// The menu's Copy: the rows, the position and the figure, as shown.
    @objc func copy(_ sender: Any?) {
        let parts = [rows, position].filter { !$0.isHidden }.map(\.stringValue) + (figure.isHidden ? [] : [figure.title])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.filter { !$0.isEmpty }.joined(separator: " · "), forType: .string)
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
