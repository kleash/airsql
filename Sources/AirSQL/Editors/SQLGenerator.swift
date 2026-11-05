import AirSQLCore
import AppKit

/// The SQL Generator: the statements that recreate the chosen objects, live as its options change, to copy, open in a query
/// tab or save as a file per object. It reads only. The statements load off the main thread (an Activity with Cancel).
@MainActor
final class SQLGeneratorController: NSViewController, TabContent {
    let context: EditorContext
    let objects: [DatabaseObject]
    private let activity: ActivityCenter
    private var script: DDLScript?

    let (textScroll, text) = SQLEditorView.make(fontSize: 12.5)
    let overlay = EditorOverlay()
    let summary = label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, truncates: true)
    let layouts = popup(["One folder", "By kind", "By database and kind", "Numbered"], selected: 1,
                        id: "generator.layout", tip: "Choose how Save to Folder lays its files out", target: nil, action: nil)
    private(set) lazy var copyButton = button("Copy", id: "generator.copy", tip: "Copy the script", target: self, action: #selector(copyScript(_:)))
    private(set) lazy var consoleButton = button("Open in Query Tab", id: "generator.console", tip: "Put the script in a new query tab: nothing runs until you do",
                                                 target: self, action: #selector(openInConsole(_:)))
    private(set) lazy var saveButton = button("Save to Folder…", id: "generator.save", tip: "Write a .sql file for each object in a folder you choose",
                                              target: self, action: #selector(saveToFolder(_:)))
    /// The boxes, with what each sets.
    private(set) lazy var boxes: [(NSButton, WritableKeyPath<DDLScript.Options, Bool>)] = [
        (box("IF NOT EXISTS", "generator.ifNotExists", "Add IF NOT EXISTS where this server takes it"), \.ifNotExists),
        (box("OR REPLACE", "generator.orReplace", "Add OR REPLACE where this server takes it"), \.orReplace),
        (box("Skip DEFINER", "generator.skipDefiner", "Leave out who objects run as, so they suit another server"), \.skipDefiner),
        (box("Database names", "generator.databaseNames", "Write each object's name with its database"), \.databaseNames),
        (box("Indexes", "generator.indexes", "Keep the tables' indexes", on: true), \.indexes),
        (box("Foreign keys", "generator.foreignKeys", "Keep the tables' foreign keys", on: true), \.foreignKeys),
        (box("AUTO_INCREMENT", "generator.autoIncrement", "Keep each table's next AUTO_INCREMENT number", on: true), \.autoIncrement),
        (box("Triggers", "generator.triggers", "Add the triggers of the tables chosen", on: true), \.triggers),
    ]

    init(context: EditorContext, objects: [DatabaseObject], activity: ActivityCenter) {
        self.context = context
        self.objects = objects
        self.activity = activity
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var tabTitle: String { objects.count == 1 ? objects[0].name + " · DDL" : "SQL Generator" }

    private func box(_ title: String, _ id: String, _ tip: String, on: Bool = false) -> NSButton {
        checkbox(title, id: id, tip: tip, on: on, target: self, action: #selector(optionChanged(_:)))
    }

    override func loadView() {
        text.isEditable = false
        text.setAccessibilityIdentifier("generator.text")
        text.toolTip = "The statements that recreate what you chose, kept up to date with the options"
        let rows = [boxes.prefix(4), boxes.suffix(4)].map { row -> NSStackView in
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let line = NSStackView(views: row.map(\.0) + [spacer])
            line.spacing = Spacing.double
            line.edgeInsets = NSEdgeInsets(top: Spacing.unit, left: Spacing.double, bottom: 0, right: Spacing.double)
            return line
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let actions = NSStackView(views: [summary, spacer, layouts, saveButton, consoleButton, copyButton, helpButton(.editors)])
        actions.spacing = Spacing.unit
        actions.edgeInsets = NSEdgeInsets(top: Spacing.unit, left: Spacing.double, bottom: Spacing.unit, right: Spacing.double)
        let bar = NSStackView(views: rows + [actions])
        bar.orientation = .vertical
        bar.spacing = 0
        bar.alignment = .width
        let root = editorLayout(bar: bar, content: textScroll)
        root.addSubview(overlay)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: textScroll.topAnchor), overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        root.setAccessibilityIdentifier("generator")
        view = root
        load()
    }

    func load() {
        overlay.show(loading: "Reading \(objects.count == 1 ? objects[0].name : "\(objects.count) objects")…")
        enable(false)
        let context = self.context, objects = self.objects
        let reading = Task { () -> DDLScript in
            if context.schema.snapshot.server == nil { try await context.schema.load() }
            guard let server = context.schema.snapshot.server else { throw DesignError("The server didn't say what it is") }
            // The triggers of the tables chosen, which the Triggers box keeps or leaves out.
            var triggers: [DatabaseObject: String] = [:]
            for object in objects where object.kind == .table {
                for trigger in context.schema.snapshot.database(object.database)?.triggers ?? [] where trigger.table == object.name {
                    triggers[DatabaseObject(.trigger, object.database, trigger.name)] = trigger.table
                }
            }
            let all = objects + triggers.keys.filter { !objects.contains($0) }.sorted { $0.name < $1.name }
            return DDLScript(try await context.read { try await DDLScript.load(all, triggers: triggers, from: $0) },
                             server: server)
        }
        let work = activity.start("Reading the statements of \(tabTitle)", connection: context.connection.id) { reading.cancel() }
        Task {
            defer { work.end() }
            do {
                script = try await reading.value
                overlay.hide()
                show()
                enable(true)
            } catch is CancellationError {
                overlay.show(error: "Stopped before everything was read", retry: (self, #selector(retry(_:))))
            } catch {
                overlay.show(error: error.localizedDescription, retry: (self, #selector(retry(_:))))
            }
        }
    }

    @objc private func retry(_ sender: Any?) { load() }

    private func enable(_ enabled: Bool) {
        for control in [copyButton, consoleButton, saveButton] { control.isEnabled = enabled }
    }

    private func show() {
        guard var script else { return }
        for (control, path) in boxes { script.options[keyPath: path] = control.state == .on }
        self.script = script
        text.noBackslashEscapes = context.schema.snapshot.server?.noBackslashEscapes ?? false
        text.setText(script.text)
        summary.stringValue = script.items.count == 1 ? "1 object" : "\(script.items.count) objects"
    }

    @objc func optionChanged(_ sender: Any?) { show() }

    @objc func copyScript(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.string, forType: .string)
    }

    @objc func openInConsole(_ sender: Any?) {
        guard let main = view.window?.windowController as? MainWindowController else { return }
        _ = main.openConsole(text: text.string, title: nil, connection: context.connection.id)
    }

    @objc func saveToFolder(_ sender: Any?) {
        guard let window = view.window, let script else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose the folder for a .sql file per object; files of the same name are replaced"
        let files = script.files(DDLScript.Layout(rawValue: layouts.indexOfSelectedItem) ?? .byKind)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url else { return }
            Task.detached {
                do {
                    try Self.write(files, to: folder)
                } catch {
                    await MainActor.run { showError(error.localizedDescription, title: "Couldn't save the files", on: window) }
                }
            }
        }
    }

    nonisolated static func write(_ files: [(path: String, text: String)], to folder: URL) throws {
        for file in files {
            let url = folder.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.text.utf8).write(to: url, options: .atomic)
        }
    }
}
