import Foundation

/// A suggestion of completion (plan §2.6).
public struct CompletionItem: Equatable, Sendable {
    public enum Kind: String, Sendable { case template, join, column, table, view, alias, database, function, routine, keyword, variable, word, value }

    public var kind: Kind
    /// What goes in place of the word being typed. A `.template`'s is a template's body (`SQLTemplate`).
    public var text: String
    /// What the list shows.
    public var label: String
    /// Its type, or where it comes from: "int unsigned", "orders", "foreign key", "view".
    public var detail: String
    /// What it replaces, when that's more than the word being typed: `*`, or `orders.` in `orders.from`.
    public var replacing: Range<Int>?

    public init(kind: Kind, text: String, label: String, detail: String, replacing: Range<Int>? = nil) {
        self.kind = kind
        self.text = text
        self.label = label
        self.detail = detail
        self.replacing = replacing
    }
}

/// What completion follows besides the text.
public struct CompletionOptions: Sendable {
    public var keywordCase = SQLWordCase.upper
    public var functionCase = SQLWordCase.upper
    /// A table completed after FROM or JOIN brings an alias: `orders o`.
    public var tableAlias = false
    /// Those with an abbreviation are offered by it.
    public var snippets = SQLSnippet.builtIn
    /// How often each label was chosen, in small letters: those come first among equals.
    public var recent: [String: Int] = [:]

    public init() {}
}

/// Completion from the schema cache only (plan §2.6: nothing goes to the server while typing), on `SQLAnalysis`: what's
/// offered is what fits the place in the statement, by name, abbreviation or the middle of a word (`SQLCompletionPlace`).
public enum SQLCompletion {
    /// The range of the word being typed at `caret` and the suggestions for it, best first.
    public static func suggestions(text: String, caret: Int, snapshot: SchemaSnapshot?, database: String?,
                                   noBackslashEscapes: Bool = false, options: CompletionOptions = CompletionOptions())
        -> (range: Range<Int>, items: [CompletionItem]) {
        let utf16 = Array(text.utf16)
        let caret = min(max(0, caret), utf16.count)
        var start = caret
        while start > 0, SQLLexer.isNameChar(utf16[start - 1]) { start -= 1 }
        if start > 0, utf16[start - 1] == 0x60 { start -= 1 }  // an opening backtick
        while start > 0, utf16[start - 1] == 0x40 { start -= 1 }  // @name, @@name
        let prefix = String(decoding: utf16[start..<caret], as: UTF16.self).replacingOccurrences(of: "`", with: "").lowercased()
        // The statement around the caret: it's all that's read, so a long script costs no more than a short one.
        let statement = SQLSplitter.statement(at: start, in: text, noBackslashEscapes: noBackslashEscapes)
        let lower = min(statement?.range.lowerBound ?? 0, start)
        let upper = max(statement?.range.upperBound ?? caret, caret)
        let place = SQLCompletionPlace(text: text, utf16: utf16, lower: lower, upper: upper, start: start, caret: caret, prefix: prefix,
                                       snapshot: snapshot, database: database, noBackslashEscapes: noBackslashEscapes, options: options)
        let found = place.items()
        return (found.range ?? start..<caret, rank(found.items, found.prefix ?? prefix, recent: options.recent))
    }

    /// The sources of the statement at `caret`, each (by its alias when it has one) with its columns, as the schema cache
    /// has them or a CTE or derived table gives them: what the helpers panel lists.
    public static func columns(text: String, caret: Int, snapshot: SchemaSnapshot?, database: String?,
                               noBackslashEscapes: Bool = false) -> [(table: String, columns: [SQLColumnInfo])] {
        guard let statement = SQLSplitter.statement(at: caret, in: text, noBackslashEscapes: noBackslashEscapes) else { return [] }
        let analysis = SQLAnalysis(statement.sql, snapshot: snapshot, database: database, noBackslashEscapes: noBackslashEscapes)
        guard let scope = analysis.scope(at: caret - statement.range.lowerBound) else { return [] }
        return scope.visibleSources.filter { !$0.columns.isEmpty }.map { source in
            (source.objectName.map { $0 == source.name ? $0 : "\($0) \(source.name)" } ?? source.name, source.columns)
        }
    }

    /// How `query` (small letters) matches a name, best first: 0 its start, 1 the start of one of its words, 2 an
    /// abbreviation of its words (`fica`: film_category, `ob`: ORDER BY), 3 the middle of a word; nil if it doesn't.
    static func match(_ name: String, _ query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let lower = name.lowercased()
        if lower.hasPrefix(query) { return 0 }
        let parts = words(of: name)
        if parts.contains(where: { $0.hasPrefix(query) }) { return 1 }
        if abbreviates(Array(query.utf8.filter { $0 != 0x5F }), parts.map { Array($0.utf8) }) { return 2 }
        return lower.contains(query) ? 3 : nil
    }

    /// `film_category`, `ORDER BY` and `filmCategory` in small letters, word by word.
    private static func words(of name: String) -> [String] {
        var parts: [String] = [], current = "", previousLower = false
        for character in name {
            if character == "_" || character == " " || character == "$" {
                if !current.isEmpty { parts.append(current) }
                current = ""
                previousLower = false
                continue
            }
            if character.isUppercase, previousLower {
                parts.append(current)
                current = ""
            }
            current += character.lowercased()
            previousLower = character.isLowercase
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// `query` is, in order, the start of some of `parts`, at least one letter of each it takes from.
    private static func abbreviates(_ query: [UInt8], _ parts: [[UInt8]]) -> Bool {
        func from(_ q: Int, _ part: Int) -> Bool {
            if q == query.count { return true }
            guard part < parts.count else { return false }
            var common = 0
            while common < parts[part].count, q + common < query.count, parts[part][common] == query[q + common] { common += 1 }
            return (0...common).reversed().contains { from(q + $0, part + 1) }
        }
        return from(0, 0)
    }

    /// Those that match what was typed, the closest match first, then what was chosen before, then the best kind (the
    /// schema's in its order; functions and keywords together, shortest first: FROM before FROM_UNIXTIME); at most 200, no
    /// repeats. A template leads only with nothing typed or its abbreviation typed whole.
    static func rank(_ items: [CompletionItem], _ prefix: String, recent: [String: Int] = [:]) -> [CompletionItem] {
        let order: [CompletionItem.Kind: Int] = [.value: 0, .join: 1, .column: 2, .alias: 3, .table: 4, .view: 5, .database: 6, .variable: 7,
                                                 .function: 8, .routine: 8, .keyword: 8, .template: 9, .word: 10]
        func kindOrder(_ item: CompletionItem) -> Int {
            item.kind == .template && (prefix.isEmpty || item.label.lowercased() == prefix) ? -1 : order[item.kind]!
        }
        var seen = Set<String>()
        return items.compactMap { item in match(item.label, prefix).map { (item: item, match: $0, kind: kindOrder(item)) } }
            .enumerated()
            .sorted { a, b in
                let (x, y) = (a.element, b.element)
                if x.match != y.match { return x.match < y.match }
                let (rx, ry) = (recent[x.item.label.lowercased()] ?? 0, recent[y.item.label.lowercased()] ?? 0)
                if rx != ry { return rx > ry }
                if x.kind != y.kind { return x.kind < y.kind }
                if x.kind == 8, x.item.label.count != y.item.label.count { return x.item.label.count < y.item.label.count }
                return a.offset < b.offset
            }
            .map(\.element.item)
            .filter { seen.insert($0.kind.rawValue + $0.text).inserted }
            .prefix(200).map { $0 }
    }

    /// A way to join a table to `sources`: `target` as it's written, `on` the condition.
    struct Link {
        var table: String, target: String, alias: String, on: String, detail: String
    }

    /// An alias for a table not yet used: the first letters of its words, as `film_category fc`.
    static func alias(_ table: String, used: Set<String>) -> String {
        let letters = table.split { $0 == "_" || $0 == " " }.compactMap(\.first).map { String($0).lowercased() }.joined()
        let plain = letters.utf16.allSatisfy(SQLLexer.isNameChar) && !letters.isEmpty && letters.first?.isNumber == false
        let base = plain ? letters : "t"
        var candidate = base, n = 1
        while used.contains(candidate) || quote(candidate) != candidate { n += 1; candidate = base + "\(n)" }
        return candidate
    }

    /// `word_id`'s table: `word`, in the singular or plural.
    private static func owners(_ word: String, _ table: SchemaTable) -> Bool {
        let name = table.name.lowercased()
        return [word, word + "s", word + "es", word.hasSuffix("y") ? word.dropLast() + "ies" : word].contains(name)
    }

    /// The joins foreign keys give from `sources`, real or defined by the person (`SchemaSnapshot.adding`), then those
    /// names suggest: `customer_id` to `customers.id`, and two tables' same `…_id`. `alias` names the other table.
    static func links(from sources: [SQLRowSource], snapshot: SchemaSnapshot?, database: String?, alias named: ((String) -> String)? = nil) -> [Link] {
        guard let snapshot else { return [] }
        var links: [Link] = []
        let used = Set(sources.map { $0.name.lowercased() })
        func name(_ table: String) -> String { named?(table) ?? alias(table, used: used) }
        func condition(_ left: [String], _ a: String, _ right: [String], _ b: String) -> String {
            zip(left, right).map { "\(quote(a)).\(quote($0)) = \(quote(b)).\(quote($1))" }.joined(separator: " AND ")
        }
        for source in sources {
            guard let from = source.table, let db = source.database ?? database else { continue }
            // This table's keys point at others…
            for key in from.foreignKeys {
                let other = key.referencedTable, a = name(other)
                // In another database, its name goes with it: the plain name would be looked for in this one.
                let target = key.referencedDatabase == db ? quote(other) : "\(quote(key.referencedDatabase)).\(quote(other))"
                links.append(Link(table: other, target: target, alias: a, on: condition(key.referencedColumns, a, key.columns, source.name), detail: "foreign key"))
            }
            let tables = snapshot.database(db)?.tables ?? []
            // …and others' keys point at this one.
            for table in tables {
                for key in table.foreignKeys where key.referencedTable == from.name && key.referencedDatabase == db {
                    let a = name(table.name)
                    links.append(Link(table: table.name, target: quote(table.name), alias: a,
                                      on: condition(key.columns, a, key.referencedColumns, source.name), detail: "foreign key"))
                }
            }
            func hasID(_ table: SchemaTable) -> Bool { table.columns.contains { $0.name.lowercased() == "id" } }
            for table in tables where table.name != from.name && table.kind != .view {
                let a = name(table.name)
                func link(_ left: String, _ right: String) {
                    let on = condition([left], a, [right], source.name)
                    guard !links.contains(where: { $0.table == table.name && $0.on == on }) else { return }
                    links.append(Link(table: table.name, target: quote(table.name), alias: a, on: on, detail: "same names"))
                }
                for column in from.columns where column.name.lowercased().hasSuffix("_id") {
                    let word = String(column.name.lowercased().dropLast(3))
                    if owners(word, table), hasID(table) { link("id", column.name) }
                    if table.columns.contains(where: { $0.name == column.name }) { link(column.name, column.name) }
                }
                for column in table.columns where column.name.lowercased().hasSuffix("_id") {
                    if owners(String(column.name.lowercased().dropLast(3)), from), hasID(from) { link(column.name, "id") }
                }
            }
        }
        return links
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

    /// Reserved since MySQL 8, where a bare `rank` is error 1064; keywords, not names, for the highlighter elsewhere.
    static let mysql8Reserved: Set<String> = [
        "CUBE", "CUME_DIST", "DENSE_RANK", "EMPTY", "EXCEPT", "FIRST_VALUE", "FUNCTION", "GROUPING", "GROUPS", "JSON_TABLE", "LAG",
        "LAST_VALUE", "LATERAL", "LEAD", "MANUAL", "NTH_VALUE", "NTILE", "OF", "OVER", "PARALLEL", "PERCENT_RANK", "QUALIFY", "RANK",
        "RECURSIVE", "ROW", "ROWS", "ROW_NUMBER", "SYSTEM", "TABLESAMPLE", "WINDOW",
    ]

    /// A name as it can be typed: bare when it is a plain word that isn't reserved, else in backticks.
    public static func quote(_ name: String) -> String {
        let plain = !name.isEmpty && name.utf16.allSatisfy(SQLLexer.isNameChar) && !(name.first?.isNumber ?? true)
            && !SQLWords.reserved.contains(name.uppercased()) && !mysql8Reserved.contains(name.uppercased())
        return plain ? name : SQLQuote.identifier(name)
    }

    /// Keywords offered: the reserved words and the common others.
    public static let keywords: [String] = (SQLWords.reserved.union(["OFFSET", "COMMIT", "ROLLBACK", "BEGIN", "TRANSACTION", "TEMPORARY",
                                                              "ENGINE", "AUTO_INCREMENT", "COMMENT", "TABLES", "COLUMNS",
                                                              "PROCESSLIST", "VARIABLES", "STATUS", "VIEW", "TRUNCATE",
                                                              "DUPLICATE", "IFNULL", "COALESCE", "ESCAPE"])).sorted()
}
