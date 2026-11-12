import AirSQLCore
import AppKit

/// A collection tab's Indexes page (mongo-plan, Indexes): each index's name, keys and options, its size from `$collStats`
/// and its use from `$indexStats`, which one member counts from when it started (or the index was made), so the caption
/// names the member. The tab reads them (`MongoCollectionController+Indexes`), with its spinner and Cancel; the bar's
/// buttons are the tab's Create, Drop and Hide commands.
@MainActor
final class MongoIndexesView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let createButton = button(Commands.createIndex.title, id: "mongo.indexes.create", tip: Commands.createIndex.tip, target: nil,
                              action: Commands.createIndex.action)
    let dropButton = button(Commands.dropIndex.title, id: "mongo.indexes.drop", tip: Commands.dropIndex.tip, target: nil,
                            action: Commands.dropIndex.action)
    let hideButton = button(Commands.hideIndex.title, id: "mongo.indexes.hide", tip: Commands.hideIndex.tip, target: nil,
                            action: Commands.hideIndex.action)
    let caption = label("", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    let table = NSTableView()
    let empty = label("", color: .secondaryLabelColor, wraps: true)
    /// The selection changed: the tab brings its buttons up to date.
    var selectionChanged: (() -> Void)?
    private(set) var indexes: [MongoIndex] = []
    /// The index to select when they next show (one just made, or double-clicked in the tree).
    var wanted: String?

    private static let columns: [(id: String, title: String, width: CGFloat, tip: String)] = [
        ("name", "Name", 140, "The index's name; Drop Index… and hint name it"),
        ("keys", "Keys", 180, "The fields it orders by: 1 ascending, -1 descending, or its kind (text, 2dsphere, hashed)"),
        ("options", "Options", 200, "Unique, sparse, TTL (expires documents), partial filter, collation, hidden"),
        ("size", "Size", 70, "Its size on disk, from $collStats"),
        ("ops", "Uses", 70, "How many operations used it on the member named below, since the date beside it"),
        ("since", "Since", 150, "When that member began counting: its restart, or the index's creation"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("mongo.indexes")
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
        table.setAccessibilityIdentifier("mongo.indexes.table")
        let menu = NSMenu(title: "Indexes")
        menu.add([Commands.dropIndex, Commands.hideIndex, nil, Commands.createIndex])
        table.menu = menu
        caption.setAccessibilityIdentifier("mongo.indexes.caption")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let top = NSStackView(views: [createButton, dropButton, hideButton, caption])
        top.spacing = Spacing.unit
        top.edgeInsets = NSEdgeInsets(top: 4, left: Spacing.double, bottom: 4, right: Spacing.double)
        top.setHuggingPriority(.defaultHigh, for: .vertical)
        let bar = SurfaceView(.bar)
        for view in [bar, top, scroll, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        empty.alignment = .center
        empty.setAccessibilityIdentifier("mongo.indexes.empty")
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

    /// The selected index; nil: none.
    var selected: MongoIndex? { indexes.indices.contains(table.selectedRow) ? indexes[table.selectedRow] : nil }

    /// Shows the indexes read, keeping the one selected (or choosing the one `wanted`), and what the caption says of them.
    func show(_ indexes: [MongoIndex], caption text: String, emptyText: String) {
        let chosen = wanted ?? selected?.name
        wanted = nil
        self.indexes = indexes
        caption.stringValue = text
        caption.toolTip = text
        empty.stringValue = emptyText
        empty.isHidden = !indexes.isEmpty
        table.reloadData()
        if let row = indexes.firstIndex(where: { $0.name == chosen }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        selectionChanged?()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { indexes.count }

    /// A cell's text; the tests read these too.
    static func text(_ index: MongoIndex, _ column: String) -> String {
        switch column {
        case "name": return index.name + (index.building ? " (building)" : "")
        case "keys": return index.keys.shellForm()
        case "options": return index.options.joined(separator: ", ")
        case "size": return index.size.map { shortSize(Int($0)) } ?? ""
        case "ops": return index.ops?.formatted() ?? ""
        case "since": return index.since?.formatted(date: .abbreviated, time: .shortened) ?? ""
        default: return ""
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let text = Self.text(indexes[row], id)
        let field = label(text, font: id == "keys" || id == "name" ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12),
                          truncates: true)
        field.alignment = id == "size" || id == "ops" ? .right : .left
        field.toolTip = text
        field.translatesAutoresizingMaskIntoConstraints = true  // the table sets its frame
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged?() }
}

/// Create Index…: the keys and options in shell form; Preview… reads them (a field that's wrong says why, under the
/// fields) and hands them on, and the tab shows the command before anything runs.
@MainActor
final class MongoIndexSheet: NSWindowController {
    let keys = textField("", placeholder: "{ field: 1, other: -1 }", id: "mongoIndex.keys",
                         tip: "The fields to index in shell form: 1 ascending, -1 descending, or \"text\", \"2dsphere\", \"hashed\"", width: 360)
    let name = textField("", placeholder: "Made from the keys", id: "mongoIndex.name", tip: "The index's name; empty: made from its keys",
                         width: 360)
    let unique = checkbox("Unique", id: "mongoIndex.unique", tip: "Refuse two documents with the same keys", on: false, target: nil, action: nil)
    let sparse = checkbox("Sparse", id: "mongoIndex.sparse", tip: "Leave out documents that lack the indexed fields", on: false,
                          target: nil, action: nil)
    let hidden = checkbox("Hidden", id: "mongoIndex.hidden", tip: "Make it hidden from the query planner, kept up to date", on: false,
                          target: nil, action: nil)
    let ttl = textField("", placeholder: "Never", id: "mongoIndex.ttl",
                        tip: "Delete each document this many seconds after the date in its indexed field (a TTL index)", width: 120)
    let partial = textField("", placeholder: "{ qty: { $gt: 10 } }", id: "mongoIndex.partial",
                            tip: "Index only the documents this filter matches, in shell form", width: 360)
    let collation = textField("", placeholder: "{ locale: \"en\", strength: 2 }", id: "mongoIndex.collation",
                              tip: "How the index compares strings, in shell form; empty: the collection's", width: 360)
    let problem = label("", font: .systemFont(ofSize: 12), color: .statusBad, wraps: true)
    private let next: (_ keys: BSONDocument, _ options: BSONDocument) -> Void
    private var retainUntilClosed: MongoIndexSheet?

    /// Shows the sheet on `window`; `next` gets what to create once the fields read well.
    @discardableResult
    static func show(collection: String, on window: NSWindow, next: @escaping (BSONDocument, BSONDocument) -> Void) -> MongoIndexSheet {
        let sheet = MongoIndexSheet(collection: collection, next: next)
        window.beginSheet(sheet.window!)
        sheet.retainUntilClosed = sheet
        return sheet
    }

    private init(collection: String, next: @escaping (BSONDocument, BSONDocument) -> Void) {
        self.next = next
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 360), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = "Create Index"
        super.init(window: window)
        let heading = label("Create an Index on \(collection)", font: .systemFont(ofSize: 14, weight: .semibold), wraps: true)
        let note = label("Type the keys and options in shell form. The command shows before it runs; a big collection takes a while to "
                         + "index.", font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, wraps: true)
        for field in [keys, name, partial, collation] { field.font = .monospacedSystemFont(ofSize: 12, weight: .regular) }  // as the query bar's
        let form = Form()
        form.row("Keys", [keys])
        form.row("Name", [name])
        form.row("Options", [unique, sparse, hidden])
        form.row("Expire After", [ttl, label("seconds", font: .systemFont(ofSize: 12.5))])
        form.row("Partial Filter", [partial])
        form.row("Collation", [collation])
        let grid = form.finish()
        problem.setAccessibilityIdentifier("mongoIndex.problem")
        problem.isSelectable = true
        problem.isHidden = true
        let cancel = button("Cancel", id: "mongoIndex.cancel", tip: "Close this and make no index", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = button("Preview…", id: "mongoIndex.preview", tip: "Show the createIndexes command, to run it or not", target: self,
                        action: #selector(preview(_:)), primary: true)
        ok.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, ok])
        let stack = NSStackView(views: [heading, note, grid, problem, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: heading)
        for view in [heading, note, problem, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let root = SurfaceView(.ground)
        root.addSubview(stack)
        stack.pin(to: root, insets: NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20))
        root.widthAnchor.constraint(equalToConstant: 540).isActive = true
        window.contentView = root
        window.setContentSize(root.fittingSize)
        window.initialFirstResponder = keys
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc func preview(_ sender: Any?) {
        do {
            let made = try MongoIndex.create(keys: keys.stringValue, name: name.stringValue, unique: unique.state == .on,
                                             sparse: sparse.state == .on, hidden: hidden.state == .on, expireAfterSeconds: ttl.stringValue,
                                             partial: partial.stringValue, collation: collation.stringValue)
            finish()
            next(made.keys, made.options)
        } catch {
            NSSound.beep()
            problem.stringValue = "\(error)"
            problem.isHidden = false
        }
    }

    @objc func cancel(_ sender: Any?) { finish() }

    private func finish() {
        if let sheet = window, let parent = sheet.sheetParent { parent.endSheet(sheet) }
        retainUntilClosed = nil
    }
}
