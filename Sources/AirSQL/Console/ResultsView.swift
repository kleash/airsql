import AirSQLCore
import AppKit

/// A tab under the console's editor: a result set, an EXPLAIN's plan, or the Messages (always last).
@MainActor
final class ResultTab {
    enum Content {
        case rows(ResultStore)
        case plan(table: ResultStore?, tree: String)
        /// A result compared with another result or a table (Compare With…): the rows that differ.
        case diff(DiffSource)
        case messages

        /// A result's rows, which can be compared.
        var store: ResultStore? {
            if case .rows(let store) = self { return store }
            return nil
        }
    }

    let id = UUID()
    var title: String
    var pinned = false
    let content: Content
    /// A comparison with another connection's result: agents see its rows only if they may read that connection's too.
    var otherConnection: UUID?
    /// What the bar's right end says while it is shown: "38 ms · 200 rows".
    var summary: String
    /// Made once, kept while the tab is open.
    lazy var view: NSView = makeView()
    var makeView: () -> NSView = { NSView() }

    init(title: String, content: Content, summary: String) {
        self.title = title
        self.content = content
        self.summary = summary
    }

    /// The label on its button: its name and, for rows, their size ("Result 1 · 200 × 5").
    var label: String {
        switch content {
        case .rows(let store): return title + " · \(store.rowCount.formatted())\(store.capped ? "+" : "") × \(store.columns.count)"
        case .diff(let diff): return title + " · \(diff.rowCount.formatted()) × \(diff.columns.count)"
        case .plan, .messages: return title
        }
    }
}

/// The results part of a console (mockup: result tabs on a bar, "Pin result · 38 ms · 200 rows" at its right, the
/// shown tab under it). A click shows a tab, a double-click renames it, a right-click opens its menu; while a run is
/// under way the bar's right end shows its progress, the time so far and Cancel.
@MainActor
final class ResultsView: NSView, NSTextFieldDelegate {
    private let strip = NSStackView()
    /// The tabs, scrolled sideways when more are open than fit.
    private let tabsScroll = NSScrollView()
    private let summary = label("", font: .systemFont(ofSize: 11.5), color: .tertiaryLabelColor, truncates: true)
    private let spinner = NSProgressIndicator()
    let cancelButton = AirSQL.button("Cancel", id: "console.cancel", tip: Commands.cancelQuery.tip + " (⌘.)", target: nil,
                                     action: Commands.cancelQuery.action)
    private let holder = NSView()
    private var shown: NSView?
    private(set) var buttons: [ResultTabButton] = []
    /// A tab is chosen (click), renamed (the new name), or its menu asked for (it is selected first).
    var onSelect: ((ResultTab) -> Void)?
    var onRename: ((ResultTab, String) -> Void)?
    var tabMenu: (() -> NSMenu)?
    static let barHeight: CGFloat = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        let bar = SurfaceView(.bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let line = Hairline(), topLine = Hairline()
        strip.spacing = Spacing.half
        strip.setHuggingPriority(.defaultHigh, for: .horizontal)
        strip.translatesAutoresizingMaskIntoConstraints = false
        tabsScroll.drawsBackground = false
        tabsScroll.hasHorizontalScroller = false
        tabsScroll.verticalScrollElasticity = .none
        tabsScroll.documentView = strip
        tabsScroll.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.controlSize = .small
        cancelButton.isHidden = true
        summary.setAccessibilityIdentifier("console.summary")
        holder.translatesAutoresizingMaskIntoConstraints = false
        for view in [bar, topLine, line, holder] { addSubview(view) }
        for view in [tabsScroll, spinner, summary, cancelButton] { bar.addSubview(view) }
        NSLayoutConstraint.activate([
            topLine.topAnchor.constraint(equalTo: topAnchor), topLine.heightAnchor.constraint(equalToConstant: 1),
            topLine.leadingAnchor.constraint(equalTo: leadingAnchor), topLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topLine.bottomAnchor), bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor), bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
            line.topAnchor.constraint(equalTo: bar.bottomAnchor), line.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            holder.topAnchor.constraint(equalTo: line.bottomAnchor), holder.leadingAnchor.constraint(equalTo: leadingAnchor),
            holder.trailingAnchor.constraint(equalTo: trailingAnchor), holder.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabsScroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Spacing.unit),
            tabsScroll.topAnchor.constraint(equalTo: bar.topAnchor), tabsScroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: tabsScroll.contentView.leadingAnchor),
            strip.centerYAnchor.constraint(equalTo: tabsScroll.contentView.centerYAnchor),
            spinner.leadingAnchor.constraint(greaterThanOrEqualTo: tabsScroll.trailingAnchor, constant: Spacing.unit),
            spinner.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            summary.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: Spacing.half),
            summary.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            cancelButton.leadingAnchor.constraint(equalTo: summary.trailingAnchor, constant: Spacing.unit),
            cancelButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Spacing.unit),
            cancelButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        // The summary gives way to the tabs, down to a readable part of it; past that the tabs scroll.
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let fits = tabsScroll.widthAnchor.constraint(equalTo: strip.widthAnchor)
        fits.priority = .defaultLow + 5
        let readable = summary.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        readable.priority = .defaultLow + 10
        NSLayoutConstraint.activate([fits, readable])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `tabs` on the bar, `selected` under it (`empty` when there is none).
    func show(_ tabs: [ResultTab], selected: ResultTab?, empty: NSView) {
        while buttons.count > tabs.count {
            let button = buttons.removeLast()
            strip.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        while buttons.count < tabs.count {
            let button = ResultTabButton(bar: self)
            buttons.append(button)
            strip.addArrangedSubview(button)
        }
        for (button, tab) in zip(buttons, tabs) { button.update(tab, selected: tab === selected) }
        if let button = buttons.first(where: { $0.tab === selected }) {
            layoutSubtreeIfNeeded()
            strip.scrollToVisible(button.frame)
        }
        let view = selected?.view ?? empty
        if view !== shown {
            shown?.removeFromSuperview()
            holder.addSubview(view)
            view.pin(to: holder)
            shown = view
        }
        if let selected, cancelButton.isHidden { setSummary(selected.summary) }
    }

    func setSummary(_ text: String) {
        summary.stringValue = text
        summary.toolTip = text.isEmpty ? nil : text
    }

    /// While a run is under way: the spinner, its progress and time so far, and Cancel.
    func setRunning(_ text: String?) {
        if let text {
            spinner.startAnimation(nil)
            setSummary(text)
        } else {
            spinner.stopAnimation(nil)
        }
        cancelButton.isHidden = text == nil
    }

    func clicked(_ button: ResultTabButton, count: Int) {
        guard let tab = button.tab else { return }
        onSelect?(tab)
        if count == 2, tab.content.isRenamable { button.beginRename() }
    }

    func renamed(_ button: ResultTabButton, to title: String) {
        guard let tab = button.tab else { return }
        onRename?(tab, title)
    }

    func menu(for button: ResultTabButton) -> NSMenu? {
        guard let tab = button.tab else { return nil }
        onSelect?(tab)
        return tabMenu?()
    }

    func tabButton(for tab: ResultTab) -> ResultTabButton? { buttons.first { $0.tab === tab } }
}

extension ResultTab.Content {
    /// Messages keep their name.
    var isRenamable: Bool {
        if case .messages = self { return false }
        return true
    }
}
