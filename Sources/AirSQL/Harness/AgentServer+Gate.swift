import AirSQLCore
import AppKit

/// The gate's side of UI driving (plan §2.8), for an agent's requests only (`AgentGate.agent`): the Settings window is
/// to look at, the clipboard is the person's, text for a production console waits for their OK, and the rows of a
/// connection whose agent access doesn't include reading data are left out of snapshots and covered in screenshots.
extension AgentServer {
    static let pasteActions: Set<String> = ["paste:", "pasteAsPlainText:", "pasteAsRichText:", "pasteAndMatchStyle:"]

    /// Refuses an agent's action in `window` (or a sheet of it) when that window is the person's alone: Settings.
    func checkAgentMayAct(in window: NSWindow?) throws {
        guard AgentGate.agent != nil, var root = window else { return }
        while let parent = root.sheetParent { root = parent }
        if root.windowController is SettingsWindowController {
            throw Failure("Settings are the person's: agents can look at them (snapshot, include settings) but not change them.")
        }
    }

    /// A button marked destructive (Disconnect with a transaction open, Don't Save, Clear) is the person's call: an
    /// agent's press is refused (noted for the reply).
    static func refusesDestructive(_ button: NSButton) -> Bool {
        button.hasDestructiveAction && AgentGuard.refuses("“\(button.title)” can't be undone: only the person at the Mac can "
                                                          + "choose it. Ask them, or choose another button.")
    }

    /// Refuses an agent's menu command that pastes, or acts in Settings.
    func checkAgentMayChoose(_ action: Selector, target: AnyObject?) throws {
        guard AgentGate.agent != nil else { return }
        if Self.pasteActions.contains(NSStringFromSelector(action)) {
            throw Failure("The clipboard is the person's: agents can't paste. Use type or set to put text in a field.")
        }
        if action == #selector(NSApplication.terminate(_:)) { throw Failure("Only the person at the Mac can quit AirSQL.") }
        let window = (target as? NSView)?.window ?? target as? NSWindow ?? (target as? NSWindowController)?.window
            ?? (target as? NSViewController)?.view.window
        try checkAgentMayAct(in: window)
    }

    /// Text an agent would put in a production console's editor waits for the person's OK, on the SQL preview sheet.
    func checkPersonAllows(_ text: String, into view: NSView?) async throws {
        guard let agent = AgentGate.agent, let saved = AgentGuard.productionConsole(view), let window = main?.window else { return }
        var request = SQLPreviewRequest(change: ChangeSQL(title: "Text from \(agent)", statements: [text], connection: saved.id),
                                        heading: "Put this text in a console of \(saved.displayName)?",
                                        caption: "\(agent) wants to type it into a production console. Nothing runs: it goes "
                                            + "into the editor, for you to check and run yourself.")
        request.agent = agent
        request.actionTitle = "Put It In"
        request.text = text
        guard await AgentGuard.ask(request, connection: saved, on: window) else {
            throw Failure("The person at the Mac declined: the text wasn't put in the production console.")
        }
    }

    /// Shortcuts of commands an agent may not choose, and keys that would change a production console's text (type asks
    /// once): refused.
    func checkAgentMayPress(_ keys: KeyCombo, in window: NSWindow) throws {
        guard AgentGate.agent != nil else { return }
        for action in menuItems(for: keys).compactMap(\.action) { try checkAgentMayChoose(action, target: nil) }  // ⌘V, ⌘Q
        if keys.modifiers.intersection([.command, .control]).isEmpty, AgentGuard.productionConsole(window.firstResponder as? NSView) != nil {
            throw Failure("Typing into a production console needs the person's OK: use type or set, which ask them once.")
        }
    }

    // MARK: Data agents may not read

    static let hiddenNote = "Hidden from agents: this connection's agent access doesn't include reading data"

    /// Views that show a connection's rows: grids (table data, results, Transpose and Record View), what the grid's viewer
    /// shows of them (the value panel, View As ▸ Text and Tree, a chart, Column Summary, the status bar's figure), the
    /// filters a cell's value goes into (a result's conditions, the table tab's WHERE, Filter by Values' list, Type a
    /// Value…'s field), the compare's rows and sync script, the process list (other sessions' statements carry their
    /// values), the console's Messages (a server's error quotes values: Duplicate entry '…') and an EXPLAIN's tree (its
    /// table is a grid), the SQL preview's statements (an Apply's or a sync's carry the rows' values) and the SQL log
    /// (every connection's statements, in a window of its own: hidden from every agent).
    static func showsData(_ view: NSView) -> Bool {
        view is DataGridView || ["valuePanel", "grid.text", "grid.tree", "grid.chart", "columnSummary", "grid.figure", "grid.set",
                                 "grid.lookup", "grid.editor.problem", "result.filter", "tableData.where", "tableData.suggestions", "values.list",
                                 "quickFilter.value", "recon.rows", "recon.script", "processes.list", "console.messages",
                                 "console.planTree", "preview.sql", "sqlLog.text"]
            .contains(view.accessibilityIdentifier())
    }

    /// Whether `view` shows rows an agent may not read: of a connection whose agent access is below Schema + read, or of
    /// one it can't tell (it fails closed). The main window's are its selected tab's connection's (and a console
    /// comparison's other connection's); a compare's, both sides'.
    func hidesData(_ view: NSView) -> Bool {
        guard AgentGate.agent != nil, Self.showsData(view) else { return false }
        var window = view.window
        while let parent = window?.sheetParent ?? (window?.className.contains("Popover") == true ? window?.parent : nil) {
            window = parent
        }
        let connections: [UUID?]
        if let recon = window?.windowController as? ReconWindowController {
            connections = [recon.source.connection?.id, recon.target.connection?.id]
        } else if let main, window === main.window {
            // A console's comparison with another connection's result shows that connection's rows too.
            let compared = (main.selectedTab?.content as? ConsoleViewController)?.currentResult?.otherConnection
            connections = [main.selectedTab?.connectionID] + (compared.map { [$0] } ?? [])
        } else {
            connections = [nil]
        }
        return connections.contains { (model.connection($0)?.agentAccess.rank ?? 0) < AgentAccess.schemaRead.rank }
    }

    /// The accessibility tree under `root` as an agent may see it.
    func nodes(_ root: NSObject) -> [AXNode] {
        AXNode.flatten(root, hiding: AgentGate.agent == nil ? nil : { [self] in hidesData($0) })
    }

    /// Covers, in a screenshot being drawn, what `window` (placed at `origin`) shows that an agent may not read.
    func coverHidden(in window: NSWindow, at origin: NSPoint) {
        guard AgentGate.agent != nil else { return }
        let hidden = Self.views(NSView.self, in: window.contentView?.superview ?? window.contentView)
            .filter { !$0.isHiddenOrHasHiddenAncestor && hidesData($0) }
        for view in hidden {
            let shown = view.enclosingScrollView ?? view
            let rect = shown.convert(shown.bounds, to: nil).offsetBy(dx: origin.x, dy: origin.y)
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 6), xRadius: Radius.control, yRadius: Radius.control).fill()
                let words = NSAttributedString(string: "Hidden from agents", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
                let size = words.size()
                if rect.width > size.width + 16, rect.height > size.height + 12 {
                    words.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
                }
            }
        }
    }
}
