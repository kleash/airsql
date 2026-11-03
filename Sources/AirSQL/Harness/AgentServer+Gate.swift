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

    /// The console tab whose editor `view` is, when its connection is coloured Production.
    func productionConsole(_ view: NSView?) -> SavedConnection? {
        guard let editor = view as? SQLEditorView else { return nil }
        return (main?.tabs ?? []).lazy.compactMap { tab -> SavedConnection? in
            guard (tab.content as? ConsoleViewController)?.editor === editor, let saved = self.model.connection(tab.connectionID),
                  saved.colour == .production else { return nil }
            return saved
        }.first
    }

    /// Text an agent would put in a production console's editor waits for the person's OK, on the SQL preview sheet.
    func checkPersonAllows(_ text: String, into view: NSView?) async throws {
        guard let agent = AgentGate.agent, let saved = productionConsole(view), let window = main?.window else { return }
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

    /// Keys an agent presses into a production console's editor that would change its text: refused (type asks once).
    func checkAgentMayPress(_ keys: KeyCombo, in window: NSWindow) throws {
        guard AgentGate.agent != nil else { return }
        if menuItems(for: keys).contains(where: { $0.action.map { Self.pasteActions.contains(NSStringFromSelector($0)) } ?? false }) {
            throw Failure("The clipboard is the person's: agents can't paste. Use type or set to put text in a field.")
        }
        if keys.modifiers.intersection([.command, .control]).isEmpty, productionConsole(window.firstResponder as? NSView) != nil {
            throw Failure("Typing into a production console needs the person's OK: use type or set, which ask them once.")
        }
    }

    // MARK: Data agents may not read

    static let hiddenNote = "Hidden from agents: this connection's agent access doesn't include reading data"

    /// Views that show a connection's rows: grids (table data, results, Transpose), the compare's rows and sync script.
    static func showsData(_ view: NSView) -> Bool {
        view is DataGridView || ["recon.rows", "recon.script"].contains(view.accessibilityIdentifier())
    }

    /// Whether `view` shows rows an agent may not read: of a connection whose agent access is below Schema + read, or of
    /// one it can't tell (it fails closed). The main window's are its selected tab's connection's; a compare's, both
    /// sides'.
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
            connections = [main.selectedTab?.connectionID]
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
