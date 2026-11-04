import AirSQLCore
import AppKit
import UniformTypeIdentifiers

/// The ER diagram of a database (scope: "ER diagram of a database"): its tables layered by foreign key, exported as a
/// PNG or as Mermaid text. The details load off the main thread (an Activity), with a spinner where the diagram goes.
@MainActor
final class ERDiagramController: NSViewController, TabContent, NSMenuItemValidation {
    let context: EditorContext
    private(set) var database: String?
    private let activity: ActivityCenter
    private(set) var diagram: ERDiagram?
    let canvas = ERDiagramView()
    let databases = popup([], selected: 0, id: "erDiagram.database", tip: "Draw the tables of this database", target: nil, action: nil)
    let exportImage = button("Export Image…", id: "erDiagram.exportImage", tip: "Save the diagram as a PNG picture", target: nil, action: nil)
    let exportMermaid = button("Export Mermaid…", id: "erDiagram.exportMermaid",
                               tip: "Save the diagram as Mermaid text, for docs and wikis that draw it", target: nil, action: nil)
    let summary = label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, truncates: true)
    let overlay = EditorOverlay()
    let find = NSSearchField()
    let fitButton = button("Fit", id: "erDiagram.fit", tip: "Zoom so that the whole diagram shows", target: nil, action: nil)
    let scroll = NSScrollView()

    init(context: EditorContext, database: String?, activity: ActivityCenter) {
        self.context = context
        self.database = database
        self.activity = activity
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var tabTitle: String { (database ?? "Database") + " · diagram" }

    override func loadView() {
        databases.target = self
        databases.action = #selector(databaseChosen(_:))
        exportImage.target = self
        exportImage.action = #selector(exportImage(_:))
        exportMermaid.target = self
        exportMermaid.action = #selector(exportMermaid(_:))
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
        let tools = NSStackView(views: [find, fitButton, second])
        tools.spacing = Spacing.unit
        tools.edgeInsets = NSEdgeInsets(top: 0, left: Spacing.double, bottom: Spacing.unit, right: Spacing.double)
        let top = NSStackView(views: [label("Database:"), databases, summary, spacer, exportImage, exportMermaid,
                                      helpButton(.editors)])
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
        scroll.backgroundColor = .controlBackgroundColor
        scroll.allowsMagnification = true  // pinch, and ⌘+ ⌘− ⌘0 below
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 3
        canvas.onOpen = { [weak self] table in self?.open(table) }
        let menu = NSMenu()
        menu.add([Commands.openStructure, Commands.openData, Commands.copyName])
        canvas.menu = menu
        let empty = NSMenu()
        empty.add([Commands.refresh, Commands.bigger, Commands.smaller, Commands.actualSize])
        canvas.emptyMenu = empty
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
        exportImage.isEnabled = false
        exportMermaid.isEnabled = false
        let work = activity.start("Drawing the diagram of \(database ?? "a database")", connection: context.connection.id) {}
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
                let virtual = await Task.detached { TableViewSettingsStore.shared.virtualKeys(connection: id) }.value
                guard let schema = context.schema.snapshot.adding(virtual).database(database) else {
                    throw DesignError("\(database) isn't on the server any more")
                }
                self.database = database
                show(ERDiagram(schema), databases: names)
            } catch {
                overlay.show(error: error.localizedDescription, retry: (self, #selector(retry(_:))))
            }
        }
    }

    @objc private func retry(_ sender: Any?) { load() }

    private func show(_ diagram: ERDiagram, databases names: [String]) {
        self.diagram = diagram
        canvas.show(diagram)
        scroll.magnification = 1
        canvas.fit(scroll.contentView.bounds.size)
        canvas.scroll(.zero)
        databases.removeAllItems()
        databases.addItems(withTitles: names)
        databases.selectItem(withTitle: database ?? "")
        let tables = diagram.columns.reduce(0) { $0 + $1.count }
        summary.stringValue = tables == 0 ? "No tables here yet" : "\(tables) tables, \(diagram.links.count) foreign keys"
        summary.toolTip = summary.stringValue
        overlay.hide()
        exportImage.isEnabled = tables > 0
        exportMermaid.isEnabled = tables > 0
        for button in [exportImage, exportMermaid] where !button.isEnabled { button.toolTip = "There are no tables to export" }
        if let main = view.window?.windowController as? MainWindowController, let tab = main.tabs.first(where: { $0.content === self }) {
            main.rename(tab, to: tabTitle)
        }
    }

    @objc func databaseChosen(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem, title != database else { return }
        database = title
        canvas.selected = nil
        load()
    }

    private func open(_ table: String) {
        guard let main = view.window?.windowController as? MainWindowController else { return }
        main.openTableEditor(table, database: database, context: context)
    }

    // MARK: Export

    @objc func exportImage(_ sender: Any?) {
        save(type: .png, name: (database ?? "diagram") + ".png") { [weak self] in self?.canvas.png() }
    }

    @objc func exportMermaid(_ sender: Any?) {
        save(type: UTType(filenameExtension: "mmd") ?? .plainText, name: (database ?? "diagram") + ".mmd") { [weak self] in
            self?.diagram.map { Data($0.mermaid().utf8) }
        }
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
        guard [Commands.openStructure.action, Commands.openData.action, Commands.copyName.action, Commands.copy.action].contains(item.action)
        else { return true }
        let enabled = canvas.selected != nil
        item.explain(enabled: enabled, reason: enabled ? nil : "Click a table first")
        return enabled
    }
}
