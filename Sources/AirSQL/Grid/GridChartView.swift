import AirSQLCore
import AppKit
import Charts
import SwiftUI

/// Chart (grid-spec §3): the rows loaded (the first 10,000) as a bar, line, area, pie, scatter or histogram chart of a
/// number column, by a label column; Save as PNG keeps a picture of it. Swift Charts, in the app's colours: one series
/// in the palette's first hue, pie slices in its eight hues in a fixed order with the rest as "Other". A pie needs
/// macOS 14 (Swift Charts' SectorMark), so on macOS 13 it is off and says so.
@MainActor
final class GridChartView: NSView {
    private weak var viewer: GridViewer?
    let kind = NSPopUpButton()
    let xColumn = NSPopUpButton()
    private let xTip = "Choose the column for the labels or the x axis"
    let yColumn = NSPopUpButton()
    private let hosting = NSHostingView(rootView: GridChartBody(spec: .empty))
    private let empty = label("", font: .systemFont(ofSize: 13), color: .secondaryLabelColor, wraps: true)
    /// The source columns the pop-ups list.
    private var labels: [Int] = []
    private var numbers: [Int] = []
    private(set) var spec = GridChartSpec.empty

    init(viewer: GridViewer) {
        self.viewer = viewer
        super.init(frame: .zero)
        setAccessibilityIdentifier("grid.chart")
        kind.addItems(withTitles: GridChart.Kind.allCases.map(\.title))
        kind.toolTip = "Choose how the chart draws the values"
        kind.setAccessibilityIdentifier("chart.kind")
        kind.autoenablesItems = false
        if #unavailable(macOS 14) {
            kind.item(at: GridChart.Kind.pie.rawValue)?.isEnabled = false
            kind.item(at: GridChart.Kind.pie.rawValue)?.toolTip = "Pie charts need macOS 14 or later"
        }
        xColumn.toolTip = xTip
        xColumn.setAccessibilityIdentifier("chart.x")
        yColumn.toolTip = "Choose the number column the chart draws"
        yColumn.setAccessibilityIdentifier("chart.y")
        for popup in [kind, xColumn, yColumn] {
            popup.target = self
            popup.action = #selector(changed(_:))
            popup.controlSize = .small
            popup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            popup.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
        }
        // The chart fills the room it has, whatever SwiftUI would like.
        hosting.sizingOptions = []
        let save = button("Save as PNG…", id: "chart.save", tip: "Save a picture of the chart as a PNG file", target: self,
                          action: #selector(saveImage(_:)))
        save.controlSize = .small
        let bar = NSStackView(views: [kind, label("of", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor), yColumn,
                                      label("by", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor), xColumn, NSView(), save])
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        empty.alignment = .center
        for view in [bar, hosting, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor), bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: bar.bottomAnchor), hosting.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor), empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        fillColumns()
        update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The pop-ups' columns: every shown column for the labels, the number columns for the values; the first number
    /// column that isn't the key drawn, by the first text or date column.
    private func fillColumns() {
        guard let viewer, let source = viewer.source else { return }
        let shown = viewer.grid.columnOrder
        labels = shown
        numbers = shown.filter { source.columns[$0].kind == .number }
        xColumn.addItems(withTitles: labels.map { source.columns[$0].name })
        yColumn.addItems(withTitles: numbers.map { source.columns[$0].name })
        let y = numbers.first { !source.columns[$0].isKey } ?? numbers.first
        if let y { yColumn.selectItem(at: numbers.firstIndex(of: y)!) }
        let x = shown.first { source.columns[$0].kind == .text || source.columns[$0].kind == .date } ?? shown.first { $0 != y }
        if let x { xColumn.selectItem(at: labels.firstIndex(of: x)!) }
        let byDate = x.map { source.columns[$0].kind == .date } ?? false
        kind.selectItem(at: (byDate ? GridChart.Kind.line : .bar).rawValue)
    }

    @objc private func changed(_ sender: Any?) { update() }

    /// Draws the chart for the pop-ups' choices.
    func update() {
        guard let viewer, let source = viewer.source, !numbers.isEmpty, yColumn.indexOfSelectedItem >= 0 else {
            empty.stringValue = "A chart needs a number column, and these rows have none. Choose View As ▸ Table to see them."
            empty.isHidden = false
            hosting.isHidden = true
            return
        }
        empty.isHidden = true
        hosting.isHidden = false
        let chosen = GridChart.Kind(rawValue: kind.indexOfSelectedItem) ?? .bar
        let y = numbers[yColumn.indexOfSelectedItem], x = labels.indices.contains(xColumn.indexOfSelectedItem) ? labels[xColumn.indexOfSelectedItem] : nil
        let ys = viewer.numbers(y)
        xColumn.isEnabled = chosen != .histogram
        xColumn.toolTip = chosen == .histogram ? "Off for a histogram: its x axis is the numbers themselves" : xTip
        var points: [GridChart.Point], byDate = false, byRow = false
        switch chosen {
        case .bar, .pie:
            let names: [String?] = x.map { column in (0..<ys.count).map { source.value($0, column) } }
                ?? (0..<ys.count).map { String($0 + 1) }
            points = chosen == .pie ? GridChart.totals(labels: names, values: ys, limit: GridChart.sliceLimit)
                : GridChart.totals(labels: names, values: ys, limit: GridChart.barLimit, other: false)
        case .line, .area, .scatter:
            byDate = x.map { source.columns[$0].kind == .date } ?? false
            if byDate, let x {
                points = GridChart.series(dates: (0..<ys.count).map { source.value($0, x) }, ys: ys)
            } else {
                let xs = x.flatMap { source.columns[$0].kind == .number ? viewer.numbers($0) : nil }
                byRow = xs == nil
                points = GridChart.series(xs: xs, ys: ys)
            }
        case .histogram:
            points = GridChart.histogram(ys, bins: 20)
        }
        spec = GridChartSpec(kind: chosen, points: points,
                             x: chosen == .histogram ? source.columns[y].name : byRow ? "Row" : x.map { source.columns[$0].name } ?? "Row",
                             y: chosen == .histogram ? "Rows" : source.columns[y].name, byDate: byDate, coverage: viewer.chartCoverage)
        hosting.rootView = GridChartBody(spec: spec)
    }

    /// Save as PNG…: the chart as it looks now, at twice the screen's size, written off the main thread.
    @objc func saveImage(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, let data = pngData() else { return NSSound.beep() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(spec.y) by \(spec.x).png".replacingOccurrences(of: "/", with: "-")
        panel.message = "Save a picture of the chart"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                let result = await Task.detached { Result { try data.write(to: url, options: .atomic) } }.value
                if case .failure(let error) = result {
                    showError(error.localizedDescription, title: "AirSQL couldn't save the chart", on: window)
                }
            }
        }
    }

    /// The chart drawn as a PNG (what Save as PNG writes).
    func pngData() -> Data? {
        let size = hosting.bounds.size.width > 50 ? hosting.bounds.size : NSSize(width: 800, height: 500)
        // The ground as this view's appearance gives it, which a Dark view in a Light app isn't otherwise.
        var ground = NSColor.content
        effectiveAppearance.performAsCurrentDrawingAppearance { ground = NSColor.content.solid }
        let renderer = ImageRenderer(content: GridChartBody(spec: spec).frame(width: size.width, height: size.height)
            .padding(16).background(Color(nsColor: ground)).environment(\.colorScheme, effectiveAppearance.isDark ? .dark : .light))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// What a chart shows.
struct GridChartSpec {
    var kind: GridChart.Kind
    var points: [GridChart.Point]
    var x: String
    var y: String
    /// x is a place in time (`GridChart.seconds`), and the axis says so.
    var byDate = false
    /// What the chart leaves out of the table or result, when it does.
    var coverage: String?

    static let empty = GridChartSpec(kind: .bar, points: [], x: "", y: "")
}

/// The chart itself; hovering shows the value under the pointer.
struct GridChartBody: View {
    let spec: GridChartSpec
    @State private var hovered: GridChart.Point?

    /// The palette's first hue for one series; its eight hues, in order, for pie slices (and grey for "Other").
    static let series = Color(nsColor: .accent)
    static let slices: [Color] = [(0x2A78D6, 0x3987E5), (0xEB6834, 0xD95926), (0x1BAF7A, 0x199E70), (0xEDA100, 0xC98500),
                                  (0xE87BA4, 0xD55181), (0x008300, 0x008300), (0x6250D6, 0x9085E9), (0xE34948, 0xE66767)]
        .map { light, dark in Color(nsColor: .pair(light, dark)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hovered.map { "\($0.label): \($0.y.formatted())" } ?? caption)
                .font(.system(size: 11.5).monospacedDigit()).foregroundColor(.secondary)
            if let coverage = spec.coverage {
                Text(coverage).font(.system(size: 11.5)).foregroundColor(.secondary)
            }
            chart.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What the chart leaves out, when it does.
    private var caption: String {
        spec.kind == .bar && spec.points.count == GridChart.barLimit ? "The first \(GridChart.barLimit) labels; point at a bar for its value"
            : "Point at the chart for a value"
    }

    @ViewBuilder private var chart: some View {
        switch spec.kind {
        case .bar:
            // Labels written upwards, so long ones fit under their bars.
            Chart(spec.points) { point in
                BarMark(x: .value(spec.x, point.label), y: .value(spec.y, point.y)).foregroundStyle(Self.series).cornerRadius(4)
            }
            .chartXAxis { AxisMarks { _ in AxisValueLabel(orientation: .vertical) } }
            .chartXAxisLabel(spec.x).chartYAxisLabel(spec.y)
            .modifier(Hover(points: spec.points, axis: .label, hovered: $hovered))
        case .histogram:
            Chart(spec.points) { point in
                BarMark(xStart: .value(spec.x, point.x), xEnd: .value(spec.x, point.x + point.width), y: .value(spec.y, point.y))
                    .foregroundStyle(Self.series).cornerRadius(4)
            }
            .chartXAxisLabel(spec.x).chartYAxisLabel(spec.y).modifier(Hover(points: spec.points, axis: .bin, hovered: $hovered))
        case .line:
            Chart(spec.points) { point in
                LineMark(x: .value(spec.x, point.x), y: .value(spec.y, point.y)).foregroundStyle(Self.series)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .modifier(DateAxis(spec: spec))
            .chartXAxisLabel(spec.x).chartYAxisLabel(spec.y).modifier(Hover(points: spec.points, axis: .number, hovered: $hovered))
        case .area:
            Chart(spec.points) { point in
                AreaMark(x: .value(spec.x, point.x), y: .value(spec.y, point.y)).foregroundStyle(Self.series.opacity(0.35))
                LineMark(x: .value(spec.x, point.x), y: .value(spec.y, point.y)).foregroundStyle(Self.series)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .modifier(DateAxis(spec: spec))
            .chartXAxisLabel(spec.x).chartYAxisLabel(spec.y).modifier(Hover(points: spec.points, axis: .number, hovered: $hovered))
        case .scatter:
            Chart(spec.points) { point in
                PointMark(x: .value(spec.x, point.x), y: .value(spec.y, point.y)).foregroundStyle(Self.series).symbolSize(64)
            }
            .modifier(DateAxis(spec: spec))
            .chartXAxisLabel(spec.x).chartYAxisLabel(spec.y).modifier(Hover(points: spec.points, axis: .number, hovered: $hovered))
        case .pie:
            if #available(macOS 14, *) {
                Chart(spec.points) { point in
                    SectorMark(angle: .value(spec.y, point.y), innerRadius: .ratio(0.5), angularInset: 1.5)
                        .foregroundStyle(by: .value(spec.x, point.label))
                }
                .chartForegroundStyleScale(domain: spec.points.map(\.label),
                                           range: spec.points.map { $0.label == "Other" ? Color(nsColor: .dataNull) : Self.slices[$0.id % 8] })
            } else {
                Text("Pie charts need macOS 14 or later: choose Bar to compare the same values.").foregroundColor(.secondary)
            }
        }
    }
}

/// Writes a date chart's x axis as dates, not seconds.
private struct DateAxis: ViewModifier {
    let spec: GridChartSpec

    func body(content: Content) -> some View {
        if spec.byDate {
            let span = (spec.points.last?.x ?? 0) - (spec.points.first?.x ?? 0)
            content.chartXScale(domain: .automatic(includesZero: false)).chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(value.as(Double.self).map { GridChart.dateLabel($0, span: span) } ?? "") }
                }
            }
        } else {
            content
        }
    }
}

/// The point under the pointer: by its label (bars), its bin, or its nearest x (lines, areas, points).
private struct Hover: ViewModifier {
    enum Axis { case label, bin, number }

    let points: [GridChart.Point]
    let axis: Axis
    @Binding var hovered: GridChart.Point?

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                guard case .active(let location) = phase else { return hovered = nil }
                switch axis {
                case .label:
                    let label: String? = proxy.value(atX: location.x)
                    hovered = points.first { $0.label == label }
                case .bin:
                    let x: Double? = proxy.value(atX: location.x)
                    hovered = x.flatMap { x in points.first { x >= $0.x && x < $0.x + $0.width } }
                case .number:
                    let x: Double? = proxy.value(atX: location.x)
                    hovered = x.flatMap { x in points.min { abs($0.x - x) < abs($1.x - x) } }
                }
            }
        }
    }
}
