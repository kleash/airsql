import AirSQLCore
import AppKit

/// Quick Documentation, Quick Definition, Go to DDL and F4 from the tree: the editor's own notes (`SQLIntentions`) for
/// the row selected, without leaving it.
extension SidebarController {
    /// The one object a selected row is, or belongs to.
    var notedObject: DatabaseObject? {
        guard let nodes = treeSelection?.nodes, nodes.count == 1 else { return nil }
        return nodes[0].object ?? nodes[0].owner
    }

    /// The Tables or Views group selected.
    var selectedCategory: (database: String, kind: DatabaseObject.Kind)? {
        guard let nodes = treeSelection?.nodes, nodes.count == 1, case .category(_, let database, let kind) = nodes[0].kind,
              kind == .table || kind == .view else { return nil }
        return (database, kind)
    }

    private func showNote(_ title: String, _ body: String) -> NSPopover {
        treeNote?.close()
        let popover = InsightNote.popover(title, InsightNote.text(body))
        treeNote = popover
        shownTreeNote = title + "\n" + body
        if view.window != nil, outline.selectedRow >= 0 {
            popover.show(relativeTo: outline.rect(ofRow: outline.selectedRow), of: outline, preferredEdge: .maxX)
        }
        return popover
    }

    /// F1: what the editor says of the same name, then a table's first rows. An agent's request reads no rows.
    @objc func quickDocumentation(_ sender: Any?) {
        guard let (open, nodes) = treeSelection, nodes.count == 1 else { return }
        if case .database(_, let name) = nodes[0].kind, let database = open.snapshot.database(name) {
            _ = showNote(name, "Database · \(database.tables.count) tables · \(database.charset) / \(database.collation)")
            return
        }
        guard let object = notedObject else { return }
        var column: String?
        if case .detail(_, _, .columns, let name) = nodes[0].kind { column = name }
        if let about = nodes[0].detail?.about, column == nil { return _ = showNote(nodes[0].name ?? object.name, about) }
        guard let doc = SQLIntentions.documentation(of: object, column: column, snapshot: open.snapshot) else {
            return quickDefinition(sender)  // a trigger or event is its code
        }
        let popover = showNote(doc.title, doc.body)
        guard column == nil, object.kind == .table || object.kind == .view, AgentGate.agent == nil,
              let columns = open.snapshot.table(object.database, object.name)?.columns,
              let read = NavigatorSQL.firstRows(object, columns) else { return }
        Task { [weak self] in
            guard let rows = try? await open.connection.session(.schema).rows(read.sql), !rows.isEmpty else { return }
            let text = NavigatorSQL.rowsText(read.names, rows)
            InsightNote.append(text, to: popover)
            if self?.treeNote === popover { self?.shownTreeNote += "\n" + text }
        }
    }

    /// The CREATE statement, read through the schema session.
    @objc func quickDefinition(_ sender: Any?) {
        guard let open = treeSelection?.open, let object = notedObject else { return }
        Task { [weak self] in
            let text: String
            do { text = try await open.createStatement(object) } catch { text = "Couldn't read it: " + error.localizedDescription }
            _ = self?.showNote(object.name, text)
        }
    }

    /// F4: a table's rows; a group of tables or views as a list.
    @objc func openNameData(_ sender: Any?) {
        if let category = selectedCategory, let main, let open = treeSelection?.open {
            let list = DatabaseViewController(open, category.database, only: category.kind == .view ? .view : .table)
            main.open(list, title: category.kind.group + " of " + category.database, connection: open.id)
        } else {
            openData(sender)
        }
    }

    @objc func goToDDL(_ sender: Any?) {
        guard let main, let open = treeSelection?.open, let object = notedObject else { return }
        main.goToDDL(object, of: open)
    }
}

extension MainWindowController {
    /// A table's or view's tab on its DDL page; anything else's code.
    func goToDDL(_ object: DatabaseObject, of open: OpenConnection) {
        guard object.kind.isTableLike else { return openEditor(object, of: open) }
        openTableData(object, of: open)
        guard let table = selectedTab?.shown as? TableDataController else { return }
        _ = table.view
        table.show(.ddl)
    }
}

extension SidebarNode {
    /// An index, key or check under a table: Drop takes it from the table, never the table itself.
    var isDroppablePart: Bool {
        if case .detail(_, _, let part, _) = kind { return [.indexes, .foreignKeys, .checks].contains(part) }
        return false
    }
}

extension SidebarController {
    /// What Find Where Used looks for: an object's name, or a column's.
    var usageName: String? {
        guard let nodes = treeSelection?.nodes, nodes.count == 1 else { return nil }
        switch nodes[0].kind {
        case .object(_, let object): return object.name
        case .detail(_, _, .columns, let name): return name
        default: return nil
        }
    }

    /// Lists what names the object: definitions the server keeps, and foreign keys from the schema cache.
    @objc func findWhereUsed(_ sender: Any?) {
        guard let window = view.window, let main, let open = treeSelection?.open, let name = usageName else { return }
        let self_ = notedObject
        Task {
            do {
                let session = try await open.connection.session(.schema)
                let rows = try await session.rows(NavigatorSQL.usages(of: name, noBackslashEscapes: session.noBackslashEscapes))
                var items = rows.compactMap { row -> QuickOpenSheet.Item? in
                    guard row.count == 4, let raw = row[0], let kind = DatabaseObject.Kind(rawValue: raw), let database = row[1], let found = row[2],
                          NavigatorSQL.names(name, in: row[3] ?? "") else { return nil }
                    let object = DatabaseObject(kind, database, found)
                    guard object != self_ else { return nil }
                    return .init(name: found, place: kind.noun + " in " + database) { main.openEditor(object, of: open) }
                }
                for database in open.snapshot.databases {
                    for table in database.tables where table.foreignKeys.contains(where: { $0.referencedTable == name || $0.referencedColumns.contains(name) }) {
                        let object = DatabaseObject(.table, database.name, table.name)
                        items.append(.init(name: table.name, place: "foreign key in " + database.name) { main.openEditor(object, of: open) })
                    }
                }
                QuickOpenSheet.show(items, title: "Where “\(name)” Is Used", prompt: "Filter the list", on: window)
            } catch {
                showError(error.localizedDescription, title: "Couldn't read the definitions", on: window)
            }
        }
    }

    @objc func editComment(_ sender: Any?) {
        guard let window = view.window, let open = treeSelection?.open, let object = selectedObjects.first else { return }
        let old = open.snapshot.database(object.database)?.comment(of: object) ?? ""
        let field = AirSQL.textField(old, placeholder: "No comment", id: "tree.comment", tip: "Type the comment; leave it empty for none", width: 320)
        NavigatorActions.ask("Comment of \(object.name)", "Change what \(object.database).\(object.name) says about itself.", field: field, action: "Next…",
                             on: window) {
            Task {
                do {
                    let flag = try await open.connection.session(.schema).noBackslashEscapes
                    let sql = NavigatorSQL.setComment(field.stringValue, of: object, noBackslashEscapes: flag)
                    var request = SQLPreviewRequest(change: ChangeSQL(title: "Comment on \(object.name)", statements: [sql], connection: open.id),
                                                    heading: "Change the comment of \(object.name)?", caption: "Only the comment changes.")
                    request.actionTitle = "Change"
                    NavigatorActions.confirmAndRun(request, on: open, window: window, refreshing: [object.schemaObject])
                } catch {
                    showError(error.localizedDescription, title: "Couldn't change the comment", on: window)
                }
            }
        }
    }

    /// New Column…, New Index…, New Foreign Key…: the table's editor with a new row of that section to fill in. Nothing
    /// changes until Apply there.
    @objc func addToTable(_ sender: Any?) {
        guard let main, let open = treeSelection?.open, let table = selectedObjects.first, let context = Editors.context(model.connection(open.id), in: model),
              let section = TableEditorController.Section(rawValue: (sender as? NSMenuItem)?.tag ?? 0) else { return }
        main.openTableEditor(table.name, database: table.database, context: context)
        (main.selectedTab?.content as? TableEditorController)?.addOnceLoaded(section)
    }

    @objc func moveConnectionUp(_ sender: Any?) { moveConnection(by: -1) }
    @objc func moveConnectionDown(_ sender: Any?) { moveConnection(by: 1) }

    private func moveConnection(by step: Int) {
        guard selectedConnectionIDs.count == 1, let id = selectedConnectionIDs.first else { return }
        model.moveConnection(id, by: step)
    }
}

extension NavigatorActions {
    /// Drops indexes, keys or checks from their tables: each statement shows first.
    static func dropParts(_ nodes: [SidebarNode], on open: OpenConnection, window: NSWindow?) {
        var statements: [String] = [], tables: [SchemaObject] = []
        for node in nodes {
            guard case .detail(_, let table, let part, let name) = node.kind, let sql = NavigatorSQL.dropPart(part, name, of: table) else { continue }
            statements.append(sql)
            tables.append(table.schemaObject)
        }
        guard let first = nodes.first?.name, !statements.isEmpty else { return }
        let what = statements.count == 1 ? first : "\(statements.count) keys and indexes"
        var request = SQLPreviewRequest(change: ChangeSQL(title: "Drop \(what)", statements: statements, connection: open.id),
                                        heading: "Drop \(what)?", caption: "The table's rows stay. Queries that used it may slow down, and rows it kept in check can change.")
        request.actionTitle = "Drop"
        request.destructive = true
        confirmAndRun(request, on: open, window: window, refreshing: tables)
    }
}

/// The same commands in a query tab, for the name at the cursor.
extension ConsoleViewController {
    private func withObject(_ body: @escaping (DatabaseObject, OpenConnection, MainWindowController) -> Void) {
        guard let main = mainWindow, let open = model.openConnection(connectionID) else { return }
        editor.withInsight { [weak self] analysis in
            guard let self, let symbol = analysis.reference(at: self.editor.selectedRange().location)?.symbol, let object = open.object(of: symbol) else {
                self?.editor.showNote("Nothing to Show Here", "Put the cursor on a table, a view or a routine.")
                return
            }
            body(object, open, main)
        }
    }

    @objc func quickDefinition(_ sender: Any?) {
        withObject { [weak self] object, open, _ in
            Task {
                let text: String
                do { text = try await open.createStatement(object) } catch { text = "Couldn't read it: " + error.localizedDescription }
                self?.editor.showNote(object.name, text)
            }
        }
    }

    @objc func openNameData(_ sender: Any?) {
        withObject { object, open, main in
            if object.kind.isTableLike { main.openTableData(object, of: open) } else { main.openEditor(object, of: open) }
        }
    }

    @objc func goToDDL(_ sender: Any?) {
        withObject { object, open, main in main.goToDDL(object, of: open) }
    }

    /// The tab's statements, each by its first line.
    @objc func showStatementList(_ sender: Any?) {
        guard let window = view.window, window.attachedSheet == nil else { return }
        let text = editor.string as NSString
        let items = editor.statements.map { statement -> QuickOpenSheet.Item in
            let start = statement.range.lowerBound
            let line = text.substring(to: min(start, text.length)).components(separatedBy: "\n").count
            let first = statement.sql.split(whereSeparator: \.isNewline).first.map(String.init) ?? statement.sql
            return .init(name: String(first.prefix(100)), place: "Line \(line)") { [weak self] in
                self?.editor.setSelectedRange(NSRange(location: start, length: 0))
                self?.editor.scrollRangeToVisible(NSRange(location: start, length: 0))
                self?.view.window?.makeFirstResponder(self?.editor)
            }
        }
        QuickOpenSheet.show(items, title: "Go to Statement", prompt: "Letters of a statement", on: window)
    }
}
