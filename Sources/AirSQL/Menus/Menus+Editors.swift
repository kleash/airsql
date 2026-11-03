import AppKit

extension MainMenu {
    /// Lane L5b (editors): Database ▸ Create Table…, New Object ▸ (a view, procedure, function, trigger or event as CREATE
    /// code), ER Diagram. The navigator's slot (before this one) may list Create Table… and ER Diagram already: each shows
    /// once. Until the navigator handles them for the object it is on, the main window does, for the active connection.
    static func addEditorItems(_ menus: Menus) {
        let database = menus.database
        func listed(_ command: Command) -> Bool { database.items.contains { $0.action == command.action && $0.tag == command.tag } }
        if !listed(Commands.createTable) { database.add([Commands.createTable]) }
        let newObject = submenu("New Object", [Commands.newView, Commands.newProcedure, Commands.newFunction, Commands.newTrigger,
                                               Commands.newEvent].map { $0.item() })
        let after = database.items.lastIndex { $0.action == Commands.createTable.action || $0.action == Commands.createObject.action }
        database.insertItem(newObject, at: after.map { $0 + 1 } ?? database.numberOfItems)
        if !listed(Commands.erDiagram) { database.add([Commands.erDiagram]) }
    }
}
