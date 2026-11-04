import Foundation

/// A console result whose cells can be edited (grid-spec §5, R15): the result's rows with each table's pending changes
/// drawn over them, addressed by that table's key, so Apply runs the same statements as the table tab. `ResultEditing`
/// decides which columns can be edited; until it is set (the schema is being read) every column is read-only. Rows
/// can be deleted only in a one-table result. Main thread.
public final class ResultEditSource: GridSource {
    public let base: ResultSetSource
    public var store: ResultStore { base.store }
    public var columns: [GridColumn] { base.columns }
    public private(set) var editing: ResultEditing?
    /// The tables of `editing.sources`, as the schema cache has them, and each one's pending changes.
    public private(set) var tables: [SchemaTable] = []
    public private(set) var changes: [PendingChanges] = []
    /// The tables each undo step changed, in the order made (a step may change several: a multi-cell edit).
    private var steps: [[Int]] = [], undone: [[Int]] = []
    /// The result's rows still shown (those Apply deleted go), and the values Apply wrote, as read back.
    private var rows: [Int]
    private var written: [Int: [Int: String?]] = [:]

    public init(_ store: ResultStore) {
        base = ResultSetSource(store)
        rows = Array(0..<store.rowCount)
    }

    /// Takes the rules worked out for the result; a table the snapshot lacks leaves every column read-only.
    public func setEditing(_ editing: ResultEditing, snapshot: SchemaSnapshot) {
        let tables = editing.sources.compactMap { snapshot.table($0.database, $0.table) }
        guard tables.count == editing.sources.count else { return }
        self.editing = editing
        self.tables = tables
        changes = editing.sources.map { PendingChanges(keyColumns: $0.key) }
        steps = []
        undone = []
    }

    /// Why a column can't be edited; nil when it can.
    public func reason(_ column: Int) -> String? {
        guard let editing else { return "AirSQL is still reading the tables this result comes from" }
        if case .readOnly(let reason) = editing.columns[column] { return reason }
        return nil
    }

    /// Rows can be deleted: a one-table result.
    public var canDelete: Bool { editing?.sources.count == 1 && editing?.isEditable == true }

    // MARK: Rows

    public var rowCount: Int { rows.count }

    /// The key of a result row in a table's terms, as last written.
    func key(_ row: Int, _ source: Int) -> PendingChanges.Key {
        editing?.sources[source].keyColumns.map { stored(rows[row], $0) ?? "" } ?? []
    }

    /// A cell as the server last had it: as read back after Apply, else as the query found it (whole; binary as 0x…).
    private func stored(_ row: Int, _ column: Int) -> String? {
        if let values = written[row], let value = values[column] { return value }
        return TableDataSource.text(store, row, column)
    }

    /// The cell's value when a pending change or an Apply changed it (.some(nil) for NULL); nil when the query's stands.
    private func changed(_ row: Int, _ column: Int) -> String?? {
        if case .editable(let source, let name)? = editing?.columns[column], !changes[source].state.edits.isEmpty,
           let value = changes[source].value(key(row, source), name) {
            return .some(value.text)
        }
        if let values = written[rows[row]], let value = values[column] { return .some(value) }
        return nil
    }

    public func cell(_ row: Int, _ column: Int) -> GridCell {
        guard let value = changed(row, column) else { return base.cell(rows[row], column) }
        guard let text = value else { return .null }
        guard !columns[column].isKey, text.count > ResultSetSource.shownLimit else { return .text(text) }
        return .text(String(text.prefix(ResultSetSource.shownLimit)) + "…")
    }

    public func value(_ row: Int, _ column: Int) -> String? { changed(row, column) ?? base.value(rows[row], column) }

    /// The bytes the server sent for an unchanged cell (the value panel's hex and image).
    public func bytes(_ row: Int, _ column: Int) -> [UInt8]? {
        changed(row, column) == nil ? store.bytes(rows[row], column) : nil
    }

    public func mark(_ row: Int, _ column: Int) -> GridMark {
        guard let editing, !isEmpty else { return .none }
        if canDelete, changes[0].isDeleted(key(row, 0)) { return .deleted }
        guard case .editable(let source, let name) = editing.columns[column] else { return .none }
        return changes[source].value(key(row, source), name) == nil ? .none : .edited
    }

    // MARK: Editing

    public func canEdit(_ row: Int, _ column: Int) -> Bool {
        guard row < rows.count, case .editable? = editing?.columns[column] else { return false }
        return !canDelete || !changes[0].isDeleted(key(row, 0))
    }

    /// The column's type, for checking a value.
    public func type(_ column: Int) -> ColumnType? {
        guard case .editable(let source, let name)? = editing?.columns[column], let info = tables[source].column(name) else { return nil }
        return ColumnType(info)
    }

    /// Whether NULL can go in the column.
    public func nullable(_ column: Int) -> Bool {
        guard case .editable(let source, let name)? = editing?.columns[column] else { return false }
        return tables[source].column(name)?.nullable == true
    }

    public func set(_ value: PendingChanges.Value, row: Int, column: Int) {
        guard canEdit(row, column), case .editable(let source, let name)? = editing?.columns[column] else { return }
        change(source) { $0.set(value, column: name, key: key(row, source), original: stored(rows[row], column)) }
    }

    /// Marks rows for deletion (a one-table result).
    public func delete(_ rows: [Int]) {
        guard canDelete else { return }
        change(0) { changes in changes.delete(rows.map { key($0, 0) }) }
    }

    /// Throws away the rows' changes, or every change.
    public func revert(_ rows: [Int]? = nil) {
        group {
            for source in changes.indices {
                change(source) { changes in
                    if let rows { changes.revert(rows.map { key($0, source) }) } else { changes.revertAll() }
                }
            }
        }
    }

    public var isEmpty: Bool { changes.allSatisfy(\.isEmpty) }
    /// Rows with changes, over every table.
    public var pendingRows: Int { changes.reduce(0) { $0 + $1.rowCount } }
    public func isChanged(_ row: Int) -> Bool {
        changes.indices.contains { changes[$0].isEdited(key(row, $0)) || changes[$0].isDeleted(key(row, $0)) }
    }

    public var canUndo: Bool { !steps.isEmpty }
    public var canRedo: Bool { !undone.isEmpty }

    public func undo() {
        guard let step = steps.popLast() else { return }
        for source in step { changes[source].undo() }
        undone.append(step)
    }

    public func redo() {
        guard let step = undone.popLast() else { return }
        for source in step { changes[source].redo() }
        steps.append(step)
    }

    /// Changes made in `body` undo as one step.
    public func group(_ body: () -> Void) {
        let depths = changes.map(\.undoDepth), first = steps.count
        body()
        guard steps.count - first > 1 else { return }
        let touched = Set(steps[first...].joined()).sorted()
        for source in touched { changes[source].squashUndo(to: depths[source]) }
        steps.removeSubrange(first...)
        steps.append(touched)
    }

    private func change(_ source: Int, _ body: (inout PendingChanges) -> Void) {
        let depth = changes[source].undoDepth
        body(&changes[source])
        guard changes[source].undoDepth > depth else { return }
        steps.append([source])
        undone = []
    }

    // MARK: Apply

    /// The statements Apply runs, table by table, each value written as SQL for its column's type and checked again.
    /// A value its column refuses throws `ApplyFailure` naming the column.
    public func statements(context: EditContext) throws -> [PendingChanges.Statement] {
        guard let editing else { return [] }
        return try changes.indices.flatMap { index -> [PendingChanges.Statement] in
            guard !changes[index].isEmpty else { return [] }
            let table = tables[index]
            let types = Dictionary(table.columns.map { ($0.name, ColumnType($0)) }, uniquingKeysWith: { first, _ in first })
            return try changes[index].statements(database: editing.sources[index].database, table: table.name, columns: gridColumns(index),
                                                 noBackslashEscapes: context.noBackslashEscapes) { text, column in
                guard let type = types[column] else { throw EditError("\(table.name) has no column \(column) any more") }
                return try type.literal(text, context)
            }
        }
    }

    /// A table's columns as the statements need them.
    private func gridColumns(_ index: Int) -> [GridColumn] {
        tables[index].columns.map { column in
            var shown = GridColumn(name: column.name, kind: TableDataSource.kind(column))
            shown.describe(tables[index])
            return shown
        }
    }

    /// The edited columns Apply can't check for someone else's change (`PendingChanges.uncheckedColumns`).
    public var uncheckedColumns: [String] {
        changes.indices.flatMap { changes[$0].uncheckedColumns(gridColumns($0)) }
    }

    /// The row an Apply failure is about, and its column when the failure names one: the statement's table decides
    /// which table's key to look for.
    public func position(of failure: ApplyFailure) -> (row: Int, column: Int?)? {
        guard let editing else { return nil }
        let keys: [PendingChanges.Key]
        switch failure.statement.target {
        case .update(let key): keys = [key]
        case .delete(let list): keys = list
        case .insert: return nil
        }
        for index in editing.sources.indices {
            let name = SQLQuote.identifier(editing.sources[index].database, tables[index].name)
            let column = failure.column(in: tables[index])
            let typed = failure.statement.sql.isEmpty && editing.columns.contains(.editable(source: index, column: column ?? ""))
            guard failure.statement.sql.contains(" \(name) ") || typed,
                  let row = rows.indices.first(where: { keys.contains(key($0, index)) }) else { continue }
            return (row, editing.columns.indices.first { editing.columns[$0] == .editable(source: index, column: column ?? "") })
        }
        return nil
    }

    /// The SELECTs that read the edited rows back after Apply, by key, with the result's columns of each table they
    /// show (`columns`: the result's columns, key first, in the SELECT's order). None for a table whose key was edited:
    /// its typed values show instead.
    public func readBack(noBackslashEscapes: Bool) -> [(sql: String, source: Int, columns: [Int])] {
        guard let editing else { return [] }
        return changes.indices.flatMap { index -> [(sql: String, source: Int, columns: [Int])] in
            let source = editing.sources[index], edits = changes[index].state.edits
            let keys = edits.keys.filter { !changes[index].isDeleted($0) }.sorted { $0.lexicographicallyPrecedes($1) }
            guard !keys.isEmpty, !edits.values.contains(where: { values in source.key.contains { values[$0] != nil } }) else { return [] }
            let shown = source.keyColumns + editing.columns.indices.filter { column in
                if case .editable(index, _) = editing.columns[column] { return !source.keyColumns.contains(column) }
                return false
            }
            let names = shown.map { SQLQuote.identifier(store.columns[$0].originalName) }
            let keyNames = source.key.map(SQLQuote.identifier), table = tables[index]
            func literal(_ name: String, _ text: String) -> String {
                guard let column = table.column(name) else { return SQLQuote.string(text, noBackslashEscapes: noBackslashEscapes) }
                var shown = GridColumn(name: name, kind: TableDataSource.kind(column))
                shown.describe(table)
                return shown.literal(text, noBackslashEscapes: noBackslashEscapes)
            }
            return stride(from: 0, to: keys.count, by: PendingChanges.deleteBatch).map { start in
                let batch = keys[start..<min(start + PendingChanges.deleteBatch, keys.count)]
                let tuples = batch.map { key in zip(source.key, key).map { literal($0, $1) } }
                let condition = keyNames.count == 1 ? keyNames[0] + " IN (" + tuples.map { $0[0] }.joined(separator: ", ") + ")"
                    : "(" + keyNames.joined(separator: ", ") + ") IN (" + tuples.map { "(" + $0.joined(separator: ", ") + ")" }
                        .joined(separator: ", ") + ")"
                return ("SELECT " + names.joined(separator: ", ") + " FROM " + SQLQuote.identifier(source.database, table.name)
                        + " WHERE " + condition, index, shown)
            }
        }
    }

    /// Apply ran: the changed cells show their new values (as `read` back from the server, else as typed), deleted rows
    /// go, and nothing is pending. `read`: each read-back's rows with the `readBack` entry it answers.
    public func applied(_ read: [(rows: ResultStore, source: Int, columns: [Int])]) {
        guard let editing else { return }
        var deleted = Set<Int>()
        for (index, source) in editing.sources.enumerated() where !changes[index].isEmpty {
            var byKey: [PendingChanges.Key: Int] = [:]
            for row in rows.indices { byKey[key(row, index)] = rows[row] }
            for (key, values) in changes[index].state.edits where !changes[index].isDeleted(key) {
                guard let row = byKey[key] else { continue }
                for (column, kind) in editing.columns.enumerated() {
                    if case .editable(index, let name) = kind, let value = values[name] {
                        written[row, default: [:]].updateValue(value.text, forKey: column)  // nil stays: NULL
                    }
                }
            }
            for answer in read where answer.source == index && answer.rows.columns.count == answer.columns.count {
                let width = source.keyColumns.count
                for row in 0..<answer.rows.rowCount {
                    let key = (0..<width).map { TableDataSource.text(answer.rows, row, $0) ?? "" }
                    guard let shown = byKey[key] else { continue }
                    for (position, column) in answer.columns.enumerated() {
                        written[shown, default: [:]].updateValue(TableDataSource.text(answer.rows, row, position), forKey: column)
                    }
                }
            }
            deleted.formUnion(changes[index].state.deletes.compactMap { byKey[$0] })
        }
        rows.removeAll { deleted.contains($0) }
        changes = changes.map { PendingChanges(keyColumns: $0.keyColumns) }
        steps = []
        undone = []
    }
}
