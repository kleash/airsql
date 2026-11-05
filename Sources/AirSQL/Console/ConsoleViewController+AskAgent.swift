import AirSQLCore
import AppKit

/// Query ▸ Ask an Agent: copies a request for the person's own agent. AirSQL has no model of its own; the agent answers
/// through its usual tools, behind the gate, whatever the request says (`AgentRequest`).
extension ConsoleViewController {
    @objc func askAgent(_ sender: Any?) {
        guard let request = ((sender as? NSMenuItem)?.tag).flatMap(AgentRequest.init(rawValue:)), let window = view.window,
              !AgentGuard.refuses("Asking an agent is the person's to do.") else { return }
        guard request == .write else { return copy(request, wish: nil) }
        let wish = textField("", placeholder: "Which customers ordered twice this month?", id: "console.agentWish",
                             tip: "Type what you want the SQL to do", width: 320)
        wish.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        wish.translatesAutoresizingMaskIntoConstraints = true
        ConsoleClosing.alert(window, "What should the SQL do?", "AirSQL copies this for your agent, with the name of this tab.",
                             buttons: [("Copy Request", "Copy the request, to paste into your agent"), ("Cancel", "Copy nothing")],
                             destructive: nil, accessory: wish) { [weak self] choice in
            if choice == 0 { self?.copy(request, wish: wish.stringValue) }
        }
    }

    private func copy(_ request: AgentRequest, wish: String?) {
        guard let tab, let saved = connection else { return }
        let range = editor.selectedRange(), text = editor.string
        let first = ConsoleScript.line(of: range.location, in: text), last = ConsoleScript.line(of: NSMaxRange(range), in: text)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(request.prompt(tab: tab.id.uuidString, title: tab.title, connection: saved.displayName,
                                                      lines: request == .write ? nil : first...max(first, last), wish: wish), forType: .string)
        note(.info, "A request for your agent is on the clipboard: paste it into your agent. It holds no SQL: the agent reads this tab at "
             + "the access \(saved.displayName) allows.")
    }

    /// Whether Ask an Agent can work: agents are on, may see this connection and, to fix, something failed.
    func askAgentVerdict(_ item: NSMenuItem) -> (Bool, String) {
        guard model.data.settings.agentsAllowed else { return (false, "Turn agents on first: AirSQL ▸ Settings ▸ Agents") }
        guard let saved = connection else { return (false, "Choose a connection for this tab first") }
        guard saved.agentAccess != .off else { return (false, "Agents can't see \(saved.displayName): choose a level in Settings ▸ Agents") }
        if item.tag == AgentRequest.fix.rawValue, lastOutcome?.error == nil { return (false, "The last run here had no error") }
        return (true, "")
    }
}
