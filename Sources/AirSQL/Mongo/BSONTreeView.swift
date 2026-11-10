import AirSQLCore
import AppKit

/// A value of a document as a row of `BSONTreeView`: its key ("[0]" in an array) and value; its children are made only
/// when its row opens, so a big document costs what is looked at (mongo-plan, risk 2: BSON all the way, no JSON detour).
@MainActor
final class BSONNode {
    let key: String
    let value: BSONValue

    init(key: String, value: BSONValue) {
        self.key = key
        self.value = value
    }

    lazy var children: [BSONNode] = {
        switch value {
        case .document(let document): return document.fields.map { BSONNode(key: $0.key, value: $0.value) }
        case .array(let values): return values.enumerated().map { BSONNode(key: "[\($0.offset)]", value: $0.element) }
        default: return []
        }
    }()

    var isContainer: Bool {
        switch value {
        case .document, .array: return true
        default: return false
        }
    }

    /// What the value column shows: a sub-document's or array's size, else the value in shell form.
    var text: String {
        switch value {
        case .document(let document): return "{ \(document.fields.count) field\(document.fields.count == 1 ? "" : "s") }"
        case .array(let values): return "[ \(values.count) element\(values.count == 1 ? "" : "s") ]"
        default: return value.shellForm(maxLength: 10_000)
        }
    }
}

/// A document, sub-document or array as a tree (the value panel's tree for a MongoDB cell): keys, values in shell form
/// in the editor's colours, each one's BSON type in its tooltip. Rows open with their arrow or a double-click; a right-click
/// copies a value in shell form, or opens or closes the whole tree.
@MainActor
final class BSONTreeView: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuItemValidation {
    let outline = NSOutlineView()
    private var root: BSONNode?

    var value: BSONValue? {
        didSet {
            root = value.map { BSONNode(key: "", value: $0) }
            outline.reloadData()
            if let root { outline.expandItem(root) }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (id, title, width) in [("key", "Key", 130.0), ("value", "Value", 200.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = self
        outline.delegate = self
        outline.style = .plain
        outline.backgroundColor = .content
        outline.centreText(rowHeight: 24)
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.target = self
        outline.doubleAction = #selector(openOrClose(_:))
        outline.setAccessibilityIdentifier("valuePanel.bson")
        documentView = outline
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func openOrClose(_ sender: Any?) {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard let node = outline.item(atRow: row) as? BSONNode, node.isContainer else { return }
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        _ = outline.selectsRow(for: event)
        let menu = NSMenu(title: "Document")
        let items = [Commands.copy.item(), .separator(), Commands.expandAll.item(), Commands.collapseAll.item()]
        for (item, tip) in zip(items, ["Copy the selected value in shell form", "", "Open every sub-document and array",
                                       "Close every sub-document and array"]) {
            item.target = self
            item.toolTip = tip
            menu.addItem(item)
        }
        return menu
    }

    private var selected: BSONNode? { outline.item(atRow: outline.selectedRow) as? BSONNode }

    /// Edit ▸ Copy, and the menu's: the selected value in shell form, sub-documents and arrays whole.
    @objc func copy(_ sender: Any?) {
        guard let node = selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.value.shellForm(), forType: .string)
    }

    @objc func expandAll(_ sender: Any?) { outline.expandItem(nil, expandChildren: true) }
    @objc func collapseAll(_ sender: Any?) { outline.collapseItem(nil, collapseChildren: true) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(copy(_:)), selected == nil else { return true }
        item.toolTip = "Select a value to copy it"
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? BSONNode)?.children.count ?? (root == nil ? 0 : 1)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? BSONNode)?.children[index] ?? root!
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? BSONNode)?.isContainer == true }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? BSONNode else { return nil }
        let text: String, colour: NSColor
        switch tableColumn?.identifier.rawValue {
        case "key"?:
            (text, colour) = (node.key.isEmpty ? "(document)" : node.key, .labelColor)
        default:
            text = node.text
            switch node.value {
            case .string: colour = .sqlString
            case .int32, .int64, .double, .decimal128: colour = .sqlNumber
            case .bool: colour = .sqlKeyword
            case .null, .undefined: colour = .dataNull
            default: colour = node.isContainer ? .secondaryLabelColor : .labelColor
            }
        }
        let field = label(text, font: .monospacedSystemFont(ofSize: 11.5, weight: .regular), color: colour, truncates: true)
        // The value's BSON type with it, where there is no room for a column of its own.
        field.toolTip = tableColumn?.identifier.rawValue == "value" ? node.value.typeAlias + ": " + String(text.prefix(2_000)) : nil
        field.translatesAutoresizingMaskIntoConstraints = true  // the outline sets its frame
        return field
    }
}
