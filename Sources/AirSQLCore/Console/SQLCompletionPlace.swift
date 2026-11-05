import Foundation

/// The place in a statement completion was asked for, and what fits there. Offsets are of the whole text, but for `local`
/// ones, which are of the statement `analysis` read.
struct SQLCompletionPlace {
    typealias Found = (items: [CompletionItem], range: Range<Int>?, prefix: String?)

    let text: String
    let utf16: [UInt16]
    /// The statement's bounds.
    let lower: Int, upper: Int
    /// The word being typed.
    let start: Int, caret: Int
    let prefix: String
    let snapshot: SchemaSnapshot?
    let database: String?
    let noBackslashEscapes: Bool
    let options: CompletionOptions
    let words: [StatementCheck.Word]
    let analysis: SQLAnalysis
    let scope: SQLScope?
    let clause: SQLClause?
    let current: SchemaDatabase?

    init(text: String, utf16: [UInt16], lower: Int, upper: Int, start: Int, caret: Int, prefix: String, snapshot: SchemaSnapshot?,
         database: String?, noBackslashEscapes: Bool, options: CompletionOptions) {
        self.text = text
        self.utf16 = utf16
        self.lower = lower
        self.upper = upper
        self.start = start
        self.caret = caret
        self.prefix = prefix
        self.snapshot = snapshot
        self.database = database
        self.noBackslashEscapes = noBackslashEscapes
        self.options = options
        words = StatementCheck.codeWords(String(decoding: utf16[lower..<start], as: UTF16.self), noBackslashEscapes: noBackslashEscapes)
        analysis = SQLAnalysis(String(decoding: utf16[lower..<upper], as: UTF16.self), snapshot: snapshot, database: database,
                               noBackslashEscapes: noBackslashEscapes)
        scope = analysis.scope(at: start - lower)
        clause = scope?.clause(at: start - lower)
        current = database.flatMap { snapshot?.database($0) }
    }

    private var last: String { words.last?.text ?? "" }
    private var kind: SQLParsedStatement.Kind? { analysis.statement(at: start - lower)?.kind }
    private var sources: [SQLRowSource] { scope?.visibleSources ?? [] }

    func items() -> Found {
        if let inString = stringValues() { return inString }
        if prefix.hasPrefix("@") { return (variables(), nil, nil) }
        if last == "*", let star = starExpansion() { return ([star], nil, nil) }
        if last == ".", words.count >= 2 { return (afterDot(), nil, nil) }
        if SQLCompletionWords.onlyKeywords(after: last, first: words.count == 1) {
            return (keywordItems(SQLCompletionWords.after(last)), nil, nil)
        }
        switch last {
        case "USE":
            return (SQLCompletion.databases(snapshot), nil, nil)
        case "CALL":
            return ((current?.routines ?? []).filter { $0.kind == .procedure }
                .map { CompletionItem(kind: .routine, text: SQLCompletion.quote($0.name) + "(", label: $0.name, detail: "procedure") }, nil, nil)
        case "ENGINE", "CHARSET", "COLLATE":
            return (settingValues(last), nil, nil)
        case "SET" where kind == .set:
            return (variableNames() + keywordItems(SQLCompletionWords.setStart), nil, nil)
        case "FROM", "JOIN", "INTO", "UPDATE", "TABLE", "DESCRIBE", "DESC", "TRUNCATE", "STRAIGHT_JOIN":
            return (tableList(), nil, nil)
        default:
            break
        }
        if words.count >= 2, last == "=", ["ENGINE", "CHARSET", "COLLATE"].contains(words[words.count - 2].text) {
            return (settingValues(words[words.count - 2].text), nil, nil)
        }
        if words.count >= 2, last == "SET", ["CHARACTER", "CHAR"].contains(words[words.count - 2].text) {
            return (settingValues("CHARSET"), nil, nil)
        }
        if last == ",", clause == .from { return (tableList(), nil, nil) }
        if clause == .insertColumns { return (insertColumns(), nil, nil) }
        // Just after a table's name.
        if clause == .from || ((kind == .insert || kind == .replace || kind == .update) && [nil, .into, .other].contains(clause)) {
            return (keywordItems(SQLCompletionWords.after(last, clause: clause, kind: kind)), nil, nil)
        }
        if clause == .set, last == "SET" || last == "," { return (columnItems(qualified: false), nil, nil) }
        return (expressionItems(), nil, nil)
    }

    // MARK: Names

    /// Where a name that ends just before `end` begins, dots included.
    private func nameStart(before end: Int) -> Int {
        var at = end
        while at > lower {
            let unit = utf16[at - 1]
            if unit == 0x60 {
                at -= 1
                while at > lower, utf16[at - 1] != 0x60 { at -= 1 }
                at = max(lower, at - 1)
            } else if SQLLexer.isNameChar(unit) || unit == 0x2E {
                at -= 1
            } else {
                break
            }
        }
        return at
    }

    private func source(_ name: String) -> SQLRowSource? {
        sources.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func afterDot() -> [CompletionItem] {
        let qualifier = SQLQuote.unquoted(words[words.count - 2].raw)
        // db.table.
        if words.count >= 4, words[words.count - 3].raw == ".", let db = Optional(SQLQuote.unquoted(words[words.count - 4].raw)),
           let table = snapshot?.table(db, qualifier) {
            return table.columns.map { CompletionItem(kind: .column, text: SQLCompletion.quote($0.name), label: $0.name, detail: $0.columnType) }
        }
        if let source = source(qualifier) {
            var items = source.columns.map {
                CompletionItem(kind: .column, text: SQLCompletion.quote($0.name), label: $0.name, detail: $0.type ?? "")
            }
            if clause == .selectList, source.columns.count > 1 {
                items.append(CompletionItem(kind: .column, text: star([source], qualified: true), label: "all columns", detail: source.name,
                                            replacing: nameStart(before: start)..<caret))
            }
            return items + (prefix.isEmpty ? [] : postfixCast())
        }
        if let named = snapshot?.database(qualifier) { return SQLCompletion.tables(of: named) }
        return postfix(table: qualifier) + postfixCast()
    }

    /// `orders.from`, `orders.cfrom`, `orders.afrom`, `orders.join`: a table's name turned into a query, where one can start.
    private func postfix(table name: String) -> [CompletionItem] {
        let before = nameStart(before: start)
        guard let table = database.flatMap({ snapshot?.table($0, name) }), let database else { return [] }
        let leading = StatementCheck.codeWords(String(decoding: utf16[lower..<before], as: UTF16.self), noBackslashEscapes: noBackslashEscapes)
        guard leading.isEmpty || leading.last?.raw == "(" else { return [] }
        let quoted = SQLCompletion.quote(table.name), alias = SQLCompletion.alias(table.name, used: [])
        let columns = table.columns.filter { !$0.invisible }.map { SQLCompletion.quote($0.name) }
        func item(_ label: String, _ body: String, _ detail: String) -> CompletionItem {
            CompletionItem(kind: .template, text: SQLTemplate.escape(keyword("SELECT") + " " + body) + "$END$", label: label, detail: detail,
                           replacing: before..<caret)
        }
        var items = [item("from", "* \(keyword("FROM")) \(quoted)", "all of \(table.name)"),
                     item("cfrom", columns.joined(separator: ", ") + " \(keyword("FROM")) \(quoted)", "every column of \(table.name)"),
                     item("afrom", columns.map { "\(alias).\($0)" }.joined(separator: ", ") + " \(keyword("FROM")) \(quoted) \(alias)",
                          "every column of \(table.name), by alias")]
        let source = SQLRowSource(kind: .table, name: alias, objectName: table.name, database: database, range: 0..<0, table: table)
        if let join = SQLCompletion.links(from: [source], snapshot: snapshot, database: database).first {
            items.append(item("join", "* \(keyword("FROM")) \(quoted) \(alias) \(keyword("JOIN")) \(join.target) \(join.alias) \(keyword("ON")) \(join.on)",
                              "\(table.name) with \(join.table)"))
        }
        return items
    }

    /// `total.cast`, `o.total.cast`: CAST around a name.
    private func postfixCast() -> [CompletionItem] {
        guard start > lower, utf16[start - 1] == 0x2E else { return [] }  // `t. x`: the word isn't against the dot
        let before = nameStart(before: start), name = String(decoding: utf16[before..<(start - 1)], as: UTF16.self)
        return [CompletionItem(kind: .template, text: "\(options.functionCase.apply("CAST"))(\(SQLTemplate.escape(name)) \(keyword("AS")) $type$)$END$",
                               label: "cast", detail: "CAST(\(name) AS type)", replacing: before..<caret)]
    }

    // MARK: Tables and joins

    private func tableItems() -> [CompletionItem] {
        let ctes = (scope?.visibleCTEs ?? []).map { CompletionItem(kind: .table, text: SQLCompletion.quote($0.name), label: $0.name, detail: "CTE") }
        return ctes + (current.map(SQLCompletion.tables(of:)) ?? [])
    }

    /// What can follow FROM and its like: at a JOIN first what the tables before it give.
    private func tableList() -> [CompletionItem] {
        var tables = tableItems()
        if aliasFits {
            let used = Set(sources.map { $0.name.lowercased() })
            tables = tables.map { item in
                guard item.kind == .table || item.kind == .view, item.detail != "CTE" else { return item }
                var aliased = item
                aliased.text += " " + SQLCompletion.alias(item.label, used: used)
                return aliased
            }
        }
        guard last == "JOIN" || last == "STRAIGHT_JOIN" else { return tables + SQLCompletion.databases(snapshot) }
        let joins = SQLCompletion.links(from: sources, snapshot: snapshot, database: database).map {
            CompletionItem(kind: .join, text: "\($0.target) \($0.alias) \(keyword("ON")) \($0.on)", label: "\($0.table) \($0.alias) ON \($0.on)", detail: $0.detail)
        }
        return joins + tables + SQLCompletion.databases(snapshot)
    }

    /// An alias is wanted: in a query or UPDATE, unless the table has one already.
    private var aliasFits: Bool {
        guard options.tableAlias, ["FROM", "JOIN", "STRAIGHT_JOIN", "UPDATE", ","].contains(last),
              kind == .select || kind == .update else { return false }
        let next = StatementCheck.codeWords(String(decoding: utf16[caret..<max(caret, upper)], as: UTF16.self), noBackslashEscapes: noBackslashEscapes).first
        guard let next else { return true }
        return next.kind != .quotedName && (next.kind != .word || SQLWords.reserved.contains(next.text)) && next.raw != "."
    }

    /// After ON, the conditions that tie the last table to those before it.
    private func onConditions() -> [CompletionItem] {
        guard last == "ON", let tables = scope?.sources, tables.count >= 2, let right = tables.last, let name = right.objectName else { return [] }
        return SQLCompletion.links(from: Array(tables.dropLast()), snapshot: snapshot, database: database, alias: { _ in right.name })
            .filter { $0.table.caseInsensitiveCompare(name) == .orderedSame }
            .map { CompletionItem(kind: .join, text: $0.on, label: $0.on, detail: $0.detail) }
    }

    // MARK: Columns

    /// The columns in sight, by their table's name where two tables have the same one.
    private func columnItems(qualified: Bool = true) -> [CompletionItem] {
        var counts: [String: Int] = [:]
        for source in sources { for column in source.columns { counts[column.name.lowercased(), default: 0] += 1 } }
        return sources.flatMap { source in
            source.columns.map { column in
                let ambiguous = qualified && counts[column.name.lowercased()]! > 1 && !source.name.isEmpty
                let name = SQLCompletion.quote(column.name)
                return CompletionItem(kind: .column, text: ambiguous ? "\(SQLCompletion.quote(source.name)).\(name)" : name, label: column.name,
                                      detail: (column.type.map { $0 + " · " } ?? "") + source.name)
            }
        }
    }

    /// `sources`' columns as `*` would give them.
    private func star(_ sources: [SQLRowSource], qualified: Bool) -> String {
        sources.flatMap { source in
            source.columns.filter { $0.schema?.invisible != true }.map {
                (qualified ? SQLCompletion.quote(source.name) + "." : "") + SQLCompletion.quote($0.name)
            }
        }.joined(separator: ", ")
    }

    /// Just after a `*` or `t.*` of the select list: what it stands for, in its place.
    private func starExpansion() -> CompletionItem? {
        guard prefix.isEmpty, clause == .selectList, let scope else { return nil }
        let star = words[words.count - 1].range.lowerBound + lower
        if words.count >= 3, words[words.count - 2].raw == "." {
            guard let source = source(SQLQuote.unquoted(words[words.count - 3].raw)), !source.columns.isEmpty else { return nil }
            return CompletionItem(kind: .column, text: self.star([source], qualified: true), label: "all columns", detail: source.name,
                                  replacing: nameStart(before: star)..<caret)
        }
        guard words.count >= 2, ["SELECT", "DISTINCT", ","].contains(words[words.count - 2].text) else { return nil }
        let tables = scope.sources.filter { !$0.columns.isEmpty }
        guard !tables.isEmpty, tables.count == scope.sources.count else { return nil }
        return CompletionItem(kind: .column, text: self.star(tables, qualified: tables.count > 1), label: "all columns",
                              detail: tables.map(\.name).joined(separator: ", "), replacing: star..<caret)
    }

    /// `INSERT INTO t (`: the columns not listed yet, and first all of them at once.
    private func insertColumns() -> [CompletionItem] {
        let write = analysis.statement(at: start - lower)?.write
        let listed = Set((write?.columns ?? []).filter { $0.range.lowerBound + lower != start }.map { $0.value.lowercased() })
        guard let table = sources.first else { return [] }
        let open = table.columns.filter { !listed.contains($0.name.lowercased()) && $0.schema?.generated == nil && $0.schema?.autoIncrement != true }
        var items = table.columns.filter { !listed.contains($0.name.lowercased()) }
            .map { CompletionItem(kind: .column, text: SQLCompletion.quote($0.name), label: $0.name, detail: $0.type ?? "") }
        if open.count > 1 {
            items.insert(CompletionItem(kind: .column, text: open.map { SQLCompletion.quote($0.name) }.joined(separator: ", "), label: "all columns",
                                        detail: table.name), at: 0)
        }
        return items
    }

    /// `VALUES (`: a field for each column of the list, or of the table.
    private func valuesSkeleton() -> [CompletionItem] {
        guard clause == .values, last == "(", let write = analysis.statement(at: start - lower)?.write,
              words.count >= 2, words[words.count - 2].text == "VALUES" || words[words.count - 2].raw == "," else { return [] }
        let columns = !write.columns.isEmpty ? write.columns.map(\.value)
            : (sources.first?.columns ?? []).filter { $0.schema?.generated == nil }.map(\.name)
        guard columns.count > 1 else { return [] }
        let fields = columns.enumerated().map { "$\(SQLCompletionPlace.fieldName($1, $0))$" }.joined(separator: ", ")
        return [CompletionItem(kind: .template, text: fields + "$END$", label: "values for all columns", detail: columns.joined(separator: ", "))]
    }

    /// A template's field can only be a plain name.
    private static func fieldName(_ column: String, _ index: Int) -> String {
        let name = String(column.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" })
        return name.isEmpty || name.first!.isNumber || name == "END" || name == "SELECTION" ? "value\(index + 1)" : name
    }

    // MARK: Values

    /// The members of the ENUM or SET column compared just before `words`' end: `status = `, `status IN ('a', `.
    private func enumMembers(_ words: [StatementCheck.Word]) -> [String] {
        var index = words.count - 1
        guard index >= 1 else { return [] }
        if ["=", "!=", "<>"].contains(words[index].raw) {
            index -= 1
        } else {
            var depth = 0
            while index >= 0 {
                if words[index].raw == ")" { depth += 1 }
                if words[index].raw == "(" {
                    if depth == 0 { break }
                    depth -= 1
                }
                index -= 1
            }
            guard index >= 2, words[index - 1].text == "IN" else { return [] }
            index -= words[index - 2].text == "NOT" ? 3 : 2
        }
        guard index >= 0, words[index].kind == .word || words[index].kind == .quotedName else { return [] }
        let name = SQLQuote.unquoted(words[index].raw)
        let owner = index >= 2 && words[index - 1].raw == "." ? source(SQLQuote.unquoted(words[index - 2].raw)).map { [$0] } : sources
        guard let column = owner?.lazy.compactMap({ $0.has(name) }).first?.schema, ["enum", "set"].contains(column.dataType) else { return [] }
        return ColumnType.members(column.columnType)
    }

    /// Inside a string, what's offered is what it may be compared with; `nil` outside one, and inside a comment nothing.
    private func stringValues() -> Found? {
        var lexer = SQLLexer(String(decoding: utf16[lower..<upper], as: UTF16.self), noBackslashEscapes: noBackslashEscapes)
        let at = caret - lower
        while let token = lexer.next(), token.range.lowerBound < at {
            // A -- or # comment goes on to the line's end, so the caret just after it is still in it.
            let lineComment = token.kind == .comment && utf16[lower + token.range.lowerBound] != 0x2F
            guard token.range.upperBound > at || lineComment || (!token.isClosed && token.range.upperBound == at) else { continue }
            if token.kind == .comment || token.kind == .hint { return ([], nil, nil) }
            guard token.kind == .string else { return nil }
            let before = StatementCheck.codeWords(String(decoding: utf16[lower..<(lower + token.range.lowerBound)], as: UTF16.self), noBackslashEscapes: noBackslashEscapes)
            let typed = String(decoding: utf16[(lower + token.range.lowerBound + 1)..<caret], as: UTF16.self).lowercased()
            let range = (lower + token.range.lowerBound)..<(lower + token.range.upperBound)
            return (enumMembers(before).map(value), range, typed)
        }
        return nil
    }

    private func value(_ member: String) -> CompletionItem {
        CompletionItem(kind: .value, text: SQLQuote.string(member, noBackslashEscapes: noBackslashEscapes), label: member, detail: "value")
    }

    private func settingValues(_ word: String) -> [CompletionItem] {
        let values = word == "ENGINE" ? SQLCompletionWords.engines : word == "CHARSET" ? SQLCompletionWords.charsets : SQLCompletionWords.collations
        return values.map { CompletionItem(kind: .value, text: $0, label: $0, detail: word.lowercased()) }
    }

    private func variables() -> [CompletionItem] {
        if prefix.hasPrefix("@@") { return variableNames().map { var item = $0; item.text = "@@" + item.text; item.label = item.text; return item } }
        var seen = Set<String>()
        var lexer = SQLLexer(text, noBackslashEscapes: noBackslashEscapes)
        var items: [CompletionItem] = []
        while let token = lexer.next() {
            guard token.kind == .variable, token.range.lowerBound != start else { continue }
            let name = lexer.string(token.range)
            if !name.hasPrefix("@@"), seen.insert(name.lowercased()).inserted {
                items.append(CompletionItem(kind: .variable, text: name, label: name, detail: "in this text"))
            }
        }
        return items
    }

    private func variableNames() -> [CompletionItem] {
        SQLCompletionWords.systemVariables.map { CompletionItem(kind: .variable, text: $0, label: $0, detail: "server variable") }
    }

    // MARK: Everything else

    private func keyword(_ word: String) -> String { options.keywordCase.apply(word) }

    private func keywordItems(_ words: [String]) -> [CompletionItem] {
        words.map { CompletionItem(kind: .keyword, text: keyword($0), label: $0, detail: "keyword") }
    }

    private func expressionItems() -> [CompletionItem] {
        if words.isEmpty { return keywordItems(SQLCompletionWords.statementStart) + templates() }
        var items = valuesSkeleton() + onConditions() + enumMembers(words).map(value) + columnItems()
        if [.orderBy, .groupBy, .having].contains(clause) {
            items += (scope?.outputs ?? []).filter { $0.symbol.kind == .selectAlias }.map {
                CompletionItem(kind: .column, text: SQLCompletion.quote($0.name), label: $0.name, detail: "alias")
            }
        }
        items += sources.filter { !$0.name.isEmpty && $0.name.lowercased() != prefix }.map { source in
            CompletionItem(kind: .alias, text: SQLCompletion.quote(source.name), label: source.name,
                           detail: source.objectName.map { $0 == source.name ? "table" : $0 } ?? "subquery")
        }
        items += SQLFunction.all.filter { $0.available(on: snapshot?.server) }
            .map { CompletionItem(kind: .function, text: options.functionCase.apply($0.name) + "(", label: $0.name, detail: $0.call) }
        items += (current?.routines ?? []).filter { $0.kind == .function }
            .map { CompletionItem(kind: .routine, text: SQLCompletion.quote($0.name) + "(", label: $0.name, detail: "function") }
        items += keywordItems(SQLCompletionWords.after(last, clause: clause, kind: kind))
        if sources.isEmpty {
            items += tableItems()
            if clause == .selectList { items += columnsBeforeFrom() }
        }
        return items + wordsInText()
    }

    /// A statement's first word can also be a template's abbreviation.
    private func templates() -> [CompletionItem] {
        options.snippets.filter { !$0.abbreviation.isEmpty }.map {
            CompletionItem(kind: .template, text: $0.body, label: $0.abbreviation, detail: $0.name)
        }
    }

    /// `SELECT nam` with no FROM yet: the columns of every table of the database; choosing one adds its FROM too.
    private func columnsBeforeFrom() -> [CompletionItem] {
        guard !prefix.isEmpty, let current else { return [] }
        let rest = String(decoding: utf16[caret..<upper], as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.uppercased().contains("FROM") else { return [] }
        return current.tables.flatMap { table in
            table.columns.map { column in
                let tail = (rest.isEmpty ? "" : " " + rest) + " " + keyword("FROM") + " " + SQLCompletion.quote(table.name)
                return CompletionItem(kind: .template, text: SQLTemplate.escape(SQLCompletion.quote(column.name)) + "$END$" + SQLTemplate.escape(tail),
                                      label: column.name, detail: "\(column.columnType) · adds FROM \(table.name)", replacing: start..<upper)
            }
        }
    }

    /// Words already in the text, for names the schema cache doesn't know.
    private func wordsInText() -> [CompletionItem] {
        guard prefix.utf16.count >= 2 else { return [] }
        var lexer = SQLLexer(text, noBackslashEscapes: noBackslashEscapes)
        var seen = Set<String>(), items: [CompletionItem] = []
        while let token = lexer.next() {
            guard token.kind == .word, token.range.lowerBound != start else { continue }
            let word = lexer.string(token.range), upper = lexer.upper(token.range)
            guard !SQLWords.reserved.contains(upper), seen.insert(word).inserted else { continue }
            items.append(CompletionItem(kind: .word, text: word, label: word, detail: "in this text"))
        }
        return items
    }
}
