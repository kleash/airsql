import AppKit

extension MainMenu {
    /// Lane L7 (agents): Help ▸ AI Agents. Tools ▸ Agents ▸ Set Up Agents…, Agent Activity and Turn Agents Off are P0's
    /// already (the agent chip's menu has them).
    static func addAgentItems(_ menus: Menus) {
        menus.help.insertItem(Commands.agentGuide.item(), at: min(2, menus.help.numberOfItems))
    }
}
