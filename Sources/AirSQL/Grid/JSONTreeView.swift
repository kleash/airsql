import AirSQLCore
import AppKit

/// A JSON tree in an outline (the value panel's JSON, View As ▸ Tree): keys on the left, values on the right in the
/// editor's colours for strings, numbers and literals; objects and arrays show their size and open with a click.
@MainActor
final class JSONTreeView: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = NSOutlineView()
    /// Shown opened up to this many levels (a whole result opens its rows only).
    var openLevels = Int.max
    var tree: JSONNode? {
        didSet {
            outline.reloadData()
            if let tree { open(tree, level: 0) }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let key = NSTableColumn(identifier: .init("key")), value = NSTableColumn(identifier: .init("value"))
        key.title = "Key"
        value.title = "Value"
        key.width = 130
        outline.addTableColumn(key)
        outline.addTableColumn(value)
        outline.outlineTableColumn = key
        outline.dataSource = self
        outline.delegate = self
        outline.style = .plain
        outline.usesAlternatingRowBackgroundColors = true
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        documentView = outline
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func open(_ node: JSONNode, level: Int) {
        guard level < openLevels else { return }
        outline.expandItem(node)
        for child in node.children where !child.children.isEmpty { open(child, level: level + 1) }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? JSONNode)?.children.count ?? (tree == nil ? 0 : 1)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? JSONNode)?.children[index] ?? tree!
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? JSONNode)?.children.isEmpty ?? true) }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? JSONNode else { return nil }
        let isKey = tableColumn?.identifier.rawValue == "key"
        let colours: [JSONNode.Kind: NSColor] = [.string: .sqlString, .number: .sqlNumber, .bool: .sqlKeyword, .null: .dataNull]
        let field = label(isKey ? (node.key.isEmpty ? "(root)" : node.key) : node.value,
                          font: .monospacedSystemFont(ofSize: 11.5, weight: .regular),
                          color: isKey ? .labelColor : colours[node.kind] ?? .secondaryLabelColor, truncates: true)
        field.toolTip = isKey ? nil : node.value
        field.translatesAutoresizingMaskIntoConstraints = true  // the outline sets its frame
        return field
    }
}
