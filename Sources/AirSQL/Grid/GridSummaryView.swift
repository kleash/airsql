import AirSQLCore
import AppKit

/// Column Summary… (grid-spec §3) in a popover under the column's header: its distinct values, NULLs, smallest and
/// largest, and its 50 most frequent values with their counts and a bar each. A table's comes from the server (all
/// rows within the filter, under a spinner); a result's from its rows in memory. In a table, a value clicked filters
/// the rows by it.
@MainActor
final class GridSummaryView: NSViewController {
    private let column: String
    private let origin: String
    private let stack = NSStackView()
    private let spinner = NSProgressIndicator()
    private(set) var summary: ColumnSummary?
    private let nullText: String
    /// Filters by a value clicked (nil is NULL); nil: the values are only shown.
    var choose: ((String?) -> Void)?

    /// `origin`: where the figures come from ("From the server, within the filter").
    init(column: String, origin: String, nullText: String) {
        self.column = column
        self.origin = origin
        self.nullText = nullText
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = .all(12)
        stack.setAccessibilityIdentifier("columnSummary")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        stack.addArrangedSubview(label("Column summary · \(column)", font: .systemFont(ofSize: 12, weight: .semibold), truncates: true))
        stack.addArrangedSubview(NSStackView(views: [spinner, label("Counting on the server…", font: .systemFont(ofSize: 11.5),
                                                                    color: .secondaryLabelColor)]))
        stack.widthAnchor.constraint(equalToConstant: 320).isActive = true
        view = stack
    }

    /// Shows the figures (or why there are none).
    func show(_ result: Result<ColumnSummary, Error>) {
        _ = view
        for view in stack.arrangedSubviews.dropFirst() { view.removeFromSuperview() }
        let small = NSFont.systemFont(ofSize: 11.5)
        switch result {
        case .failure(let error):
            stack.addArrangedSubview(label((error as? AirSQLError)?.message ?? error.localizedDescription, font: small,
                                           color: .statusBad, wraps: true))
            return
        case .success(let summary):
            self.summary = summary
            let facts = "\(summary.distinct.formatted()) distinct · \(summary.nulls.formatted()) NULL\(summary.nulls == 1 ? "" : "s") · "
                + "\(summary.rows.formatted()) row\(summary.rows == 1 ? "" : "s")"
            stack.addArrangedSubview(label(facts, font: small, color: .secondaryLabelColor))
            for (title, value) in [("Smallest", summary.minimum), ("Largest", summary.maximum)] {
                let line = label("\(title): \(value ?? nullText)", font: small, truncates: true)
                line.toolTip = value
                stack.addArrangedSubview(line)
            }
            let list = NSStackView()
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 3
            let most = max(1, summary.top.first?.count ?? 1)
            for (index, (value, count)) in summary.top.enumerated() {
                let name: NSView
                if choose != nil {
                    let shown = value.map { $0.count > 60 ? String($0.prefix(60)) + "…" : $0 } ?? "NULL"
                    let link = GridStatusView.link(value ?? nullText, id: "columnSummary.value",
                                                   tip: "Show only the rows where \(column) is \(shown)", action: #selector(chosen(_:)))
                    link.target = self
                    link.tag = index
                    link.lineBreakMode = .byTruncatingTail
                    link.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                    name = link
                } else {
                    let text = label(value ?? nullText, font: small, color: value == nil ? .dataNull : .labelColor, truncates: true)
                    text.toolTip = value
                    name = text
                }
                let number = label(count.formatted(), font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold))
                let row = NSStackView(views: [name, NSView(), number])
                let bar = NSProgressIndicator()
                bar.isIndeterminate = false
                bar.controlSize = .small
                bar.maxValue = Double(most)
                bar.doubleValue = Double(count)
                bar.toolTip = "\(count.formatted()) of \(summary.rows.formatted()) rows"
                for part in [row, bar] as [NSView] {
                    list.addArrangedSubview(part)
                    part.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                }
            }
            let scroll = NSScrollView()
            scroll.documentView = list
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            list.translatesAutoresizingMaskIntoConstraints = false
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: min(300, CGFloat(summary.top.count) * 36 + 4)).isActive = true
            stack.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            stack.addArrangedSubview(label(origin + (summary.top.count == ColumnSummary.topLimit ? " · the 50 most frequent" : ""),
                                           font: .systemFont(ofSize: 11), color: .tertiaryLabelColor, wraps: true))
        }
    }

    @objc private func chosen(_ sender: NSButton) {
        guard let summary, summary.top.indices.contains(sender.tag) else { return }
        choose?(summary.top[sender.tag].value)
    }
}
