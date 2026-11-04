import AirSQLCore
import AppKit

/// A JSON tree in an outline (the value panel's JSON, View As ▸ Tree): keys on the left, values on the right in the
/// editor's colours for strings, numbers and literals; objects and arrays show their size and open with a click on
/// their arrow or a double-click. A right-click copies a value, or opens or closes the whole tree.
@MainActor
final class JSONTreeView: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuItemValidation {
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
        outline.backgroundColor = .content
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.target = self
        outline.doubleAction = #selector(openOrClose(_:))
        documentView = outline
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func openOrClose(_ sender: Any?) {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard let node = outline.item(atRow: row) as? JSONNode, !node.children.isEmpty else { return }
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }

    /// A right-click selects the row under the pointer, then offers to copy its value, or to open or close the whole
    /// tree (Database ▸ Expand All and Collapse All too, while the tree has the focus).
    override func menu(for event: NSEvent) -> NSMenu? {
        _ = outline.selectsRow(for: event)
        let menu = NSMenu(title: "JSON")
        let items = [Commands.copy.item(), .separator(), Commands.expandAll.item(), Commands.collapseAll.item()]
        for (item, tip) in zip(items, ["Copy the selected value as it is written", "", "Open every object and array",
                                       "Close every object and array"]) {
            item.target = self
            item.toolTip = tip
            menu.addItem(item)
        }
        return menu
    }

    private var selected: JSONNode? { outline.item(atRow: outline.selectedRow) as? JSONNode }

    /// Edit ▸ Copy, and the menu's: a string, number or literal as written (an object's or array's value is its size).
    @objc func copy(_ sender: Any?) {
        guard let node = selected, node.children.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.value, forType: .string)
    }

    @objc func expandAll(_ sender: Any?) { outline.expandItem(nil, expandChildren: true) }
    @objc func collapseAll(_ sender: Any?) { outline.collapseItem(nil, collapseChildren: true) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(copy(_:)), selected?.children.isEmpty != true else { return true }
        item.toolTip = "Select a string, number, true, false or null to copy it"
        return false
    }

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
