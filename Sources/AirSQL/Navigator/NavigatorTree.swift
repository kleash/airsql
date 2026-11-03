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
            NSBezierPath(roundedRect: rect, xRadius: Radius.cell, yRadius: Radius.cell).fill()
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
}

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
    /// only the objects whose names hold it, in the databases and groups that have them (a database whose name holds it
    /// keeps everything).
    func tree(_ id: UUID, matching text: String, node: (SidebarNode.Kind) -> SidebarNode) -> [SidebarNode] {
        guard let open = model.openConnection(id) else { return [] }
        let snapshot = open.snapshot
        guard snapshot.server != nil else {
            if !text.isEmpty { return [] }
            return [node(.message(id, open.loadError.map { "Couldn't read the schema: " + $0 } ?? "Loading the schema…"))]
        }
        return snapshot.databases.compactMap { database in
            let all = text.isEmpty || database.name.localizedCaseInsensitiveContains(text)
            let groups = groups(database).compactMap { kind, names -> SidebarNode? in
                let shown = all ? names : names.filter { $0.localizedCaseInsensitiveContains(text) }
                if (!all && shown.isEmpty) || (kind == .sequence && names.isEmpty) { return nil }
                let group = node(.category(id, database.name, kind))
                group.children = shown.map { node(.object(id, DatabaseObject(kind, database.name, $0))) }
                return group
            }
            guard all || !groups.isEmpty else { return nil }
            let row = node(.database(id, database.name))
            row.children = groups
            return row
        }
    }

    private func groups(_ database: SchemaDatabase) -> [(DatabaseObject.Kind, [String])] {
        func tables(_ kind: SchemaTable.Kind) -> [String] { database.tables.filter { $0.kind == kind }.map(\.name) }
        func routines(_ kind: SchemaRoutine.Kind) -> [String] { database.routines.filter { $0.kind == kind }.map(\.name) }
        return [(.table, tables(.table)), (.view, tables(.view)), (.sequence, tables(.sequence)),
                (.procedure, routines(.procedure)), (.function, routines(.function)),
                (.trigger, database.triggers.map(\.name)), (.event, database.events.map(\.name))]
    }

    /// The cell of a tree row.
    func treeCell(_ node: SidebarNode, in outlineView: NSOutlineView) -> NSView? {
        let cell = (outlineView.makeView(withIdentifier: TreeCell.identifier, owner: nil) as? TreeCell) ?? TreeCell()
        guard let id = node.connectionOfTree, let open = model.openConnection(id) else { return cell }
        switch node.kind {
        case .database(_, let name):
            let current = open.currentDatabase == name
            let busy = open.loading.contains(.details(name)) || open.loading.contains(.statistics(name))
            let count = node.children.reduce(0) { $0 + $1.children.count }
            cell.show(TreeIcon.database, name, count: "\(count)", bold: current, busy: busy,
                      tip: "\(name)\(current ? ", the current database" : ""): click to see its tables, double-click to make it "
                        + "current, right-click for more")
        case .category(_, _, let kind):
            cell.show(TreeIcon.of(kind), kind.group, count: "\(node.children.count)", busy: false,
                      tip: "\(kind.group): double-click to open or close, right-click for more")
        case .object(_, let object):
            var count = ""
            if object.kind == .table, let rows = open.snapshot.database(object.database)?.statistics?[object.name]?.rows {
                count = shortCount(rows)
            }
            let action = object.kind.isTableLike ? "its data" : "its definition"
            cell.show(TreeIcon.of(object.kind), object.name, count: count, busy: false,
                      tip: "\(object.name), a \(object.kind.noun): click to see \(action), double-click to open it in a tab, "
                        + "right-click for more")
        case .message(_, let text):
            cell.showMessage(text, busy: open.loading.contains(.schema))
        default:
            break
        }
        return cell
    }
}

extension SidebarNode {
    /// The connection of a tree row (a database, group, object or message).
    var connectionOfTree: UUID? {
        switch kind {
        case .database(let id, _), .category(let id, _, _), .object(let id, _), .message(let id, _): return id
        default: return nil
        }
    }

    /// The database of a database, group or object row.
    var database: String? {
        switch kind {
        case .database(_, let name), .category(_, let name, _): return name
        case .object(_, let object): return object.database
        default: return nil
        }
    }

    var object: DatabaseObject? {
        if case .object(_, let object) = kind { return object }
        return nil
    }

    /// What type-to-find and the drag read.
    var name: String? {
        switch kind {
        case .database(_, let name): return name
        case .category(_, _, let kind): return kind.group
        case .object(_, let object): return object.name
        default: return nil
        }
    }
}

/// A tree row: its icon, name (cut with an ellipsis, in full in the tooltip), a count, and a spinner while it loads.
final class TreeCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TreeCell")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .tertiaryLabelColor
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.setContentHuggingPriority(.required, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Loading")
        let stack = NSStackView(views: [icon, name, spinner, count])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        textField = name
        imageView = icon
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ image: NSImage, _ text: String, count value: String, bold: Bool = false, busy: Bool, tip: String) {
        icon.isHidden = false
        icon.image = image
        name.stringValue = text
        name.font = .systemFont(ofSize: 13, weight: bold ? .semibold : .regular)
        name.textColor = .labelColor
        count.stringValue = value
        count.isHidden = value.isEmpty
        setBusy(busy)
        toolTip = tip
        setAccessibilityLabel(text)
    }

    func showMessage(_ text: String, busy: Bool) {
        icon.isHidden = true
        name.stringValue = text
        name.font = .systemFont(ofSize: 12)
        name.textColor = .secondaryLabelColor
        count.isHidden = true
        setBusy(busy)
        toolTip = text
        setAccessibilityLabel(text)
    }

    private func setBusy(_ busy: Bool) {
        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
}
