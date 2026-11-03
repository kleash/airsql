import AppKit

extension MainMenu {
    /// Lane L8 (compare and Liquibase): Tools ▸ Generate Liquibase Changelog…, Query ▸ Save as Changeset… and Compare
    /// With…. Compare… is P0's already.
    static func addReconItems(_ menus: Menus) {
        // After Compare…, for the compare window (elsewhere nothing answers them, so they are off).
        let tools = menus.tools
        let after = tools.items.firstIndex { $0.action == Commands.compare.action }.map { $0 + 1 } ?? tools.numberOfItems
        for (offset, command) in [Commands.syncScript, Commands.exportReport, Commands.copySyncScript,
                                  Commands.leaveOutOfCompare, Commands.generateLiquibase].enumerated() {
            tools.insertItem(command.item(), at: after + offset)
        }
        // The console's statements as a changeset (LiquibaseResponder), with the console's other commands.
        let query = menus.query
        let profile = query.items.firstIndex { $0.action == Commands.profile.action }.map { $0 + 1 } ?? query.numberOfItems
        query.insertItem(Commands.saveAsChangeset.item(), at: profile)
    }
}
