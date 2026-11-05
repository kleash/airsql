import AppKit

extension MainMenu {
    /// Lane L8 (compare and Liquibase): the compare window's commands and Query ▸ Save as Changeset…. Compare… is P0's,
    /// Tools ▸ Generate Liquibase Changelog… the navigator's (Menus+Navigator); LiquibaseResponder answers both of L8b's.
    static func addReconItems(_ menus: Menus) {
        // After Compare…, for the compare window (elsewhere nothing answers them, so they are off).
        let tools = menus.tools
        let after = tools.items.firstIndex { $0.action == Commands.compare.action }.map { $0 + 1 } ?? tools.numberOfItems
        tools.insertItem(Commands.compareWith.item(), at: after)
        tools.insertItem(Commands.compareRows.item(), at: after + 1)
        tools.insertItem(submenu("In Compare", [Commands.syncScript, Commands.exportReport, Commands.copySyncScript, Commands.includeInSync,
                                                Commands.leaveOutOfCompare, Commands.backToServer, Commands.nextDifference,
                                                Commands.previousDifference].map { $0.item() }), at: after + 2)
        // The console's statements as a changeset (LiquibaseResponder), with the console's other commands.
        let query = menus.query
        let profile = query.items.firstIndex { $0.action == Commands.profile.action }.map { $0 + 1 } ?? query.numberOfItems
        query.insertItem(Commands.saveAsChangeset.item(), at: profile)
    }
}
