import Foundation

/// Compares two databases' structure as the schema cache read them (plan §2.9: normalised SchemaCache objects with
/// ignore rules): tables part by part (columns, indexes, foreign keys, checks, options), and views, routines, triggers,
/// events and sequences by their definitions. The details say what makes the target different, target → source.
struct ReconStructure {
    let source: SchemaDatabase, target: SchemaDatabase
    let sourceServer: SchemaServer, targetServer: SchemaServer
    let options: ReconOptions

    private var caseless: Bool { sourceServer.lowerCaseTableNames != 0 || targetServer.lowerCaseTableNames != 0 }

    private func same(_ a: String, _ b: String) -> Bool {
        caseless ? a.caseInsensitiveCompare(b) == .orderedSame : a == b
    }

    /// Source tables (left out ones skipped) with their target tables, by name or as mapped; then the target's tables
    /// that no source table claims.
    func tablePairs() -> (pairs: [(source: SchemaTable, target: SchemaTable?)], onlyInTarget: [SchemaTable]) {
        let sourceTables = source.tables.filter { $0.kind == .table }
        let targetTables = target.tables.filter { $0.kind == .table }
        if let only = options.only {
            guard only.kind == .table, let table = sourceTables.first(where: { same($0.name, only.source) }) else { return ([], []) }
            return ([(table, targetTables.first { same($0.name, only.target) })], [])
        }
        var claimed: [String] = []
        var pairs: [(source: SchemaTable, target: SchemaTable?)] = []
        for table in sourceTables {
            let choice = options.choice(table.name)
            let name = choice.target ?? table.name
            claimed.append(name)
            guard choice.included else { continue }
            pairs.append((table, targetTables.first { same($0.name, name) }))
        }
        let onlyInTarget = targetTables.filter { table in !claimed.contains { same($0, table.name) } }
        return (pairs, onlyInTarget)
    }

    /// What makes the target table differ from the source table; empty when they match.
    func compare(_ left: SchemaTable, _ right: SchemaTable) -> [ReconPart] {
        columns(left, right) + indexes(left, right) + foreignKeys(left, right) + checks(left, right) + tableOptions(left, right)
    }

    private func columns(_ left: SchemaTable, _ right: SchemaTable) -> [ReconPart] {
        var parts: [ReconPart] = []
        var previous: String?
        // The columns both have, in the source's order; `order` plays the moves that put the target's in it.
        let shared = left.columns.filter { right.column($0.name) != nil }.map { $0.name.lowercased() }
        var order = right.columns.filter { left.column($0.name) != nil }.map { $0.name.lowercased() }
        var moved: Set<String> = []
        for (index, name) in shared.enumerated() where order[index] != name {
            moved.insert(name)
            order.removeAll { $0 == name }
            order.insert(name, at: index)
        }
        for column in left.columns {
            if let other = right.column(column.name) {
                let isMoved = !options.ignore.columnOrder && moved.contains(column.name.lowercased())
                let changes = columnChanges(from: other, to: column) + (isMoved ? ["moved"] : [])
                if !changes.isEmpty {
                    var part = ReconPart(kind: .column, name: column.name, change: .changed, after: previous,
                                         detail: changes.joined(separator: ", "),
                                         narrowing: Self.narrows(from: other, to: column))
                    part.moved = isMoved
                    parts.append(part)
                }
            } else {
                parts.append(ReconPart(kind: .column, name: column.name, change: .added, after: previous, detail: "added"))
            }
            previous = column.name
        }
        for column in right.columns where left.column(column.name) == nil {
            parts.append(ReconPart(kind: .column, name: column.name, change: .dropped, detail: "only in the target"))
        }
        return parts
    }

    /// The column's differences in plain words, target → source.
    private func columnChanges(from old: SchemaColumn, to new: SchemaColumn) -> [String] {
        var changes: [String] = []
        let oldType = ReconNormal.type(old), newType = ReconNormal.type(new)
        if oldType != newType { changes.append("type \(oldType) → \(newType)") }
        if old.nullable != new.nullable { changes.append(new.nullable ? "NOT NULL → NULL" : "NULL → NOT NULL") }
        if old.generated == nil, new.generated == nil,
           ReconNormal.defaultValue(old.defaultValue) != ReconNormal.defaultValue(new.defaultValue) {
            changes.append("default")
        }
        if old.autoIncrement != new.autoIncrement { changes.append("auto-increment") }
        if ReconNormal.onUpdate(old.onUpdate) != ReconNormal.onUpdate(new.onUpdate) { changes.append("on update") }
        if old.generated.map({ ReconNormal.expression($0.expression) }) != new.generated.map({ ReconNormal.expression($0.expression) })
            || old.generated?.stored != new.generated?.stored {
            changes.append("generated expression")
        }
        if old.invisible != new.invisible { changes.append(new.invisible ? "made invisible" : "made visible") }
        if !options.ignore.collation, !old.isJSON, !new.isJSON {
            if ReconNormal.charset(old.charset) != ReconNormal.charset(new.charset) {
                changes.append("character set \(old.charset ?? "none") → \(new.charset ?? "none")")
            } else if ReconNormal.charset(old.collation) != ReconNormal.charset(new.collation) {
                changes.append("collation \(old.collation ?? "none") → \(new.collation ?? "none")")
            }
        }
        if old.comment != new.comment { changes.append("comment") }
        return changes
    }

    /// The new definition may not hold every value the old one does (or rejects some it has): MODIFY could lose or
    /// refuse data, so it is a destructive step. Only clear widenings count as safe.
    static func narrows(from old: SchemaColumn, to new: SchemaColumn) -> Bool {
        if old.nullable && !new.nullable { return true }
        let a = ReconNormal.type(old), b = ReconNormal.type(new)
        if a == b { return false }
        func split(_ type: String) -> (base: String, size: [Int], unsigned: Bool) {
            let base = String(type.prefix { $0.isLetter })
            var size: [Int] = []
            if let open = type.firstIndex(of: "("), let close = type.firstIndex(of: ")"), open < close {
                size = type[type.index(after: open)..<close].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            }
            return (base, size, type.contains("unsigned"))
        }
        let (oldBase, oldSize, oldUnsigned) = split(a), (newBase, newSize, newUnsigned) = split(b)
        let integers = ["tinyint", "smallint", "mediumint", "int", "bigint"]
        if let from = integers.firstIndex(of: oldBase), let to = integers.firstIndex(of: newBase) {
            return oldUnsigned == newUnsigned ? to < from : !(oldUnsigned && !newUnsigned && to > from)
        }
        let texts = ["varchar", "tinytext", "text", "mediumtext", "longtext"]
        if let from = texts.firstIndex(of: oldBase), let to = texts.firstIndex(of: newBase), from != to {
            return to < from || from == 0 && to == 1
        }
        if oldBase == newBase, ["varchar", "char", "varbinary", "binary"].contains(oldBase) {
            return (newSize.first ?? 0) < (oldSize.first ?? 0)
        }
        if oldBase == "decimal", newBase == "decimal", oldSize.count == 2, newSize.count == 2 {
            return newSize[1] < oldSize[1] || newSize[0] - newSize[1] < oldSize[0] - oldSize[1]
        }
        return !(oldBase == "float" && newBase == "double")
    }

    private func indexes(_ left: SchemaTable, _ right: SchemaTable) -> [ReconPart] {
        func shape(_ index: SchemaIndex) -> [String] {
            [index.unique ? "unique" : "", index.type.uppercased(), index.visible ? "" : "invisible", index.comment]
                + index.parts.map { part in
                    [part.column?.lowercased() ?? ReconNormal.expression(part.expression ?? ""),
                     part.prefixLength.map(String.init) ?? "", part.descending ? "desc" : ""].joined(separator: ":")
                }
        }
        return matched(left.indexes, right.indexes, name: \.name, kind: .index, differ: { shape($0) != shape($1) })
    }

    private func foreignKeys(_ left: SchemaTable, _ right: SchemaTable) -> [ReconPart] {
        func shape(_ key: SchemaForeignKey, _ database: String) -> [String] {
            let referenced = same(key.referencedDatabase, database) ? "" : key.referencedDatabase
            return [referenced, caseless ? key.referencedTable.lowercased() : key.referencedTable,
                    ReconNormal.rule(key.onUpdate), ReconNormal.rule(key.onDelete)]
                + key.columns.map { $0.lowercased() } + ["→"] + key.referencedColumns.map { $0.lowercased() }
        }
        var theirs = right.foreignKeys
        // Two tables of one database can't share a key's name: a chosen pair matches keys by what they do.
        if options.only != nil {
            for key in left.foreignKeys where !theirs.contains(where: { $0.name == key.name }) {
                if let match = theirs.firstIndex(where: { other in
                    !left.foreignKeys.contains { $0.name == other.name } && shape(other, target.name) == shape(key, source.name)
                }) {
                    theirs[match].name = key.name
                }
            }
        }
        return matched(left.foreignKeys, theirs, name: \.name, kind: .foreignKey,
                       differ: { shape($0, source.name) != shape($1, target.name) })
    }

    private func checks(_ left: SchemaTable, _ right: SchemaTable) -> [ReconPart] {
        var sourceChecks = Self.ownChecks(left), targetChecks = Self.ownChecks(right)
        // Checks the servers named differently (MySQL: orders_chk_1, MariaDB: CONSTRAINT_1) pair up by their clause.
        for check in sourceChecks where !targetChecks.contains(where: { $0.name == check.name }) {
            if let match = targetChecks.firstIndex(where: { other in
                !sourceChecks.contains { $0.name == other.name }
                    && ReconNormal.expression(other.clause) == ReconNormal.expression(check.clause)
            }) {
                targetChecks[match].name = check.name
            }
        }
        sourceChecks.sort { $0.name < $1.name }
        return matched(sourceChecks, targetChecks, name: \.name, kind: .check, differ: {
            ReconNormal.expression($0.clause) != ReconNormal.expression($1.clause) || $0.enforced != $1.enforced
        })
    }

    /// A table's checks without MariaDB's json_valid(`column`) checks on its JSON columns (MySQL's JSON type needs none).
    static func ownChecks(_ table: SchemaTable) -> [SchemaCheck] {
        table.checks.filter { check in
            !table.columns.contains { column in
                column.isJSON && ReconNormal.expression(check.clause)
                    == "json_valid(" + SQLQuote.identifier(column.name.lowercased()) + ")"
            }
        }
    }

    private func tableOptions(_ left: SchemaTable, _ right: SchemaTable) -> [ReconPart] {
        var parts: [ReconPart] = []
        if let engine = left.engine, let other = right.engine, engine.lowercased() != other.lowercased() {
            parts.append(ReconPart(kind: .options, name: "engine", change: .changed, definition: "ENGINE=\(engine)",
                                   detail: "engine \(other) → \(engine)"))
        }
        if left.comment != right.comment {
            parts.append(ReconPart(kind: .options, name: "comment", change: .changed,
                                   definition: "COMMENT=" + SQLQuote.string(left.comment,
                                                                            noBackslashEscapes: targetServer.noBackslashEscapes),
                                   detail: "comment"))
        }
        let ours = source.statistics?[left.name], theirs = target.statistics?[right.name]
        if !options.ignore.collation, let collation = ours?.collation, let other = theirs?.collation,
           ReconNormal.charset(collation) != ReconNormal.charset(other) {
            parts.append(ReconPart(kind: .options, name: "collation", change: .changed, definition: "COLLATE=\(collation)",
                                   detail: "default collation \(other) → \(collation)"))
        }
        if let format = ours?.rowFormat, let other = theirs?.rowFormat, format.lowercased() != other.lowercased() {
            parts.append(ReconPart(kind: .options, name: "row_format", change: .changed, definition: "ROW_FORMAT=\(format.uppercased())",
                                   detail: "row format \(other) → \(format)"))
        }
        // Whether, not how: no statement here, as a partitioning clause isn't among what the compare reads.
        let partitioned = ours?.createOptions?.lowercased().contains("partitioned"), other = theirs?.createOptions?.lowercased().contains("partitioned")
        if let partitioned, let other, partitioned != other {
            parts.append(ReconPart(kind: .options, name: "partitioning", change: .changed,
                                   detail: partitioned ? "partitioned only in the source" : "partitioned only in the target"))
        }
        if !options.ignore.autoIncrement, let next = ours?.autoIncrement, let other = theirs?.autoIncrement, next != other {
            parts.append(ReconPart(kind: .options, name: "auto_increment", change: .changed,
                                   definition: "AUTO_INCREMENT=\(next)", detail: "AUTO_INCREMENT \(other) → \(next)"))
        }
        return parts
    }

    /// Parts added (source only), changed (`differ`) and dropped (target only), matched by name without case.
    private func matched<Item>(_ left: [Item], _ right: [Item], name: (Item) -> String, kind: ReconPart.Kind,
                               differ: (Item, Item) -> Bool) -> [ReconPart] {
        var parts: [ReconPart] = []
        for item in left {
            if let other = right.first(where: { name($0).caseInsensitiveCompare(name(item)) == .orderedSame }) {
                if differ(item, other) { parts.append(ReconPart(kind: kind, name: name(item), change: .changed, detail: "changed")) }
            } else {
                parts.append(ReconPart(kind: kind, name: name(item), change: .added, detail: "added"))
            }
        }
        for item in right where !left.contains(where: { name($0).caseInsensitiveCompare(name(item)) == .orderedSame }) {
            parts.append(ReconPart(kind: kind, name: name(item), change: .dropped, detail: "only in the target"))
        }
        return parts
    }

    /// A view, routine, trigger, event or sequence compared by its definition (SHOW CREATE …, nil where it doesn't
    /// exist, "" where it exists but couldn't be read); `targetName` when a chosen pair's names differ.
    func definition(_ kind: ReconObject.Kind, name: String, targetName: String? = nil, source left: String?,
                    target right: String?) -> ReconObject? {
        let status: ReconObject.Status
        switch (left, right) {
        case (nil, nil): return nil
        case (_?, nil): status = .onlyInSource
        case (nil, _?): status = .onlyInTarget
        case let (left?, right?):
            // Both sides spell the name alike: renaming quotes it, and a trigger's own text often doesn't.
            let wanted = targetName ?? name
            status = !left.isEmpty && !right.isEmpty && (options.ignore.definitions
                || ReconNormal.definition(ReconNormal.renamed(left, kind, to: wanted), database: source.name, rules: options.ignore)
                    == ReconNormal.definition(ReconNormal.renamed(right, kind, to: wanted), database: target.name, rules: options.ignore))
                ? .same : .different
        }
        var object = ReconObject(kind: kind, name: name, targetName: targetName, status: status)
        object.sourceDDL = left
        object.targetDDL = right
        if left == "" || right == "" {
            object.parts = [ReconPart(kind: .options, name: name, change: .changed,
                                      detail: "its definition couldn't be read on the \(left == "" ? "source" : "target") (the account may not have the privilege)")]
        }
        return object
    }
}
