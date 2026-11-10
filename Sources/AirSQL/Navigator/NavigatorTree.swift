import AirSQLCore
import AppKit

extension DatabaseObject.Kind {
    /// The tree's group for this kind ("Tables").
    var group: String {
        switch self {
        case .table: return "Tables"
        case .view: return "Views"
        case .sequence: return "Sequences"
        case .procedure: return "Procedures"
        case .function: return "Functions"
        case .trigger: return "Triggers"
        case .event: return "Events"
        }
    }

    /// One of them, in plain words ("view").
    var noun: String { rawValue }

    /// Its row opens to its columns and, for a table, indexes and keys.
    var hasParts: Bool { self == .table || self == .view }

    /// The letters and colour of its icon (the mockup's).
    var badge: (String, UInt32) {
        switch self {
        case .table: return ("T", 0x3A7BD9)
        case .view: return ("V", 0x8A4BAF)
        case .sequence: return ("S", 0x5B6EE0)
        case .procedure: return ("P", 0x2E9E5B)
        case .function: return ("F", 0x0A7F91)
        case .trigger: return ("Tr", 0xD9911E)
        case .event: return ("E", 0xC2577A)
        }
    }
}

/// The tree's icons: a rounded square of the kind's colour with its letters, as in the mockup.
@MainActor
enum TreeIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(_ letters: String, _ colour: UInt32) -> NSImage {
        if let image = cache[letters] { return image }
        let image = NSImage(size: NSSize(width: 15, height: 15), flipped: false) { rect in
            NSColor.hex(colour).setFill()
            rect.fill()
            let text = NSAttributedString(string: letters, attributes: [
                .font: NSFont.systemFont(ofSize: letters.count > 1 ? 7.5 : 8.5, weight: .bold), .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
            return true
        }
        cache[letters] = image
        return image
    }

    static var database: NSImage { image("DB", 0x6B7785) }
    static func of(_ kind: DatabaseObject.Kind) -> NSImage { image(kind.badge.0, kind.badge.1) }
    static var primaryKey: NSImage { image("PK", 0xD9911E) }

    static func of(_ part: TablePart) -> NSImage {
        switch part {
        case .columns: return image("C", 0x6B7785)
        case .indexes: return image("I", 0x2E9E5B)
        case .foreignKeys: return image("FK", 0x8A4BAF)
        case .checks: return image("Ck", 0x0A7F91)
        case .triggers: return of(.trigger)
        }
    }
}

/// Sizes as the tree shows them: 12 MB.
func shortSize(_ bytes: Int) -> String { DiskUsage.size(bytes) }

/// Counts as the tree shows them: 88 K, 2.4 M.
func shortCount(_ value: Int) -> String {
    switch value {
    case ..<1_000: return "\(value)"
    case ..<10_000: return String(format: "%.1f K", Double(value) / 1_000).replacingOccurrences(of: ".0 ", with: " ")
    case ..<1_000_000: return "\(value / 1_000) K"
    case ..<10_000_000: return String(format: "%.1f M", Double(value) / 1_000_000).replacingOccurrences(of: ".0 ", with: " ")
    case ..<1_000_000_000: return "\(value / 1_000_000) M"
    default: return String(format: "%.1f G", Double(value) / 1_000_000_000)
    }
}

extension SidebarController {
    /// The tree under an open connection (plan §2.7): its databases, each with its objects grouped by kind. With `text`,
    /// only the objects whose names match it, in the databases and groups that have them (a database whose name matches
    /// keeps everything). View ▸ Tree's choices apply on top.
    func tree(_ id: UUID, matching text: String, node: (SidebarNode.Kind) -> SidebarNode) -> [SidebarNode] {
        if let mongo = model.openMongo[id] { return mongoTree(mongo, matching: text, node: node) }
        guard let open = model.openConnection(id) else { return [] }
        let snapshot = open.snapshot
        guard snapshot.server != nil else {
            if !text.isEmpty { return [] }
            return [node(.message(id, open.loadError.map { "Couldn't read the schema: " + $0 } ?? "Loading the schema…"))]
        }
        let options = model.data.settings.tree, saved = model.connection(id)
        let names = NameFilter(text), databaseNames = NameFilter(databaseFilter.stringValue.trimmingCharacters(in: .whitespaces))
        let favourites = Set(saved?.favourites ?? [])
        func objects(_ kind: DatabaseObject.Kind, _ database: String, _ names: [String]) -> [SidebarNode] {
            func row(_ name: String) -> SidebarNode {
                let row = node(.object(id, DatabaseObject(kind, database, name)))
                row.children = []  // made again when it opens, from this snapshot
                return row
            }
            guard options.groupsByPrefix else { return names.map(row) }
            return TreeGrouping.groups(names).flatMap { group -> [SidebarNode] in
                guard let prefix = group.prefix else { return group.names.map(row) }
                let folded = node(.prefix(id, database, kind, prefix))
                folded.children = group.names.map(row)
                return [folded]
            }
        }
        let rows = snapshot.databases.compactMap { database -> SidebarNode? in
            guard saved?.showsDatabase(database.name) != false, databaseNames.matches(database.name) else { return nil }
            let all = text.isEmpty || names.matches(database.name)
            let narrowed = !all || options.favouritesOnly
            let groups = groups(database).compactMap { kind, found -> (DatabaseObject.Kind, [SidebarNode])? in
                guard !options.hiddenKinds.contains(kind.rawValue) else { return nil }
                let shown = found.filter { name in
                    (all || names.matches(name)) && !options.hides(name)
                        && (!options.favouritesOnly || favourites.contains(DatabaseObject(kind, database.name, name)))
                }
                if (narrowed && shown.isEmpty) || (kind == .sequence && found.isEmpty) { return nil }
                return (kind, objects(kind, database.name, shown))
            }
            guard !narrowed || !groups.isEmpty else { return nil }
            let row = node(.database(id, database.name))
            row.children = options.flat ? groups.flatMap(\.1) : groups.map { kind, objects in
                let group = node(.category(id, database.name, kind))
                group.children = objects
                return group
            }
            return row
        }
        if rows.isEmpty, text.isEmpty, options.favouritesOnly {
            return [node(.message(id, "No favourites here: point at an object and click its star")), node(.users(id))]
        }
        return text.isEmpty ? rows + [node(.users(id))] : rows
    }

    /// "3 of 12" when the connection's database filter leaves databases out of the tree.
    func shownDatabases(_ id: UUID) -> String? {
        guard let open = model.openConnection(id), let saved = model.connection(id), !saved.databaseFilter.isEmpty else { return nil }
        let all = open.snapshot.databases
        let shown = all.filter { saved.showsDatabase($0.name) }.count
        return shown == all.count ? nil : "\(shown) of \(all.count)"
    }

    private func groups(_ database: SchemaDatabase) -> [(DatabaseObject.Kind, [String])] {
        func tables(_ kind: SchemaTable.Kind) -> [String] { database.tables.filter { $0.kind == kind }.map(\.name) }
        func routines(_ kind: SchemaRoutine.Kind) -> [String] { database.routines.filter { $0.kind == kind }.map(\.name) }
        return [(.table, tables(.table)), (.view, tables(.view)), (.sequence, tables(.sequence)),
                (.procedure, routines(.procedure)), (.function, routines(.function)),
                (.trigger, database.triggers.map(\.name)), (.event, database.events.map(\.name))]
    }

    /// The rows under a table or view: a group for each thing it has, from the schema cache, or a message until that
    /// has its database's details. They join `treeNodes`, so a reload finds them to select again.
    func tableParts(_ id: UUID, _ object: DatabaseObject) -> [SidebarNode] {
        guard let open = model.openConnection(id), let database = open.snapshot.database(object.database),
              let table = database.table(object.name) else { return [] }
        guard database.detailsLoaded else {
            // Not by `treeNodes`: the same message under two tables must be two rows.
            return [SidebarNode(.message(id, open.loadError.map { "Couldn't read the schema: " + $0 } ?? "Loading the columns…"))]
        }
        func row(_ kind: SidebarNode.Kind) -> SidebarNode {
            let node = treeNodes[kind] ?? SidebarNode(kind)
            treeNodes[kind] = node
            return node
        }
        return TablePart.allCases.compactMap { part in
            var seen = Set<String>()  // an outline shows each item once
            let rows = part.rows(of: table, in: database).filter { seen.insert($0.name).inserted }
            guard !rows.isEmpty else { return nil }
            let group = row(.part(id, object, part))
            group.children = rows.map { detail in
                let node = row(.detail(id, object, part, detail.name))
                node.detail = detail
                return node
            }
            return group
        }
    }

    /// A database's largest table and total, from the sizes the schema cache has (`treeSizes` keeps them until a reload);
    /// nil: it hasn't read them.
    private func sizes(_ open: OpenConnection, _ database: String) -> (largest: Int, total: Int)? {
        let key = open.id.uuidString + database
        if let known = treeSizes[key] { return known }
        guard let statistics = open.snapshot.database(database)?.statistics else { return nil }
        let bytes = statistics.values.map(\.bytes)
        let sizes = (bytes.max() ?? 0, bytes.reduce(0, +))
        treeSizes[key] = sizes
        return sizes
    }

    /// The cell of a tree row.
    func treeCell(_ node: SidebarNode, in outlineView: NSOutlineView) -> NSView? {
        let cell = (outlineView.makeView(withIdentifier: TreeCell.identifier, owner: nil) as? TreeCell) ?? TreeCell()
        // A message shows without its connection's schema (the filter's "nothing matches" has none).
        if case .message(let id, let text) = node.kind {
            cell.showMessage(text, busy: model.openConnection(id)?.loading.contains(.schema) ?? model.openMongo[id]?.isLoading ?? false)
            return cell
        }
        if case .mongo(let id, let item) = node.kind {
            if let mongo = model.openMongo[id] { showMongo(item, of: mongo, in: cell) }
            return cell
        }
        guard let id = node.connectionOfTree, let open = model.openConnection(id) else { return cell }
        let options = model.data.settings.tree
        switch node.kind {
        case .database(_, let name):
            let current = open.currentDatabase == name
            let busy = open.loading.contains(.details(name)) || open.loading.contains(.statistics(name))
            let total = options.showsSizes ? sizes(open, name)?.total : nil
            let largest = open.snapshot.databases.compactMap { sizes(open, $0.name)?.total }.max() ?? 0
            cell.show(TreeIcon.database, name, count: total.map(shortSize) ?? "\(node.objectCount)", bold: current, busy: busy,
                      bar: total.map { CGFloat($0) / CGFloat(max(largest, 1)) } ?? 0,
                      tip: "\(name)\(current ? ", the current database" : "")\(total.map { ", " + shortSize($0) } ?? ""): "
                        + "click to see its tables, double-click to make it current, right-click for more")
        case .category(_, _, let kind):
            cell.show(TreeIcon.of(kind), kind.group, count: "\(node.children.reduce(0) { $0 + $1.objectCount })", busy: false,
                      tip: "\(kind.group): double-click to open or close, right-click for more")
        case .prefix(_, _, let kind, let prefix):
            cell.show(TreeIcon.of(kind), prefix + "…", count: "\(node.children.count)", busy: false,
                      tip: "\(kind.group) named \(prefix)…: double-click to open or close")
        case .object(_, let object):
            let database = open.snapshot.database(object.database)
            let stats = object.kind == .table ? database?.statistics?[object.name] : nil
            let rows = stats?.rows.map(shortCount) ?? ""
            let size = options.showsSizes ? stats?.bytes : nil
            let count = size.map(shortSize) ?? rows
            let action = object.kind.isTableLike ? "its data" : "its definition"
            let about = (rows.isEmpty ? "" : " of about \(rows) rows, the server's estimate") + (size.map { ", " + shortSize($0) } ?? "")
            let favourite = model.connection(id)?.favourites.contains(object) == true
            cell.show(TreeIcon.of(object.kind), object.name, count: count, busy: false,
                      bar: size.map { CGFloat($0) / CGFloat(max(sizes(open, object.database)?.largest ?? 0, 1)) } ?? 0,
                      comment: options.showsComments ? database?.comment(of: object) ?? "" : "",
                      favourite: favourite, onStar: { [weak self] in self?.setFavourite([object], !favourite, on: id) },
                      tip: "\(object.name), a \(object.kind.noun)\(about): "
                        + "click to see \(action), double-click to open it in a tab, right-click for more"
                        + (object.kind.hasParts ? ", its arrow shows its columns" + (object.kind == .table ? " and indexes" : "") : ""))
        case .part(_, let object, let part):
            cell.show(TreeIcon.of(part), part.rawValue, count: "\(node.children.count)", busy: false,
                      tip: "\(part.rawValue) of \(object.name): double-click to open or close, right-click for more")
        case .detail(_, _, let part, let name):
            cell.show(node.detail?.isKey == true ? TreeIcon.primaryKey : TreeIcon.of(part), name, count: node.detail?.note ?? "", countGivesWay: true, busy: false,
                      tip: (node.detail?.about ?? name) + "\nDouble-click to open " + (part == .triggers ? "it" : "the table's structure")
                        + ", right-click for more")
        case .users:
            cell.show(TreeIcon.image("US", 0x6B7785), "Users and Roles", count: "", busy: false,
                      tip: "The server's logins and roles: click to see them, right-click for more")
        default:
            break
        }
        return cell
    }
}

extension TableStatistics {
    /// Its data and indexes, in bytes.
    var bytes: Int { (dataLength ?? 0) + (indexLength ?? 0) }
}

extension SchemaDatabase {
    /// What the server keeps as this table's or routine's comment.
    func comment(of object: DatabaseObject) -> String {
        object.kind.isTableLike ? table(object.name)?.comment ?? "" : routines.first { $0.name == object.name }?.comment ?? ""
    }
}

extension SidebarNode {
    /// The connection of a tree row (a database, group, object or message).
    var connectionOfTree: UUID? {
        switch kind {
        case .database(let id, _), .category(let id, _, _), .object(let id, _), .part(let id, _, _), .detail(let id, _, _, _),
             .prefix(let id, _, _, _), .message(let id, _), .users(let id), .mongo(let id, _): return id
        default: return nil
        }
    }

    /// How many objects are under this row (or it, an object).
    var objectCount: Int { object != nil ? 1 : children.reduce(0) { $0 + $1.objectCount } }

    /// The database of a database, group or object row.
    var database: String? {
        switch kind {
        case .database(_, let name), .category(_, let name, _), .prefix(_, let name, _, _): return name
        case .object(_, let object), .part(_, let object, _), .detail(_, let object, _, _): return object.database
        case .mongo(_, let item): return item.database
        default: return nil
        }
    }

    var object: DatabaseObject? {
        if case .object(_, let object) = kind { return object }
        return nil
    }

    /// The table or view a row under one belongs to. Not an `object`: Drop and the like must never reach a table from
    /// its column's row.
    var owner: DatabaseObject? {
        switch kind {
        case .part(_, let object, _), .detail(_, let object, _, _): return object
        default: return nil
        }
    }

    /// What type-to-find and the drag read.
    var name: String? {
        switch kind {
        case .database(_, let name): return name
        case .category(_, _, let kind): return kind.group
        case .prefix(_, _, _, let prefix): return prefix
        case .object(_, let object): return object.name
        case .part(_, _, let part): return part.rawValue
        case .detail(_, _, _, let name): return name
        case .users: return "Users and Roles"
        case .mongo(_, let item): return item.index ?? item.collection ?? item.database
        default: return nil
        }
    }
}

/// A tree row: its icon, name (cut with an ellipsis, in full in the tooltip), a comment, a star at the edge (always on
/// a favourite, else under the pointer), a count or size with its bar behind the row, and a spinner while it loads.
final class TreeCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TreeCell")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let comment = NSTextField(labelWithString: "")
    private let star = NSButton()
    private let spinner = NSProgressIndicator()
    /// The name's colour off the selection (a message's is quieter).
    private var nameColour = NSColor.labelColor
    /// How much of the row its size bar fills, 0 to 1.
    private var bar: CGFloat = 0 { didSet { if bar != oldValue { needsDisplay = true } } }
    private var favourite = false
    private var onStar: (() -> Void)?
    private var pointerInside = false

    /// On the selection's accent: the accent's own text colour, as the mockups give it (AppKit's white is 2.4:1 on Deep
    /// Water's petrol).
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            colour()
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.required, for: .horizontal)
        comment.font = .systemFont(ofSize: 11)
        comment.lineBreakMode = .byTruncatingTail
        comment.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        comment.setContentHuggingPriority(.defaultLow, for: .horizontal)
        star.bezelStyle = .texturedRounded
        star.isBordered = false
        star.target = self
        star.action = #selector(starClicked(_:))
        star.setAccessibilityIdentifier("tree.star")
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.lineBreakMode = .byTruncatingTail
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.setContentHuggingPriority(.required, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Loading")
        let stack = NSStackView(views: [icon, name, comment, NSView(), spinner, star, count])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        textField = name
        imageView = icon
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),
            star.widthAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard bar > 0 else { return }
        let rect = NSRect(x: 0, y: 1, width: bounds.width * min(bar, 1), height: 2).intersection(bounds)
        (backgroundStyle == .emphasized ? NSColor.onAccent : NSColor.accent).withAlphaComponent(0.5).setFill()
        rect.fill()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        updateStar()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        updateStar()
    }

    private func updateStar() {
        star.isHidden = onStar == nil || !(favourite || pointerInside)
        star.image = NSImage(systemSymbolName: favourite ? "star.fill" : "star", accessibilityDescription: favourite ? "Favourite" : "Not a favourite")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        star.contentTintColor = favourite ? .statusWarning : .quietText
        star.toolTip = favourite ? "Take this object out of the favourites" : "Add this object to the favourites"
    }

    @objc private func starClicked(_ sender: Any?) { onStar?() }

    /// `countGivesWay`: the count is words (a column's type), cut before the name rather than beside it. `bar`: how much
    /// of the row its size fills. `onStar`: it can be a favourite.
    func show(_ image: NSImage, _ text: String, count value: String, countGivesWay: Bool = false, bold: Bool = false, busy: Bool,
              bar: CGFloat = 0, comment note: String = "", favourite: Bool = false, onStar: (() -> Void)? = nil, tip: String) {
        self.bar = bar
        self.favourite = favourite
        self.onStar = onStar
        updateStar()
        comment.stringValue = note
        comment.isHidden = note.isEmpty
        icon.isHidden = false
        icon.image = image
        name.stringValue = text
        name.font = .systemFont(ofSize: 13, weight: bold ? .semibold : .regular)
        nameColour = .labelColor
        colour()
        count.stringValue = value
        count.isHidden = value.isEmpty
        count.setContentCompressionResistancePriority(countGivesWay ? .defaultLow - 1 : .required, for: .horizontal)
        setBusy(busy)
        toolTip = tip
        setAccessibilityLabel(bold ? text + ", current database" : text)
        setAccessibilityHelp(tip)
    }

    func showMessage(_ text: String, busy: Bool) {
        bar = 0
        onStar = nil
        updateStar()
        comment.isHidden = true
        icon.isHidden = true
        name.stringValue = text
        name.font = .systemFont(ofSize: 12)
        nameColour = .secondaryLabelColor
        colour()
        count.isHidden = true
        setBusy(busy)
        toolTip = text
        setAccessibilityLabel(text)
    }

    private func colour() {
        let selected = backgroundStyle == .emphasized
        name.textColor = selected ? .onAccent : nameColour
        count.textColor = selected ? .onAccent : .quietText
        comment.textColor = selected ? .onAccent : .quietText
    }

    private func setBusy(_ busy: Bool) {
        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
}
