import AirSQLCore
import AppKit

// Edit as Table (grid-spec §5): the selected INSERT statements, or the one at the cursor, open in their table's tab as
// new rows waiting for Apply, which shows the SQL first. Nothing runs from here.
extension ConsoleViewController {
    @objc func editAsTable(_ sender: Any?) {
        let title = "Can't edit these statements as a table"
        let selection = editor.selectedRange()
        let statements = ConsoleScript.statements(in: text, selection: selection.length > 0 ? Range(selection) : nil, caret: selection.location,
                                                  all: false, noBackslashEscapes: editor.noBackslashEscapes)
        let rows: InsertRows
        do {
            rows = try InsertRows.parse(statements.map(\.sql).joined(separator: ";\n"), noBackslashEscapes: editor.noBackslashEscapes)
        } catch {
            return showError(((error as? EditError)?.message ?? error.localizedDescription) + ".", title: title, on: view.window)
        }
        guard let main = mainWindow, let context = Editors.context(connection, in: model) else {
            return showError("Connect to “\(connection?.displayName ?? "the connection")” first.", title: title, on: view.window)
        }
        guard let database = rows.database ?? database else {
            return showError("Choose a database first (USE, or the toolbar), or name it in the statements.", title: title, on: view.window)
        }
        (main.openTableData(rows.table, database: database, context: context).content as? TableDataController)?.add(rows)
    }
}

extension TableDataController {
    /// Edit as Table: INSERT statements' rows as new rows, one step for undo; Apply shows the SQL first. Once the first
    /// rows have loaded, when they haven't yet.
    func add(_ inserts: InsertRows) {
        guard let source, loading == nil, viewer.source === source || !source.hasMore else { return waitingInserts = inserts }
        let title = "Can't edit these statements as a table"
        if let off = editingOff { return showError("\(tableName) can't take new rows here: \(off).", title: title, on: view.window) }
        var names: [String] = []
        for name in inserts.columns.isEmpty ? source.columns.map(\.name) : inserts.columns {
            guard let column = source.columns.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                return showError("\(tableName) has no column \(name).", title: title, on: view.window)
            }
            names.append(column.name)
        }
        guard let short = inserts.rows.first(where: { $0.count != names.count }) else {
            let depth = source.changes.undoDepth
            var first: UUID?
            for row in inserts.rows {
                let id = source.changes.addRow(Dictionary(zip(names, row).map { $0 }, uniquingKeysWith: { _, last in last }))
                first = first ?? id
            }
            source.changes.squashUndo(to: depth)
            previewsApply = true
            changesDidChange()
            return focus(row: first.flatMap(source.index(of:)))
        }
        showError("A row has \(short.count) values for the \(names.count) columns of \(tableName).", title: title, on: view.window)
    }
}
