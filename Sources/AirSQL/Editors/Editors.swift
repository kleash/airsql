import AirSQLCore
import AppKit

/// What the editors work on (the table editor, the object editors, the ER diagram): a connected connection, its
/// sessions (the editors read and run on a tools session of their own, opened for each piece of work) and its schema
/// cache (refreshed after each change, so the tree and completion see it). On the main actor: the statements run on
/// their session's own thread, so nothing waits here.
@MainActor
struct EditorContext {
    let connection: SavedConnection
    let sessions: Connection
    let schema: SchemaCache
    /// Answers the editors' reads instead of a tools session (the tests' recorded server); nil: a tools session.
    var reads: SchemaQuerying?

    /// Runs a read on `reads`, else on a tools session of its own.
    func read<T>(_ work: (SchemaQuerying) async throws -> T) async throws -> T {
        if let reads { return try await work(reads) }
        return try await withTools { try await work($0) }
    }

    /// Runs `work` on a tools session of its own, closed after.
    func withTools<T>(_ work: (DBConnection) async throws -> T) async throws -> T {
        let session = try await sessions.toolsSession()
        do {
            let result = try await work(session)
            await session.close()
            return result
        } catch {
            await session.close()
            throw error
        }
    }

    /// The server, once the schema cache has read it.
    var server: SchemaServer? { schema.snapshot.server }

    /// Where a new table or object goes, and what a diagram first draws, when nothing says: the first database that
    /// isn't the server's own (with tables, if `withTables`).
    func firstDatabase(withTables: Bool = false) -> String? {
        let own: Set<String> = ["information_schema", "performance_schema", "mysql", "sys"]
        let databases = schema.snapshot.databases.filter { !own.contains($0.name.lowercased()) }
        return (withTables ? databases.first { !$0.tables.isEmpty } : nil)?.name ?? databases.first?.name
    }
}

/// The editors' way in for the rest of the app: a connected connection's context, and the `MainWindowController`
/// entry points below, which the navigator calls for the object it is on (Open Structure, Create Table…, New…, Open,
/// ER Diagram).
@MainActor
enum Editors {
    /// A connected connection's sessions and schema cache (`AppModel.open`), by its id; nil while it isn't connected.
    /// Tests answer from a recording.
    static var open: (AppModel, UUID) -> (sessions: Connection, schema: SchemaCache)? = { model, id in
        model.openConnection(id).map { ($0.connection, $0.schema) }
    }

    static func context(_ connection: SavedConnection?, in model: AppModel) -> EditorContext? {
        guard let connection, let open = open(model, connection.id) else { return nil }
        return EditorContext(connection: connection, sessions: open.sessions, schema: open.schema)
    }
}

extension MainWindowController {
    // MARK: Entry points

    /// Shows the table editor on `table` of `database` (nil: a new table there; a nil database: the editor asks),
    /// in the tab already open on it if there is one.
    func openTableEditor(_ table: String?, database: String?, context: EditorContext) {
        if let table, let tab = tabs.first(where: { ($0.content as? TableEditorController)?.edits(context.connection.id, database, table) == true }) {
            select(tab)
            return
        }
        let editor = TableEditorController(context: context, database: database, table: table, activity: model.activity)
        open(editor, title: editor.tabTitle, connection: context.connection.id)
    }

    /// Shows the object editor on the `kind` named `name` in `database` (nil: a new one, its code from a template; a
    /// new trigger is for `table`).
    func openObjectEditor(_ kind: ObjectKind, name: String?, database: String, table: String? = nil, context: EditorContext) {
        if let name, let tab = tabs.first(where: {
            ($0.content as? ObjectEditorController)?.edits(context.connection.id, kind, database, name) == true
        }) {
            select(tab)
            return
        }
        let editor = ObjectEditorController(context: context, kind: kind, database: database, name: name, table: table,
                                            activity: model.activity)
        open(editor, title: editor.tabTitle, connection: context.connection.id)
    }

    /// The navigator's Open Structure and Open: the table editor or the object's editor, in the tab already on it if
    /// there is one; a sequence's CREATE statement, read-only.
    func openEditor(_ object: DatabaseObject, of connection: OpenConnection) {
        guard let context = Editors.context(model.connection(connection.id), in: model) else { return }
        if object.kind == .table {
            openTableEditor(object.name, database: object.database, context: context)
        } else if let kind = ObjectKind(rawValue: object.kind.rawValue) {
            openObjectEditor(kind, name: object.name, database: object.database, context: context)
        } else {
            open(TextContent.definition(connection, object), title: object.name, connection: connection.id)
        }
    }

    /// Shows the ER diagram of `database` (nil: the first database with tables).
    func openERDiagram(database: String?, context: EditorContext) {
        let diagram = ERDiagramController(context: context, database: database, activity: model.activity)
        open(diagram, title: diagram.tabTitle, connection: context.connection.id)
    }

    // MARK: Menu commands

    /// The connection the editor commands act on: the tree's (its right-click menus), else the window's.
    private var editorConnection: SavedConnection? {
        sidebar.treeSelection.flatMap { model.connection($0.open.id) } ?? activeConnection
    }

    /// The editor context and the database to start in: the tree's, else the connection's own default database.
    private var editorTarget: (EditorContext, String?)? {
        guard let context = Editors.context(editorConnection, in: model) else { return nil }
        let database = sidebar.treeSelection?.nodes.first?.database ?? context.connection.database
        return (context, database.isEmpty ? nil : database)
    }

    @objc func createTable(_ sender: Any?) {
        guard let (context, database) = editorTarget else { return }
        openTableEditor(nil, database: database, context: context)
    }

    @objc func showERDiagram(_ sender: Any?) {
        guard let (context, database) = editorTarget else { return }
        openERDiagram(database: database, context: context)
    }

    @objc func createObject(_ sender: Any?) {
        // The kind: the item's (the navigator's New… on a folder), else New Object's choice (by its tag).
        let item = sender as? NSMenuItem
        guard let (context, database) = editorTarget,
              let kind = (item?.representedObject as? String).flatMap(ObjectKind.init(rawValue:))
                ?? item.flatMap({ ObjectKind.allCases.indices.contains($0.tag - 1) ? ObjectKind.allCases[$0.tag - 1] : nil }),
              let database = database ?? context.firstDatabase() else { return }
        openObjectEditor(kind, name: nil, database: database, context: context)
    }

    /// Whether an editor command can run now, and why not (nil: not an editor command).
    func validateEditorItem(_ item: NSMenuItem) -> (enabled: Bool, reason: String?)? {
        guard [Commands.createTable.action, Commands.erDiagram.action, Commands.createObject.action].contains(item.action) else {
            return nil
        }
        guard let connection = editorConnection else { return (false, "Choose a connection first") }
        guard let context = Editors.context(connection, in: model) else { return (false, "Connect to \(connection.displayName) first") }
        if item.action == Commands.createObject.action, context.schema.snapshot.databases.isEmpty, connection.database.isEmpty {
            return (false, "The server has no database to create it in")
        }
        return (true, nil)
    }
}

/// An editor's frame: `bar` along the top, then `content` filling the rest (and `footer` along the bottom), hairlines
/// between them, all on the content surface.
@MainActor
func editorLayout(bar: NSView, content: NSView, footer: NSView? = nil) -> SurfaceView {
    let root = SurfaceView(.content)
    var column: [NSView] = [bar, Hairline(), content]
    if let footer { column += [Hairline(), footer] }
    var above: NSLayoutYAxisAnchor = root.topAnchor
    for view in column {
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                                     view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                                     view.topAnchor.constraint(equalTo: above)])
        if view is Hairline { view.heightAnchor.constraint(equalToConstant: 1).isActive = true }
        above = view.bottomAnchor
    }
    above.constraint(equalTo: root.bottomAnchor).isActive = true
    // The bar and the footer as tall as their contents, the content the rest. A stack view hugs each of its views by its
    // own priority: below their own (750), or it stretches its labels (their text then sits high) and squeezes its buttons.
    for view in [bar, footer].compactMap({ $0 }) {
        view.setContentHuggingPriority(.required, for: .vertical)
        (view as? NSStackView)?.setHuggingPriority(.init(749), for: .vertical)
    }
    return root
}

