import AirSQLCore
import AppKit

/// What each side of a compare is: a whole server, a database, or one table or other object.
enum ReconLevel: Int {
    case server, database, object
}

/// One side of a compare: a saved connection, one of its databases (listed once the connection answers; a name can be
/// typed too) and, for two objects, one of its tables, views, routines, triggers, events or sequences.
@MainActor
final class ReconSidePicker: NSObject, NSComboBoxDelegate {
    let view = NSStackView()
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    let databases = NSComboBox()
    let objects = NSComboBox()
    let spinner = NSProgressIndicator()
    /// The objects of the chosen database, by the title `objects` lists them under.
    private var listed: [String: (kind: ReconObject.Kind, name: String)] = [:]
    /// The database `listed` belongs to: leaving the field unchanged keeps the choice.
    private var listedDatabase = ""
    private var loadingObjects: Task<Void, Never>?
    var level = ReconLevel.database {
        didSet {
            databases.isHidden = level == .server
            if level == .object, listed.isEmpty { loadObjects() }
        }
    }
    var connections: [SavedConnection] = [] { didSet { reload() } }
    private(set) var connection: SavedConnection?
    var changed: (() -> Void)?
    private var loading: Task<Void, Never>?
    private let side: String

    var database: String { databases.stringValue.trimmingCharacters(in: .whitespaces) }
    /// The object chosen from the list, for a compare of two objects.
    var object: (kind: ReconObject.Kind, name: String)? { listed[objects.stringValue] }
    /// "Production · shop", "Production", "Production · shop.orders", or "" before a connection is chosen.
    var summary: String {
        guard let connection else { return "" }
        switch level {
        case .server: return connection.displayName
        case .object where object != nil: return "\(connection.displayName) · \(database).\(object?.name ?? "")"
        default: return "\(connection.displayName) · \(database.isEmpty ? "no database" : database)"
        }
    }

    /// How the objects' list writes an object: a table by its name, others with their kind, as the compare's list does.
    private static func title(_ kind: ReconObject.Kind, _ name: String) -> String {
        kind == .table ? name : "\(name) (\(kind.rawValue))"
    }

    init(side: String) {
        self.side = side
        super.init()
        let title = label(side == "source" ? "Source" : "Target", font: .systemFont(ofSize: 12, weight: .semibold),
                          color: .secondaryLabelColor)
        popup.target = self
        popup.action = #selector(connectionChosen(_:))
        popup.toolTip = side == "source" ? "Choose the connection to compare from: the script makes the target like it"
            : "Choose the connection to compare with: the script changes this one"
        popup.setAccessibilityIdentifier("recon.\(side).connection")
        popup.setAccessibilityLabel(side == "source" ? "Source connection" : "Target connection")
        databases.placeholderString = "Database"
        databases.toolTip = "Choose or type the database on this connection"
        databases.setAccessibilityIdentifier("recon.\(side).database")
        databases.setAccessibilityLabel(side == "source" ? "Source database" : "Target database")
        databases.delegate = self
        databases.completes = true
        databases.numberOfVisibleItems = 16
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.toolTip = "Reading the databases on this connection"
        spinner.isHidden = true  // a hidden spinner keeps no space in the bar
        for view in [popup, databases] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        // A long connection name is shortened (its menu has all of it) rather than widening the window past its minimum.
        popup.setContentCompressionResistancePriority(.init(490), for: .horizontal)
        popup.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        databases.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        databases.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        objects.placeholderString = "Table, View or Routine"
        objects.toolTip = "Choose the table, view, routine, trigger, event or sequence to compare"
        objects.setAccessibilityIdentifier("recon.\(side).object")
        objects.setAccessibilityLabel(side == "source" ? "Source object" : "Target object")
        objects.delegate = self
        objects.completes = true
        objects.numberOfVisibleItems = 16
        objects.translatesAutoresizingMaskIntoConstraints = false
        objects.widthAnchor.constraint(equalToConstant: 320).isActive = true
        view.setViews([title, popup, databases, spinner], in: .leading)
        view.spacing = Spacing.unit
        reload()
    }

    private func reload() {
        popup.removeAllItems()
        popup.addItem(withTitle: "Choose a Connection")
        popup.lastItem?.isEnabled = false
        for saved in connections {
            popup.addItem(withTitle: saved.displayName)
            popup.lastItem?.representedObject = saved.id
            popup.lastItem?.image = Self.dot(saved.colour)
            popup.lastItem?.toolTip = saved.routeBadge
        }
        popup.selectItem(at: connection.flatMap { chosen in connections.firstIndex { $0.id == chosen.id }.map { $0 + 1 } } ?? 0)
    }

    /// The connection's colour as a menu item's dot.
    static func dot(_ colour: ConnectionColour) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            (colour.color ?? NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    func choose(_ saved: SavedConnection?, database: String? = nil, object: (kind: ReconObject.Kind, name: String)? = nil) {
        connection = saved
        reload()
        databases.removeAllItems()
        databases.stringValue = database ?? saved?.database ?? ""
        loadDatabases()
        listed = [:]
        listedDatabase = self.database
        objects.removeAllItems()
        objects.stringValue = ""
        if let object {
            let title = Self.title(object.kind, object.name)
            listed[title] = object
            objects.stringValue = title
        }
        if level == .object { loadObjects() }
        changed?()
    }

    @objc private func connectionChosen(_ sender: NSPopUpButton) {
        let id = sender.selectedItem?.representedObject as? UUID
        choose(connections.first { $0.id == id })
    }

    /// Lists the connection's databases, off the main thread, through a tools session of its own.
    private func loadDatabases() {
        loading?.cancel()
        guard let saved = connection, let connect = ReconWindowController.connect else { return }
        spinner.isHidden = false
        spinner.startAnimation(nil)
        let window = popup.window
        loading = Task { [weak self] in
            var names: [String] = [], failure: String?
            do {
                let session = try await connect(saved, window).toolsSession()
                do {
                    names = try await session.rows("SHOW DATABASES").compactMap { $0.first ?? nil }
                        .filter { !["information_schema", "performance_schema"].contains($0.lowercased()) }
                } catch {
                    failure = error.localizedDescription
                }
                await session.close()
            } catch {
                failure = error.localizedDescription
            }
            guard let self, !Task.isCancelled else { return }
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            self.databases.removeAllItems()
            self.databases.addItems(withObjectValues: names)
            // Why the list is empty, where the person looks for it; a name can still be typed.
            self.databases.toolTip = failure.map { "Couldn't list the databases: \($0)" } ?? "Choose or type the database on this connection"
            self.databases.placeholderString = failure == nil ? "Database" : "Couldn't connect"
        }
    }

    /// Lists the chosen database's objects, off the main thread, through a tools session of its own; what is chosen stays.
    private func loadObjects() {
        loadingObjects?.cancel()
        let database = self.database
        guard let saved = connection, let connect = ReconWindowController.connect, !database.isEmpty else { return }
        spinner.isHidden = false
        spinner.startAnimation(nil)
        let window = popup.window
        loadingObjects = Task { [weak self] in
            var found: [(kind: ReconObject.Kind, name: String)] = [], failure: String?
            do {
                let session = try await connect(saved, window).toolsSession()
                do {
                    let cache = SchemaCache(source: session, includes: { $0 == database })
                    try await cache.load()
                    try await cache.loadDetails([database])
                    found = cache.snapshot.database(database).map(Self.objects) ?? []
                } catch {
                    failure = error.localizedDescription
                }
                await session.close()
            } catch {
                failure = error.localizedDescription
            }
            guard let self, !Task.isCancelled else { return }
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            for object in found { self.listed[Self.title(object.kind, object.name)] = object }
            self.objects.removeAllItems()
            self.objects.addItems(withObjectValues: found.map { Self.title($0.kind, $0.name) })
            self.objects.placeholderString = failure == nil ? "Table, View or Routine" : "Couldn't read the objects"
            self.objects.toolTip = failure.map { "Couldn't list the objects: \($0)" }
                ?? "Choose the table, view, routine, trigger, event or sequence to compare"
            self.changed?()
        }
    }

    static func objects(of database: SchemaDatabase) -> [(kind: ReconObject.Kind, name: String)] {
        let kinds: [SchemaTable.Kind: ReconObject.Kind] = [.table: .table, .view: .view, .sequence: .sequence]
        let tables = database.tables.compactMap { table in kinds[table.kind].map { (kind: $0, name: table.name) } }
        let routines = database.routines.map { (kind: $0.kind == .procedure ? ReconObject.Kind.procedure : .function, name: $0.name) }
        return tables + routines + database.triggers.map { (kind: .trigger, name: $0.name) }
            + database.events.map { (kind: .event, name: $0.name) }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // The field shows the choice after this returns.
        DispatchQueue.main.async {
            if notification.object as? NSComboBox === self.databases { self.databaseChanged() }
            self.changed?()
        }
    }

    func controlTextDidChange(_ notification: Notification) { changed?() }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSComboBox === databases { databaseChanged() }
    }

    /// Another database has other objects.
    private func databaseChanged() {
        guard level == .object, database != listedDatabase else { return }
        listedDatabase = database
        listed = [:]
        objects.removeAllItems()
        objects.stringValue = ""
        loadObjects()
    }
}

extension NSToolbarItem.Identifier {
    static let reconCompare = Self("recon.compare")
    static let reconMode = Self("recon.mode")
    static let reconIgnore = Self("recon.ignore")
    static let reconTables = Self("recon.tables")
    static let reconExport = Self("recon.export")
    static let reconChangeset = Self("recon.changeset")
    static let reconSync = Self("recon.sync")
}

/// The compare window's toolbar: Compare, what to compare, the ignore rules and tables; then the report, the changeset
/// and the sync script.
@MainActor
final class ReconToolbar: NSObject, NSToolbarDelegate {
    weak var window: ReconWindowController?
    let compare = button("Compare", id: "recon.compareButton", tip: "Compare the two databases (⌘R)", target: nil,
                         action: #selector(ReconWindowController.refresh(_:)))
    static let levelTip = "Choose what to compare: two servers, two databases, or two tables or other objects"
    /// In the setup bar, before the sides it speaks of.
    let level = popup(["Servers", "Databases", "Objects"], selected: ReconLevel.database.rawValue, id: "recon.level",
                      tip: levelTip, target: nil, action: nil)
    static let modeTip = "Choose what to compare: tables' structure, their rows, or both"
    static let ignoreTip = "Choose differences the compare doesn't count: AUTO_INCREMENT values, DEFINER, collations, whitespace"
    let mode = popup(["Structure and Data", "Structure", "Data"], selected: 0, id: "recon.mode", tip: modeTip, target: nil, action: nil)
    let ignore = NSPopUpButton(frame: .zero, pullsDown: true)
    let tables = button("Tables…", id: "recon.tables", tip: "Choose the tables to compare, columns to leave out, a WHERE per table and renamed tables",
                        target: nil, action: #selector(ReconWindowController.showTables(_:)))
    let export = button("Export Report…", id: "recon.export", tip: Commands.exportReport.tip, target: nil,
                        action: #selector(ReconWindowController.exportReport(_:)))
    let changeset = button("Save as Changeset…", id: "recon.changeset", tip: "Save the sync script as a Liquibase changeset",
                           target: nil, action: #selector(ReconWindowController.saveChangeset(_:)))
    let sync = button("Sync Script…", id: "recon.sync", tip: Commands.syncScript.tip, target: nil,
                      action: #selector(ReconWindowController.showSyncScript(_:)))
    private static let rules: [(title: String, tip: String, rule: WritableKeyPath<ReconIgnoreRules, Bool>)] = [
        ("AUTO_INCREMENT Values", "Don't count tables' next AUTO_INCREMENT values as differences", \.autoIncrement),
        ("DEFINER", "Don't count who views, routines, triggers and events run as; the script leaves DEFINER out", \.definer),
        ("Collations and Character Sets", "Don't count tables' and columns' character sets and collations", \.collation),
        ("Whitespace in Definitions", "Don't count spaces and line breaks in views, routines, triggers and events", \.whitespace),
        ("Column Order", "Don't count the order of a table's columns", \.columnOrder),
        ("Letter Case in Definitions", "Don't count upper and lower case in views, routines, triggers and events", \.letterCase),
        ("Definitions", "Don't count what views, routines, triggers and events say, only whether each exists", \.definitions),
    ]

    override init() {
        super.init()
        mode.target = self
        mode.action = #selector(modeChosen(_:))
        level.target = self
        level.action = #selector(levelChosen(_:))
        ignore.addItem(withTitle: "Ignore Rules")
        for (index, rule) in Self.rules.enumerated() {
            ignore.addItem(withTitle: rule.title)
            ignore.lastItem?.toolTip = rule.tip
            ignore.lastItem?.tag = index
            ignore.lastItem?.target = self
            ignore.lastItem?.action = #selector(ruleToggled(_:))
        }
        ignore.toolTip = Self.ignoreTip
        ignore.setAccessibilityIdentifier("recon.ignore")
        for button in [compare, tables, export, changeset, sync] { button.bezelStyle = .texturedRounded }  // as the main toolbar's
        sync.bezelColor = .controlAccentColor
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.reconCompare, .reconMode, .reconIgnore, .reconTables, .flexibleSpace, .reconExport, .reconChangeset, .reconSync]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let views: [NSToolbarItem.Identifier: (NSControl, String)] = [
            .reconCompare: (compare, "Compare"), .reconMode: (mode, "Compare What"), .reconIgnore: (ignore, "Ignore Rules"),
            .reconTables: (tables, "Tables"), .reconExport: (export, "Export Report"),
            .reconChangeset: (changeset, "Save as Changeset"), .reconSync: (sync, "Sync Script"),
        ]
        guard let (view, title) = views[identifier] else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = view
        item.label = title
        item.paletteLabel = title
        item.toolTip = view.toolTip
        return item
    }

    @objc private func modeChosen(_ sender: NSPopUpButton) {
        window?.options.mode = [ReconOptions.Mode.both, .structure, .data][max(0, sender.indexOfSelectedItem)]
    }

    @objc private func levelChosen(_ sender: NSPopUpButton) {
        window?.choose(level: ReconLevel(rawValue: sender.indexOfSelectedItem) ?? .database)
    }

    @objc private func ruleToggled(_ sender: NSMenuItem) {
        guard let window else { return }
        window.options.ignore[keyPath: Self.rules[sender.tag].rule].toggle()
        update()
    }

    /// Each control enabled where it can act, saying why where it can't.
    func update() {
        guard let window else { return }
        for (index, rule) in Self.rules.enumerated() {
            ignore.item(at: index + 1)?.state = window.options.ignore[keyPath: rule.rule] ? .on : .off
        }
        func set(_ control: NSControl, _ reason: String?, _ tip: String) {
            control.isEnabled = reason == nil
            control.toolTip = reason ?? tip
            // Its item's tooltip too: AppKit gives it to the control as its accessibility help (what VoiceOver reads).
            window.window?.toolbar?.items.first { $0.view === control }?.toolTip = control.toolTip
        }
        let noResult = window.result == nil ? "Compare first: then there is something to show" : nil
        let noScript = window.scriptBlocked
        let what = ["the two servers", "the two databases", "the two objects"][window.level.rawValue]
        set(compare, window.compareBlocked, "Compare \(what) (⌘R)")
        set(tables, window.tablesBlocked,
            "Choose the tables to compare, columns to leave out, a WHERE per table and renamed tables")
        set(export, noResult, Commands.exportReport.tip)
        set(changeset, noScript, "Save the sync script as a Liquibase changeset")
        set(sync, noScript, Commands.syncScript.tip)
        let running = window.isRunning ? window.compareBlocked : nil  // "A compare is running…"
        set(mode, running, Self.modeTip)
        set(level, running, Self.levelTip)
        set(ignore, running, Self.ignoreTip)
    }
}
