import AppKit

extension MainMenu {
    /// Lane L7 (agents): Help ▸ AI Agents; View ▸ Agent Results and Query ▸ Open in New Query (the Agent tab's).
    /// Tools ▸ Agents ▸ Set Up Agents…, Agent Activity and Turn Agents Off are P0's already (the agent chip's menu has
    /// them).
    static func addAgentItems(_ menus: Menus) {
        menus.help.insertItem(Commands.agentGuide.item(), at: min(2, menus.help.numberOfItems))
        let cancelAll = menus.view.items.firstIndex { $0.action == Commands.cancelAll.action }
        menus.view.insertItem(Commands.agentResults.item(), at: cancelAll.map { $0 + 1 } ?? menus.view.items.count)
        menus.query.add([nil, Commands.openInNewConsole])
    }
}
