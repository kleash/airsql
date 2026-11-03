import CMariaDB
import Foundation

/// A table's rows in the grid (`GridSource`'s table tab): pages of `SELECT … LIMIT … OFFSET …` with the WHERE filter
/// and ORDER BY on the server, which the tab runs on the data session and hands over (`append`); the loaded rows
/// searched locally (`localFilter`); and the pending changes drawn over them, new rows after the loaded ones. Key
/// columns are fetched and kept whole, so an edit addresses its exact row. It writes every statement the tab sends
/// about the table (pages, counts, Column Summary, Filter by Values), so they share one filter. Main thread.
public final class TableDataSource: GridSource {
    public let database: String
    public let table: SchemaTable
    public let columns: [GridColumn]
    /// The key columns' indexes; nil when the table can't be edited (`readOnlyReason` says why).
    public let key: [Int]?
    public let readOnlyReason: String?
    public var changes: PendingChanges
    /// The WHERE bar's condition and the sort, as the next `pageSQL` sends them.
    public var filter = ""
    public var sort: [TableViewSettings.SortKey] = []
    /// Search on the loaded rows: only the rows it keeps are shown (nil: every loaded row).
    public var localFilter: (([String?]) -> Bool)? { didSet { applyLocalFilter() } }
    /// The loaded rows sorted here, by columns in order, instead of on the server.
    public var localSort: [(column: Int, ascending: Bool)] = [] { didSet { applyLocalFilter() } }
    /// The most characters a cell shows (key columns: all of them).
    public static let shownLimit = 1_000

    private var pages: [ResultStore] = []
    /// Each page's first row.
    private var pageStarts: [Int] = []
    public private(set) var loadedRows = 0
    /// Whether the last page was full: there may be more rows.
    public private(set) var hasMore = true
    /// The loaded rows shown while the local filter is on.
    private var shown: [Int]?
    /// New rows Apply wrote, read back from the server with what it filled in (the AUTO_INCREMENT key, defaults):
    /// shown after the loaded rows, where they were added, until a page brings them. Load More's offset leaves them out.
    public private(set) var saved: [ResultStore] = []
    /// Loaded rows Apply changed, as read back (a read-back result and its row), and those it deleted: kept until the
    /// rows load again, so an Apply with every row loaded doesn't load them all again.
    private var replaced: [Int: (store: ResultStore, row: Int)] = [:]
    private var removed: Set<Int> = []

    public init(database: String, table: SchemaTable) {
        self.database = database
        self.table = table
        columns = table.columns.map { column in
            var shown = GridColumn(name: column.name, kind: Self.kind(column))
            shown.describe(table)
            return shown
        }
        readOnlyReason = table.editingRefusal
        let keyColumns = readOnlyReason == nil ? table.editingKey : nil
        key = keyColumns?.compactMap { name in table.columns.firstIndex { $0.name == name } }
        changes = PendingChanges(keyColumns: keyColumns ?? [])
    }

    static func kind(_ column: SchemaColumn) -> GridColumn.Kind {
        let type = column.dataType.lowercased()
        if column.isJSON || type == "json" { return .json }
        if ["tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal", "numeric", "float", "double", "real"]
            .contains(type) { return .number }
        if ["date", "datetime", "timestamp", "time", "year"].contains(type) { return .date }
        if type.hasSuffix("binary") || type.hasSuffix("blob") || ["geometry", "point", "linestring", "polygon", "multipoint",
           "multilinestring", "multipolygon", "geometrycollection", "vector"].contains(type) { return .binary }
        return .text
    }

    // MARK: Statements

    /// " FROM `database`.`table`", then " WHERE (…)" with the filter: a newline before the closing parenthesis, so a
    /// condition ending in a -- comment can't swallow it (or the ORDER BY and LIMIT after it).
    private var from: String {
        let condition = GridFilter.condition(filter)
        return " FROM " + SQLQuote.identifier(database, table.name) + (condition.isEmpty ? "" : " WHERE (\(condition)\n)")
    }

    /// The SELECT of `limit` rows from `offset` (no limit: nil): every column by name (invisible ones too), the filter,
    /// and the sort, else the key's order, so pages follow one another.
    public func pageSQL(offset: Int, limit: Int?) -> String {
        var sql = "SELECT " + columns.map { SQLQuote.identifier($0.name) }.joined(separator: ", ") + from
        let order = sort.isEmpty ? (key ?? []).map { TableViewSettings.SortKey(column: columns[$0].name, ascending: true) } : sort
        if !order.isEmpty { sql += " ORDER BY " + GridSorting.orderBy(order) }
        if let limit { sql += " LIMIT \(limit)" }
        if offset > 0 { sql += (limit == nil ? " LIMIT 18446744073709551615" : "") + " OFFSET \(offset)" }
        return sql
    }

    /// `SELECT COUNT(*)` with the filter: Count Rows Exactly.
    public var countSQL: String { "SELECT COUNT(*)" + from }

    /// The server's estimate of the table's rows (InnoDB's is a guess), for the status bar until they are counted, and
    /// its size in bytes (Column Summary asks first above 2 GB).
    public func estimateSQL(noBackslashEscapes: Bool) -> String {
        "SELECT TABLE_ROWS, DATA_LENGTH FROM information_schema.TABLES WHERE TABLE_SCHEMA = "
            + SQLQuote.string(database, noBackslashEscapes: noBackslashEscapes) + " AND TABLE_NAME = "
            + SQLQuote.string(table.name, noBackslashEscapes: noBackslashEscapes)
    }

    /// Column Summary on the server: a column's distinct values, NULLs, smallest, largest and all rows, within the filter.
    public func summarySQL(_ column: Int) -> String {
        let name = SQLQuote.identifier(columns[column].name)
        return "SELECT COUNT(DISTINCT \(name)), COUNT(*) - COUNT(\(name)), MIN(\(name)), MAX(\(name)), COUNT(*)" + from
    }

    /// A column's most frequent values with how many rows have each, within the filter (Column Summary, Filter by
    /// Values).
    public func topValuesSQL(_ column: Int, limit: Int) -> String {
        let name = SQLQuote.identifier(columns[column].name)
        return "SELECT \(name), COUNT(*)" + from + " GROUP BY \(name) ORDER BY COUNT(*) DESC, \(name) LIMIT \(limit)"
    }

    /// Forgets the loaded rows (a new filter or sort, Refresh); the pending changes stay, and with `keepingSaved` the rows
    /// read back after Apply.
    public func reset(keepingSaved: Bool = false) {
        if !keepingSaved { saved = [] }
        replaced = [:]
        removed = []
        pages = []
        pageStarts = []
        loadedRows = 0
        hasMore = true
        applyLocalFilter()
    }

    /// Adds a page that asked for `requested` rows (nil: all the rest), after the rows already loaded.
    public func append(_ page: ResultStore, requested: Int?) {
        if !saved.isEmpty, let key, page.rowCount > 0 {
            // A row read back after Apply that this page brings shows once, where the page has it.
            let keys = Set((0..<page.rowCount).map { row in key.map { Self.text(page, row, $0) ?? "" } })
            saved.removeAll { store in keys.contains(key.map { Self.text(store, 0, $0) ?? "" }) }
        }
        if page.rowCount > 0 {
            pages.append(page)
            pageStarts.append(loadedRows)
            loadedRows += page.rowCount
        }
        hasMore = requested.map { page.rowCount >= $0 } ?? false || page.capped
        applyLocalFilter()
    }

    /// The rows read back after Apply (each one row, the table's columns in order), in place of those before.
    public func setSaved(_ rows: [ResultStore]) {
        saved = rows.filter { $0.rowCount == 1 && $0.columns.count == columns.count }
    }

    /// The keys of the rows read back after Apply.
    public var savedKeys: [PendingChanges.Key] {
        guard let key else { return [] }
        return saved.map { store in key.map { Self.text(store, 0, $0) ?? "" } }
    }

    /// The end of Load All's stream.
    public func finishLoading() {
        hasMore = false
    }

    /// The SELECTs that read loaded rows back by their keys after Apply, every column, up to `deleteBatch` keys each.
    public func readBackSQL(_ keys: [PendingChanges.Key], noBackslashEscapes: Bool) -> [String] {
        guard let key, !keys.isEmpty else { return [] }
        let names = key.map { SQLQuote.identifier(columns[$0].name) }
        func literals(_ values: PendingChanges.Key) -> [String] {
            zip(key, values).map { columns[$0].literal($1, noBackslashEscapes: noBackslashEscapes) }
        }
        return stride(from: 0, to: keys.count, by: PendingChanges.deleteBatch).map { start in
            let batch = keys[start..<min(start + PendingChanges.deleteBatch, keys.count)]
            let condition = names.count == 1 ? names[0] + " IN (" + batch.map { literals($0)[0] }.joined(separator: ", ") + ")"
                : "(" + names.joined(separator: ", ") + ") IN (" + batch.map { "(" + literals($0).joined(separator: ", ") + ")" }
                    .joined(separator: ", ") + ")"
            return "SELECT " + columns.map { SQLQuote.identifier($0.name) }.joined(separator: ", ") + " FROM "
                + SQLQuote.identifier(database, table.name) + " WHERE " + condition
        }
    }

    /// Shows what Apply wrote without loading the rows again: the loaded rows in `rows` (read back by key, the table's
    /// columns in order) take those values, and the rows with `deleted` keys go. False, changing nothing, when a row
    /// read back isn't among the loaded ones: load them again then.
    public func patch(_ rows: [ResultStore], deleted: Set<PendingChanges.Key>) -> Bool {
        guard let key else { return false }
        var loaded: [PendingChanges.Key: Int] = [:]
        for row in 0..<loadedRows where !removed.contains(row) { loaded[key.map { value(loaded: row, $0) ?? "" }] = row }
        var found: [Int: (store: ResultStore, row: Int)] = [:]
        for store in rows where store.columns.count == columns.count {
            for row in 0..<store.rowCount {
                guard let index = loaded[key.map { Self.text(store, row, $0) ?? "" }] else { return false }
                found[index] = (store, row)
            }
        }
        replaced.merge(found) { _, new in new }
        removed.formUnion(deleted.compactMap { loaded[$0] })
        applyLocalFilter()
        return true
    }

    /// The loaded rows less those an Apply deleted.
    public var keptRows: Int { loadedRows - removed.count }

    private func applyLocalFilter() {
        guard localFilter != nil || !localSort.isEmpty || !removed.isEmpty else { return shown = nil }
        var rows = removed.isEmpty ? Array(0..<loadedRows) : (0..<loadedRows).filter { !removed.contains($0) }
        if let localFilter { rows = rows.filter { row in localFilter(columns.indices.map { value(loaded: row, $0) }) } }
        shown = GridSorting.sorted(rows, by: localSort, columns: columns) { value(loaded: $0, $1) }
    }

    // MARK: Rows

    /// What a grid row is: a loaded row (its index among the loaded rows) or a new row.
    public enum Row: Equatable {
        case loaded(Int)
        case inserted(UUID)
    }

    public var shownLoadedRows: Int { (shown?.count ?? loadedRows) + saved.count }
    public var rowCount: Int { shownLoadedRows + changes.state.inserts.count }

    public func row(_ index: Int) -> Row? {
        let pageRows = shown?.count ?? loadedRows
        if index < pageRows { return .loaded(shown?[index] ?? index) }
        if index < shownLoadedRows { return .loaded(loadedRows + index - pageRows) }  // read back after Apply
        let inserts = changes.state.inserts, new = index - shownLoadedRows
        return inserts.indices.contains(new) ? .inserted(inserts[new].id) : nil
    }

    /// The grid row of a new row.
    public func index(of insert: UUID) -> Int? {
        changes.state.inserts.firstIndex { $0.id == insert }.map { shownLoadedRows + $0 }
    }

    /// The key of a loaded row (nil for a new row, or a table without a key).
    public func rowKey(_ index: Int) -> PendingChanges.Key? {
        guard let key, case .loaded(let row) = self.row(index) else { return nil }
        return key.map { value(loaded: row, $0) ?? "" }
    }

    /// The grid row showing the loaded row with this key, if it is shown.
    public func index(of rowKey: PendingChanges.Key) -> Int? {
        (0..<shownLoadedRows).first { self.rowKey($0) == rowKey }
    }

    private func page(_ row: Int) -> (ResultStore, Int) {
        if row >= loadedRows { return (saved[row - loadedRows], 0) }
        if let patched = replaced[row] { return patched }
        var low = 0, high = pageStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if pageStarts[middle] <= row { low = middle } else { high = middle - 1 }
        }
        return (pages[low], row - pageStarts[low])
    }

    /// A loaded row's value as the server sent it, whole: text, BIT as its bits, binary as "0x…"; nil for NULL.
    public func value(loaded row: Int, _ column: Int) -> String? {
        let (store, local) = page(row)
        return Self.text(store, local, column)
    }

    /// A loaded cell's bytes as the server sent them, for the value panel's hex and image (nil for NULL, and for a cell
    /// with a pending change or of a new row: those show as text).
    public func bytes(_ index: Int, _ column: Int) -> [UInt8]? {
        guard case .loaded(let row) = self.row(index), mark(index, column) == .none else { return nil }
        let (store, local) = page(row)
        return store.bytes(local, column)
    }

    /// A stored value as the grid's sources give it whole (export streams them this way too): binary as all its hex.
    public static func text(_ store: ResultStore, _ row: Int, _ column: Int) -> String? {
        store.display(row, column, binaryBytes: .max)
    }

    /// A cell's value with its pending change, whole (for editing, copying and exporting): nil for NULL.
    public func value(_ index: Int, _ column: Int) -> String? {
        switch row(index) {
        case .loaded(let row):
            if !changes.state.edits.isEmpty, let key = rowKey(index), let value = changes.value(key, columns[column].name) {
                return value.text ?? shownText(value)
            }
            return value(loaded: row, column)
        case .inserted(let id):
            guard let value = changes.insert(id)?.values[columns[column].name] else { return unset(column) }
            return value.text ?? shownText(value)
        case nil: return nil
        }
    }

    /// An unset cell of a new row: the column's default, as the server will put it there (nil for an AUTO_INCREMENT or
    /// generated value, which only the server knows).
    private func unset(_ column: Int) -> String? {
        let info = table.columns[column]
        guard !info.autoIncrement, info.generated == nil else { return nil }
        switch info.defaultValue {
        case .none: return ""
        case .null: return nil
        case .value(let text), .expression(let text): return text
        }
    }

    /// What a cell shows while the server decides its value at Apply: a pending DEFAULT or expression ("ƒ NOW()"), or a
    /// new row's untouched column ("auto", "default", "generated"); nil for a value or NULL.
    private func placeholder(_ index: Int, _ column: Int) -> String? {
        let name = columns[column].name, pending: PendingChanges.Value?
        switch row(index) {
        case .loaded: pending = changes.state.edits.isEmpty ? nil : rowKey(index).flatMap { changes.value($0, name) }
        case .inserted(let id):
            pending = changes.insert(id)?.values[name]
            if pending == nil {
                let untouched = table.columns[column].newRowValue
                return untouched == .null || untouched == .required ? nil : untouched.placeholder
            }
        case nil: return nil
        }
        switch pending {
        case .default?: return "default"
        case .sql(let sql)?: return "ƒ " + sql
        default: return nil
        }
    }

    private func shownText(_ value: PendingChanges.Value) -> String? { value == .default ? "DEFAULT" : nil }

    // MARK: GridSource

    public func cell(_ row: Int, _ column: Int) -> GridCell {
        guard row < rowCount else { return .loading }
        if let shown = placeholder(row, column) { return .placeholder(shown) }
        guard let text = value(row, column) else { return .null }
        guard !columns[column].isKey, text.count > Self.shownLimit else { return .text(text) }
        return .text(String(text.prefix(Self.shownLimit)) + "…")
    }

    public func mark(_ row: Int, _ column: Int) -> GridMark {
        guard !changes.isEmpty else { return .none }
        switch self.row(row) {
        case .inserted: return .inserted
        case .loaded:
            guard let key = rowKey(row) else { return .none }
            if changes.isDeleted(key) { return .deleted }
            return changes.value(key, columns[column].name) == nil ? .none : .edited
        case nil: return .none
        }
    }

    // MARK: Editing

    /// Whether a cell can be edited: the table has a key, the column isn't generated, the row isn't being deleted.
    public func canEdit(_ index: Int, _ column: Int) -> Bool {
        guard key != nil, table.columns[column].generated == nil, let row = row(index) else { return false }
        if case .loaded = row, let key = rowKey(index) { return !changes.isDeleted(key) }
        return true
    }

    /// Sets a cell as a pending change (nil: NULL).
    public func set(_ value: PendingChanges.Value, row index: Int, column: Int) {
        guard canEdit(index, column) else { return }
        switch row(index) {
        case .loaded(let row):
            guard let key = rowKey(index) else { return }
            changes.set(value, column: columns[column].name, key: key, original: self.value(loaded: row, column))
        case .inserted(let id): changes.set(value, column: columns[column].name, insert: id)
        case nil: break
        }
    }
}

extension GridColumn {
    /// Adds what a table's schema says to a column of its rows: the full type ("varchar(120)"), the key marks
    /// (primary, foreign, unique, indexed), auto-increment, a default, generated, NULL allowed, and the comment.
    /// `isKey` marks the key that addresses a row (`SchemaTable.editingKey`).
    public mutating func describe(_ table: SchemaTable) {
        guard let column = table.column(name) else { return }
        func has(_ index: SchemaIndex) -> Bool {
            index.parts.contains { $0.column?.caseInsensitiveCompare(column.name) == .orderedSame }
        }
        type = column.columnType
        comment = column.comment
        var marks: Marks = column.nullable ? .nullable : []
        if column.autoIncrement { marks.insert(.autoIncrement) }
        if column.generated != nil { marks.insert(.generated) }
        if column.defaultValue != .none, column.defaultValue != .null, column.generated == nil { marks.insert(.hasDefault) }
        for index in table.indexes where has(index) {
            marks.insert(index.isPrimary ? .primary : index.unique ? .unique : .indexed)
        }
        if table.foreignKeys.contains(where: { $0.columns.contains { $0.caseInsensitiveCompare(column.name) == .orderedSame } }) {
            marks.insert(.foreign)
        }
        self.marks = marks
        isKey = table.editingKey?.contains { $0.caseInsensitiveCompare(column.name) == .orderedSame } ?? false
    }
}
