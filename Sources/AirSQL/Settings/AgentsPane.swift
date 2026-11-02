import AirSQLCore
import AppKit

/// Settings ▸ Agents: whether AI agents may use AirSQL, and the folder their exports go to (plan §2.8). The agents lane
/// (L7) adds the setup for each client here.
final class AgentsPane: SettingsPaneController {
    /// Where agents' exports go: inside AirSQL's folder, so macOS asks nothing (R18).
    static var exportFolder: URL { Store.directory.appendingPathComponent("Agent Exports", isDirectory: true) }

    override func build() {
        form.row("", [toggle("Allow AI agents to use AirSQL", id: "settings.agentsAllowed",
                             tip: "Off by default: lets Claude Code, Gemini CLI or another MCP client use AirSQL",
                             \.agentsAllowed)],
                 caption: "Each connection's access (Off, Schema, Schema + read, + analytics) is set in its Agents tab; "
                    + "Production starts at Off. Agents never see passwords, and every action they take is listed.")
        let folder = label(Self.shown(Self.exportFolder), truncates: true)
        folder.toolTip = Self.shown(Self.exportFolder)
        folder.lineBreakMode = .byTruncatingMiddle
        folder.isSelectable = true
        form.row("Exports", [folder, action("Show in Finder", id: "settings.agentExports",
                                            tip: "Show the folder agents save query results in") { [weak self] in
            self?.reveal(Self.exportFolder)
        }], caption: "Files agents save (with the analytics access) go here, and nowhere else.")
    }
}
