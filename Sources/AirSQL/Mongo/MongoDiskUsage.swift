import AirSQLCore
import AppKit

/// Disk Usage of a MongoDB server (mongo-plan, Phase 2 "host"), as the MySQL one (`DiskUsageContent`) shows it: sorted
/// bars of the space on disk. The server lists its databases (dbStats); a double-click goes into a database's
/// collections (`$collStats`' storageStats). Read one at a time on a session of its own, each row as it comes.
@MainActor
final class MongoDiskUsageContent: NSViewController, TabContent, NSMenuItemValidation {
    let open: OpenMongoConnection
    /// nil: the server's databases.
    private(set) var database: String?
    private(set) var found: [(row: DiskUsageRow, uncompressed: Int?)] = []
    private var problems: [String] = []
    private let heading = label("", font: .systemFont(ofSize: 15, weight: .semibold), truncates: true)
    private let notice = label("Sizes are what WiredTiger keeps on disk, compressed; only what this login can see.",
                               font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, truncates: true)
    let summary = label("", font: .systemFont(ofSize: 11.5), truncates: true)
    private let spinner = NSProgressIndicator()
    private(set) lazy var back = button("Back", id: "mongoDisk.back", tip: "Go back to the server's databases", target: self,
                                        action: #selector(goUp(_:))).onBar("chevron.left")
    private(set) lazy var refreshButton = button("Refresh", id: "mongoDisk.refresh", tip: Commands.refresh.tipWithShortcut, target: self,
                                                 action: #selector(refresh(_:))).onBar("arrow.clockwise")
    private(set) lazy var list = HostList(
        name: "Mongo Disk Usage",
        columns: [
            .init(id: "name", title: "Name", width: 120, tip: "The database or collection"),
            .init(id: "bar", title: "Space", width: 100, tip: "Documents, indexes and free space on disk, against the largest row", bar: true),
            .init(id: "total", title: "Size", width: 66, numeric: true, tip: "Documents plus indexes on disk"),
            .init(id: "share", title: "Share", width: 52, numeric: true, tip: "Its part of the size of all the rows listed"),
            .init(id: "data", title: "Documents", width: 72, numeric: true, tip: "Space its documents take on disk, compressed"),
            .init(id: "index", title: "Indexes", width: 64, numeric: true, tip: "Space its indexes take on disk"),
            .init(id: "free", title: "Free", width: 56, numeric: true, tip: "Space kept for reuse; compact gives it back"),
            .init(id: "uncompressed", title: "Uncompressed", width: 84, numeric: true, tip: "Its documents' size in memory, uncompressed"),
            .init(id: "rows", title: "Count", width: 60, numeric: true, tip: "How many documents"),
            .init(id: "detail", title: "Kind", width: 100, tip: "How many collections or indexes"),
        ],
        sort: NSSortDescriptor(key: "total", ascending: false), accessories: [back, refreshButton])
    private var session: MongoSession?
    private let slot = "disk-" + UUID().uuidString
    private var reading: Task<Void, Never>?

    init(_ open: OpenMongoConnection, database: String? = nil) {
        self.open = open
        self.database = database
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = SurfaceView(.content)
        root.setAccessibilityIdentifier("mongoDisk")
        heading.setAccessibilityIdentifier("mongoDisk.heading")
        notice.toolTip = notice.stringValue
        summary.setAccessibilityIdentifier("mongoDisk.summary")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Reading sizes")
        let top = NSStackView(views: [heading, spinner, NSView()])
        top.spacing = Spacing.unit
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let figures = NSStackView(views: [summary, NSView(), sizeLegend()])
        let texts = NSStackView(views: [top, notice, figures])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = Spacing.half
        texts.translatesAutoresizingMaskIntoConstraints = false
        addChild(list)
        list.view.translatesAutoresizingMaskIntoConstraints = false
        list.onOpen = { [weak self] row in if self?.database == nil { self?.show(row.key) } }
        list.onMenu = { [weak self] in self?.contextMenu() }
        list.onSelect = { [weak self] in self?.updateState() }
        [texts, list.view].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            top.widthAnchor.constraint(equalTo: texts.widthAnchor),
            figures.widthAnchor.constraint(equalTo: texts.widthAnchor),
            texts.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.double),
            texts.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.double),
            texts.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.double),
            list.view.topAnchor.constraint(equalTo: texts.bottomAnchor, constant: Spacing.unit),
            list.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        refresh(nil)
    }

    /// Shows `database`'s collections (nil: the server's databases), reading them.
    func show(_ database: String?) {
        self.database = database
        guard isViewLoaded else { return }
        list.table.deselectAll(nil)
        list.filter.stringValue = ""
        refresh(nil)
    }

    @objc func goUp(_ sender: Any?) { if database != nil { show(nil) } }

    var isReading: Bool { reading != nil }

    /// Reads the level again, one database or collection at a time; each row shows as it comes.
    @objc func refresh(_ sender: Any?) {
        reading?.cancel()
        found = []
        problems = []
        reload()
        spinner.startAnimation(nil)
        let level = database
        reading = Task { [weak self] in
            guard let self else { return }
            do {
                if session == nil { session = try await open.connection.session(.data, slot: slot) }
                guard let session else { return }
                if let level {
                    let collections = try await session.listCollections(database: level)
                        .filter { $0.kind != .view && !$0.name.hasPrefix("system.") }
                    for collection in collections where !Task.isCancelled {
                        do {
                            add(MongoHost.collection(collection.name, try await session.collectionStats(database: level, collection: collection.name)))
                        } catch {
                            problems.append("\(collection.name): \(error.localizedDescription)")
                        }
                    }
                } else {
                    let names = try await session.listDatabases().compactMap { info -> String? in
                        if case .string(let name)? = info["name"] { return name } else { return nil }
                    }
                    for name in names where !Task.isCancelled {
                        do { add(MongoHost.database(name, try await session.storageStats(database: name))) } catch {
                            problems.append("\(name): \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                problems.append(error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            spinner.stopAnimation(nil)
            reading = nil
            reload()
        }
    }

    private func add(_ row: (row: DiskUsageRow, uncompressed: Int?)) {
        guard !Task.isCancelled else { return }
        found.append(row)
        reload()
    }

    /// Shows what was read, keeping the selection and the order.
    private func reload() {
        let largest = found.map { ($0.row.total ?? 0) + ($0.row.free ?? 0) }.max() ?? 0
        let whole = found.reduce(0) { $0 + ($1.row.total ?? 0) }
        let scale = Double(max(largest, 1))
        list.show(found.map { row, uncompressed in
            var numbers: [String: Double] = [:]
            for (id, value) in [("total", row.total), ("bar", row.total), ("share", row.total), ("data", row.data), ("index", row.index),
                                ("free", row.free), ("rows", row.rows), ("uncompressed", uncompressed)] {
                if let value { numbers[id] = Double(value) }
            }
            let size = DiskUsage.size(row.total)
            return HostList.Row(key: row.name, cells: [
                "name": row.name, "detail": row.detail, "total": size, "share": DiskUsage.share(row.total, of: whole),
                "data": DiskUsage.size(row.data), "index": DiskUsage.size(row.index), "free": DiskUsage.size(row.free),
                "uncompressed": DiskUsage.size(uncompressed), "rows": row.rows?.formatted() ?? "",
                "bar": "\(size) (\(DiskUsage.size(row.data ?? 0)) documents, \(DiskUsage.size(row.index ?? 0)) indexes, "
                    + "\(DiskUsage.size(row.free ?? 0)) free)",
            ], numbers: numbers, bars: ["bar": SizeBar.Parts(data: Double(row.data ?? 0) / scale, index: Double(row.index ?? 0) / scale,
                                                             free: Double(row.free ?? 0) / scale)])
        })
        updateState()
    }

    private func updateState() {
        back.isHidden = database == nil
        heading.stringValue = "Disk Usage · " + (database ?? open.saved.displayName)
        heading.toolTip = heading.stringValue
        let what = database == nil ? "databases" : "collections; views take no space"
        list.note = reading != nil ? "reading \(found.count + 1)…"
            : problems.isEmpty ? what + (database == nil ? ": double-click one to see its collections" : "")
            : "couldn't read \(problems.count): " + problems.joined(separator: "; ")
        let chosen = Set(list.selected.map(\.key))
        let rows = found.map(\.row)
        summary.stringValue = chosen.count > 1 ? DiskUsage.summary(rows.filter { chosen.contains($0.name) })
            : "Total \(DiskUsage.size(rows.reduce(0) { $0 + ($1.total ?? 0) })), \(DiskUsage.size(rows.reduce(0) { $0 + ($1.free ?? 0) })) free"
        summary.toolTip = summary.stringValue
    }

    @objc func copyList(_ sender: Any?) { list.copyList(sender) }
    @objc func exportList(_ sender: Any?) { list.exportList(sender) }

    private func contextMenu() -> NSMenu? {
        let menu = NSMenu(title: "Disk Usage")
        menu.add([Commands.copy, Commands.copyList, Commands.exportList, nil, Commands.refresh])
        return menu
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let reason = item.action == Commands.copy.action && list.selected.isEmpty ? "Select some rows first" : nil
        item.explain(enabled: reason == nil, reason: reason)
        return reason == nil
    }

    /// The tab closes: its reading stops and its session goes.
    func shouldClose(_ answer: @escaping (Bool) -> Void) {
        reading?.cancel()
        session = nil
        let (connection, slot) = (open.connection, slot)
        Task { await connection.closeSession(.data, slot: slot) }
        answer(true)
    }
}

extension MainWindowController {
    /// Shows `database` (nil: the server) in the MongoDB connection's Disk Usage tab, made the first time.
    func showMongoDiskUsage(_ open: OpenMongoConnection, database: String?) {
        if let tab = model.allTabs.first(where: { ($0.content as? MongoDiskUsageContent)?.open === open }),
           let content = tab.content as? MongoDiskUsageContent {
            show(tab)
            content.show(database)
        } else {
            self.open(MongoDiskUsageContent(open, database: database), title: "Disk Usage", connection: open.saved.id)
        }
    }
}
