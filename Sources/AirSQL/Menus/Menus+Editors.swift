import AppKit

extension MainMenu {
    /// Lane L5b (editors): Database ▸ Create Table…, New Object ▸ (a view, procedure, function, trigger or event as CREATE
    /// code), ER Diagram. Until the navigator (L5a) handles them for the object it is on, the main window does, for the
    /// active connection and its default database.
    static func addEditorItems(_ menus: Menus) {
        menus.database.add([Commands.createTable])
        menus.database.addItem(submenu("New Object", [Commands.newView, Commands.newProcedure, Commands.newFunction,
                                                      Commands.newTrigger, Commands.newEvent].map { $0.item() }))
        menus.database.add([Commands.erDiagram])
    }
}
