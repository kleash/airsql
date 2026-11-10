import AirSQLCore
import AppKit

/// A collection tab's Schema page (mongo-plan, Schema): a `$sample` of the collection (100, 1,000 or 10,000
/// documents) summed up per path by `MongoSchema`: its types and their shares, how often it is null or missing, its
/// distinct and most common values, and its smallest and largest number or date. A double-click on a path finds the
/// documents that have it. The tab runs the sample (`sample`), so it has the tab's spinner and Cancel.
@MainActor
final class MongoSchemaView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let sizes = [100, 1_000, 10_000]
    let size = popup(MongoSchemaView.sizes.map { $0.formatted() + " documents" }, selected: 1, id: "mongo.schema.size",
                     tip: "How many documents the sample takes, picked at random by the server", target: nil, action: nil)
    let sampleButton = button("Sample", id: "mongo.schema.sample", tip: "Take a new random sample and sum it up", target: nil, action: nil)
    let caption = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    let table = NSTableView()
    private let empty = label("Sample the collection to see its fields: choose a size, then press Sample.", color: .secondaryLabelColor,
                              wraps: true)
    /// Asks the tab for a sample of this many documents.
    var sample: ((Int) -> Void)?
    /// A path double-clicked: the tab finds the documents that have it.
    var choose: ((String) -> Void)?
    private(set) var schema: MongoSchema?

    private static let columns: [(id: String, title: String, width: CGFloat, tip: String)] = [
        ("path", "Field", 150, "The field's path; [] stands for an array's elements"),
        ("types", "Types", 150, "The BSON types found here and their share of the values"),
        ("present", "Present", 60, "How many sampled documents hold the field"),
        ("nulls", "Null", 45, "How many of its values are null"),
        ("missing", "Missing", 60, "How many documents that could hold it don't"),
        ("distinct", "Distinct", 60, "How many different values the sample holds"),
        ("top", "Most Common", 160, "The values found most often, with their counts"),
        ("min", "Smallest", 100, "The smallest number or earliest date"),
        ("max", "Largest", 100, "The largest number or latest date"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("mongo.schema")
        size.target = self
        size.action = #selector(samplePressed(_:))
        sampleButton.target = self
        sampleButton.action = #selector(samplePressed(_:))
        caption.setAccessibilityIdentifier("mongo.schema.caption")
        for column in Self.columns {
            let made = NSTableColumn(identifier: .init(column.id))
            made.title = column.title
            made.width = column.width
            made.headerToolTip = column.tip
            table.addTableColumn(made)
        }
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.centreText(rowHeight: 24)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.setAccessibilityIdentifier("mongo.schema.table")
        table.toolTip = "Double-click a field to find the documents that have it"
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let top = NSStackView(views: [label("Sample", font: .systemFont(ofSize: 12), color: .secondaryLabelColor), size, sampleButton, caption])
        top.spacing = Spacing.unit
        top.edgeInsets = NSEdgeInsets(top: 4, left: Spacing.double, bottom: 4, right: Spacing.double)
        top.setHuggingPriority(.defaultHigh, for: .vertical)
        let bar = SurfaceView(.bar)
        for view in [bar, top, scroll, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        empty.alignment = .center
        empty.setAccessibilityIdentifier("mongo.schema.empty")
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor), top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: top.topAnchor), bar.bottomAnchor.constraint(equalTo: top.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -2 * Spacing.double),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var sampleSize: Int { Self.sizes[max(0, size.indexOfSelectedItem)] }

    @objc private func samplePressed(_ sender: Any?) { sample?(sampleSize) }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let fields = schema?.fields, fields.indices.contains(table.clickedRow) else { return }
        choose?(fields[table.clickedRow].path)
    }

    /// Shows a sample's summary (nil: none yet) and where it came from.
    func show(_ schema: MongoSchema?, caption text: String) {
        self.schema = schema
        caption.stringValue = text
        caption.toolTip = text
        empty.stringValue = schema == nil ? "Sample the collection to see its fields: choose a size, then press Sample."
            : "The sample is empty: the collection has no documents."
        empty.isHidden = schema.map { $0.documents > 0 } ?? false
        table.reloadData()
    }

    var busy = false { didSet { sampleButton.isEnabled = !busy } }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { schema?.fields.count ?? 0 }

    /// A field's cell as text; the tests read these too.
    static func text(_ field: MongoSchema.Field, _ column: String, of documents: Int) -> String {
        func percent(_ share: Double) -> String { share.formatted(.percent.precision(.fractionLength(0))) }
        switch column {
        case "path": return field.path
        case "types": return field.types.map { "\($0.name) \(percent(field.share($0.name)))" }.joined(separator: ", ")
        case "present": return field.present.formatted()
        case "nulls": return field.nulls.formatted()
        case "missing": return field.missing.formatted()
        case "distinct": return field.distinct.formatted() + (field.distinctIsExact ? "" : "+")
        case "top": return field.top.prefix(5).map { "\($0.value) (\($0.count.formatted()))" }.joined(separator: ", ")
        case "min": return (field.minNumber ?? field.minDate)?.shellForm(maxLength: 60) ?? ""
        case "max": return (field.maxNumber ?? field.maxDate)?.shellForm(maxLength: 60) ?? ""
        default: return ""
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let schema, let id = tableColumn?.identifier.rawValue else { return nil }
        let text = Self.text(schema.fields[row], id, of: schema.documents)
        let number = ["present", "nulls", "missing", "distinct"].contains(id)
        let field = label(text, font: id == "path" ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12),
                          truncates: true)
        field.alignment = number ? .right : .left
        field.toolTip = text
        field.translatesAutoresizingMaskIntoConstraints = true  // the table sets its frame
        return field
    }
}
