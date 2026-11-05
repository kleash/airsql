import AppKit

extension MainMenu {
    /// Lane L5b (editors): Database ▸ Create Table…, New Object ▸ (a view, procedure, function, trigger or event as CREATE
    /// code), ER Diagram. The navigator's slot (before this one) may list Create Table… and ER Diagram already: each shows
    /// once. Until the navigator handles them for the object it is on, the main window does, for the active connection.
    static func addEditorItems(_ menus: Menus) {
        let database = menus.database
        let newObject = submenu("New Object", ([Commands.createObject, nil, Commands.newView, Commands.newProcedure, Commands.newFunction,
                                                Commands.newTrigger, Commands.newEvent] as [Command?]).map { $0?.item() ?? .separator() })
        let after = database.items.firstIndex { $0.action == Commands.createTable.action }.map { $0 + 1 } ?? database.numberOfItems
        database.insertItem(newObject, at: after)
        let diagram = submenu("Diagram", ([Commands.erDiagram, Commands.diagramOfSelection, Commands.diagramOfNeighbours, nil, Commands.diagramNew,
                                           Commands.diagramRename, Commands.diagramDelete, nil, Commands.diagramNeighbours, Commands.diagramRemove, nil]
                                          + Commands.diagramArrange + [nil] + Commands.diagramDetail
                                          + [Commands.diagramComments, Commands.diagramVirtualKeys, nil]
                                          + Commands.diagramExports + [Commands.printDiagram])
            .map { $0?.item() ?? .separator() })
        // With the other views of the database, before the server's.
        let server = database.items.firstIndex { $0.title == "Server" } ?? database.numberOfItems
        database.insertItem(diagram, at: server - 1)
    }
}
