import AirSQLCore
import AppKit

// Foreign keys' labels and the keys the person defines (grid-spec §5). A one-column foreign key's cell shows the row it
// refers to by its label, grey, after the value: the referenced table's column chosen with Use as Label, else its first
// text column, read on the data session for the values on screen only. Virtual foreign keys, kept with the table's view
// settings on this Mac and never written to the server, lead the drop-down, Related Rows, the labels and the ER diagram
// as the table's own keys do.
extension TableDataController {
    /// The grey label after a foreign key's value; nil for none, or not read yet (it is asked for).
    func label(_ row: Int, _ column: Int) -> String? {
        guard let keys = labelKeys ?? makeLabelKeys(), column < keys.count, keys[column] != nil,
              let value = source?.value(row, column) else { return nil }
        if let known = labels[column]?[value] { return known.isEmpty ? nil : known }
        guard wantedLabels[column]?.contains(value) != true else { return nil }
        wantedLabels[column, default: []].insert(value)
        if loading == nil { readLabels() }
        return nil
    }

    private func makeLabelKeys() -> [SchemaForeignKey?]? {
        guard let source else { return nil }
        labelKeys = source.columns.indices.map { column in foreignKey(column).flatMap { $0.columns.count == 1 ? $0 : nil } }
        return labelKeys
    }

    /// The column a table's rows are shown by: the one chosen with Use as Label, else its first text column off the key.
    func labelColumn(of referenced: SchemaTable, database: String, key: [String]) -> String? {
        let chosen = TableViewSettingsStore.shared.settings(connection: context.connection.id, database: database, table: referenced.name).labelColumn
        if let chosen, referenced.column(chosen) != nil { return chosen }
        return ForeignKeyQueries.defaultLabel(referenced, key: key)
    }

    /// Reads the labels asked for, a column at a time, on the data session (in a moment, so one screen's go together).
    func readLabels() {
        guard readingLabels == nil, !wantedLabels.isEmpty else { return }
        let open = openSession, values = self.values, schema = context.schema
        readingLabels = Task {
            try? await Task.sleep(nanoseconds: 30_000_000)
            while let (column, wanted) = wantedLabels.first {
                wantedLabels[column] = nil
                guard let keys = labelKeys, column < keys.count, let key = keys[column] else { continue }
                if schema.snapshot.table(key.referencedDatabase, key.referencedTable) == nil {
                    try? await schema.loadDetails([key.referencedDatabase])
                }
                var found = labels[column] ?? [:]
                for value in wanted { found[value] = "" }  // none unless the server has one: not asked again
                if let referenced = schema.snapshot.table(key.referencedDatabase, key.referencedTable),
                   let label = labelColumn(of: referenced, database: key.referencedDatabase, key: key.referencedColumns) {
                    let list = Array(wanted)
                    for start in stride(from: 0, to: list.count, by: 500) {
                        let batch = Array(list[start..<min(start + 500, list.count)])
                        guard let sql = ForeignKeyQueries.labels(key, referenced: referenced, label: label, values: batch, context: values),
                              let rows = try? await open().query(sql, rowCap: batch.count).first?.rows, rows.columns.count == 2 else { continue }
                        for row in 0..<rows.rowCount {
                            if let id = TableDataSource.text(rows, row, 0) { found[id] = rows.string(row, 1).map(GridStyles.display) ?? "" }
                        }
                    }
                }
                labels[column] = found
            }
            readingLabels = nil
            grid.needsDisplay = true
        }
    }

    /// Whether the column is the one this table's rows are shown by.
    func isLabel(_ column: Int?) -> Bool {
        guard let source, let column else { return false }
        return labelColumn(of: source.table, database: database, key: source.table.editingKey ?? []) == source.columns[column].name
    }

    /// Changes this table's view settings as kept (read again first: the viewer keeps the columns' widths there too).
    private func changeSettings(_ change: (inout TableViewSettings) -> Void) {
        let store = TableViewSettingsStore.shared
        settings = store.settings(connection: context.connection.id, database: database, table: tableName)
        change(&settings)
        store.set(settings, connection: context.connection.id, database: database, table: tableName)
        labelKeys = nil
        labels = [:]
        grid.needsDisplay = true
    }

    /// Use as Label: the focused column shows beside keys that refer to this table (again: back to the first text column).
    @objc func useAsLabel(_ sender: Any?) {
        guard let source, let column = focusedColumn() else { return NSSound.beep() }
        let name = source.columns[column].name
        changeSettings { $0.labelColumn = $0.labelColumn == name ? nil : name }
    }

    /// Add Virtual Foreign Key…: which table's key the focused column holds, chosen from each table with a one-column key.
    @objc func addVirtualKey(_ sender: Any?) {
        guard let source, let column = focusedColumn(), let window = view.window else { return NSSound.beep() }
        let name = source.columns[column].name
        let targets = (context.schema.snapshot.database(database)?.tables ?? []).compactMap { table -> (String, String)? in
            guard table.kind == .table, let key = table.editingKey, key.count == 1 else { return nil }
            return (table.name, key[0])
        }.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        guard !targets.isEmpty else {
            return showError("No table of \(database) has a one-column key to refer to.", title: "Nothing to refer to", on: window)
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        for (table, key) in targets {
            popup.addItem(withTitle: "\(table) (\(key))")
            popup.lastItem?.representedObject = [table, key]
        }
        popup.toolTip = "Choose the table whose key \(name) holds"
        popup.setAccessibilityIdentifier("virtualKey.table")
        // A guess from the name: customer_id → customers.
        let stem = name.lowercased().hasSuffix("_id") ? String(name.lowercased().dropLast(3)) : name.lowercased()
        if let guess = targets.firstIndex(where: { [stem, stem + "s", stem + "es"].contains($0.0.lowercased()) }) { popup.selectItem(at: guess) }
        let alert = NSAlert()
        alert.messageText = "Which table does \(name) refer to?"
        alert.informativeText = "AirSQL keeps this foreign key on this Mac, not in the database. The drop-down, Related Rows, the labels "
            + "and the ER diagram follow it."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Add").toolTip = "Keep this foreign key for \(name)"
        alert.addButton(withTitle: "Cancel").toolTip = "Close without adding a foreign key"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let target = popup.selectedItem?.representedObject as? [String] else { return }
            let key = SchemaForeignKey(name: "virtual \(name)", columns: [name], referencedDatabase: database, referencedTable: target[0],
                                       referencedColumns: [target[1]], onUpdate: "NO ACTION", onDelete: "NO ACTION")
            changeSettings { settings in
                settings.virtualKeys.removeAll { $0.columns == [name] }
                settings.virtualKeys.append(key)
            }
        }
    }

    @objc func removeVirtualKey(_ sender: Any?) {
        guard let source, let column = focusedColumn() else { return NSSound.beep() }
        let name = source.columns[column].name
        changeSettings { $0.virtualKeys.removeAll { $0.columns.contains(name) } }
    }

    /// Whether Use as Label and the virtual foreign key commands can act on the focused column, and why not.
    func keyState(of action: Selector?) -> (Bool, String?) {
        guard let source, let column = focusedColumn() else { return (false, "Select a column first") }
        let name = source.columns[column].name
        switch action {
        case Commands.useAsLabel.action:
            return (!source.columns[column].isKey, "\(name) is the key, which shows already: choose another column")
        case Commands.addVirtualKey.action:
            let own = ForeignKeyQueries.foreignKey(of: name, in: source.table) != nil
            return (!own, "\(name) is a foreign key of the table already")
        default:
            return (settings.virtualKeys.contains { $0.columns.contains(name) }, "\(name) has no foreign key you defined")
        }
    }
}
