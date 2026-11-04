import AirSQLCore
import AppKit

/// Settings ▸ Safety (plan §2.10): what asks first, on by default. These are the defaults: a connection can have its
/// own in its Safety tab, and one coloured Production starts with the strict preset. Agents can never change them.
final class SafetyPane: SettingsPaneController {
    override var helpPage: HelpPage { .safety }

    /// What each switch protects against, by its id: here (with its default) and in a connection's Safety tab.
    static let tips = [
        "unboundedWrite": "Protect against changing or deleting every row of a table by mistake",
        "consoleWrite": "Ask first at every INSERT, UPDATE, DELETE or change of structure you run",
        "previewApply": "Show exactly what Apply will run before it runs",
        "drop": "Ask before dropping or emptying a table; a database's name must be typed",
        "typeTableName": "Protect against dropping the wrong table",
        "restore": "Ask also when the dump would write to another database than the one chosen",
        "agentChanges": "Hold what an agent would change through AirSQL's windows until you allow it",
        "unindexedSort": "Ask first: sorting millions of rows without an index can slow the server down",
        "warnOnClose": "Ask before closing a tab or quitting, so nothing is lost",
    ]

    private static func tip(_ id: String, _ preset: String) -> String { (tips[id] ?? "") + " (\(preset))" }

    override func build() {
        form.heading("Changing data")
        form.row("", [toggle("Ask before UPDATE or DELETE without WHERE", id: "settings.safety.unboundedWrite",
                             tip: Self.tip("unboundedWrite", "on by default"),
                             \.safety.askBeforeUnboundedWrite)])
        form.row("", [toggle("Ask before any write from the console", id: "settings.safety.consoleWrite",
                             tip: Self.tip("consoleWrite", "off by default"),
                             \.safety.askBeforeConsoleWrite)])
        form.row("", [toggle("Show the SQL before the grid's Apply", id: "settings.safety.previewApply",
                             tip: Self.tip("previewApply", "off by default"),
                             \.safety.previewBeforeApply)])
        form.row("", [toggle("Ask before DROP or TRUNCATE", id: "settings.safety.drop",
                             tip: Self.tip("drop", "on by default"),
                             \.safety.askBeforeDrop)])
        form.row("", [toggle("Type a table's name to drop or empty it", id: "settings.safety.typeTableName",
                             tip: Self.tip("typeTableName", "off by default, on for Production"),
                             \.safety.typeNameForTables)])
        form.row("", [toggle("Ask before restoring into a database that has tables", id: "settings.safety.restore",
                             tip: Self.tip("restore", "on by default"),
                             \.safety.askBeforeRiskyRestore)])
        let sync = checkbox("Leave DROP and DELETE out of sync scripts unless ticked", id: "settings.safety.sync",
                            tip: "Always on: a sync script never removes tables or rows you didn't tick",
                            on: SafetySettings.syncLeavesOutDestructive, target: nil, action: nil)
        sync.isEnabled = false
        form.row("", [sync])

        form.heading("Agents")
        form.row("", [toggle("Ask before agents change anything", id: "settings.safety.agentChanges",
                             tip: Self.tip("agentChanges", "on by default"),
                             \.safety.askBeforeAgentChanges)])
        form.row("Rows per query", [number(\.safety.agentRowCap, id: "settings.safety.agentRowCap",
                                           tip: "Type the most rows an agent's query returns (10,000 by default; 1,000 for Production)",
                                           range: 1...1_000_000, width: 90)])
        form.row("Time limit", [number(\.safety.agentTimeout, id: "settings.safety.agentTimeout",
                                       tip: "Type how long an agent's query may run (30 s by default; 15 s for Production)",
                                       range: 1...3_600),
                                label("seconds", color: .secondaryLabelColor)])

        form.heading("Sessions")
        form.row("Open transaction", [label("Warn after", color: .secondaryLabelColor),
                                      number(\.safety.openTransactionMinutes, id: "settings.safety.openTransaction",
                                             tip: "Warn when a transaction stays open this long (15 minutes by default; 5 for "
                                                 + "Production)", range: 1...1_440),
                                      label("minutes", color: .secondaryLabelColor)],
                 caption: "Keep-alive stops for it then, so a forgotten transaction can't hold its locks for ever.")
        form.row("", [toggle("Ask before sorting a large table by a column without an index", id: "settings.safety.unindexedSort",
                             tip: Self.tip("unindexedSort", "on by default"),
                             \.safety.askBeforeUnindexedSort)])
        form.row("", [toggle("Warn when closing with an open transaction or pending edits", id: "settings.safety.warnOnClose",
                             tip: Self.tip("warnOnClose", "on by default"),
                             \.safety.warnOnClose)])
        form.row("", [action("Restore Defaults", id: "settings.safety.restoreDefaults",
                             tip: "Put every switch and limit on this pane back to AirSQL's defaults") { [weak self] in
            self?.model.data.settings.safety = SafetySettings()
            self?.reloadPane()
        }], caption: "A connection can override these in its Safety tab. One coloured Production starts strict: writes from a query tab "
            + "ask, Apply shows its SQL, tables need their names typed, agents get 1,000 rows and 15 seconds. Read-only is a "
            + "switch of each connection.")
    }

    /// Shows the settings again after Restore Defaults.
    private func reloadPane() {
        guard let tabs = parent as? NSTabViewController,
              let item = tabs.tabViewItems.first(where: { $0.viewController === self }) else { return }
        let fresh = SafetyPane(model: model)
        fresh.title = title
        item.viewController = fresh
    }
}
