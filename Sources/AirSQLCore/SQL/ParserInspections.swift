import Foundation

/// A change of the text, in UTF-16 offsets.
public struct SQLEdit: Equatable, Sendable {
    public var range: Range<Int>
    public var text: String

    public init(range: Range<Int>, text: String) {
        self.range = range
        self.text = text
    }
}

/// What the Option-Return menu offers: a fix for a problem, or an intention at the caret.
public struct SQLFix: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Changes the text, as one undo step. Nothing runs.
        case edit([SQLEdit])
        /// Reads the schema again.
        case refreshSchema
        /// Shows, without changing anything, the rows this SELECT finds: what an UPDATE or DELETE would touch.
        case previewRows(String)
        /// Rename here: the console asks for the new name.
        case rename
    }

    public var title: String
    public var action: Action

    public init(_ title: String, _ action: Action) {
        self.title = title
        self.action = action
    }
}

/// Checks of the text while typing, on `SQLAnalysis`: nothing goes to the server, Run still runs, and what can't be
/// certain stays silent.
public enum SQLInspections {
    public struct Inspection: Sendable {
        public var code: String
        /// For Settings: what it looks for.
        public var title: String
        public var severity: SQLProblem.Severity
    }

    public static let all: [Inspection] = [
        .init(code: "syntax", title: "Syntax errors", severity: .error),
        .init(code: "unknownName", title: "Unknown tables, columns and routines", severity: .error),
        .init(code: "ambiguousColumn", title: "A column in more than one table", severity: .error),
        .init(code: "insertCount", title: "INSERT values that don't match its columns", severity: .error),
        .init(code: "derivedAlias", title: "A subquery in FROM with no alias", severity: .error),
        .init(code: "duplicateAlias", title: "The same alias twice", severity: .error),
        .init(code: "usingColumn", title: "A USING column missing from a table", severity: .error),
        .init(code: "aggregateMisuse", title: "Aggregates in WHERE, ON, GROUP BY or inside each other", severity: .error),
        .init(code: "autoIncrement", title: "Two AUTO_INCREMENT columns", severity: .error),
        .init(code: "reservedWord", title: "Reserved words used as names", severity: .error),
        .init(code: "functionSpace", title: "A space between a function's name and its bracket", severity: .error),
        .init(code: "functionArguments", title: "The wrong number of arguments to a built-in function", severity: .error),
        .init(code: "nullComparison", title: "Comparing with = NULL", severity: .warning),
        .init(code: "noWhere", title: "UPDATE or DELETE without WHERE", severity: .warning),
        .init(code: "joinWithoutOn", title: "JOIN without ON in an UPDATE or DELETE", severity: .warning),
        .init(code: "groupBy", title: "A column that isn't in GROUP BY", severity: .warning),
        .init(code: "nullIntoNotNull", title: "NULL into a NOT NULL column", severity: .warning),
        .init(code: "generatedColumn", title: "A value for a generated column", severity: .warning),
        .init(code: "readOnlyWrite", title: "Writes on a read-only connection", severity: .warning),
        .init(code: "constantCondition", title: "A condition that's always the same", severity: .warning),
        .init(code: "unusedCTE", title: "A WITH query nothing reads", severity: .weak),
        .init(code: "redundantCode", title: "Redundant ASC, ELSE NULL and alias", severity: .weak),
    ]

    private static let aggregates: Set<String> = [
        "AVG", "BIT_AND", "BIT_OR", "BIT_XOR", "COUNT", "GROUP_CONCAT", "JSON_ARRAYAGG", "JSON_OBJECTAGG", "MAX", "MIN", "STD", "STDDEV",
        "STDDEV_POP", "STDDEV_SAMP", "SUM", "VAR_POP", "VAR_SAMP", "VARIANCE",
    ]
    /// Functions the server reads as a function only with the bracket right after the name (without IGNORE_SPACE).
    private static let noSpaceFunctions: Set<String> = [
        "AVG", "BIT_AND", "BIT_OR", "BIT_XOR", "CAST", "COUNT", "CURDATE", "CURTIME", "DATE_ADD", "DATE_SUB", "EXTRACT", "GROUP_CONCAT", "MAX",
        "MID", "MIN", "NOW", "POSITION", "SESSION_USER", "STD", "STDDEV", "STDDEV_POP", "STDDEV_SAMP", "SUBDATE", "SUBSTR", "SUBSTRING", "SUM",
        "SYSDATE", "SYSTEM_USER", "TRIM", "VARIANCE", "VAR_POP", "VAR_SAMP",
    ]
    /// The argument counts of common built-ins with a fixed shape; Int.max: no limit.
    private static let argumentCounts: [String: ClosedRange<Int>] = [
        "SUM": 1...1, "AVG": 1...1, "MIN": 1...1, "MAX": 1...1, "LENGTH": 1...1, "CHAR_LENGTH": 1...1, "LOWER": 1...1, "UPPER": 1...1,
        "LTRIM": 1...1, "RTRIM": 1...1, "REVERSE": 1...1, "HEX": 1...1, "UNHEX": 1...1, "MD5": 1...1, "ABS": 1...1, "CEIL": 1...1, "FLOOR": 1...1,
        "SQRT": 1...1, "SIGN": 1...1, "YEAR": 1...1, "MONTH": 1...1, "DAY": 1...1, "HOUR": 1...1, "MINUTE": 1...1, "LAST_DAY": 1...1,
        "IF": 3...3, "IFNULL": 2...2, "NULLIF": 2...2, "LEFT": 2...2, "RIGHT": 2...2, "REPLACE": 3...3, "SUBSTRING_INDEX": 3...3, "LPAD": 2...3,
        "RPAD": 2...3, "REPEAT": 2...2, "DATEDIFF": 2...2, "DATE_FORMAT": 2...3, "STR_TO_DATE": 2...2, "POW": 2...2, "POWER": 2...2, "MOD": 2...2,
        "CONV": 3...3, "CONVERT_TZ": 3...3, "ROUND": 1...2, "TRUNCATE": 2...2, "SUBSTRING": 2...3, "SUBSTR": 2...3, "LOCATE": 2...3, "INSTR": 2...2,
        "NOW": 0...1, "CURDATE": 0...0, "COALESCE": 1...Int.max, "CONCAT": 1...Int.max, "CONCAT_WS": 2...Int.max, "GREATEST": 1...Int.max,
        "LEAST": 1...Int.max, "JSON_EXTRACT": 2...Int.max, "DATE_ADD": 2...2, "DATE_SUB": 2...2, "TIMESTAMPDIFF": 3...3,
    ]

    /// What's wrong with the text, by position. `readOnly`: the connection refuses writes. `disabled`: codes turned off.
    public static func problems(_ analysis: SQLAnalysis, readOnly: Bool = false, disabled: Set<String> = [], noBackslashEscapes: Bool = false) -> [SQLProblem] {
        var check = Check(analysis: analysis, noBackslashEscapes: noBackslashEscapes)
        check.run(readOnly: readOnly)
        let found = check.found.filter { !disabled.contains($0.code) }.sorted {
            ($0.range.lowerBound, $1.severity.rawValue) < ($1.range.lowerBound, $0.severity.rawValue)
        }
        return Array(found.prefix(ConsoleScript.unclosedLimit))
    }

    private struct Check {
        let analysis: SQLAnalysis
        let noBackslashEscapes: Bool
        let utf16: [UInt16]
        var found: [SQLProblem] = []

        init(analysis: SQLAnalysis, noBackslashEscapes: Bool) {
            self.analysis = analysis
            self.noBackslashEscapes = noBackslashEscapes
            utf16 = Array(analysis.text.utf16)
        }

        func string(_ range: Range<Int>) -> String { String(decoding: utf16[range], as: UTF16.self) }

        mutating func say(_ code: String, _ range: Range<Int>, _ message: String, fixes: [SQLFix] = []) {
            let severity = SQLInspections.all.first { $0.code == code }?.severity ?? .warning
            found.append(SQLProblem(range: range, message: message, severity: severity, code: code, fixes: fixes))
        }

        mutating func run(readOnly: Bool) {
            names()
            references()
            for statement in analysis.statements {
                if let error = statement.errors.first { syntax(error) }
                // What follows a syntax error isn't what was meant, so nothing else is said of the statement.
                if statement.errors.isEmpty, !statement.shallow || statement.kind == .create { check(statement) }
                if readOnly, StatementCheck.writes(string(statement.range), noBackslashEscapes: noBackslashEscapes) {
                    say("readOnlyWrite", verbRange(statement), "This connection is read-only: AirSQL will refuse to run this")
                }
            }
        }

        func verbRange(_ statement: SQLParsedStatement) -> Range<Int> {
            let start = statement.range.lowerBound
            var end = start
            while end < statement.range.upperBound, SQLLexer.isNameChar(utf16[end]) { end += 1 }
            return start..<max(end, min(start + 1, statement.range.upperBound))
        }

        mutating func syntax(_ error: SQLSyntaxError) {
            var fixes: [SQLFix] = []
            let word = string(error.range)
            if SQLWords.reserved.contains(word.uppercased()), error.message.contains("name") || error.message.contains("value") {
                fixes.append(SQLFix("Quote “\(word)” as a Name", .edit([SQLEdit(range: error.range, text: SQLQuote.identifier(word))])))
            }
            say("syntax", error.range, error.message, fixes: fixes)
        }

        mutating func names() {
            let refresh = "as far as AirSQL knows. If it's new, refresh the schema"
            for issue in analysis.issues {
                let replace = closest(to: issue.name, in: issue.candidates).map {
                    SQLFix("Change to “\($0)”", .edit([SQLEdit(range: issue.range, text: SQLCompletion.quote($0))]))
                }
                let reload = SQLFix("Refresh the Schema", .refreshSchema)
                switch issue.kind {
                case .unknownTable(let database):
                    say("unknownName", issue.range, "No table named “\(issue.name)” in “\(database)”, \(refresh)", fixes: [replace, reload].compactMap { $0 })
                case .unknownColumn(let place):
                    var fixes = [replace, reload].compactMap { $0 }
                    if let table = issue.table, table.kind == .table, let name = table.objectName {
                        let start = analysis.statements[issue.statement].range.lowerBound
                        let qualified = (table.database.map { SQLCompletion.quote($0) + "." } ?? "") + SQLCompletion.quote(name)
                        let text = "ALTER TABLE \(qualified) ADD COLUMN \(SQLCompletion.quote(issue.name)) VARCHAR(255);\n"
                        fixes.append(SQLFix("Write ALTER TABLE to Add “\(issue.name)”", .edit([SQLEdit(range: start..<start, text: text)])))
                    }
                    say("unknownName", issue.range, "No column named “\(issue.name)” in \(place), \(refresh)", fixes: fixes)
                case .unknownQualifier:
                    say("unknownName", issue.range, "No table or alias “\(issue.name)” in this statement", fixes: [replace].compactMap { $0 })
                case .unknownRoutine(let database):
                    say("unknownName", issue.range, "No routine named “\(issue.name)” in “\(database)”, \(refresh)", fixes: [replace, reload].compactMap { $0 })
                case .ambiguous(let sources):
                    let fixes = sources.filter { !$0.isEmpty }.map {
                        SQLFix("Qualify as \($0).\(issue.name)", .edit([SQLEdit(range: issue.range.lowerBound..<issue.range.lowerBound, text: SQLCompletion.quote($0) + ".")]))
                    }
                    say("ambiguousColumn", issue.range, "“\(issue.name)” is in " + sources.map { "“\($0)”" }.joined(separator: " and "), fixes: fixes)
                }
            }
        }

        /// The name nearest `name`, when it's near enough to be a typo.
        func closest(to name: String, in candidates: [String]) -> String? {
            let lower = Array(name.lowercased())
            let limit = max(1, lower.count / 3)
            var best: (name: String, distance: Int)?
            for candidate in candidates {
                let other = Array(candidate.lowercased())
                guard abs(other.count - lower.count) <= limit else { continue }
                let distance = editDistance(lower, other)
                if distance <= limit, distance < (best?.distance ?? .max) { best = (candidate, distance) }
            }
            return best?.name
        }

        private func editDistance(_ a: [Character], _ b: [Character]) -> Int {
            var row = Array(0...b.count)
            for (i, x) in a.enumerated() {
                var previous = row[0]
                row[0] = i + 1
                for (j, y) in b.enumerated() {
                    let cost = min(previous + (x == y ? 0 : 1), row[j] + 1, row[j + 1] + 1)
                    previous = row[j + 1]
                    row[j + 1] = cost
                }
            }
            return row[b.count]
        }

        // MARK: Statements

        mutating func check(_ statement: SQLParsedStatement) {
            for query in statement.allQueries { self.query(query, statement) }
            for expr in statement.expressions { expression(expr) }
            if let write = statement.write { self.write(write, statement) }
            var autoIncrement = 0
            for column in statement.columns where column.autoIncrement {
                autoIncrement += 1
                if autoIncrement == 2 { say("autoIncrement", column.name.range, "A table can have only one AUTO_INCREMENT column") }
            }
        }

        mutating func query(_ query: SQLQuery, _ statement: SQLParsedStatement) {
            for item in query.orderBy { redundantDirection(item) }
            for block in query.blocks {
                aliases(block.from)
                for ref in block.from where ref.kind == .derived && ref.alias == nil {
                    let end = ref.range.upperBound
                    say("derivedAlias", ref.range, "A subquery in FROM needs an alias", fixes: [SQLFix("Add an Alias", .edit([SQLEdit(range: end..<end, text: " AS d")]))])
                }
                usingColumns(block.from)
                for expr in block.expressions { expression(expr) }
                for item in block.orderBy { redundantDirection(item) }
                aggregateMisuse(block)
                groupBy(block)
                for item in block.items { redundantAlias(item) }
                for condition in [block.whereClause, block.having].compactMap({ $0 }) + block.from.compactMap(\.join?.on) { constant(condition) }
            }
        }

        mutating func aliases(_ tables: [SQLTableRef]) {
            var seen = Set<String>()
            for ref in tables {
                guard let name = ref.alias?.value ?? ref.name?.last.value, let range = ref.alias?.range ?? ref.name?.last.range else { continue }
                if !seen.insert(name.lowercased()).inserted, ref.name?.qualifier == nil || ref.alias != nil {
                    say("duplicateAlias", range, "“\(name)” is already a table of this query: give one of them another alias")
                }
            }
        }

        mutating func usingColumns(_ tables: [SQLTableRef]) {
            for (index, ref) in tables.enumerated() {
                guard let join = ref.join, !join.using.isEmpty, let scope = analysis.scope(at: join.range.lowerBound) else { continue }
                let sources = scope.sources
                guard sources.count == tables.count else { continue }
                for column in join.using {
                    let left = sources[0..<index]
                    if sources[index].complete, sources[index].has(column.value) == nil {
                        say("usingColumn", column.range, "“\(sources[index].name)” has no column “\(column.value)”")
                    } else if left.allSatisfy(\.complete), left.allSatisfy({ $0.has(column.value) == nil }) {
                        say("usingColumn", column.range, "No table before this join has a column “\(column.value)”")
                    }
                }
            }
        }

        /// Checks of one expression and all that's inside it.
        mutating func expression(_ root: SQLExpr) {
            var calls: [SQLExpr] = [], comparisons: [SQLExpr] = [], cases: [SQLExpr] = []
            root.walk { expr in
                switch expr.kind {
                case .call: calls.append(expr)
                case .binary where ["=", "<>", "!="].contains(expr.op): comparisons.append(expr)
                case .caseWhen: cases.append(expr)
                default: break
                }
            }
            for comparison in comparisons where comparison.children.count == 2 { nullComparison(comparison) }
            for call in calls { self.call(call) }
            for value in cases where value.children.count % 2 == 1 {
                if let last = value.children.last, case .literal = last.kind, last.op == "NULL", let previous = value.children.dropLast().last {
                    let range = previous.range.upperBound..<last.range.upperBound
                    say("redundantCode", range, "ELSE NULL is what CASE does anyway", fixes: [SQLFix("Remove ELSE NULL", .edit([SQLEdit(range: range, text: "")]))])
                }
            }
        }

        mutating func nullComparison(_ expr: SQLExpr) {
            let left = expr.children[0], right = expr.children[1]
            func isNull(_ value: SQLExpr) -> Bool { if case .literal = value.kind { return value.op == "NULL" } else { return false } }
            guard isNull(right) || isNull(left), !(isNull(right) && isNull(left)), let opRange = expr.opRange else { return }
            let test = expr.op == "=" ? "IS NULL" : "IS NOT NULL"
            let value = isNull(right) ? left : right
            let fix = SQLFix("Change to \(test)", .edit([SQLEdit(range: expr.range, text: "\(string(value.range)) \(test)")]))
            say("nullComparison", opRange, "\(expr.op) NULL is never true: use \(test)", fixes: [fix])
        }

        mutating func call(_ call: SQLExpr) {
            guard let name = call.name, name.parts.count == 1 else { return }
            let upper = name.last.value.uppercased()
            guard !name.last.quoted else { return }
            let bracket = name.last.range.upperBound
            if SQLInspections.noSpaceFunctions.contains(upper), let open = nextBracket(after: bracket), open > bracket {
                say("functionSpace", name.last.range, "\(upper) needs its bracket right after the name, or the server reads it as a column",
                    fixes: [SQLFix("Remove the Space", .edit([SQLEdit(range: bracket..<open, text: "")]))])
            }
            if let counts = SQLInspections.argumentCounts[upper], !call.opaque, !counts.contains(call.children.count),
               !call.children.contains(where: { if case .invalid = $0.kind { return true } else { return false } }), !isStoredFunction(upper) {
                let wanted = counts.upperBound == .max ? "at least \(counts.lowerBound)" : counts.count == 1 ? "\(counts.lowerBound)" : "\(counts.lowerBound) to \(counts.upperBound)"
                say("functionArguments", name.last.range, "\(upper) takes \(wanted) argument\(counts.upperBound == 1 ? "" : "s"), not \(call.children.count)")
            }
        }

        /// The "(" after `offset`, past only spaces.
        func nextBracket(after offset: Int) -> Int? {
            var i = offset
            while i < utf16.count, SQLLexer.isSpace(utf16[i]) { i += 1 }
            return i < utf16.count && utf16[i] == 0x28 ? i : nil
        }

        func isStoredFunction(_ upper: String) -> Bool {
            analysis.databases.lazy.compactMap { $0 }.contains { database in
                analysis.snapshot?.database(database)?.routines.contains { $0.name.uppercased() == upper } == true
            }
        }

        // MARK: Aggregates and GROUP BY

        func isAggregate(_ expr: SQLExpr) -> Bool {
            guard case .call = expr.kind, !expr.isWindow, let name = expr.name, name.parts.count == 1 else { return false }
            return SQLInspections.aggregates.contains(name.last.value.uppercased())
        }

        mutating func aggregateMisuse(_ block: SQLSelect) {
            func aggregate(in expr: SQLExpr) -> [SQLExpr] {
                var found: [SQLExpr] = []
                expr.walk { if isAggregate($0) { found.append($0) } }
                return found
            }
            let places: [(String, [SQLExpr])] = [("WHERE", [block.whereClause].compactMap { $0 }), ("ON", block.from.compactMap(\.join?.on)), ("GROUP BY", block.groupBy)]
            for (place, exprs) in places {
                for expr in exprs {
                    for call in aggregate(in: expr) {
                        say("aggregateMisuse", call.range, "\(call.name!.last.value.uppercased()) can’t be used in \(place)\(place == "WHERE" ? ": use HAVING" : "")")
                    }
                }
            }
            for expr in block.expressions {
                for call in aggregate(in: expr) {
                    for nested in call.children.flatMap(aggregate(in:)) {
                        say("aggregateMisuse", nested.range, "An aggregate can’t be inside another")
                    }
                }
            }
        }

        /// Columns outside GROUP BY and aggregates, which ONLY_FULL_GROUP_BY (the default) refuses.
        mutating func groupBy(_ block: SQLSelect) {
            guard !block.groupBy.isEmpty, !block.rollup, let scope = analysis.scope(at: block.range.lowerBound + 1),
                  scope.sources.allSatisfy(\.complete), !scope.sources.isEmpty else { return }
            let grouped = Set(block.groupBy.map { normal($0.range) })
            var keys = Set<String>()
            for value in block.groupBy {
                if case .column = value.kind, let symbol = symbol(of: value) { keys.insert(symbol.key) }
            }
            // A primary key in GROUP BY settles every column of its table.
            var settled = Set<String>()
            for source in scope.sources {
                guard let table = source.table, let primary = table.primaryKey, !primary.parts.isEmpty else { continue }
                let columns = primary.parts.map { SQLSymbol(kind: .column, name: $0.column ?? "", database: source.database, table: table.name).key }
                if columns.allSatisfy(keys.contains) { settled.insert(table.name.lowercased()) }
            }
            let aliases = Set(block.items.compactMap { $0.alias?.value.lowercased() })
            func scan(_ expr: SQLExpr, _ offending: inout [SQLExpr]) {
                if grouped.contains(normal(expr.range)) || isAggregate(expr) || expr.isWindow || expr.query != nil { return }
                if case .call = expr.kind, expr.name?.last.value.uppercased() == "ANY_VALUE" { return }
                if case .column = expr.kind {
                    guard let symbol = symbol(of: expr), symbol.kind == .column, !keys.contains(symbol.key), !settled.contains(symbol.table?.lowercased() ?? "")
                    else { return }
                    offending.append(expr)
                    return
                }
                for child in expr.children { scan(child, &offending) }
            }
            var offending: [SQLExpr] = []
            for item in block.items {
                if item.alias.map({ grouped.contains($0.value.lowercased()) }) == true { continue }
                scan(item.expr, &offending)
            }
            if let having = block.having { scan(having, &offending) }
            for item in block.orderBy {
                if case .column = item.expr.kind, aliases.contains(item.expr.name?.last.value.lowercased() ?? "") { continue }
                scan(item.expr, &offending)
            }
            let end = block.groupBy.last!.range.upperBound
            var seen = Set<Int>()
            for column in offending where seen.insert(column.range.lowerBound).inserted {
                let text = string(column.range)
                say("groupBy", column.range, "“\(text)” isn’t in GROUP BY or an aggregate: the server refuses this under ONLY_FULL_GROUP_BY",
                    fixes: [SQLFix("Add “\(text)” to GROUP BY", .edit([SQLEdit(range: end..<end, text: ", " + text)]))])
            }
        }

        func symbol(of expr: SQLExpr) -> SQLSymbol? {
            guard let name = expr.name else { return nil }
            return analysis.reference(at: name.last.range.lowerBound)?.symbol
        }

        /// Text without case or spaces: enough to see that two expressions are the same.
        func normal(_ range: Range<Int>) -> String {
            String(string(range).lowercased().filter { !$0.isWhitespace && $0 != "`" })
        }

        // MARK: Small ones

        mutating func redundantDirection(_ item: SQLOrderItem) {
            guard let direction = item.direction, direction.value.uppercased() == "ASC" else { return }
            let range = item.expr.range.upperBound..<direction.range.upperBound
            say("redundantCode", direction.range, "ASC is the default", fixes: [SQLFix("Remove ASC", .edit([SQLEdit(range: range, text: "")]))])
        }

        mutating func redundantAlias(_ item: SQLSelectItem) {
            guard let alias = item.alias, case .column = item.expr.kind, let name = item.expr.name, name.last.value == alias.value else { return }
            let range = item.expr.range.upperBound..<alias.range.upperBound
            say("redundantCode", alias.range, "The column is called this already", fixes: [SQLFix("Remove the Alias", .edit([SQLEdit(range: range, text: "")]))])
        }

        /// `'a' = 'a'`, `1 = 2`: the same whatever the row. `1 = 1` is left: people write it to line up the ANDs after it.
        mutating func constant(_ condition: SQLExpr) {
            var comparisons: [SQLExpr] = []
            condition.walk { if case .binary = $0.kind, ["=", "<>", "!="].contains($0.op), $0.children.count == 2 { comparisons.append($0) } }
            for comparison in comparisons {
                let left = comparison.children[0], right = comparison.children[1]
                guard case .literal = left.kind, case .literal = right.kind, left.op != "NULL", right.op != "NULL" else { continue }
                let same = normal(left.range) == normal(right.range)
                if same, left.op == "number" { continue }
                let verdict = same == (comparison.op == "=") ? "true" : "false"
                if !same, left.op != right.op { continue }  // '1' = 1 is up to the server's conversions
                say("constantCondition", comparison.range, "This is always \(verdict)")
            }
        }

        /// One pass over the names: CTEs nothing reads, and words the parser takes for names that MySQL 8 reserves.
        mutating func references() {
            let server = analysis.snapshot?.server, mysql8 = server?.flavour == .mysql && server?.atLeast(8) == true
            for reference in analysis.references {
                guard analysis.statement(at: reference.range.lowerBound)?.errors.isEmpty == true else { continue }
                if reference.isDeclaration, reference.symbol.kind == .cte, analysis.usages(of: reference.symbol).count == 1 {
                    say("unusedCTE", reference.range, "Nothing reads “\(reference.symbol.name)”")
                }
                let word = string(reference.range)
                if mysql8, SQLCompletion.mysql8Reserved.contains(word.uppercased()) {
                    say("reservedWord", reference.range, "“\(word)” is reserved in MySQL 8: put it in backticks",
                        fixes: [SQLFix("Quote “\(word)”", .edit([SQLEdit(range: reference.range, text: SQLQuote.identifier(word))]))])
                }
            }
        }

        // MARK: Writes

        mutating func write(_ write: SQLWrite, _ statement: SQLParsedStatement) {
            if statement.kind == .update || statement.kind == .delete {
                if write.whereClause == nil {
                    let reach = write.limit.isEmpty ? "every row" : "rows in no particular order"
                    say("noWhere", verbRange(statement), "\(statement.verb) without WHERE reaches \(reach)")
                }
                for ref in write.tables {
                    guard let join = ref.join, join.on == nil, join.using.isEmpty, !join.natural, join.kind != "CROSS JOIN" else { continue }
                    say("joinWithoutOn", join.range, "\(join.kind) without ON pairs every row with every row")
                }
                aliases(write.tables)
            }
            if statement.kind == .insert || statement.kind == .replace { insert(write, statement) }
            for condition in [write.whereClause].compactMap({ $0 }) { constant(condition) }
            for item in write.orderBy { redundantDirection(item) }
        }

        mutating func insert(_ write: SQLWrite, _ statement: SQLParsedStatement) {
            let table = write.tables.first.flatMap { ref -> SQLRowSource? in
                analysis.scope(at: statement.range.lowerBound)?.sources.first { $0.range == ref.range }
            }
            // Without a list a row fills the table's visible columns, generated ones included.
            let names = write.columns.map(\.value)
            let expected = write.columnsRange != nil ? names.count : table.flatMap { $0.complete ? $0.columns.filter { $0.schema?.invisible != true }.count : nil }
            for row in write.rows {
                if let expected, row.values.count != expected, !(row.values.isEmpty && (write.columnsRange == nil || names.isEmpty)) {
                    say("insertCount", row.range, "\(row.values.count) value\(row.values.count == 1 ? "" : "s") for \(expected) column\(expected == 1 ? "" : "s")")
                }
                guard let table, table.complete else { continue }
                let columns = write.columnsRange != nil ? names.map { table.has($0) } : table.columns.filter { $0.schema?.invisible != true }.map { Optional($0) }
                for (value, column) in zip(row.values, columns) {
                    guard let schema = column?.schema else { continue }
                    let text = string(value.range).uppercased()
                    if text == "NULL", !schema.nullable, !schema.autoIncrement, schema.generated == nil, schema.dataType.lowercased() != "timestamp" {
                        say("nullIntoNotNull", value.range, "“\(schema.name)” is NOT NULL")
                    }
                    if schema.generated != nil, text != "DEFAULT" {
                        say("generatedColumn", value.range, "“\(schema.name)” is generated: only DEFAULT is allowed here",
                            fixes: [SQLFix("Change to DEFAULT", .edit([SQLEdit(range: value.range, text: "DEFAULT")]))])
                    }
                }
            }
        }
    }
}

extension SQLSelect {
    /// Every expression of the block itself, not those in the queries of its FROM.
    var expressions: [SQLExpr] {
        var all = items.map(\.expr) + rows.flatMap { $0 } + groupBy + windows + limit + orderBy.map(\.expr)
        all += [whereClause, having].compactMap { $0 } + from.compactMap(\.join?.on) + from.flatMap(\.expressions)
        return all
    }
}

extension SQLParsedStatement {
    /// Expressions of the statement outside any query: a write's and CALL's.
    var expressions: [SQLExpr] {
        var all = arguments
        if let write {
            all += write.rows.flatMap(\.values) + write.assignments.map(\.value) + write.onDuplicate.map(\.value) + write.orderBy.map(\.expr) + write.limit
            all += write.returning.map(\.expr) + [write.whereClause].compactMap { $0 } + write.tables.compactMap(\.join?.on)
        }
        return all
    }

    /// Every query in it, however deep, outermost first.
    public var allQueries: [SQLQuery] {
        var found: [SQLQuery] = []
        func visit(_ expr: SQLExpr) { expr.walk { if let query = $0.query { add(query) } } }
        func add(_ query: SQLQuery) {
            found.append(query)
            query.ctes.forEach { add($0.query) }
            query.orderBy.forEach { visit($0.expr) }
            for block in query.blocks {
                if let nested = block.nested { add(nested) }
                block.from.compactMap(\.query).forEach(add)
                block.expressions.forEach(visit)
            }
        }
        ctes.forEach { add($0.query) }
        if let query { add(query) }
        write?.tables.compactMap(\.query).forEach(add)
        expressions.forEach(visit)
        return found
    }
}
