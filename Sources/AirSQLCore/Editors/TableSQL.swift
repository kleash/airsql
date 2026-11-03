import Foundation

extension TableDesign {
    /// The statements that make the table as designed, built only with `SQLQuote`: CREATE TABLE when `original` is nil,
    /// else ALTER TABLE for what changed (none when nothing did). A foreign key that changes is dropped in a statement of
    /// its own first: neither server takes a drop and an add of the same key name in one ALTER. Throws `DesignError`
    /// for what the server couldn't take (a VARCHAR without a length, two columns of one name).
    public func statements(database: String, from original: TableDesign?, server: SchemaServer) throws -> [String] {
        let sql = TableSQL(server: server, database: database)
        try sql.validate(self)
        guard let original else { return [try sql.create(self)] }
        return try sql.alter(from: original, to: self)
    }
}

struct TableSQL {
    let server: SchemaServer
    let database: String

    func text(_ value: String) -> String { SQLQuote.string(value, noBackslashEscapes: server.noBackslashEscapes) }

    // MARK: CREATE

    func create(_ table: TableDesign) throws -> String {
        var lines = try table.columns.map(definition)
        lines += try table.indexes.map(index)
        lines += try table.foreignKeys.map(foreignKey)
        lines += table.checks.map(check)
        let options = try self.options(table.options, from: nil)
        return "CREATE TABLE " + SQLQuote.identifier(database, table.name) + " (\n  " + lines.joined(separator: ",\n  ") + "\n)"
            + (options.isEmpty ? "" : " " + options.joined(separator: " "))
    }

    // MARK: ALTER

    func alter(from old: TableDesign, to new: TableDesign) throws -> [String] {
        // Keys are compared with the old column names put as they are now: the server renames a column in its keys.
        var dropKeys: [String] = [], drops: [String] = [], changes: [String] = [], adds: [String] = []
        for key in old.foreignKeys {
            let current = new.foreignKeys.first { $0.original == key.name }
            if current.map({ same($0, new.renamingColumns(of: key)) }) != true {
                dropKeys.append("DROP FOREIGN KEY " + SQLQuote.identifier(key.name))
            }
        }
        for key in new.foreignKeys {
            let before = old.foreignKeys.first { $0.name == key.original }.map(new.renamingColumns(of:))
            if before.map({ same(key, $0) }) != true { adds.append("ADD " + (try foreignKey(key))) }
        }

        for check in old.checks {
            guard let current = new.checks.first(where: { $0.original == check.name }),
                  current.name == check.name, current.clause == check.clause else {
                drops.append((server.flavour == .mysql ? "DROP CHECK " : "DROP CONSTRAINT ") + SQLQuote.identifier(check.name))
                continue
            }
            if current.enforced != check.enforced, server.flavour == .mysql {
                changes.append("ALTER CHECK " + SQLQuote.identifier(check.name) + (current.enforced ? " ENFORCED" : " NOT ENFORCED"))
            }
        }
        for check in new.checks {
            let before = old.checks.first { $0.name == check.original }
            if before == nil || before?.name != check.name || before?.clause != check.clause { adds.append("ADD " + self.check(check)) }
        }

        for index in old.indexes {
            let moved = new.renamingColumns(of: index)
            let current = new.indexes.first { $0.original == index.name }
            if let current, same(current, moved) {
                if current.name != index.name, current.kind != .primary {
                    changes.append("RENAME INDEX " + SQLQuote.identifier(index.name) + " TO " + SQLQuote.identifier(current.name))
                }
                continue
            }
            drops.append(index.kind == .primary ? "DROP PRIMARY KEY" : "DROP INDEX " + SQLQuote.identifier(index.name))
            if let current { adds.append("ADD " + (try self.index(current))) }
        }
        for index in new.indexes where index.original.flatMap({ name in old.indexes.first { $0.name == name } }) == nil {
            adds.append("ADD " + (try self.index(index)))
        }

        let kept = Set(new.columns.compactMap(\.original))
        for column in old.columns where !kept.contains(column.name) {
            drops.append("DROP COLUMN " + SQLQuote.identifier(column.name))
        }
        changes += try columnChanges(from: old, to: new)
        changes += try options(new.options, from: old.options)
        if new.name != old.name { changes.append("RENAME TO " + SQLQuote.identifier(database, new.name)) }

        let table = "ALTER TABLE " + SQLQuote.identifier(database, old.name) + "\n  "
        var statements: [String] = []
        if !dropKeys.isEmpty { statements.append(table + dropKeys.joined(separator: ",\n  ")) }
        let clauses = drops + changes + adds
        if !clauses.isEmpty { statements.append(table + clauses.joined(separator: ",\n  ")) }
        return statements
    }

    /// ADD, CHANGE and MODIFY COLUMN in the new order. The server keeps a changed column in place unless it is told
    /// FIRST or AFTER, and places the columns that are told in the order of the clauses, each after a column already
    /// there; so only the columns that really moved (those outside the longest run of columns still in their old order)
    /// and the new ones get a position, in the new order.
    func columnChanges(from old: TableDesign, to new: TableDesign) throws -> [String] {
        let oldOrder = Dictionary(old.columns.enumerated().map { ($1.name, $0) }) { first, _ in first }
        let existing = new.columns.indices.filter { new.columns[$0].original.flatMap { oldOrder[$0] } != nil }
        let sequence = existing.map { oldOrder[new.columns[$0].original!]! }
        let staying = Set(Self.longestIncreasingRun(sequence).map { existing[$0] })
        var clauses: [String] = []
        for (offset, column) in new.columns.enumerated() {
            let position = offset == 0 ? " FIRST" : " AFTER " + SQLQuote.identifier(new.columns[offset - 1].name)
            guard let original = column.original, let before = old.columns.first(where: { $0.name == original }) else {
                clauses.append("ADD COLUMN " + (try definition(column)) + position)
                continue
            }
            var unchanged = before
            unchanged.name = column.name
            let moved = !staying.contains(offset)
            guard moved || unchanged != column || column.name != original else { continue }
            let head = column.name == original ? "MODIFY COLUMN " : "CHANGE COLUMN " + SQLQuote.identifier(original) + " "
            clauses.append(head + (try definition(column)) + (moved ? position : ""))
        }
        return clauses
    }

    /// The positions in `values` of a longest strictly increasing subsequence.
    static func longestIncreasingRun(_ values: [Int]) -> [Int] {
        guard !values.isEmpty else { return [] }
        var length = Array(repeating: 1, count: values.count), previous = Array(repeating: -1, count: values.count)
        for index in values.indices {
            for earlier in 0..<index where values[earlier] < values[index] && length[earlier] + 1 > length[index] {
                length[index] = length[earlier] + 1
                previous[index] = earlier
            }
        }
        var position = length.indices.max { length[$0] < length[$1] }!
        var run: [Int] = []
        while position >= 0 {
            run.append(position)
            position = previous[position]
        }
        return run.reversed()
    }
}
