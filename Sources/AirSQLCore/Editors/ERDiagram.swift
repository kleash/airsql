import Foundation

/// The ER diagram of a database (scope: "ER diagram of a database"; R15: tables layered by foreign key, no edge
/// routing). Tables that point at nothing sit in the first column, every other table one column right of the furthest
/// table it points at, so keys run left to right; within a column, tables sit near the tables they point at. Tables
/// with no keys either way come last, in columns of their own. Also its Mermaid text.
public struct ERDiagram: Equatable {
    /// A foreign key between two tables of the database (keys to other databases are left out).
    public struct Link: Equatable {
        public let child: String
        public let parent: String
        public let name: String
        /// The key's columns may be NULL: the child may point at no row.
        public let optional: Bool
        /// The key's columns are unique in the child: one child row at most per parent row.
        public let unique: Bool
    }

    /// The tables, column by column, top to bottom.
    public let columns: [[SchemaTable]]
    public let links: [Link]

    /// Tables with no keys either way go in columns of at most this many.
    public static let looseColumnHeight = 8

    /// `only`: the tables to draw (nil: every table of the database).
    public init(_ database: SchemaDatabase, only: Set<String>? = nil) {
        let tables = database.tables.filter { $0.kind == .table && only?.contains($0.name) != false }
        let byName = Dictionary(tables.map { ($0.name, $0) }) { first, _ in first }
        var links: [Link] = []
        for table in tables {
            for key in table.foreignKeys where key.referencedDatabase == database.name && byName[key.referencedTable] != nil {
                let columns = key.columns.compactMap { table.column($0) }
                let unique = table.indexes.contains { index in
                    index.unique && Set(index.parts.compactMap(\.column)) == Set(key.columns)
                }
                links.append(Link(child: table.name, parent: key.referencedTable, name: key.name,
                                  optional: columns.contains { $0.nullable }, unique: unique))
            }
        }
        self.links = links

        // Each table's column: 0 when it points at nothing, else one right of the furthest table it points at (a key
        // back into a table still being placed, in a cycle, doesn't count).
        let parents = Dictionary(grouping: links.filter { $0.child != $0.parent }, by: \.child).mapValues { $0.map(\.parent) }
        var layer: [String: Int] = [:], placing = Set<String>()
        func place(_ name: String) -> Int {
            if let known = layer[name] { return known }
            placing.insert(name)
            let deepest = (parents[name] ?? []).filter { !placing.contains($0) }.map(place).max()
            placing.remove(name)
            let result = deepest.map { $0 + 1 } ?? 0
            layer[name] = result
            return result
        }
        let linked = Set(links.flatMap { [$0.child, $0.parent] })
        var columns: [[SchemaTable]] = []
        for table in tables where linked.contains(table.name) {
            let index = place(table.name)
            while columns.count <= index { columns.append([]) }
            columns[index].append(table)
        }
        // Within a column, by the mean row of the tables each points at (the first column by name, as listed).
        for index in columns.indices.dropFirst() {
            let rows = Dictionary(columns[..<index].flatMap { $0.enumerated().map { ($1.name, Double($0)) } }) { first, _ in first }
            func weight(_ table: SchemaTable) -> Double {
                let seen = (parents[table.name] ?? []).compactMap { rows[$0] }
                return seen.isEmpty ? .infinity : seen.reduce(0, +) / Double(seen.count)
            }
            columns[index] = columns[index].enumerated().sorted { (weight($0.element), $0.offset) < (weight($1.element), $1.offset) }
                .map(\.element)
        }
        let loose = tables.filter { !linked.contains($0.name) }
        for start in stride(from: 0, to: loose.count, by: Self.looseColumnHeight) {
            columns.append(Array(loose[start..<min(start + Self.looseColumnHeight, loose.count)]))
        }
        self.columns = columns
    }

    /// `names` and the tables that point at them or that they point at, in `database`.
    public static func neighbours(of names: Set<String>, in database: SchemaDatabase) -> Set<String> {
        var found = names
        for table in database.tables where table.kind == .table {
            let parents = table.foreignKeys.filter { $0.referencedDatabase == database.name }.map(\.referencedTable)
            if names.contains(table.name) { found.formUnion(parents) }
            if !names.isDisjoint(with: parents) { found.insert(table.name) }
        }
        return found.intersection(database.tables.filter { $0.kind == .table }.map(\.name))
    }

    /// A table's name from text dragged out of the tree, where it is quoted.
    public static func tableName(dragged text: String) -> String {
        var scanner = HeaderScanner(text)
        return scanner.name() ?? text
    }

    /// The diagram as Mermaid's erDiagram: each table with its columns (base type, name, PK, FK and UK marks), then a
    /// line per foreign key with its cardinality. Names Mermaid can't take as they are get an alias in quotes.
    public func mermaid() -> String {
        var lines = ["erDiagram"]
        let tables = columns.flatMap { $0 }
        for table in tables {
            let keyed = Set(table.foreignKeys.flatMap(\.columns))
            let unique = Set(table.indexes.filter { $0.unique && !$0.isPrimary && $0.parts.count == 1 }.compactMap { $0.parts[0].column })
            let primary = Set(table.primaryKey?.parts.compactMap(\.column) ?? [])
            lines.append("    " + Self.entity(table.name) + " {")
            for column in table.columns {
                let marks = [primary.contains(column.name) ? "PK" : nil, keyed.contains(column.name) ? "FK" : nil,
                             unique.contains(column.name) ? "UK" : nil].compactMap { $0 }
                lines.append("        " + Self.word(column.dataType.lowercased()) + " " + Self.word(column.name)
                             + (marks.isEmpty ? "" : " " + marks.joined(separator: ", ")))
            }
            lines.append("    }")
        }
        for link in links {
            let parentSide = link.optional ? "|o" : "||"
            let childSide = link.unique ? "o|" : "o{"
            lines.append("    " + Self.word(link.parent) + " " + parentSide + "--" + childSide + " " + Self.word(link.child)
                         + " : \"" + link.name.replacingOccurrences(of: "\"", with: "'") + "\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A name as a Mermaid word: letters, digits and underscores, others replaced.
    static func word(_ name: String) -> String {
        let word = String(name.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_") ? Character(scalar) : "_"
        })
        return word.first?.isNumber ?? true ? "_" + word : word
    }

    /// A table's entity: its word, and the real name as an alias when they differ.
    static func entity(_ name: String) -> String {
        let word = word(name)
        return word == name ? word : word + "[\"" + name.replacingOccurrences(of: "\"", with: "'") + "\"]"
    }
}
