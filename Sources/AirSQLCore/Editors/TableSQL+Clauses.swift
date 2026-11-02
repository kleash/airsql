import Foundation

// The pieces of the table editor's statements: a column's definition, an index, a foreign key, a check, the table
// options; and the checks that a design can be written at all.
extension TableSQL {
    /// A column as CREATE TABLE and ALTER TABLE write it, in SHOW CREATE TABLE's order.
    func definition(_ column: ColumnDesign) throws -> String {
        var parts = [SQLQuote.identifier(column.name), try column.type.sql(noBackslashEscapes: server.noBackslashEscapes)]
        if column.columnType?.text ?? false, let collation = column.collation {
            let charset = try word(column.charset.flatMap { collation.hasPrefix($0 + "_") ? $0 : nil } ?? Self.charset(of: collation),
                                   "character set")
            parts.append("CHARACTER SET " + charset + " COLLATE " + (try word(collation, "collation")))
        }
        if let generated = column.generated {
            parts.append("GENERATED ALWAYS AS (" + generated.expression + ") " + (generated.stored ? "STORED" : "VIRTUAL"))
            if !column.nullable { parts.append("NOT NULL") }
        } else {
            parts.append(column.nullable ? "NULL" : "NOT NULL")
            if !column.autoIncrement, let value = try defaultSQL(column) { parts.append("DEFAULT " + value) }
            if let onUpdate = column.onUpdate {
                guard Self.isCurrentTimestamp(onUpdate) else { throw DesignError("ON UPDATE takes CURRENT_TIMESTAMP only") }
                parts.append("ON UPDATE " + onUpdate)
            }
            if column.autoIncrement { parts.append("AUTO_INCREMENT") }
        }
        if column.invisible { parts.append("INVISIBLE") }
        if !column.comment.isEmpty { parts.append("COMMENT " + text(column.comment)) }
        if server.flavour == .mariadb, let check = column.check { parts.append("CHECK (" + check + ")") }
        return parts.joined(separator: " ")
    }

    /// What follows DEFAULT: NULL, a constant quoted with `SQLQuote` (numbers bare in number columns), or the person's
    /// expression, in parentheses where MySQL 8 wants them; nil for no default.
    func defaultSQL(_ column: ColumnDesign) throws -> String? {
        switch column.defaultValue {
        case .none: return nil
        case .null: return column.nullable ? "NULL" : nil
        case .value(let value):
            let number = column.columnType?.numeric ?? false
            return number && SchemaIntrospection.isNumber(value) ? value : text(value)
        case .expression(let expression):
            let bare = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bare.isEmpty else { return nil }
            let literal = Self.isCurrentTimestamp(bare) || bare.hasPrefix("(")
                || bare.range(of: "^([bBxX]'[0-9A-Fa-f]*'|0[xb][0-9A-Fa-f]+|NULL|[-+]?[0-9.]+)$", options: [.regularExpression,
                                                                                                           .caseInsensitive]) != nil
            let parentheses = server.flavour == .mariadb || server.atLeast(8, 0, 13)
            return literal || !parentheses ? bare : "(" + bare + ")"
        }
    }

    /// CURRENT_TIMESTAMP and its synonyms, with a precision or not: what DEFAULT and ON UPDATE take bare.
    static func isCurrentTimestamp(_ text: String) -> Bool {
        text.range(of: "^(current_timestamp|now|localtime|localtimestamp)(\\([0-6]?\\))?$", options: [.regularExpression,
                                                                                                    .caseInsensitive]) != nil
    }

    /// utf8mb4 for utf8mb4_unicode_ci: a collation's name starts with its character set's.
    static func charset(of collation: String) -> String {
        collation == "binary" ? "binary" : String(collation.prefix { $0 != "_" })
    }

    /// An index as CREATE TABLE lists it and ALTER TABLE adds it.
    func index(_ index: IndexDesign) throws -> String {
        let parts = try index.parts.map { part -> String in
            var text: String
            if let column = part.column {
                text = SQLQuote.identifier(column) + (part.prefixLength.map { "(\($0))" } ?? "")
            } else if let expression = part.expression {
                text = "(" + expression + ")"
            } else {
                throw DesignError("A part of index \(index.name) has neither a column nor an expression")
            }
            if part.descending { text += " DESC" }
            return text
        }
        let name = index.name.isEmpty ? "" : SQLQuote.identifier(index.name) + " "
        var sql: String
        switch index.kind {
        case .primary: sql = "PRIMARY KEY "
        case .unique: sql = "UNIQUE INDEX " + name
        case .index: sql = "INDEX " + name
        case .fulltext: sql = "FULLTEXT INDEX " + name
        case .spatial: sql = "SPATIAL INDEX " + name
        case .vector: sql = "VECTOR INDEX " + name
        }
        sql += "(" + parts.joined(separator: ", ") + ")"
        if !index.comment.isEmpty { sql += " COMMENT " + text(index.comment) }
        if !index.visible { sql += server.flavour == .mysql ? " INVISIBLE" : " IGNORED" }
        return sql
    }

    func foreignKey(_ key: ForeignKeyDesign) throws -> String {
        for rule in [key.onUpdate, key.onDelete] where !ForeignKeyDesign.rules.contains(rule) {
            throw DesignError("“\(rule)” isn't something a foreign key can do")
        }
        let table = key.referencedDatabase == database || key.referencedDatabase.isEmpty
            ? SQLQuote.identifier(key.referencedTable) : SQLQuote.identifier(key.referencedDatabase, key.referencedTable)
        return (key.name.isEmpty ? "" : "CONSTRAINT " + SQLQuote.identifier(key.name) + " ")
            + "FOREIGN KEY (" + key.columns.map(SQLQuote.identifier).joined(separator: ", ") + ") REFERENCES " + table
            + " (" + key.referencedColumns.map(SQLQuote.identifier).joined(separator: ", ") + ")"
            + " ON DELETE " + key.onDelete + " ON UPDATE " + key.onUpdate
    }

    func check(_ check: CheckDesign) -> String {
        (check.name.isEmpty ? "" : "CONSTRAINT " + SQLQuote.identifier(check.name) + " ") + "CHECK (" + check.clause + ")"
            + (server.flavour == .mysql && !check.enforced ? " NOT ENFORCED" : "")
    }

    /// The table options that differ from `old` (all that are set, for CREATE TABLE).
    func options(_ new: TableOptions, from old: TableOptions?) throws -> [String] {
        var options: [String] = []
        if let engine = new.engine, engine.caseInsensitiveCompare(old?.engine ?? "") != .orderedSame {
            options.append("ENGINE=" + (try word(engine, "engine")))
        }
        if let collation = new.collation, collation != old?.collation {
            let collation = try word(collation, "collation")
            options.append("DEFAULT CHARSET=" + Self.charset(of: collation) + " COLLATE=" + collation)
        }
        if new.comment != (old?.comment ?? "") { options.append("COMMENT=" + text(new.comment)) }
        if let next = new.autoIncrement, next != old?.autoIncrement { options.append("AUTO_INCREMENT=\(next)") }
        if let format = new.rowFormat, format.caseInsensitiveCompare(old?.rowFormat ?? "") != .orderedSame {
            guard TableOptions.rowFormats.contains(format.uppercased()) else { throw DesignError("“\(format)” isn't a row format") }
            options.append("ROW_FORMAT=" + format.uppercased())
        }
        return options
    }

    /// A name written without quotes (an engine, a character set, a collation), so it must be a plain word.
    func word(_ text: String, _ what: String) throws -> String {
        guard text.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil else {
            throw DesignError("“\(text)” isn't a \(what)")
        }
        return text
    }

    // MARK: Comparing

    func same(_ a: IndexDesign, _ b: IndexDesign) -> Bool {
        a.kind == b.kind && a.parts == b.parts && a.comment == b.comment && a.visible == b.visible
    }

    func same(_ a: ForeignKeyDesign, _ b: ForeignKeyDesign) -> Bool {
        a.name == b.name && a.columns == b.columns && a.referencedTable == b.referencedTable
            && (a.referencedDatabase.isEmpty ? database : a.referencedDatabase)
                == (b.referencedDatabase.isEmpty ? database : b.referencedDatabase)
            && a.referencedColumns == b.referencedColumns && a.onUpdate == b.onUpdate && a.onDelete == b.onDelete
    }

    // MARK: Checking

    /// Refuses what no server takes, in plain words, before anything is written.
    func validate(_ table: TableDesign) throws {
        try name(table.name, "The table")
        guard !table.columns.isEmpty else { throw DesignError("Add a column first: a table needs at least one") }
        var seen = Set<String>()
        for column in table.columns {
            try name(column.name, "A column")
            guard seen.insert(column.name.lowercased()).inserted else { throw DesignError("Two columns are named \(column.name)") }
            if column.autoIncrement && !(column.columnType?.integer ?? false) {
                throw DesignError("Only whole-number columns can count up by themselves (AUTO_INCREMENT): \(column.name)")
            }
        }
        var indexNames = Set<String>()
        for index in table.indexes {
            guard !index.parts.isEmpty else { throw DesignError("Give index \(index.name) a column") }
            if !index.name.isEmpty, index.kind != .primary {
                guard indexNames.insert(index.name.lowercased()).inserted else { throw DesignError("Two indexes are named \(index.name)") }
            }
            for part in index.parts {
                if let column = part.column, !seen.contains(column.lowercased()) {
                    throw DesignError("Index \(index.name) uses \(column), which isn't a column of this table")
                }
            }
        }
        guard table.indexes.filter({ $0.kind == .primary }).count <= 1 else { throw DesignError("A table has one primary key at most") }
        for key in table.foreignKeys {
            guard !key.columns.isEmpty, key.columns.count == key.referencedColumns.count, !key.referencedTable.isEmpty else {
                throw DesignError("Foreign key \(key.name) needs a table to point at, and as many columns there as here")
            }
            for column in key.columns where !seen.contains(column.lowercased()) {
                throw DesignError("Foreign key \(key.name) uses \(column), which isn't a column of this table")
            }
        }
        for check in table.checks where check.clause.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DesignError("Give check \(check.name) a condition")
        }
    }

    /// A name the server takes: not empty, at most 64 characters, not ending in a space.
    func name(_ name: String, _ what: String) throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw DesignError("\(what) needs a name") }
        guard name.count <= 64 else { throw DesignError("“\(name.prefix(20))…” is longer than the 64 characters a name may have") }
        guard !name.hasSuffix(" ") else { throw DesignError("“\(name)” ends with a space, which names may not") }
    }
}
