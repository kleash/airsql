import AirSQLCore
import AppKit

/// What Export offers on a diagram, told apart by its tag.
enum DiagramExport: Int, CaseIterable {
    case png, mermaid, plantUML, dot, graphML, drawIO

    var fileExtension: String { ["png", "mmd", "puml", "dot", "graphml", "drawio"][rawValue] }
}

/// The schema tools' commands: the ER diagram's, on `ERDiagramController` (Database ▸ Diagram).
extension Commands {
    private static func export(_ title: String, _ format: DiagramExport, tip: String) -> Command {
        Command(title, #selector(ERDiagramController.exportDiagram(_:)), tag: format.rawValue, tip: tip)
    }

    private static func arrange(_ title: String, _ value: ERLayout.Arrangement, tip: String) -> Command {
        Command(title, #selector(ERDiagramController.arrangeBoxes(_:)), tag: ERLayout.Arrangement.allCases.firstIndex(of: value)!, tip: tip)
    }

    private static func detail(_ title: String, _ value: ERLayout.Detail, tip: String) -> Command {
        Command(title, #selector(ERDiagramController.showDetail(_:)), tag: ERLayout.Detail.allCases.firstIndex(of: value)!, tip: tip)
    }

    static let diagramOfSelection = Command("Diagram of Selected Tables", #selector(MainWindowController.showDiagramOfSelection(_:)),
                                            tip: "Draw only the tables selected in the tree, as a diagram of their own")
    static let diagramOfNeighbours = Command("Diagram of Neighbours", #selector(MainWindowController.showDiagramOfNeighbours(_:)),
                                             tip: "Draw the selected tables and every table that touches them by a foreign key")
    static let diagramNew = Command("New Diagram from Selection…", #selector(ERDiagramController.newDiagram(_:)),
                                    tip: "Keep the selected boxes, or all of them, as a diagram of their own")
    static let diagramRename = Command("Rename Diagram…", #selector(ERDiagramController.renameDiagram(_:)), tip: "Give this diagram another name")
    static let diagramDelete = Command("Delete Diagram", #selector(ERDiagramController.deleteDiagram(_:)),
                                       tip: "Forget this diagram, after asking; the tables themselves aren't touched")
    static let diagramNeighbours = Command("Add Neighbours", #selector(ERDiagramController.addNeighbours(_:)),
                                           tip: "Add every table that touches the selected boxes by a foreign key")
    static let diagramRemove = Command("Remove from Diagram", #selector(ERDiagramController.removeFromDiagram(_:)),
                                       tip: "Take the selected boxes off this diagram; the tables themselves aren't touched")
    static let arrangeLeftToRight = arrange("Left to Right", .leftToRight, tip: "Lay the boxes out again, keys running left to right")
    static let arrangeTopToBottom = arrange("Top to Bottom", .topToBottom, tip: "Lay the boxes out again, keys running top to bottom")
    static let arrangeGrid = arrange("Grid", .grid, tip: "Lay the boxes out again in even rows")
    static let detailAll = detail("All Columns", .allColumns, tip: "Show each table's columns in its box")
    static let detailKeys = detail("Keys Only", .keysOnly, tip: "Show only the columns of primary and foreign keys")
    static let detailNames = detail("Names Only", .namesOnly, tip: "Show only the tables' names")
    static let diagramComments = Command("Comments", #selector(ERDiagramController.toggleComments(_:)), tip: "Show each column's comment after its type")
    static let diagramVirtualKeys = Command("Virtual Keys", #selector(ERDiagramController.toggleVirtualKeys(_:)),
                                            tip: "Draw the foreign keys you defined on this Mac as well as the database's")
    static let exportPNG = export("PNG Picture…", .png, tip: "Save the diagram as a PNG picture")
    static let exportMermaid = export("Mermaid…", .mermaid, tip: "Save the diagram as Mermaid text, for docs and wikis that draw it")
    static let exportPlantUML = export("PlantUML…", .plantUML, tip: "Save the diagram as PlantUML text")
    static let exportDOT = export("Graphviz DOT…", .dot, tip: "Save the diagram as a Graphviz DOT file")
    static let exportGraphML = export("GraphML…", .graphML, tip: "Save the diagram as GraphML, for graph tools")
    static let exportDrawIO = export("draw.io…", .drawIO, tip: "Save the diagram as a file draw.io opens and can edit")
    static let printDiagram = Command("Print Diagram…", #selector(ERDiagramController.printDiagram(_:)), tip: "Print the diagram on one page")

    static let sqlGenerator = Command("SQL Generator…", #selector(AirSQLActions.showSQLGenerator(_:)),
                                      tip: "Show the statements that recreate what is selected, with options, to copy, open or save")
    static let createToConsole = Command("Open CREATE in Query Tab", #selector(AirSQLActions.openCreateInConsole(_:)),
                                         tip: "Put the CREATE statements of what is selected in a new query tab")

    static let indexFromColumns = Command("New Index from Columns", #selector(TableEditorController.indexFromColumns(_:)),
                                          tip: "Make an index of the columns selected in the table editor")
    static let uniqueFromColumns = Command("New Unique Index from Columns", #selector(TableEditorController.uniqueFromColumns(_:)),
                                           tip: "Make a unique index of the columns selected in the table editor")

    static let diagramArrange = [arrangeLeftToRight, arrangeTopToBottom, arrangeGrid]
    static let diagramDetail = [detailAll, detailKeys, detailNames]
    static let diagramExports = [exportPNG, exportMermaid, exportPlantUML, exportDOT, exportGraphML, exportDrawIO]

    static let schema: [Command] = [diagramOfSelection, diagramOfNeighbours, diagramNew, diagramRename, diagramDelete, diagramNeighbours,
                                    diagramRemove, diagramComments, diagramVirtualKeys, printDiagram, sqlGenerator, createToConsole, indexFromColumns, uniqueFromColumns]
        + diagramArrange + diagramDetail + diagramExports
}
