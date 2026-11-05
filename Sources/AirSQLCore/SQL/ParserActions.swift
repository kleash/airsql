import Foundation

/// What Option-Return, rename, Quick Documentation and Parameter Info offer at a place of the text, from `SQLAnalysis`.
/// Pure: they change nothing and go nowhere, so the editor only applies what comes back.
public enum SQLIntentions {
    /// The rows a preview shows, at most: enough to see what's about to happen, without reading a whole table.
    static let previewLimit = 1000

    /// What can be done at `caret`, besides the fixes of problems there.
    public static func actions(at caret: Int, in analysis: SQLAnalysis) -> [SQLFix] {
        guard let statement = analysis.statement(at: caret) else { return [] }
        var actions: [SQLFix] = []
        let reader = Reader(analysis: analysis)
        if let reference = analysis.reference(at: caret) {
            if reference.symbol.isLocal || [.table, .column].contains(reference.symbol.kind) { actions.append(SQLFix("Rename…", .rename)) }
            actions += reader.quoting(reference)
            actions += reader.qualifying(reference)
            actions += reader.alias(reference, statement)
        }
        if statement.errors.isEmpty, !statement.shallow {
            actions += reader.expandStar(at: caret, statement)
            actions += reader.extractCTE(at: caret, statement)
            actions += reader.inserts(at: caret, statement)
            if let sql = preview(of: statement, in: analysis) { actions.append(SQLFix("Preview the Rows This Would Touch", .previewRows(sql))) }
        }
        return actions
    }

    /// A SELECT of the rows an UPDATE or DELETE would touch, with an UPDATE's new values first. Nil for anything else
    /// and for what isn't fully read. Built only from slices of the parsed statement, so it reads what it would write.
    public static func preview(of statement: SQLParsedStatement, in analysis: SQLAnalysis) -> String? {
        guard statement.kind == .update || statement.kind == .delete, statement.errors.isEmpty, !statement.shallow, let write = statement.write,
              let tables = write.tablesRange else { return nil }
        let reader = Reader(analysis: analysis)
        var columns: [String] = []
        for assignment in write.assignments {
            columns.append("\(reader.string(assignment.value.range)) AS \(SQLQuote.identifier("new " + assignment.column.last.value))")
        }
        if write.deleteTargets.isEmpty {
            columns.append(write.tables.count == 1 ? (write.tables[0].alias?.value ?? write.tables[0].name?.last.value).map { SQLCompletion.quote($0) + ".*" } ?? "*" : "*")
        } else {
            columns += write.deleteTargets.map { reader.string($0.range) + ".*" }
        }
        var sql = ""
        if let start = statement.ctes.first?.range.lowerBound, let end = statement.ctes.last?.range.upperBound {
            sql += "WITH " + reader.string(start..<end) + " "
        }
        sql += "SELECT " + columns.joined(separator: ", ") + " FROM " + reader.string(tables)
        if let condition = write.whereClause { sql += " WHERE " + reader.string(condition.range) }
        if !write.orderBy.isEmpty {
            let items = write.orderBy.map { item in reader.string(item.expr.range) + (item.direction.map { " " + $0.value } ?? "") }
            sql += " ORDER BY " + items.joined(separator: ", ")
        }
        let limit = write.limit.first.map { reader.string($0.range) } ?? "\(previewLimit)"
        return sql + " LIMIT " + limit
    }

    /// What renaming `symbol` to `name` changes, or why it can't be done. A name of the text changes everywhere it's
    /// used; a table or column of the server changes in this text too, and gets the statement that renames it, ready
    /// to read and run: nothing runs by itself.
    public static func rename(_ symbol: SQLSymbol, to name: String, at caret: Int, in analysis: SQLAnalysis) -> Result<[SQLEdit], SQLRenameError> {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(SQLRenameError(message: "Type a name")) }
        let new = SQLCompletion.quote(trimmed)
        if symbol.kind == .tableAlias, let scope = analysis.scope(at: caret),
           scope.visibleSources.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame && $0.symbol?.key != symbol.key }) {
            return .failure(SQLRenameError(message: "“\(trimmed)” is already a table in this query"))
        }
        var edits = analysis.usages(of: symbol).map { SQLEdit(range: $0.range, text: new) }
        guard let start = analysis.statement(at: caret)?.range.lowerBound else { return .success(edits) }
        func quoted(_ name: String?) -> String { name.map { SQLCompletion.quote($0) } ?? "" }
        let place = symbol.database.map { quoted($0) + "." } ?? ""
        switch symbol.kind {
        case .table:
            edits.append(SQLEdit(range: start..<start, text: "RENAME TABLE \(place)\(quoted(symbol.name)) TO \(place)\(new);\n"))
        case .column:
            guard let table = symbol.table else { break }
            edits.append(SQLEdit(range: start..<start, text: "ALTER TABLE \(place)\(quoted(table)) RENAME COLUMN \(quoted(symbol.name)) TO \(new);\n"))
        default:
            break
        }
        return .success(edits)
    }

    /// Every user variable named as the one at `caret`: a rename's edits for `@total`.
    public static func renameVariable(at caret: Int, to name: String, in analysis: SQLAnalysis, noBackslashEscapes: Bool = false) -> [SQLEdit]? {
        let tokens = SQLLexer.tokens(analysis.text, noBackslashEscapes: noBackslashEscapes).filter { $0.kind == .variable }
        let reader = Reader(analysis: analysis)
        guard let token = tokens.first(where: { $0.range.lowerBound <= caret && caret <= $0.range.upperBound }) else { return nil }
        let word = reader.string(token.range)
        guard !word.hasPrefix("@@") else { return nil }
        return tokens.filter { reader.string($0.range).caseInsensitiveCompare(word) == .orderedSame }
            .map { SQLEdit(range: $0.range, text: "@" + name.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))) }
    }

    /// What the name at `caret` is, for Quick Documentation: a title and plain lines.
    public static func documentation(at caret: Int, in analysis: SQLAnalysis) -> (title: String, body: String)? {
        Reader(analysis: analysis).documentation(at: caret)
    }

    /// The call or INSERT row around `caret`: what goes in each place, and which place the caret is in.
    public static func parameters(at caret: Int, in analysis: SQLAnalysis) -> (title: String, items: [String], active: Int)? {
        Reader(analysis: analysis).parameters(at: caret)
    }

    /// Where each value of each row goes: the hints beside INSERT's values.
    public static func valueHints(in analysis: SQLAnalysis, range: Range<Int>) -> [(offset: Int, column: String)] {
        var hints: [(offset: Int, column: String)] = []
        for statement in analysis.statements where statement.range.overlaps(range) {
            guard statement.kind == .insert || statement.kind == .replace, let write = statement.write else { continue }
            let names = Reader(analysis: analysis).targetColumns(write, statement)
            for row in write.rows where row.range.overlaps(range) {
                for (value, name) in zip(row.values, names) { hints.append((value.range.lowerBound, name)) }
            }
        }
        return hints
    }

    private struct Reader {
        let analysis: SQLAnalysis
        let utf16: [UInt16]

        init(analysis: SQLAnalysis) {
            self.analysis = analysis
            utf16 = Array(analysis.text.utf16)
        }

        func string(_ range: Range<Int>) -> String { String(decoding: utf16[range], as: UTF16.self) }

        func quoting(_ reference: SQLReference) -> [SQLFix] {
            let text = string(reference.range)
            if text.hasPrefix("`") {
                let bare = SQLQuote.unquoted(text)
                return SQLCompletion.quote(bare) == bare ? [SQLFix("Remove Quotes", .edit([SQLEdit(range: reference.range, text: bare)]))] : []
            }
            return [SQLFix("Quote Name", .edit([SQLEdit(range: reference.range, text: SQLQuote.identifier(text))]))]
        }

        /// `a` to `t.a` and back, `t` to `db.t` and back.
        func qualifying(_ reference: SQLReference) -> [SQLFix] {
            guard let scope = analysis.scope(at: reference.range.lowerBound) else { return [] }
            let start = reference.range.lowerBound, afterDot = start > 0 && utf16[start - 1] == SQLLexer.dot
            let symbol = reference.symbol
            switch symbol.kind {
            case .column, .selectAlias:
                guard !reference.isDeclaration else { return [] }
                let holders = scope.visibleSources.filter { $0.columns.contains { $0.symbol.key == symbol.key } && !$0.name.isEmpty }
                if afterDot {
                    var from = start - 1
                    while from > 0, SQLLexer.isNameChar(utf16[from - 1]) || utf16[from - 1] == SQLLexer.backtick { from -= 1 }
                    guard scope.visibleSources.filter({ $0.has(symbol.name) != nil }).count == 1 else { return [] }
                    return [SQLFix("Remove Table Name", .edit([SQLEdit(range: from..<start, text: "")]))]
                }
                guard let holder = holders.first else { return [] }
                return [SQLFix("Qualify with \(holder.name)", .edit([SQLEdit(range: start..<start, text: SQLCompletion.quote(holder.name) + ".")]))]
            case .table:
                guard let database = symbol.database else { return [] }
                if afterDot {
                    var from = start - 1
                    while from > 0, SQLLexer.isNameChar(utf16[from - 1]) || utf16[from - 1] == SQLLexer.backtick { from -= 1 }
                    guard analysis.databases.contains(database) else { return [] }
                    return [SQLFix("Remove Database Name", .edit([SQLEdit(range: from..<start, text: "")]))]
                }
                return [SQLFix("Qualify with \(database)", .edit([SQLEdit(range: start..<start, text: SQLCompletion.quote(database) + ".")]))]
            default:
                return []
            }
        }

        /// orders to orders o, with `orders.x` rewritten.
        func alias(_ reference: SQLReference, _ statement: SQLParsedStatement) -> [SQLFix] {
            guard reference.symbol.kind == .table, let scope = analysis.scope(at: reference.range.lowerBound) else { return [] }
            guard let source = scope.sources.first(where: { $0.kind == .table && $0.range.contains(reference.range.lowerBound) && $0.name == $0.objectName }) else { return [] }
            let parts = source.name.split(separator: "_").compactMap(\.first).map(String.init).joined().lowercased()
            var alias = parts.isEmpty ? "t" : parts, number = 2
            while scope.visibleSources.contains(where: { $0.name.caseInsensitiveCompare(alias) == .orderedSame }) || SQLWords.reserved.contains(alias.uppercased()) {
                alias = (parts.isEmpty ? "t" : parts) + "\(number)"
                number += 1
            }
            var edits = [SQLEdit(range: reference.range.upperBound..<reference.range.upperBound, text: " " + alias)]
            for use in analysis.usages(of: reference.symbol) where use.range != reference.range && scope.extent.contains(use.range.lowerBound) {
                // Only where it qualifies a column: other mentions are tables of their own.
                if use.range.upperBound < utf16.count, utf16[use.range.upperBound] == SQLLexer.dot { edits.append(SQLEdit(range: use.range, text: alias)) }
            }
            return [SQLFix("Add Table Alias “\(alias)”", .edit(edits))]
        }

        func expandStar(at caret: Int, _ statement: SQLParsedStatement) -> [SQLFix] {
            for query in statement.allQueries {
                for block in query.blocks {
                    for item in block.items {
                        guard case .star = item.expr.kind, item.expr.range.lowerBound <= caret, caret <= item.expr.range.upperBound,
                              let scope = analysis.scope(at: item.expr.range.lowerBound) else { continue }
                        let qualifier = item.expr.name?.last.value
                        let sources = scope.sources.filter { source in qualifier.map { source.name.caseInsensitiveCompare($0) == .orderedSame } ?? true }
                        guard !sources.isEmpty, sources.allSatisfy(\.complete) else { return [] }
                        let qualify = sources.count > 1 || qualifier != nil
                        let names = sources.flatMap { source in
                            source.columns.filter { $0.schema?.invisible != true }.map {
                                (qualify ? SQLCompletion.quote(source.name) + "." : "") + SQLCompletion.quote($0.name)
                            }
                        }
                        return [SQLFix("Expand * to Its Columns", .edit([SQLEdit(range: item.expr.range, text: names.joined(separator: ", "))]))]
                    }
                }
            }
            return []
        }

        /// The innermost subquery around the caret, moved to a WITH of the outermost query. Not a correlated one, which
        /// reads names only its place has.
        func extractCTE(at caret: Int, _ statement: SQLParsedStatement) -> [SQLFix] {
            guard statement.kind == .select || statement.kind == .explain, let top = statement.query else { return [] }
            let inner = statement.allQueries.filter { $0 !== top && $0.extent.contains(caret) && statementHasBracket($0) }
                .min { $0.range.count < $1.range.count }
            guard let inner, !top.ctes.contains(where: { $0.query === inner }), !isCorrelated(inner) else { return [] }
            var open = inner.range.lowerBound - 1
            while open >= 0, utf16[open] != 0x28 { open -= 1 }
            var close = inner.range.upperBound
            while close < utf16.count, utf16[close] != 0x29 { close += 1 }
            guard open >= 0, close < utf16.count else { return [] }
            let derived = statement.allQueries.flatMap(\.blocks).flatMap(\.from).first { $0.query === inner }
            let name = derived?.alias?.value ?? "extracted"
            let body = string(inner.range)
            var edits: [SQLEdit]
            if let last = top.ctes.last {
                edits = [SQLEdit(range: last.range.upperBound..<last.range.upperBound, text: ", \(SQLCompletion.quote(name)) AS (\(body))")]
            } else {
                edits = [SQLEdit(range: top.range.lowerBound..<top.range.lowerBound, text: "WITH \(SQLCompletion.quote(name)) AS (\(body))\n")]
            }
            let replacement = derived != nil ? SQLCompletion.quote(name) : "(SELECT * FROM \(SQLCompletion.quote(name)))"
            let upper = derived?.alias.map { $0.range.upperBound } ?? close + 1
            edits.append(SQLEdit(range: open..<upper, text: replacement))
            return [SQLFix("Move Subquery to WITH", .edit(edits))]
        }

        private func statementHasBracket(_ query: SQLQuery) -> Bool {
            var i = query.range.lowerBound - 1
            while i >= 0, SQLLexer.isSpace(utf16[i]) { i -= 1 }
            return i >= 0 && utf16[i] == 0x28
        }

        private func isCorrelated(_ query: SQLQuery) -> Bool {
            let range = query.range
            guard let scope = analysis.scope(at: range.lowerBound + 1) else { return true }
            let own = Set(scope.sources.compactMap { $0.symbol?.key })
            for reference in analysis.references where range.contains(reference.range.lowerBound) {
                let symbol = reference.symbol
                if let declaration = symbol.declaration, symbol.kind == .tableAlias, !range.contains(declaration.lowerBound) { return true }
                if symbol.kind == .column, !scope.sources.contains(where: { $0.columns.contains { $0.symbol.key == symbol.key } }), own.isEmpty == false,
                   !analysis.scopes.contains(where: { range.contains($0.extent.lowerBound) && $0 !== scope && $0.sources.contains { $0.has(symbol.name) != nil } }) {
                    return true
                }
            }
            return false
        }

        func inserts(at caret: Int, _ statement: SQLParsedStatement) -> [SQLFix] {
            guard statement.kind == .insert || statement.kind == .replace, let write = statement.write, let head = write.rows.first?.range.lowerBound else { return [] }
            var actions: [SQLFix] = []
            let start = statement.range.lowerBound
            let plain = write.onDuplicate.isEmpty && write.rowAlias == nil && write.returning.isEmpty && !write.rows.isEmpty
            if plain, write.rows.count > 1 {
                let prefix = string(start..<head)
                let text = write.rows.map { prefix + string($0.range) }.joined(separator: ";\n")
                actions.append(SQLFix("Split into One INSERT per Row", .edit([SQLEdit(range: statement.range, text: text)])))
            }
            if plain, let next = nextInsert(after: statement), let row = write.rows.last {
                let tail = next.write!.rows.map { string($0.range) }.joined(separator: ", ")
                actions.append(SQLFix("Merge with the Next INSERT", .edit([SQLEdit(range: row.range.upperBound..<next.range.upperBound, text: ", " + tail)])))
            }
            if let index = write.columns.firstIndex(where: { $0.range.lowerBound <= caret && caret <= $0.range.upperBound }), write.columns.count > 1,
               write.rows.allSatisfy({ $0.values.count == write.columns.count }) {
                var edits = [listRemoval(write.columns.map(\.range), index)]
                for row in write.rows { edits.append(listRemoval(row.values.map(\.range), index)) }
                actions.append(SQLFix("Remove Column “\(write.columns[index].value)” and Its Values", .edit(edits)))
            }
            return actions
        }

        /// The next statement, if it's an INSERT into the same table with the same head.
        private func nextInsert(after statement: SQLParsedStatement) -> SQLParsedStatement? {
            guard let index = analysis.statements.firstIndex(where: { $0.range == statement.range }), index + 1 < analysis.statements.count,
                  let head = statement.write?.rows.first?.range.lowerBound else { return nil }
            let next = analysis.statements[index + 1]
            guard next.kind == statement.kind, next.errors.isEmpty, let write = next.write, let nextHead = write.rows.first?.range.lowerBound,
                  write.onDuplicate.isEmpty, write.rowAlias == nil, write.returning.isEmpty,
                  string(statement.range.lowerBound..<head) == string(next.range.lowerBound..<nextHead) else { return nil }
            return next
        }

        /// Takes item `index` out of a comma-separated list with its comma.
        private func listRemoval(_ items: [Range<Int>], _ index: Int) -> SQLEdit {
            index + 1 < items.count ? SQLEdit(range: items[index].lowerBound..<items[index + 1].lowerBound, text: "")
                : SQLEdit(range: items[index - 1].upperBound..<items[index].upperBound, text: "")
        }

        // MARK: Documentation

        func documentation(at caret: Int) -> (title: String, body: String)? {
            if let reference = analysis.reference(at: caret) {
                let symbol = reference.symbol
                switch symbol.kind {
                case .table: return table(symbol)
                case .column: return column(symbol)
                case .routine: if let found = routine(symbol) { return found }
                case .database:
                    guard let database = analysis.snapshot?.database(symbol.name) else { return nil }
                    return (database.name, "Database · \(database.tables.count) tables · \(database.charset) / \(database.collation)")
                case .tableAlias, .cte, .selectAlias: return local(reference, caret)
                }
            }
            return function(at: caret)
        }

        private func table(_ symbol: SQLSymbol) -> (title: String, body: String)? {
            guard let database = symbol.database, let table = analysis.snapshot?.table(database, symbol.name) else { return nil }
            var lines = ["\(table.kind == .view ? "View" : "Table") in \(database)" + (table.engine.map { " · \($0)" } ?? "")]
            if !table.comment.isEmpty { lines.append(table.comment) }
            if let rows = analysis.snapshot?.database(database)?.statistics?[table.name]?.rows { lines.append("About \(rows) rows") }
            lines.append("")
            let width = table.columns.map(\.name.count).max() ?? 0
            for column in table.columns {
                let key = table.primaryKey?.parts.contains { $0.column == column.name } == true ? "  PK" : ""
                lines.append(column.name.padding(toLength: width + 2, withPad: " ", startingAt: 0) + column.columnType + (column.nullable ? "" : " NOT NULL") + key)
            }
            for key in table.foreignKeys {
                lines.append("→ \(key.columns.joined(separator: ", ")) references \(key.referencedTable) (\(key.referencedColumns.joined(separator: ", ")))")
            }
            return (table.name, lines.joined(separator: "\n"))
        }

        private func column(_ symbol: SQLSymbol) -> (title: String, body: String)? {
            guard let database = symbol.database, let name = symbol.table, let found = analysis.snapshot?.table(database, name)?.column(symbol.name) else { return nil }
            var lines = ["\(found.columnType)\(found.nullable ? "" : " NOT NULL")", "In \(name)"]
            switch found.defaultValue {
            case .none: break
            case .null: lines.append("Default NULL")
            case .value(let text), .expression(let text): lines.append("Default \(text)")
            }
            if found.autoIncrement { lines.append("Auto-increment") }
            if let generated = found.generated { lines.append("Generated from \(generated.expression)") }
            if !found.comment.isEmpty { lines.append(found.comment) }
            return (found.name, lines.joined(separator: "\n"))
        }

        private func routine(_ symbol: SQLSymbol) -> (title: String, body: String)? {
            guard let database = symbol.database, let found = analysis.snapshot?.database(database)?.routines.first(where: { $0.name == symbol.name }) else { return nil }
            let kind = found.kind == .function ? "Function" : "Procedure"
            return (found.name, ["\(kind) in \(database)", found.returns.map { "Returns \($0)" }, found.comment.isEmpty ? nil : found.comment].compactMap { $0 }.joined(separator: "\n"))
        }

        private func local(_ reference: SQLReference, _ caret: Int) -> (title: String, body: String)? {
            let symbol = reference.symbol
            guard let scope = analysis.scope(at: caret) else { return nil }
            if let source = (scope.visibleSources + scope.visibleCTEs).first(where: { $0.symbol?.key == symbol.key }) {
                let what = symbol.kind == .cte ? "WITH query" : source.objectName.map { "Alias of \($0)" } ?? "Subquery"
                return (symbol.name, ([what, ""] + source.columns.map { $0.name + ($0.type.map { "  " + $0 } ?? "") }).joined(separator: "\n"))
            }
            return (symbol.name, "Column of this query")
        }

        /// A built-in's signature, for the word at `caret`.
        private func function(at caret: Int) -> (title: String, body: String)? {
            var start = min(max(caret, 0), utf16.count), end = start
            while start > 0, SQLLexer.isNameChar(utf16[start - 1]) { start -= 1 }
            while end < utf16.count, SQLLexer.isNameChar(utf16[end]) { end += 1 }
            let word = string(start..<end).uppercased()
            guard let function = SQLFunction.all.first(where: { $0.name == word }) else { return nil }
            return (function.name, "\(function.call)\n\(function.group.rawValue)")
        }

        // MARK: Parameters

        func parameters(at caret: Int) -> (title: String, items: [String], active: Int)? {
            guard let statement = analysis.statement(at: caret) else { return nil }
            if let write = statement.write, let row = write.rows.first(where: { $0.range.lowerBound < caret && caret <= $0.range.upperBound }) {
                let names = targetColumns(write, statement)
                guard !names.isEmpty else { return nil }
                return (statement.write?.tables.first?.name?.last.value ?? "VALUES", names, position(of: caret, in: row.values.map(\.range), start: row.range.lowerBound))
            }
            // The innermost call around the caret.
            var best: SQLExpr?
            let roots = statement.expressions + statement.allQueries.flatMap { $0.blocks.flatMap(\.expressions) + $0.orderBy.map(\.expr) }
            for root in roots {
                root.walk { expr in
                    guard case .call = expr.kind, let name = expr.name, name.range.upperBound < caret, caret <= expr.range.upperBound,
                          expr.range.count < (best?.range.count ?? .max) else { return }
                    best = expr
                }
            }
            guard let call = best, let name = call.name else { return nil }
            let upper = name.last.value.uppercased()
            guard let function = SQLFunction.all.first(where: { $0.name == upper }) else { return nil }
            let inside = function.call.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
            let items = inside.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return (function.name, items, position(of: caret, in: call.children.map(\.range), start: name.range.upperBound))
        }

        /// Which of `items` the caret is at: the first that ends at or after it.
        private func position(of caret: Int, in items: [Range<Int>], start: Int) -> Int {
            items.firstIndex { caret <= $0.upperBound } ?? max(items.count - 1, 0)
        }

        /// The columns an INSERT's rows fill, in order.
        func targetColumns(_ write: SQLWrite, _ statement: SQLParsedStatement) -> [String] {
            if write.columnsRange != nil { return write.columns.map(\.value) }
            guard let ref = write.tables.first, let source = analysis.scope(at: statement.range.lowerBound)?.sources.first(where: { $0.range == ref.range }) else { return [] }
            return source.columns.filter { $0.schema?.invisible != true }.map(\.name)
        }
    }
}

public struct SQLRenameError: Error, Equatable {
    public var message: String
}
