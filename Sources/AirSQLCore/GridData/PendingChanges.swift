import Foundation

/// A table's changes waiting for Apply (plan §2.5, grid-spec §5): edited cells, new rows and rows to delete. Rows are
/// addressed by their key (the primary key, or a unique key whose columns are all NOT NULL), whose values the grid never
/// shortens, so every statement names exactly its row. Nothing here touches the server: `statements` gives the SQL and
/// the rows each statement must change, which `apply` checks in one transaction. Every change can be undone until then.
public struct PendingChanges: Equatable {
    /// A row by its key's values (text as the server sends it; "0x…" for binary), in `keyColumns` order.
    public typealias Key = [String]

    /// A cell's new value.
    public enum Value: Codable, Hashable, Sendable {
        case null
        case text(String)
        /// The column's default (Set DEFAULT).
        case `default`
        /// An SQL expression the server works out when Apply runs (Insert Value: NOW(), UUID()…), sent as it is.
        case sql(String)

        /// As the grid shows it: nil for NULL, DEFAULT and an expression, which the cell's style tells apart.
        public var text: String? {
            if case .text(let text) = self { return text }
            return nil
        }
    }

    /// A new row: its values by column name; a column left out gets its default (or its AUTO_INCREMENT value).
    public struct Insert: Codable, Equatable, Sendable {
        public var id: UUID
        public var values: [String: Value]
    }

    /// Everything pending: what undo steps through and what is saved for a crash.
    public struct State: Codable, Equatable, Sendable {
        public var edits: [Key: [String: Value]] = [:]
        public var inserts: [Insert] = []
        public var deletes: Set<Key> = []

        public init() {}
    }

    public let keyColumns: [String]
    public private(set) var state = State()
    private var undoStack: [State] = []
    private var redoStack: [State] = []

    public init(keyColumns: [String], state: State = State()) {
        self.keyColumns = keyColumns
        self.state = state
    }

    public var isEmpty: Bool { state.edits.isEmpty && state.inserts.isEmpty && state.deletes.isEmpty }
    /// Rows the changes touch: edited rows not being deleted, new rows, rows to delete.
    public var rowCount: Int {
        state.edits.keys.filter { !state.deletes.contains($0) }.count + state.inserts.count + state.deletes.count
    }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Reading

    /// The pending value of a loaded row's cell, nil when it isn't edited.
    public func value(_ key: Key, _ column: String) -> Value? { state.edits[key]?[column] }
    public func isEdited(_ key: Key) -> Bool { state.edits[key] != nil }
    public func isDeleted(_ key: Key) -> Bool { state.deletes.contains(key) }
    public func insert(_ id: UUID) -> Insert? { state.inserts.first { $0.id == id } }

    // MARK: Changing

    /// Sets a loaded row's cell; back to its loaded value (`original`, nil for NULL), the edit goes away.
    public mutating func set(_ value: Value, column: String, key: Key, original: String?) {
        change { state in
            var row = state.edits[key] ?? [:]
            row[column] = value == (original.map(Value.text) ?? .null) ? nil : value
            state.edits[key] = row.isEmpty ? nil : row
        }
    }

    /// Sets a new row's cell.
    public mutating func set(_ value: Value, column: String, insert id: UUID) {
        change { state in
            guard let index = state.inserts.firstIndex(where: { $0.id == id }) else { return }
            state.inserts[index].values[column] = value
        }
    }

    /// Adds a new row after the others (Add Row, Duplicate Row) and returns its id.
    @discardableResult
    public mutating func addRow(_ values: [String: Value] = [:]) -> UUID {
        let id = UUID()
        change { $0.inserts.append(Insert(id: id, values: values)) }
        return id
    }

    /// Marks loaded rows for deletion and drops new rows (Delete Rows).
    public mutating func delete(_ keys: [Key], inserts: [UUID] = []) {
        change { state in
            state.deletes.formUnion(keys)
            state.inserts.removeAll { inserts.contains($0.id) }
        }
    }

    /// Throws away the changes of these rows (Revert).
    public mutating func revert(_ keys: [Key], inserts: [UUID] = []) {
        change { state in
            for key in keys {
                state.edits[key] = nil
                state.deletes.remove(key)
            }
            state.inserts.removeAll { inserts.contains($0.id) }
        }
    }

    /// Throws away every change (Revert with nothing selected, or after Apply).
    public mutating func revertAll() { change { $0 = State() } }

    /// How many changes undo can take back: before several changes that undo as one, for `squashUndo(to:)`.
    public var undoDepth: Int { undoStack.count }

    /// Makes the changes since `depth` one step for undo (a paste, a multi-cell edit).
    public mutating func squashUndo(to depth: Int) {
        guard undoStack.count > depth + 1 else { return }
        undoStack.removeSubrange((depth + 1)...)
    }

    public mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
    }

    public mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
    }

    private mutating func change(_ body: (inout State) -> Void) {
        var next = state
        body(&next)
        guard next != state else { return }
        undoStack.append(state)
        redoStack.removeAll()
        state = next
    }

    // MARK: SQL

    /// A statement Apply runs, the rows it must change exactly, and the rows it is for (to point at when it fails).
    public struct Statement: Equatable, Sendable {
        public enum Target: Equatable, Sendable {
            case update(Key)
            case delete([Key])
            case insert(UUID)
        }

        public var sql: String
        public var expectedRows: Int
        public var target: Target
    }

    /// Rows per DELETE … WHERE key IN (…).
    public static let deleteBatch = 500

    /// The statements that write the changes to `table` in `database`, in the order Apply runs them: deletes first (so a
    /// new row can take a deleted row's key), then updates, then inserts. `columns` are the table's, in its order.
    /// `typed` turns a value's text into SQL for its column (the table tab's checks it by the column's type, as
    /// `ColumnType.literal`); without it, `GridColumn.literal`. A value it refuses stops them all: the `ApplyFailure`
    /// names the row and the column. Key values are the server's own, so they always go through `GridColumn.literal`.
    public func statements(database: String, table: String, columns: [GridColumn], noBackslashEscapes: Bool,
                           typed: ((_ text: String, _ column: String) throws -> String)? = nil) throws -> [Statement] {
        let name = SQLQuote.identifier(database, table)
        let byName = Dictionary(columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        func column(_ name: String) -> GridColumn { byName[name] ?? GridColumn(name: name) }
        func literal(_ value: Value, _ name: String, _ target: Statement.Target) throws -> String {
            switch value {
            case .null: return "NULL"
            case .default: return "DEFAULT"
            case .sql(let sql): return sql
            case .text(let text):
                guard let typed else { return column(name).literal(text, noBackslashEscapes: noBackslashEscapes) }
                do {
                    return try typed(text, name)
                } catch {
                    let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    throw ApplyFailure(statement: Statement(sql: "", expectedRows: 1, target: target), changed: nil,
                                       error: EditError("\(name): \(reason)."), column: name)
                }
            }
        }
        func keyLiterals(_ key: Key) -> [String] {
            zip(keyColumns, key).map { column($0).literal($1, noBackslashEscapes: noBackslashEscapes) }
        }
        func ordered(_ values: [String: Value]) -> [String] {
            columns.map(\.name).filter { values[$0] != nil } + values.keys.filter { byName[$0] == nil }.sorted()
        }
        var statements: [Statement] = []
        let deletes = state.deletes.sorted { $0.lexicographicallyPrecedes($1) }
        for start in stride(from: 0, to: deletes.count, by: Self.deleteBatch) {
            let batch = Array(deletes[start..<min(start + Self.deleteBatch, deletes.count)])
            let condition: String
            if keyColumns.count == 1 {
                condition = SQLQuote.identifier(keyColumns[0]) + " IN (" + batch.map { keyLiterals($0)[0] }.joined(separator: ", ") + ")"
            } else {
                condition = "(" + keyColumns.map { SQLQuote.identifier($0) }.joined(separator: ", ") + ") IN ("
                    + batch.map { "(" + keyLiterals($0).joined(separator: ", ") + ")" }.joined(separator: ", ") + ")"
            }
            statements.append(Statement(sql: "DELETE FROM \(name) WHERE \(condition)", expectedRows: batch.count, target: .delete(batch)))
        }
        for key in state.edits.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) where !state.deletes.contains(key) {
            let values = state.edits[key] ?? [:]
            let set = try ordered(values).map { SQLQuote.identifier($0) + " = " + (try literal(values[$0]!, $0, .update(key))) }
            let condition = zip(keyColumns, keyLiterals(key)).map { SQLQuote.identifier($0) + " = " + $1 }
            statements.append(Statement(sql: "UPDATE \(name) SET " + set.joined(separator: ", ") + " WHERE "
                                        + condition.joined(separator: " AND "), expectedRows: 1, target: .update(key)))
        }
        for insert in state.inserts {
            let names = ordered(insert.values)
            let values = try names.map { try literal(insert.values[$0]!, $0, .insert(insert.id)) }
            statements.append(Statement(sql: "INSERT INTO \(name) (" + names.map { SQLQuote.identifier($0) }.joined(separator: ", ")
                                        + ") VALUES (" + values.joined(separator: ", ") + ")", expectedRows: 1, target: .insert(insert.id)))
        }
        return statements
    }
}
