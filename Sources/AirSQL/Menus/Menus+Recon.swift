import AppKit

extension MainMenu {
    /// Lane L8 (compare and Liquibase): Tools ▸ Generate Liquibase Changelog…, Query ▸ Save as Changeset… and Compare
    /// With…. Compare… is P0's already.
    static func addReconItems(_ menus: Menus) {
        // After Compare…, for the compare window (elsewhere nothing answers them, so they are off).
        let tools = menus.tools
        let after = tools.items.firstIndex { $0.action == Commands.compare.action }.map { $0 + 1 } ?? tools.numberOfItems
        for (offset, command) in [Commands.syncScript, Commands.exportReport, Commands.copySyncScript,
                                  Commands.leaveOutOfCompare].enumerated() {
            tools.insertItem(command.item(), at: after + offset)
        }
    }
}
