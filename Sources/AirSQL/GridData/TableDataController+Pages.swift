import AirSQLCore
import AppKit

/// What a table tab shows, as its switch has them.
enum TablePage: Int, CaseIterable {
    case data, structure, ddl

    var command: Command { [Commands.pageData, Commands.pageStructure, Commands.pageDDL][rawValue] }
}

/// A table tab's switch: its rows, or the table editor, or its CREATE statement, on the same tab. The choice stays as the
/// tree is walked: the next table opens on the same page, and reads its rows only when they show.
extension TableDataController {
    private var objectKind: DatabaseObject.Kind {
        context.schema.snapshot.table(database, tableName).flatMap { DatabaseObject.Kind(rawValue: $0.kind.rawValue) } ?? .table
    }

    /// What the menus send: off the Data page, they aren't for the rows.
    static let commandActions = Set(Commands.all.map(\.action))

    func validatePage(_ item: NSMenuItem) -> Bool {
        item.state = item.tag == page.rawValue ? .on : .off
        let enabled = pageSwitch.isEnabled(forSegment: item.tag)
        item.explain(enabled: enabled, reason: "A sequence has no structure to edit: look at its DDL")
        return enabled
    }

    /// The page on show when it isn't the rows.
    var shownPage: NSViewController? { page == .data ? nil : pages[page] }

    /// Unsaved changes on the Structure page (a table still loading has none to lose).
    var structureEdited: Bool {
        if let editor = pages[.structure] as? TableEditorController { return editor.before != nil && editor.isEdited }
        return (pages[.structure] as? TabContent)?.isEdited == true
    }

    func addPages(to view: NSView) {
        pageSwitch.segmentCount = TablePage.allCases.count
        pageSwitch.trackingMode = .selectOne
        pageSwitch.controlSize = .small
        pageSwitch.segmentStyle = .rounded
        pageSwitch.selectedSegmentBezelColor = .selectedSegment
        pageSwitch.target = self
        pageSwitch.action = #selector(pageSwitched(_:))
        pageSwitch.setAccessibilityIdentifier("tableData.page")
        for page in TablePage.allCases {
            pageSwitch.setLabel(page.command.title, forSegment: page.rawValue)
            pageSwitch.setToolTip(page.command.tip + " (" + page.command.shortcut + ")", forSegment: page.rawValue)
        }
        pageSwitch.setEnabled(objectKind != .sequence, forSegment: TablePage.structure.rawValue)
        pageBar.translatesAutoresizingMaskIntoConstraints = false
        pageBar.clipsToBounds = true
        pageBarHeight = pageBar.heightAnchor.constraint(equalToConstant: 0)
        for part in [pageBar, dataPage, pageHolder] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(part)
        }
        NSLayoutConstraint.activate([
            pageBar.topAnchor.constraint(equalTo: view.topAnchor), pageBarHeight,
            pageBar.leadingAnchor.constraint(equalTo: view.leadingAnchor), pageBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        for part in [dataPage, pageHolder] {
            NSLayoutConstraint.activate([
                part.topAnchor.constraint(equalTo: pageBar.bottomAnchor), part.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                part.leadingAnchor.constraint(equalTo: view.leadingAnchor), part.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
        placeSwitch()
    }

    /// The switch stands at the start of the rows' toolbar; on the other pages, on a bar of its own, with what the page
    /// wants beside it (`pageActions`).
    private func placeSwitch() {
        pageBarHeight.constant = page == .data ? 0 : 31
        if page == .data {
            pageBar.subviews.forEach { $0.removeFromSuperview() }
            toolbar.leadingView = pageSwitch
            return
        }
        toolbar.leadingView = nil
        pageBar.subviews.forEach { $0.removeFromSuperview() }
        let row = actionBar([pageSwitch, NSView()] + ((pages[page] as? TableEditorController)?.barActions ?? []))
        pageBar.addSubview(row)
        row.pin(to: pageBar)
    }

    /// What was chosen last, unless this object hasn't such a page.
    func showChosenPage() {
        let chosen = TablePage(rawValue: model.data.settings.tree.tablePage) ?? .data
        show(chosen == .structure && objectKind == .sequence ? .data : chosen)
    }

    @objc private func pageSwitched(_ sender: NSSegmentedControl) {
        choose(TablePage(rawValue: sender.selectedSegment) ?? .data)
    }

    /// View ▸ Table Page.
    @objc func showTablePage(_ sender: Any?) {
        choose(TablePage(rawValue: (sender as? NSMenuItem)?.tag ?? 0) ?? .data)
    }

    private func choose(_ page: TablePage) {
        model.data.settings.tree.tablePage = page.rawValue
        show(page)
    }

    /// Shows a page without changing what the next table opens on.
    func show(_ page: TablePage) {
        self.page = page
        pageSwitch.selectedSegment = page.rawValue
        dataPage.isHidden = page != .data
        pageHolder.isHidden = page == .data
        pages.values.forEach { $0.view.isHidden = true }
        defer { placeSwitch() }
        if page == .data {
            view.window?.makeFirstResponder(grid)
            if rowsWaiting {
                rowsWaiting = false
                loadFirstRows()
            }
        } else {
            // The DDL is read each time: the Structure page may have changed it.
            if page == .ddl, let old = pages.removeValue(forKey: .ddl) {
                old.view.removeFromSuperview()
                old.removeFromParent()
            }
            let content = pages[page] ?? make(page)
            content.view.isHidden = false
            view.window?.makeFirstResponder(content.view.nextValidKeyView ?? content.view)
        }
        NotificationCenter.default.post(name: .tabContentDidChange, object: self)
    }

    private func make(_ page: TablePage) -> NSViewController {
        let content: NSViewController
        if page == .ddl, let open = model.openConnection(context.connection.id) {
            content = TextContent.definition(open, DatabaseObject(objectKind, database, tableName))
        } else if page == .ddl {
            content = TextContent(title: tableName, caption: "Connect to the server again to read its definition.")
        } else if objectKind == .view {
            content = ObjectEditorController(context: context, kind: .view, database: database, name: tableName, table: nil, activity: model.activity)
        } else {
            let editor = TableEditorController(context: context, database: database, table: tableName, activity: model.activity)
            editor.inTab = true
            content = editor
        }
        pages[page] = content
        addChild(content)
        pageHolder.addSubview(content.view)
        content.view.pin(to: pageHolder)
        return content
    }

    /// Asks about the Structure page's changes first, on that page.
    func askAboutStructure(_ answer: @escaping (Bool) -> Void) {
        guard structureEdited, let content = pages[.structure] as? TabContent else { return answer(true) }
        show(.structure)
        content.shouldClose(answer)
    }
}
