import AirSQLCore
import AppKit

/// One side of a compare: a saved connection and one of its databases (listed once the connection answers; a name can
/// be typed too).
@MainActor
final class ReconSidePicker: NSObject, NSComboBoxDelegate {
    let view = NSStackView()
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    let databases = NSComboBox()
    let spinner = NSProgressIndicator()
    var connections: [SavedConnection] = [] { didSet { reload() } }
    private(set) var connection: SavedConnection?
    var changed: (() -> Void)?
    private var loading: Task<Void, Never>?
    private let side: String

    var database: String { databases.stringValue.trimmingCharacters(in: .whitespaces) }
    /// "Production · shop", or "" before a connection is chosen.
    var summary: String { connection.map { "\($0.displayName) · \(database.isEmpty ? "no database" : database)" } ?? "" }

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
        for view in [popup, databases] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        // A long connection name is shortened (its menu has all of it) rather than widening the window past its minimum.
        popup.setContentCompressionResistancePriority(.init(490), for: .horizontal)
        popup.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        databases.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        databases.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
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

    func choose(_ saved: SavedConnection?, database: String? = nil) {
        connection = saved
        reload()
        databases.removeAllItems()
        databases.stringValue = database ?? saved?.database ?? ""
        loadDatabases()
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
            self.databases.removeAllItems()
            self.databases.addItems(withObjectValues: names)
            // Why the list is empty, where the person looks for it; a name can still be typed.
            self.databases.toolTip = failure.map { "Couldn't list the databases: \($0)" } ?? "Choose or type the database on this connection"
            self.databases.placeholderString = failure == nil ? "Database" : "Couldn't connect"
        }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { self.changed?() }  // the field shows the choice after this returns
    }

    func controlTextDidChange(_ notification: Notification) { changed?() }
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
    ]

    override init() {
        super.init()
        mode.target = self
        mode.action = #selector(modeChosen(_:))
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
        set(compare, window.compareBlocked, "Compare the two databases (⌘R)")
        set(tables, window.result == nil ? "Compare once to list the tables, then choose which to compare" : nil,
            "Choose the tables to compare, columns to leave out, a WHERE per table and renamed tables")
        set(export, noResult, Commands.exportReport.tip)
        set(changeset, noResult, "Save the sync script as a Liquibase changeset")
        set(sync, noResult, Commands.syncScript.tip)
        let running = window.isRunning ? window.compareBlocked : nil  // "A compare is running…"
        set(mode, running, Self.modeTip)
        set(ignore, running, Self.ignoreTip)
    }
}
