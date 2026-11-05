import AirSQLCore
import AppKit
import UniformTypeIdentifiers

/// An ER diagram (scope: "ER diagram of a database"): a database's tables, or those chosen, with their foreign keys. Boxes
/// move and each diagram is kept on this Mac (`ERLayout`), several per database. It exports as a picture or as text other
/// tools draw. The details load off the main thread (an Activity), with a spinner where the diagram goes.
@MainActor
final class ERDiagramController: NSViewController, TabContent, NSMenuItemValidation {
    let context: EditorContext
    private(set) var database: String?
    private let activity: ActivityCenter
    private(set) var diagram: ERDiagram?
    /// The database's diagrams, the whole database's among them, and the one shown.
    private(set) var layouts: [ERLayout] = []
    private(set) var current = 0
    /// Tables to make a new diagram of, once the database is read.
    private var pending: (name: String?, tables: Set<String>, neighbours: Bool)?
    /// The database as read, with the keys defined on this Mac and without.
    private(set) var schema: SchemaDatabase?
    private var schemaWithoutVirtualKeys: SchemaDatabase?
    private let undo = UndoManager()
    let canvas = ERDiagramView()
    let databases = popup([], selected: 0, id: "erDiagram.database", tip: "Draw the tables of this database", target: nil, action: nil)
    let diagrams = popup([], selected: 0, id: "erDiagram.diagram", tip: "Show another diagram of this database", target: nil, action: nil)
    let addTable = NSPopUpButton(frame: .zero, pullsDown: true)
    let arrange = NSPopUpButton(frame: .zero, pullsDown: true)
    let show = NSPopUpButton(frame: .zero, pullsDown: true)
    let export = NSPopUpButton(frame: .zero, pullsDown: true)
    let summary = label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, truncates: true)
    let overlay = EditorOverlay()
    let find = NSSearchField()
    let fitButton = button("Fit", id: "erDiagram.fit", tip: "Zoom so that the whole diagram shows", target: nil, action: nil)
    let scroll = NSScrollView()

    /// `tables`: start a new diagram of these, with their neighbours if `neighbours`.
    init(context: EditorContext, database: String?, tables: Set<String>? = nil, neighbours: Bool = false, activity: ActivityCenter) {
        self.context = context
        self.database = database
        self.activity = activity
        pending = tables.map { (nil, $0, neighbours) }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var tabTitle: String {
        let name = layouts.indices.contains(current) && layouts[current].tables != nil ? " · " + layouts[current].name : ""
        return (database ?? "Database") + name + " · diagram"
    }

    /// The diagram shown.
    var layout: ERLayout {
        get { layouts.indices.contains(current) ? layouts[current] : ERLayout(name: ERLayout.wholeDatabase) }
        set { if layouts.indices.contains(current) { layouts[current] = newValue } }
    }

    override func loadView() {
        databases.target = self
        databases.action = #selector(databaseChosen(_:))
        diagrams.target = self
        diagrams.action = #selector(diagramChosen(_:))
        fill(arrange, "Arrange", id: "erDiagram.arrange", tip: "Lay the boxes out again: where you moved them is forgotten", Commands.diagramArrange)
        fill(show, "Show", id: "erDiagram.show", tip: "Choose what each box shows",
             Commands.diagramDetail + [nil, Commands.diagramComments, Commands.diagramVirtualKeys])
        fill(export, "Export", id: "erDiagram.export", tip: "Save or print the diagram", Commands.diagramExports + [nil, Commands.printDiagram])
        fill(addTable, "Add Table", id: "erDiagram.add", tip: "Add a table to this diagram; you can also drag tables here from the tree", [])
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        find.placeholderString = "Find a table"
        find.toolTip = "Type part of a table's name to select it and show it; Return goes to the next"
        find.setAccessibilityIdentifier("erDiagram.find")
        find.sendsSearchStringImmediately = true
        find.target = self
        find.action = #selector(findTable(_:))
        find.widthAnchor.constraint(equalToConstant: 200).isActive = true
        fitButton.target = self
        fitButton.action = #selector(fitAll(_:))
        let second = NSView()
        second.setContentHuggingPriority(.init(1), for: .horizontal)
        let tools = NSStackView(views: [find, fitButton, addTable, arrange, show, summary, second])
        tools.spacing = Spacing.unit
        tools.edgeInsets = NSEdgeInsets(top: 0, left: Spacing.double, bottom: Spacing.unit, right: Spacing.double)
        let top = NSStackView(views: [label("Database:"), databases, label("Diagram:"), diagrams, spacer, export, helpButton(.editors)])
        top.spacing = Spacing.unit
        top.alignment = .centerY
        top.setCustomSpacing(Spacing.double, after: databases)
        top.edgeInsets = NSEdgeInsets(top: Spacing.unit, left: Spacing.double, bottom: Spacing.unit, right: Spacing.double)
        let bar = NSStackView(views: [top, tools])
        bar.orientation = .vertical
        bar.spacing = 0
        bar.alignment = .width
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.backgroundColor = .content
        scroll.allowsMagnification = true  // pinch, and ⌘+ ⌘− ⌘0 below
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 3
        canvas.onOpen = { [weak self] table in self?.open(table) }
        canvas.onMoved = { [weak self] in self?.boxesMoved() }
        canvas.onDrop = { [weak self] names in self?.add(names) }
        let menu = NSMenu()
        menu.add([Commands.openStructure, Commands.openData, Commands.copyName, nil, Commands.diagramNeighbours, Commands.diagramRemove,
                  Commands.diagramNew])
        canvas.menu = menu
        canvas.blankMenu = NSMenu()
        canvas.blankMenu?.add(Commands.diagramExports + [nil, Commands.refresh, Commands.bigger, Commands.smaller, Commands.actualSize])
        let root = editorLayout(bar: bar, content: scroll)
        root.addSubview(overlay)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: scroll.topAnchor), overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        root.setAccessibilityIdentifier("erDiagram")
        view = root
        load()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        canvas.fit(scroll.contentView.bounds.size)
    }

    /// Loads the database's details (if not yet) and draws it.
    func load() {
        overlay.show(loading: "Reading the tables of \(database ?? "the server")…")
        export.isEnabled = false
        let work = activity.start("Drawing the diagram of \(database ?? "a database")", connection: context.connection.id)
        let context = self.context
        Task {
            defer { work.end() }
            do {
                if context.schema.snapshot.server == nil { try await context.schema.load() }
                let names = context.schema.snapshot.databases.map(\.name)
                let database = self.database ?? context.firstDatabase(withTables: true)
                guard let database else { throw DesignError("The server has no database to draw") }
                try await context.schema.loadDetails([database])
                // With the foreign keys the person defined (virtual: kept on this Mac, not in the database).
                let id = context.connection.id
                let (virtual, saved) = await Task.detached {
                    (TableViewSettingsStore.shared.virtualKeys(connection: id),
                     TableViewSettingsStore.shared.settings(connection: id, database: database, table: "").diagrams)
                }.value
                guard let schema = context.schema.snapshot.adding(virtual).database(database) else {
                    throw DesignError("\(database) isn't on the server any more")
                }
                let showing = self.database == database ? layout.name : nil
                self.database = database
                self.schema = schema
                schemaWithoutVirtualKeys = context.schema.snapshot.database(database)
                layouts = ERLayout.list(saved)
                current = layouts.firstIndex { $0.name == showing } ?? 0
                if let pending {
                    self.pending = nil
                    makeDiagram(pending.name, tables: pending.neighbours ? ERDiagram.neighbours(of: pending.tables, in: schema) : pending.tables)
                }
                show(names)
            } catch {
                overlay.show(error: error.localizedDescription, retry: (self, #selector(retry(_:))))
            }
        }
    }

    @objc private func retry(_ sender: Any?) { load() }

    private func show(_ names: [String]) {
        redraw()
        scroll.magnification = 1
        canvas.fit(scroll.contentView.bounds.size)
        canvas.scroll(.zero)
        databases.removeAllItems()
        databases.addItems(withTitles: names)
        databases.selectItem(withTitle: database ?? "")
        overlay.hide()
    }

    /// Draws the diagram shown as it is now, and sets what depends on it.
    private func redraw() {
        guard let source = layout.showsVirtualKeys ? schema : schemaWithoutVirtualKeys else { return }
        let diagram = ERDiagram(source, only: layout.tables.map(Set.init))
        self.diagram = diagram
        canvas.show(diagram, layout: layout)
        diagrams.removeAllItems()
        diagrams.addItems(withTitles: layouts.map(\.name))
        diagrams.selectItem(at: current)
        let drawn = Set(diagram.columns.flatMap { $0 }.map(\.name))
        let absent = source.tables.filter { $0.kind == .table && !drawn.contains($0.name) }.map(\.name)
        while addTable.numberOfItems > 1 { addTable.removeItem(at: 1) }
        for name in absent {
            let item = NSMenuItem(title: name, action: #selector(addChosenTable(_:)), keyEquivalent: "")
            item.target = self
            item.toolTip = "Add \(name) to this diagram"
            addTable.menu?.addItem(item)
        }
        addTable.isEnabled = !absent.isEmpty
        addTable.toolTip = !absent.isEmpty ? "Add a table to this diagram; you can also drag tables here from the tree"
            : layout.tables == nil ? "This diagram shows every table already" : "Every table of the database is on this diagram"
        let tables = drawn.count
        summary.stringValue = tables > 0 ? "\(tables) tables, \(diagram.links.count) foreign keys"
            : layout.tables == nil ? "No tables here yet: choose another database, or add one with Database ▸ Create Table…"
            : "No tables on this diagram: add some with Add Table, or drag them here from the tree"
        summary.toolTip = summary.stringValue
        export.isEnabled = tables > 0
        export.toolTip = tables > 0 ? "Save or print the diagram" : "There are no tables to export"
        if let main = view.window?.windowController as? MainWindowController, let tab = main.tabs.first(where: { $0.content === self }) {
            main.rename(tab, to: tabTitle)
        }
    }

    @objc func databaseChosen(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem, title != database else { return }
        database = title
        canvas.selected = nil
        undo.removeAllActions()
        load()
    }

    @objc func diagramChosen(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem != current else { return }
        current = sender.indexOfSelectedItem
        canvas.selected = nil
        undo.removeAllActions()
        redraw()
    }

    // MARK: Changing a diagram

    /// Changes the diagram shown (undoably), keeps it and draws it.
    func edit(_ change: (inout ERLayout) -> Void) {
        var changed = layout
        change(&changed)
        replace(with: changed)
    }

    private func replace(with new: ERLayout) {
        let old = layout
        guard new != old else { return }
        undo.registerUndo(withTarget: self) { $0.replace(with: old) }
        layout = new
        keep()
        redraw()
    }

    /// Saves the database's diagrams. The file was read when the database loaded.
    private func keep() {
        guard let database else { return }
        let id = context.connection.id
        var settings = TableViewSettingsStore.shared.settings(connection: id, database: database, table: "")
        settings.diagrams = layouts
        TableViewSettingsStore.shared.set(settings, connection: id, database: database, table: "")
    }

    private func boxesMoved() {
        let positions = canvas.positions
        edit { $0.positions = positions }
    }

    /// A new diagram of `tables`, shown, its boxes where they are now (nil name: the next free one).
    private func makeDiagram(_ name: String?, tables: Set<String>) {
        var new = ERLayout(name: name ?? ERLayout.newName(in: layouts), tables: tables.sorted())
        new.arrangement = layout.arrangement
        new.detail = layout.detail
        layouts.append(new)
        current = layouts.count - 1
        undo.removeAllActions()
        keep()
    }

    /// Adds tables of this database; on the whole database's diagram they are all there.
    func add(_ names: [String]) {
        let known = Set(schema?.tables.filter { $0.kind == .table }.map(\.name) ?? [])
        let wanted = names.filter(known.contains)
        guard let tables = layout.tables, !wanted.isEmpty else { return }
        edit { $0.tables = Array(Set(tables + wanted)).sorted() }
    }

    @objc private func addChosenTable(_ sender: NSMenuItem) {
        if layout.tables == nil { return }
        add([sender.title])
    }

    @objc func addNeighbours(_ sender: Any?) {
        guard let schema, !canvas.selection.isEmpty else { return }
        let found = ERDiagram.neighbours(of: canvas.selection, in: schema)
        if layout.tables == nil {
            makeDiagram(nil, tables: found)
            redraw()
        } else {
            add(found.sorted())
        }
    }

    @objc func removeFromDiagram(_ sender: Any?) {
        guard let tables = layout.tables else { return }
        let gone = canvas.selection
        edit { layout in
            layout.tables = tables.filter { !gone.contains($0) }
            for name in gone { layout.positions[name] = nil }
        }
    }

    @objc func newDiagram(_ sender: Any?) {
        guard let window = view.window else { return }
        let field = NSTextField(string: ERLayout.newName(in: layouts))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.toolTip = "Name the new diagram"
        NavigatorActions.ask("New diagram", "Keep the selected boxes, or all of them, as a diagram of their own.", field: field, action: "Create",
                             tip: "Make the diagram; it is kept on this Mac", on: window) { [weak self] in
            self?.newDiagram(named: field.stringValue)
        }
    }

    func newDiagram(named name: String) {
        guard let diagram else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !layouts.contains(where: { $0.name == name }) else {
            return showError("Choose a name no other diagram of this database has.", title: "Couldn't make the diagram", on: view.window)
        }
        let tables = canvas.selection.isEmpty ? Set(diagram.columns.flatMap { $0 }.map(\.name)) : canvas.selection
        let positions = canvas.positions.filter { tables.contains($0.key) }
        makeDiagram(name, tables: tables)
        layout.positions = positions
        keep()
        redraw()
    }

    @objc func renameDiagram(_ sender: Any?) {
        guard let window = view.window, layout.tables != nil else { return }
        let field = NSTextField(string: layout.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.toolTip = "Name the diagram"
        NavigatorActions.ask("Rename diagram", "This changes only the name kept on this Mac.", field: field, action: "Rename",
                             tip: "Give the diagram this name", on: window) { [weak self] in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !name.isEmpty, !self.layouts.contains(where: { $0.name == name }) else { return }
            self.edit { $0.name = name }
        }
    }

    @objc func deleteDiagram(_ sender: Any?) {
        guard layout.tables != nil else { return }
        layouts.remove(at: current)
        current = 0
        undo.removeAllActions()
        keep()
        redraw()
    }

    @objc func arrangeBoxes(_ sender: Any?) {
        let arrangement = ERLayout.Arrangement.allCases[(sender as? NSMenuItem)?.tag ?? 0]
        edit {
            $0.arrangement = arrangement
            $0.positions = [:]
        }
    }

    /// Changing what boxes show changes their sizes: they stay where they are.
    @objc func showDetail(_ sender: Any?) {
        let detail = ERLayout.Detail.allCases[(sender as? NSMenuItem)?.tag ?? 0]
        edit { $0.detail = detail }
    }

    @objc func toggleComments(_ sender: Any?) { edit { $0.showsComments.toggle() } }
    @objc func toggleVirtualKeys(_ sender: Any?) { edit { $0.showsVirtualKeys.toggle() } }

    @objc func undo(_ sender: Any?) { undo.undo() }
    @objc func redo(_ sender: Any?) { undo.redo() }

    private func open(_ table: String) {
        guard let main = view.window?.windowController as? MainWindowController else { return }
        main.openTableEditor(table, database: database, context: context)
    }

    // MARK: Export

    @objc func exportDiagram(_ sender: Any?) {
        guard let format = DiagramExport(rawValue: (sender as? NSMenuItem)?.tag ?? 0) else { return }
        save(type: UTType(filenameExtension: format.fileExtension) ?? .plainText, name: (database ?? "diagram") + "." + format.fileExtension) { [weak self] in
            self?.exported(format)
        }
    }

    /// The diagram's file in `format`.
    func exported(_ format: DiagramExport) -> Data? {
        guard let diagram else { return nil }
        switch format {
        case .png: return canvas.png()
        case .mermaid: return Data(diagram.mermaid().utf8)
        case .plantUML: return Data(diagram.plantUML().utf8)
        case .dot: return Data(diagram.dot().utf8)
        case .graphML: return Data(diagram.graphML(positions: canvas.positions).utf8)
        case .drawIO: return Data(diagram.drawIO(positions: canvas.positions).utf8)
        }
    }

    @objc func printDiagram(_ sender: Any?) {
        guard let window = view.window, diagram != nil else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.orientation = canvas.bounds.width > canvas.bounds.height ? .landscape : .portrait
        NSPrintOperation(view: canvas, printInfo: info).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Asks where, then writes the file off the main thread.
    private func save(type: UTType, name: String, data: @escaping () -> Data?) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, let bytes = data() else { return }
            Task.detached {
                do {
                    try bytes.write(to: url, options: .atomic)
                } catch {
                    await MainActor.run { showError(error.localizedDescription, title: "Couldn't save \(url.lastPathComponent)", on: window) }
                }
            }
        }
    }

    // MARK: The selected table's commands

    @objc func openStructure(_ sender: Any?) {
        if let table = canvas.selected { open(table) }
    }

    @objc func openData(_ sender: Any?) {
        guard let table = canvas.selected, let database, let main = view.window?.windowController as? MainWindowController else { return }
        main.openTableData(table, database: database, context: context)
    }

    @objc func copyName(_ sender: Any?) {
        guard let table = canvas.selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SQLQuote.identifier(table), forType: .string)
    }

    @objc func copy(_ sender: Any?) { copyName(sender) }

    // MARK: Zoom and find

    @objc func zoomIn(_ sender: Any?) { scroll.magnification *= 1.25 }
    @objc func zoomOut(_ sender: Any?) { scroll.magnification /= 1.25 }
    @objc func zoomReset(_ sender: Any?) { scroll.magnification = 1 }
    @objc func fitAll(_ sender: Any?) { scroll.magnify(toFit: canvas.bounds) }

    /// Edit ▸ Find: the find field, whatever has the focus.
    override func performTextFinderAction(_ sender: Any?) { view.window?.makeFirstResponder(find) }

    /// Selects the next table with these letters in its name, after the selected one, and brings it into view.
    @objc func findTable(_ sender: Any?) {
        let matches = canvas.boxes.filter { $0.table.name.localizedCaseInsensitiveContains(find.stringValue) }
        guard !find.stringValue.isEmpty, !matches.isEmpty else { return }
        let typing = NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.keyCode != 36
        let at = matches.firstIndex { $0.table.name == canvas.selected }
        let box = at.map { typing ? matches[$0] : matches[($0 + 1) % matches.count] } ?? matches[0]
        canvas.selected = box.table.name
        canvas.scrollToVisible(box.frame)
    }

    /// Reads the schema again and draws it.
    @objc func refresh(_ sender: Any?) {
        Task {
            try? await context.schema.load()
            load()
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        var enabled = true, reason: String?
        let whole = layout.tables == nil
        switch item.action {
        case Commands.openStructure.action?, Commands.openData.action?, Commands.copyName.action?, Commands.copy.action?:
            enabled = canvas.selected != nil
            reason = "Click a table first"
        case Commands.diagramNeighbours.action?:
            enabled = !canvas.selection.isEmpty
            reason = "Click a table first"
        case Commands.diagramRemove.action?:
            enabled = !whole && !canvas.selection.isEmpty
            reason = whole ? "This diagram shows every table: make a New Diagram from Selection first" : "Click a table first"
        case Commands.diagramRename.action?, Commands.diagramDelete.action?:
            enabled = !whole
            reason = "The whole database's diagram always stays"
        case Commands.undo.action?, Commands.redo.action?:
            enabled = item.action == Commands.undo.action ? undo.canUndo : undo.canRedo
            reason = "Nothing to undo or redo on this diagram"
        case Commands.printDiagram.action?, #selector(exportDiagram(_:)):
            enabled = (diagram?.columns.isEmpty == false)
            reason = "There are no tables to export"
        case #selector(arrangeBoxes(_:)):
            item.state = ERLayout.Arrangement.allCases[item.tag] == layout.arrangement && layout.positions.isEmpty ? .on : .off
        case #selector(showDetail(_:)):
            item.state = ERLayout.Detail.allCases[item.tag] == layout.detail ? .on : .off
        case Commands.diagramComments.action?:
            item.state = layout.showsComments ? .on : .off
        case Commands.diagramVirtualKeys.action?:
            item.state = layout.showsVirtualKeys ? .on : .off
        default:
            return true
        }
        item.explain(enabled: enabled, reason: enabled ? nil : reason)
        return enabled
    }

    /// A pull-down of commands, each sent to this tab. Its first item is its title.
    private func fill(_ control: NSPopUpButton, _ title: String, id: String, tip: String, _ commands: [Command?]) {
        control.addItem(withTitle: title)
        control.toolTip = tip
        control.setAccessibilityIdentifier(id)
        for command in commands {
            let item = command?.item() ?? .separator()
            item.target = command == nil ? nil : self
            control.menu?.addItem(item)
        }
    }
}
