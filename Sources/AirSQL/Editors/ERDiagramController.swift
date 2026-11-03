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
    private let scroll = NSScrollView()

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
        let bar = NSStackView(views: [label("Database:"), databases, summary, spacer, exportImage, exportMermaid])
        bar.spacing = Spacing.unit
        bar.alignment = .firstBaseline
        bar.setCustomSpacing(Spacing.double, after: databases)
        bar.edgeInsets = NSEdgeInsets(top: Spacing.unit, left: Spacing.double, bottom: Spacing.unit, right: Spacing.double)
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.backgroundColor = .controlBackgroundColor
        canvas.onOpen = { [weak self] table in self?.open(table) }
        let menu = NSMenu()
        menu.add([Commands.openStructure, Commands.copyName])
        canvas.menu = menu
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
        canvas.fit(scroll.contentSize)
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
                guard let schema = context.schema.snapshot.database(database) else { throw DesignError("\(database) isn't on the server any more") }
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
        canvas.fit(scroll.contentSize)
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

    @objc func copyName(_ sender: Any?) {
        guard let table = canvas.selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SQLQuote.identifier(table), forType: .string)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == Commands.openStructure.action || item.action == Commands.copyName.action else { return true }
        let enabled = canvas.selected != nil
        item.explain(enabled: enabled, reason: enabled ? nil : "Click a table first")
        return enabled
    }
}
