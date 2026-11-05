import AirSQLCore
import AppKit

/// What agents may never do through AirSQL's windows (plan §2.8), checked where it would happen (approving a change,
/// saving a file, exporting, changing saved data), so every way there (a button, a key, a click, a menu) meets it. A
/// refusal is noted for the harness's reply.
@MainActor
enum AgentGuard {
    /// Where one request's refusal goes: the harness binds one per tool call (calls run side by side), and its actions
    /// carry it along as they carry the agent.
    @MainActor final class Notes {
        var refusal: String?
    }

    @TaskLocal static var notes: Notes?

    /// While an agent's request is carried out: notes `message` and returns true (refused); the person's own: false.
    static func refuses(_ message: @autoclosure () -> String) -> Bool {
        guard AgentGate.agent != nil else { return false }
        notes?.refusal = message()
        return true
    }

    /// Why an agent's request may not change the saved data from `old` to `new`, or nil: person-only things never; the
    /// rest (names, folders, settings) not while Settings ▸ Safety ▸ Ask before agents change anything is on.
    static func refusal(changing old: AirSQLData, to new: AirSQLData) -> String? {
        guard AgentGate.agent != nil, old != new else { return nil }
        if let what = AgentGate.personOnlyChange(from: old, to: new) {
            return "Only the person at the Mac can change \(what): nothing was changed."
        }
        guard old.settings.safety.askBeforeAgentChanges else { return nil }
        return "Saved connections and settings are the person's: nothing was changed (Settings ▸ Safety ▸ Ask before agents "
            + "change anything is on)."
    }

    /// Whether an agent's request may change the saved data to `new`: when not, notes why.
    static func allows(changing old: AirSQLData, to new: AirSQLData) -> Bool {
        guard let refusal = refusal(changing: old, to: new) else { return true }
        notes?.refusal = refusal
        return false
    }

    /// The connection of the console whose editor `view` is, when it is coloured Production: text an agent would put
    /// there waits for the person (the paste gate).
    static func productionConsole(_ view: NSView?) -> SavedConnection? {
        guard let editor = view as? SQLEditorView, let main = editor.window?.windowController as? MainWindowController else {
            return nil
        }
        return main.tabs.lazy.compactMap { tab -> SavedConnection? in
            guard (tab.content as? ConsoleViewController)?.editor === editor, let saved = main.model.connection(tab.connectionID),
                  saved.isProduction else { return nil }
            return saved
        }.first
    }

    /// Asks the person at the Mac on the SQL preview sheet (its agent-gate area), on the frontmost sheet of `window`:
    /// whether they approved. Agents can't press its Run (`SQLPreviewSheet`).
    static func ask(_ request: SQLPreviewRequest, connection: SavedConnection?, on window: NSWindow) async -> Bool {
        var target = window
        while let sheet = target.attachedSheet { target = sheet }
        return await withCheckedContinuation { continuation in
            SQLPreviewSheet.show(request, connection: connection, on: target) { continuation.resume(returning: $0.approved) }
        }
    }
}

/// The gate's questions and UI driving (plan §2.8): the harness's tools carried out as the agent's (`AgentGate.agent`),
/// so what they set off meets the gate; a statement that reaches the driver from there waits on the SQL preview sheet.
extension AgentService {
    /// The UI tools: the harness's, and click's double and right forms by name.
    static let uiTools = AgentServer.tools + ["double_click", "right_click"]

    func drive(_ tool: String, _ arguments: [String: Any], client: String) async -> [String: Any] {
        var name = tool, arguments = arguments
        if tool == "double_click" { (name, arguments["count"]) = ("click", 2) }
        if tool == "right_click" { (name, arguments["button"]) = ("click", "right") }
        let server = harness
        return await AgentGate.$agent.withValue(client) { await server.handle(name, arguments) }
    }

    /// The driver's question about one statement an agent's request sent on a session of the person's: on the SQL
    /// preview sheet, unless the connection's Safety settings say agents' changes needn't ask.
    func approve(_ request: AgentGate.Request) async throws {
        // The connected connection whose sessions these are, by the name they connected with: renaming connections
        // since (agents may rename them while Ask before agents change anything is off) can't point it at another.
        let named = model.open.values.filter { $0.connection.options.name == request.connection }
        let saved = named.count == 1 ? model.connection(named[0].id) : nil
        if let saved, !model.data.safety(for: saved).askBeforeAgentChanges { return }
        guard model.data.settings.agentsAllowed, let window = main?.window else {
            throw AirSQLError(.readOnly, "Agents are off, so nobody was asked: nothing ran.")
        }
        var preview = SQLPreviewRequest(
            change: ChangeSQL(title: "Agent", statements: [request.sql], connection: saved?.id ?? UUID()),
            heading: "Run this statement for \(request.agent)?",
            caption: "What \(request.agent) did in AirSQL's windows sends it to \(request.connection). It may change data or "
                + "structure: check it, then run it or decline.")
        preview.agent = request.agent
        preview.actionTitle = "Run"
        preview.noBackslashEscapes = request.noBackslashEscapes
        guard await AgentGuard.ask(preview, connection: saved, on: window) else {
            throw AirSQLError(.cancelled, AgentGate.declined)
        }
    }
}
