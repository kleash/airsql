import Foundation

/// A suggestion of completion (plan §2.6).
public struct CompletionItem: Equatable, Sendable {
    public enum Kind: String, Sendable { case join, column, table, view, alias, database, function, routine, keyword }

    public var kind: Kind
    /// What goes in place of the word being typed.
    public var text: String
    /// What the list shows.
    public var label: String
    /// Its type, or where it comes from: "int unsigned", "orders", "foreign key", "view".
    public var detail: String
}

/// Completion from the schema cache only (plan §2.6: nothing goes to the server while typing): after FROM or JOIN the
/// tables and views, after JOIN first the joins that foreign keys give, after "alias." the columns of that table
/// (aliases resolved from the statement), after USE the databases; elsewhere the columns of the statement's tables,
/// their names, functions and keywords.
public enum SQLCompletion {
    /// A table the statement names, with its alias.
    struct TableRef: Equatable {
        var database: String?
        var table: String
        var alias: String?
        var name: String { alias ?? table }
    }

    /// The range of the word being typed at `caret` and the suggestions for it, best first.
    public static func suggestions(text: String, caret: Int, snapshot: SchemaSnapshot?, database: String?,
                                   noBackslashEscapes: Bool = false) -> (range: Range<Int>, items: [CompletionItem]) {
        let utf16 = Array(text.utf16)
        let caret = min(max(0, caret), utf16.count)
        var start = caret
        while start > 0, isWordChar(utf16[start - 1]) { start -= 1 }
        if start > 0, utf16[start - 1] == 0x60 { start -= 1 }  // an opening backtick
        let prefix = String(decoding: utf16[start..<caret], as: UTF16.self).replacingOccurrences(of: "`", with: "").lowercased()
        // The statement around the caret, and what comes before the word.
        let statement = SQLSplitter.statement(at: start, in: text, noBackslashEscapes: noBackslashEscapes)
        let lower = min(statement?.range.lowerBound ?? 0, start)
        let upper = max(statement?.range.upperBound ?? caret, caret)
        let whole = String(decoding: utf16[lower..<upper], as: UTF16.self)
        let before = String(decoding: utf16[lower..<start], as: UTF16.self)
        let refs = tableRefs(StatementCheck.codeWords(whole, noBackslashEscapes: noBackslashEscapes))
        let words = StatementCheck.codeWords(before, noBackslashEscapes: noBackslashEscapes)
        let current = database.flatMap { snapshot?.database($0) }
        var items: [CompletionItem] = []

        if words.last?.raw == ".", words.count >= 2 {
            let qualifier = SQLQuote.unquoted(words[words.count - 2].raw)
            if let ref = refs.first(where: { $0.name.caseInsensitiveCompare(qualifier) == .orderedSame }),
               let table = table(ref, snapshot, database) {
                items = table.columns.map { CompletionItem(kind: .column, text: quote($0.name), label: $0.name, detail: $0.columnType) }
            } else if let named = snapshot?.database(qualifier) {
                items = tables(of: named)
            }
            return (start..<caret, rank(items, prefix))
        }
        let last = words.last?.text ?? ""
        switch last {
        case "USE":
            items = databases(snapshot)
        case "FROM", "JOIN", "INTO", "UPDATE", "TABLE", "DESCRIBE", "DESC", "TRUNCATE", "STRAIGHT_JOIN":
            if last == "JOIN" || last == "STRAIGHT_JOIN" { items = joins(refs, snapshot: snapshot, database: database) }
            items += (current.map(tables(of:)) ?? []) + databases(snapshot)
        default:
            for ref in refs {
                guard let table = table(ref, snapshot, database) else { continue }
                items += table.columns.map {
                    CompletionItem(kind: .column, text: quote($0.name), label: $0.name, detail: $0.columnType + " · " + ref.name)
                }
            }
            items += refs.map { CompletionItem(kind: .alias, text: quote($0.name), label: $0.name, detail: $0.alias == nil ? "table" : $0.table) }
            let server = snapshot?.server
            items += SQLFunction.all.filter { $0.available(on: server) }
                .map { CompletionItem(kind: .function, text: $0.name + "(", label: $0.name, detail: $0.call) }
            items += (current?.routines ?? []).filter { $0.kind == .function }
                .map { CompletionItem(kind: .routine, text: quote($0.name) + "(", label: $0.name, detail: "function") }
            items += keywords.map { CompletionItem(kind: .keyword, text: $0, label: $0, detail: "keyword") }
            if refs.isEmpty { items += (current.map(tables(of:)) ?? []) }
        }
        return (start..<caret, rank(items, prefix))
    }

    /// The tables the statement at `caret` names, each (by its alias when it has one) with its columns, as the schema
    /// cache has them: what the helpers panel lists.
    public static func columns(text: String, caret: Int, snapshot: SchemaSnapshot?, database: String?,
                               noBackslashEscapes: Bool = false) -> [(table: String, columns: [SchemaColumn])] {
        guard let statement = SQLSplitter.statement(at: caret, in: text, noBackslashEscapes: noBackslashEscapes) else { return [] }
        return tableRefs(StatementCheck.codeWords(statement.sql, noBackslashEscapes: noBackslashEscapes)).compactMap { ref in
            table(ref, snapshot, database).map { (ref.alias.map { "\(ref.table) \($0)" } ?? ref.table, $0.columns) }
        }
    }

    /// Those that start with what was typed, best kind first (the schema's in its order; functions and keywords
    /// together, shortest first: FROM before FROM_UNIXTIME); at most 200, no repeats.
    static func rank(_ items: [CompletionItem], _ prefix: String) -> [CompletionItem] {
        let order: [CompletionItem.Kind: Int] = [.join: 0, .column: 1, .alias: 2, .table: 3, .view: 4, .database: 5,
                                                 .function: 6, .routine: 6, .keyword: 6]
        var seen = Set<String>()
        return items.filter { prefix.isEmpty || $0.label.lowercased().hasPrefix(prefix) }
            .enumerated()
            .sorted { a, b in
                let ka = order[a.element.kind]!, kb = order[b.element.kind]!
                if ka != kb { return ka < kb }
                if ka == 6, a.element.label.count != b.element.label.count { return a.element.label.count < b.element.label.count }
                return a.offset < b.offset
            }
            .map(\.element)
            .filter { seen.insert($0.kind.rawValue + $0.text).inserted }
            .prefix(200).map { $0 }
    }

    /// The tables after FROM, JOIN, UPDATE and INTO, each with its alias: `[db.]name [AS] alias`, and those after
    /// commas in a FROM list.
    static func tableRefs(_ words: [StatementCheck.Word]) -> [TableRef] {
        var refs: [TableRef] = []
        var index = 0
        let starts: Set<String> = ["FROM", "JOIN", "UPDATE", "INTO", "STRAIGHT_JOIN"]
        let notAliases: Set<String> = ["WHERE", "ON", "USING", "JOIN", "LEFT", "RIGHT", "INNER", "CROSS", "NATURAL", "GROUP",
                                       "ORDER", "LIMIT", "SET", "VALUES", "HAVING", "UNION", "FOR", "LOCK", "WINDOW", "STRAIGHT_JOIN",
                                       "PARTITION", "USE", "FORCE", "IGNORE", "SELECT", "OUTER"]
        func isName(_ i: Int) -> Bool { i < words.count && (words[i].kind == .word || words[i].kind == .quotedName) }
        while index < words.count {
            guard starts.contains(words[index].text) else { index += 1; continue }
            var inList = words[index].text == "FROM"
            index += 1
            repeat {
                guard isName(index), !notAliases.contains(words[index].text) || words[index].kind == .quotedName else { break }
                var ref = TableRef(database: nil, table: SQLQuote.unquoted(words[index].raw), alias: nil)
                index += 1
                if index + 1 < words.count, words[index].raw == ".", isName(index + 1) {
                    ref.database = ref.table
                    ref.table = SQLQuote.unquoted(words[index + 1].raw)
                    index += 2
                }
                if index < words.count, words[index].text == "AS" { index += 1 }
                if isName(index), !notAliases.contains(words[index].text) || words[index].kind == .quotedName {
                    ref.alias = SQLQuote.unquoted(words[index].raw)
                    index += 1
                }
                refs.append(ref)
                if inList, index < words.count, words[index].raw == "," { index += 1 } else { inList = false }
            } while inList
        }
        return refs
    }

    /// The joins foreign keys give from the statement's tables: "products p ON p.id = r.product_id".
    static func joins(_ refs: [TableRef], snapshot: SchemaSnapshot?, database: String?) -> [CompletionItem] {
        guard let snapshot else { return [] }
        var items: [CompletionItem] = []
        let used = Set(refs.map { $0.name.lowercased() })
        func alias(_ table: String) -> String {
            var candidate = String(table.prefix(1)).lowercased(), n = 1
            while used.contains(candidate) { n += 1; candidate = String(table.prefix(1)).lowercased() + "\(n)" }
            return candidate
        }
        for ref in refs {
            let db = ref.database ?? database
            guard let db, let from = snapshot.table(db, ref.table) else { continue }
            // This table's keys point at others…
            for key in from.foreignKeys {
                let other = key.referencedTable, a = alias(other)
                let on = zip(key.columns, key.referencedColumns).map { "\(quote(a)).\(quote($1)) = \(quote(ref.name)).\(quote($0))" }
                items.append(CompletionItem(kind: .join, text: "\(quote(other)) \(a) ON " + on.joined(separator: " AND "),
                                            label: "\(other) \(a) ON " + on.joined(separator: " AND "), detail: "foreign key"))
            }
            // …and others' keys point at this one.
            for table in snapshot.database(db)?.tables ?? [] {
                for key in table.foreignKeys where key.referencedTable == ref.table && key.referencedDatabase == db {
                    let a = alias(table.name)
                    let on = zip(key.columns, key.referencedColumns).map { "\(quote(a)).\(quote($0)) = \(quote(ref.name)).\(quote($1))" }
                    items.append(CompletionItem(kind: .join, text: "\(quote(table.name)) \(a) ON " + on.joined(separator: " AND "),
                                                label: "\(table.name) \(a) ON " + on.joined(separator: " AND "), detail: "foreign key"))
                }
            }
        }
        return items
    }

    static func tables(of database: SchemaDatabase) -> [CompletionItem] {
        database.tables.map { table in
            let rows = database.statistics?[table.name]?.rows.map { " · \($0.formatted()) rows" } ?? ""
            return CompletionItem(kind: table.kind == .view ? .view : .table, text: quote(table.name), label: table.name,
                                  detail: (table.kind == .view ? "view" : "table") + rows)
        }
    }

    static func databases(_ snapshot: SchemaSnapshot?) -> [CompletionItem] {
        (snapshot?.databases ?? []).map { CompletionItem(kind: .database, text: quote($0.name), label: $0.name, detail: "database") }
    }

    static func table(_ ref: TableRef, _ snapshot: SchemaSnapshot?, _ database: String?) -> SchemaTable? {
        guard let db = ref.database ?? database else { return nil }
        return snapshot?.table(db, ref.table)
    }

    /// A name as it can be typed: bare when it is a plain word that isn't reserved, else in backticks.
    public static func quote(_ name: String) -> String {
        let plain = !name.isEmpty && name.utf16.allSatisfy(isWordChar) && !(name.first?.isNumber ?? true)
            && !SQLWords.reserved.contains(name.uppercased())
        return plain ? name : SQLQuote.identifier(name)
    }

    /// A character of a name without quotes: ASCII letters and digits, _ and $, and anything beyond ASCII.
    public static func isWordChar(_ c: UInt16) -> Bool {
        (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || c == 0x5F || c == 0x24 || c >= 0x80
    }

    /// Keywords offered: the reserved words and the common others.
    public static let keywords: [String] = (SQLWords.reserved.union(["OFFSET", "COMMIT", "ROLLBACK", "BEGIN", "TRANSACTION", "TEMPORARY",
                                                              "ENGINE", "AUTO_INCREMENT", "COMMENT", "TABLES", "COLUMNS",
                                                              "PROCESSLIST", "VARIABLES", "STATUS", "VIEW", "TRUNCATE",
                                                              "DUPLICATE", "IFNULL", "COALESCE", "ESCAPE"])).sorted()
}
